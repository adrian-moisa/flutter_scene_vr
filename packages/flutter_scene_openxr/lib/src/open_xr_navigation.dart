import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'open_xr_frame.dart';

/// The small Visual Space stick contract: upright orbit about one persistent
/// target, then camera-relative travel that moves that target with the camera.
/// Tracking is composed below this rig and never replaced by stick input.
class OpenXrNavigation {
  vm.Vector3? _position;
  vm.Vector3? _target;
  double _yaw = 0;
  double _pitch = 0;

  void reset() {
    _position = _target = null;
  }

  vm.Matrix4 update(
    OpenXrFrame frame,
    Camera camera,
    vm.Matrix4 rig,
    double deltaSeconds,
  ) {
    if (_position == null) {
      _position = camera.position.clone();
      _target = camera is PerspectiveCamera
          ? camera.target.clone()
          : camera.position + camera.forward * 4;
      final forward = (_target! - _position!).normalized();
      _yaw = math.atan2(forward.x, -forward.z);
      _pitch = math.asin(forward.y.clamp(-1.0, 1.0));
    }
    final controls = frame.navigation ?? frame.controllers;
    final rotate = controls.leftThumbstick;
    final move = controls.rightThumbstick;
    if (deltaSeconds <= 0 || (rotate.length2 == 0 && move.length2 == 0)) {
      return rig;
    }
    // Match Visual Space's 42 degrees/s and 3 metres/s, including low FPS.
    final dt = deltaSeconds.clamp(0.0, 0.25);
    final before = _pose();
    final radius = (_target! - _position!).length;
    _yaw += rotate.x * 42 * math.pi / 180 * dt;
    if (rotate.y != 0) {
      _pitch = (_pitch + rotate.y * 42 * math.pi / 180 * dt).clamp(
        -75 * math.pi / 180,
        75 * math.pi / 180,
      );
    }
    final forward = _forward;
    _position = _target! - forward * radius;
    final right = vm.Vector3(math.cos(_yaw), 0, math.sin(_yaw));
    final movement = (right * move.x + forward * move.y) * (3 * dt);
    _position!.add(movement);
    _target!.add(movement);
    // Apply only the authored rig's movement delta to the tracked reference.
    // Replacing the rig with the navigation pose would erase the user's current
    // head offset and the initial alignment to the example's camera.
    return _pose() * vm.Matrix4.inverted(before) * rig;
  }

  vm.Vector3 get _forward => vm.Vector3(
    math.sin(_yaw) * math.cos(_pitch),
    math.sin(_pitch),
    -math.cos(_yaw) * math.cos(_pitch),
  );

  vm.Matrix4 _pose() {
    final forward = _forward;
    final right = vm.Vector3(math.cos(_yaw), 0, math.sin(_yaw));
    final up = right.cross(forward).normalized();
    return vm.Matrix4.columns(
      vm.Vector4(right.x, right.y, right.z, 0),
      vm.Vector4(up.x, up.y, up.z, 0),
      vm.Vector4(-forward.x, -forward.y, -forward.z, 0),
      vm.Vector4(_position!.x, _position!.y, _position!.z, 1),
    );
  }
}
