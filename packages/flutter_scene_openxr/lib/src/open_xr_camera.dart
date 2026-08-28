import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'open_xr_eye_view.dart';

/// Converts an OpenXR asymmetric field of view into Flutter Scene clip space.
class OpenXrProjection extends PerspectiveProjection {
  OpenXrProjection({
    required this.fieldOfView,
    this.mirrorForSurfaceTexture = true,
    super.near = 0.04,
    super.far = 100.0,
  }) : super(fovRadiansY: fieldOfView.angleUp - fieldOfView.angleDown);

  final OpenXrFieldOfView fieldOfView;

  /// Matches the eye camera's horizontal basis. Only the legacy
  /// SurfaceTexture presentation copy mirrors the rendered image afterward.
  final bool mirrorForSurfaceTexture;

  @override
  vm.Matrix4 getProjectionMatrix(double aspectRatio, {vm.Vector2? jitter}) {
    if (near <= 0 || far <= near) {
      throw ArgumentError('near must be positive and far must exceed near.');
    }

    final tangentLeft = math.tan(fieldOfView.angleLeft);
    final tangentRight = math.tan(fieldOfView.angleRight);
    final tangentDown = math.tan(fieldOfView.angleDown);
    final tangentUp = math.tan(fieldOfView.angleUp);
    final tangentWidth = tangentRight - tangentLeft;
    final tangentHeight = tangentUp - tangentDown;

    if (tangentWidth <= 0 || tangentHeight <= 0) {
      throw ArgumentError('OpenXR supplied a degenerate eye field of view.');
    }

    // With positive view-space Z, a direct eye's left/right boundary rays
    // must map to -1/+1: x_ndc = 2*tan(angle)/width - (right+left)/width.
    // The legacy camera negates view-space X, so it needs the opposite offset
    // before its final horizontal presentation mirror.
    final horizontalOffset =
        (mirrorForSurfaceTexture ? 1 : -1) *
            (tangentRight + tangentLeft) /
            tangentWidth +
        (jitter?.x ?? 0);
    final verticalOffset =
        -(tangentUp + tangentDown) / tangentHeight + (jitter?.y ?? 0);

    // Both paths retain Flutter Scene's positive-forward, zero-to-one depth.
    // The renderer accounts for camera reflection when choosing face winding;
    // direct swapchain rendering needs no presentation mirror or extra copy.
    return vm.Matrix4(
      2 / tangentWidth,
      0,
      0,
      0,
      0,
      2 / tangentHeight,
      0,
      0,
      horizontalOffset,
      verticalOffset,
      far / (far - near),
      1,
      0,
      0,
      -(far * near) / (far - near),
      0,
    );
  }
}

/// Presents an OpenXR eye pose through Flutter Scene's camera contract.
class OpenXrCamera extends Camera {
  OpenXrCamera({
    required OpenXrEyeView eye,
    double near = 0.04,
    double far = 100.0,
    this.mirrorForSurfaceTexture = true,
    vm.Matrix4? worldFromReference,
  }) : _worldFromReference = worldFromReference?.clone(),
       position =
           worldFromReference?.transformed3(eye.position) ??
           eye.position.clone(),
       _worldFromEyeOrientation = eye.orientation.conjugated().normalized(),
       projection = OpenXrProjection(
         fieldOfView: eye.fieldOfView,
         mirrorForSurfaceTexture: mirrorForSurfaceTexture,
         near: near,
         far: far,
       );

  /// Keeps the historical horizontally reversed view that the SurfaceTexture
  /// copy flips back before OpenXR submission. The direct basis instead keeps
  /// eye-local right/up and reflects Z into Flutter Scene's forward convention;
  /// geometry passes compensate for that reflection in their face winding.
  final bool mirrorForSurfaceTexture;

  // OpenXR quaternions rotate eye-local axes into reference space with
  // q * v * inverse(q). vector_math's rotated() uses the opposite order,
  // so conjugating once preserves the tracked pose instead of reversing it.
  final vm.Quaternion _worldFromEyeOrientation;
  final vm.Matrix4? _worldFromReference;

  @override
  final vm.Vector3 position;

  @override
  final OpenXrProjection projection;

  @override
  vm.Vector3 get forward => _referenceDirection(vm.Vector3(0, 0, -1));

  @override
  vm.Vector3 get up => _referenceDirection(vm.Vector3(0, 1, 0));

  vm.Vector3 _referenceDirection(vm.Vector3 axis) {
    final direction = _worldFromEyeOrientation.rotated(axis);
    _worldFromReference?.rotate3(direction);
    return direction.normalized();
  }

  @override
  vm.Matrix4 getViewMatrix() {
    final viewForward = forward;
    final viewUp = up;
    final right = mirrorForSurfaceTexture
        ? viewUp.cross(viewForward).normalized()
        : viewForward.cross(viewUp).normalized();
    final correctedUp = mirrorForSurfaceTexture
        ? viewForward.cross(right).normalized()
        : right.cross(viewForward).normalized();

    return vm.Matrix4(
      right.x,
      correctedUp.x,
      viewForward.x,
      0,
      right.y,
      correctedUp.y,
      viewForward.y,
      0,
      right.z,
      correctedUp.z,
      viewForward.z,
      0,
      -right.dot(position),
      -correctedUp.dot(position),
      -viewForward.dot(position),
      1,
    );
  }
}
