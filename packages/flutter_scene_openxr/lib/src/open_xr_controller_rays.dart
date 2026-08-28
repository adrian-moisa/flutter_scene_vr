import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'open_xr_controller_state.dart';

/// Small aim hints owned by the direct renderer, with no Flutter UI dependency.
/// The tip marks a fixed beam length, not an interaction or surface hit.
class OpenXrControllerRays {
  OpenXrControllerRays(this.scene) {
    final beam = CylinderGeometry(
      bottomRadius: 0.0015,
      topRadius: 0.0015,
      height: _length,
      radialSegments: 6,
    );
    final tip = SphereGeometry(radius: 0.006, segments: 8, rings: 4);
    for (var hand = 0; hand < 2; hand++) {
      final material = UnlitMaterial()..baseColorFactor = _colors[hand];
      final aim = Node(name: 'xr-controller-aim-$hand')..visible = false;
      aim.addAll([
        Node(
            name: 'xr-controller-beam-$hand',
            mesh: Mesh(beam, material),
            localTransform: vm.Matrix4.translationValues(0, 0, -_length / 2)
              ..rotateX(-math.pi / 2),
          )
          ..castsShadows = false
          ..raycastable = false,
        Node(
            name: 'xr-controller-tip-$hand',
            mesh: Mesh(tip, material),
            localTransform: vm.Matrix4.translationValues(0, 0, -_length),
          )
          ..castsShadows = false
          ..raycastable = false,
      ]);
      _materials.add(material);
      _aims.add(aim);
      _root.add(aim);
    }
  }

  static const _length = 1.5;
  static final _colors = [
    vm.Vector4(0.12, 0.8, 1, 1),
    vm.Vector4(0.7, 0.45, 1, 1),
  ];
  static final _pressedColor = vm.Vector4.all(1);
  final Scene scene;
  final _root = Node(name: 'xr-controller-rays');
  final _aims = <Node>[];
  final _materials = <UnlitMaterial>[];

  /// Called on the native XR frame clock, including while widget frames pause.
  void update(
    OpenXrControllerState controllers,
    vm.Matrix4? worldFromReference,
  ) {
    // Some examples replace their scene children when an asset finishes loading.
    if (_root.parent == null) scene.add(_root);
    _root.localTransform = worldFromReference ?? vm.Matrix4.identity();
    for (var hand = 0; hand < _aims.length; hand++) {
      final aim = hand < controllers.aims.length
          ? controllers.aims[hand]
          : null;
      final node = _aims[hand];
      node.visible = aim != null && aim.tracked;
      if (aim == null || !aim.tracked) continue;
      // Matrix4.compose uses OpenXR's q * v * inverse(q) rotation convention.
      // Controller-local -Z is the aim direction, just like an eye's forward.
      node.localTransform = vm.Matrix4.compose(
        aim.position,
        aim.orientation,
        vm.Vector3.all(1),
      );
      _materials[hand].baseColorFactor = aim.trigger > 0.5
          ? _pressedColor
          : _colors[hand];
    }
  }

  void dispose() => _root.parent?.remove(_root);
}
