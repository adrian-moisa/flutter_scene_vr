import 'dart:math' as math;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/material/shadow_catcher_material.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_scene/src/render/shadow_catcher_bake_pass.dart';
import 'package:flutter_scene/src/render/shadow_pass.dart';
import 'package:vector_math/vector_math.dart';

/// Rasterizes a fixed world region, then bakes its visibility on a receiver.
/// The caller owns invalidation and budgets; the view camera is never an input.
/// Existing depth shaders retain alpha cutouts, skinning and morph deformation.
class PlanarShadowBaker {
  final _pool = TransientTexturePool(framesInFlight: 2);

  void bake({
    required List<RenderItem> casters,
    required RenderItem receiver,
    required DirectionalLight light,
    required Vector3 center,
    required double radius,
    int resolution = 256,
  }) {
    final material = receiver.material;
    if (material is! ShadowCatcherMaterial) {
      throw ArgumentError('A planar bake requires a shadow catcher.');
    }
    final size = resolution.clamp(32, 1024);
    final direction = light.direction.normalized();
    final extent = math.max(.01, radius);
    final matrix = light.cascadeLightSpaceMatrix(direction, center, extent);
    final cascade = ShadowCascade(
      lightSpaceMatrix: matrix,
      splitDistance: 1e12,
      boxSize: extent * 2,
    );
    _pool.beginFrame();
    final depthMap = _pool.acquire(
      TransientTextureDescriptor.color(
        width: size,
        height: size,
        format: gpu.PixelFormat.r32Float,
        debugName: 'planar_shadow_depth',
      ),
    );
    final depth = _pool.acquire(
      TransientTextureDescriptor.depth(
        width: size,
        height: size,
        format: gpu.gpuContext.defaultDepthStencilFormat,
        debugName: 'planar_shadow_z',
      ),
    );
    final commands = gpu.gpuContext.createCommandBuffer();
    final pass = commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: depthMap, clearValue: Vector4.all(1)),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: depth,
          depthClearValue: 1,
        ),
      ),
    );
    final encoder = ShadowEncoder(
      pass,
      uniformTransients,
      matrix,
      center - direction * extent * 12,
      ShadowCasterFaces.both,
    );
    for (final item in casters) {
      encoder.submit(item);
    }
    encoder.flush();
    rendererSubmissions.submit(commands);
    final board = Blackboard()..set(kShadowMapBlackboardKey, depthMap);
    ShadowCatcherBakePass(
      items: [receiver],
      environmentMap: Material.getDefaultEnvironmentMap(),
      directionalLight: light,
      directionalLightDirection: direction,
      cascades: [cascade],
    ).execute(
      RenderGraphContext(
        transientsBuffer: uniformTransients,
        texturePool: _pool,
        blackboard: board,
      ),
    );
  }

  void clear() => _pool.clear();
}
