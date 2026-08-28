import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

import '../camera.dart';
import '../light.dart';
import '../scene_color_target.dart';
import '../shaders.dart';
import 'render_scene.dart';
import 'shadow_cache.dart';
import 'shadow_pass.dart';

/// One frame's shared stereo shadow inputs and produced atlas. The cache alone
/// survives the frame; captures and other groups never mutate its matrices.
class SharedShadowFrame {
  SharedShadowFrame({required this.cascades, required this.cache});

  final List<ShadowCascade> cascades;
  final DirectionalShadowCache? cache;
  final SharedShadowAtlas atlas = SharedShadowAtlas();
  List<ShadowCascade>? effectiveCascades;
}

/// Shadow depth shaders normally ignore the camera position. A material or
/// geometry vertex override can use it for displacement, so do not reuse those
/// casters' results for another eye. Built-in alpha masks remain shareable:
/// they use fixed material textures and the same geometry in both views.
({bool viewIndependent, bool hasStaticCasters}) inspectSharedShadowCasters(
  RenderScene scene,
) {
  final depthShader = baseShaderLibrary['UnskinnedDepthVertex'];
  final unskinnedShader = baseShaderLibrary['UnskinnedVertex'];
  final skinnedShader = baseShaderLibrary['SkinnedVertex'];
  var hasStaticCasters = false;
  for (final item in scene.items) {
    if (!item.visible || !item.castsShadows || !item.material.isOpaque()) {
      continue;
    }
    hasStaticCasters |= item.shadowStatic;
    final geometry = item.geometry;
    final depthVertex = item.material.depthAlphaMasked
        ? null
        : geometry.depthOnlyVertex;
    final variant = depthVertex == null
        ? geometry.materialVertexVariant
        : 'depth';
    if (item.material.materialVertexShader(variant) != null) {
      return (viewIndependent: false, hasStaticCasters: hasStaticCasters);
    }
    final shader = depthVertex?.shader ?? geometry.vertexShader;
    if (!identical(shader, depthShader) &&
        !identical(shader, unskinnedShader) &&
        !identical(shader, skinnedShader)) {
      return (viewIndependent: false, hasStaticCasters: hasStaticCasters);
    }
  }
  return (viewIndependent: true, hasStaticCasters: hasStaticCasters);
}

/// Returns null for incompatible lenses/layers. A shared cascade must have
/// identical view-depth split thresholds in every consuming eye.
List<ShadowCascade>? fitSharedShadowCascades(
  List<TargetedRenderView> views,
  DirectionalLight? light,
  Vector3? worldDirection,
) {
  final first = views.first;
  final projection = first.view.camera.projection;
  if (projection is! PerspectiveProjection) return null;
  for (final target in views) {
    final lens = target.view.camera.projection;
    if (lens is! PerspectiveProjection ||
        lens.near != projection.near ||
        target.view.layerMask != first.view.layerMask) {
      return null;
    }
  }
  if (light == null || !light.castsShadow) return const [];

  final firstTexture = first.colorTarget.colorTexture;
  // Preserve the existing practical split scheme, including a pinned first
  // split. Only coverage/matrices change when the same map serves both eyes.
  final splits = light.computeCascades(
    first.view.camera,
    firstTexture.width / firstTexture.height,
    worldDirection,
  );
  final lenses = <_ShadowEyeLens>[];
  for (final target in views) {
    final camera = target.view.camera;
    final texture = target.colorTarget.colorTexture;
    final inverseProjection = Matrix4.zero();
    if (inverseProjection.copyInverse(
          camera.projection.getProjectionMatrix(texture.width / texture.height),
        ) ==
        0) {
      return null;
    }
    var tangentRadiusSquared = 0.0;
    for (final x in const [-1.0, 1.0]) {
      for (final y in const [-1.0, 1.0]) {
        final corner = inverseProjection.transform(Vector4(x, y, 0, 1));
        // Ratios cancel homogeneous W. Unlike fov/aspect approximations this
        // includes an asymmetric OpenXR lens's principal-point offsets.
        if (corner.z == 0 || !corner.z.isFinite) return null;
        final tangentX = corner.x / corner.z;
        final tangentY = corner.y / corner.z;
        final radiusSquared = tangentX * tangentX + tangentY * tangentY;
        if (!radiusSquared.isFinite) return null;
        tangentRadiusSquared = math.max(tangentRadiusSquared, radiusSquared);
      }
    }
    lenses.add(_ShadowEyeLens(camera, tangentRadiusSquared));
  }

  final direction = (worldDirection ?? light.direction).clone();
  if (direction.length2 == 0) {
    direction.setValues(0, -1, 0);
  } else {
    direction.normalize();
  }
  final overlap = light.cascadeOverlap.clamp(0.0, 1.0);
  final result = <ShadowCascade>[];
  var sliceNear = projection.near;
  for (var index = 0; index < splits.length; index++) {
    final split = splits[index].splitDistance;
    final sliceFar = index < splits.length - 1
        ? split + (split - sliceNear) * overlap
        : split;
    Vector3? center;
    var radius = 0.0;
    for (final lens in lenses) {
      // A sphere centered on the eye axis enclosing the rectangular slice.
      // Its radius is invariant under rigid head rotation, including reflected
      // eye view bases, so normal head motion does not resize the atlas fit.
      final depth = math.min(
        sliceFar,
        (sliceNear + sliceFar) * (1 + lens.tangentRadiusSquared) * 0.5,
      );
      final eyeCenter = lens.camera.position + lens.camera.forward * depth;
      final eyeRadius = math.sqrt(
        math.max(
          (depth - sliceNear) * (depth - sliceNear) +
              sliceNear * sliceNear * lens.tangentRadiusSquared,
          (sliceFar - depth) * (sliceFar - depth) +
              sliceFar * sliceFar * lens.tangentRadiusSquared,
        ),
      );
      if (center == null) {
        center = eyeCenter;
        radius = eyeRadius;
        continue;
      }
      final delta = eyeCenter - center;
      final distance = delta.length;
      if (radius >= distance + eyeRadius) continue;
      if (eyeRadius >= distance + radius) {
        center = eyeCenter;
        radius = eyeRadius;
      } else {
        final unionRadius = (distance + radius + eyeRadius) * 0.5;
        center += delta * ((unionRadius - radius) / distance);
        radius = unionRadius;
      }
    }
    // Texel snapping can translate the projection by half a texel. Pad the
    // union by that amount so its outer eye corners remain inside the map.
    radius /= 1 - 1 / math.max(2, light.shadowMapResolution);
    result.add(
      ShadowCascade(
        lightSpaceMatrix: light.cascadeLightSpaceMatrix(
          direction,
          center!,
          radius,
        ),
        splitDistance: split,
        boxSize: radius * 2,
        center: center,
        radius: radius,
      ),
    );
    sliceNear = split;
  }
  return result;
}

class _ShadowEyeLens {
  _ShadowEyeLens(this.camera, this.tangentRadiusSquared);

  final Camera camera;
  final double tangentRadiusSquared;
}
