import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' hide Material;
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'example_overlay.dart';
import 'example_chrome.dart' show galleryVrControlsHelp;
import 'example_settings.dart';

const _disableShadows = bool.fromEnvironment(
  'FLUTTER_SCENE_OPENXR_DISABLE_SHADOWS',
);
const _vrShadowsEnabled =
    bool.fromEnvironment(
      'FLUTTER_SCENE_OPENXR_ENABLE_SHADOWS',
      defaultValue: true,
    ) &&
    !_disableShadows;

/// The original Quest demo is a normal gallery entry in flat and VR modes.
class ExampleVr extends StatefulWidget {
  const ExampleVr({super.key});

  @override
  State<ExampleVr> createState() => _ExampleVrState();
}

class _ExampleVrState extends State<ExampleVr> {
  late final Scene _scene = _createVrScene();

  void _setShadows(bool? enabled) {
    final light = _scene.directionalLight;
    if (enabled == null || light == null) return;
    // Change the existing light; keep the scene, camera and animation alive.
    setState(() {
      light.castsShadow = enabled;
      exampleSettings.lightCastsShadow = enabled;
      rememberCustomGraphics();
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      SceneView(
        _scene,
        onTick: (_, _) => exampleSettings.applyTo(_scene),
        camera: PerspectiveCamera(
          position: vm.Vector3.zero(),
          target: vm.Vector3(0, 0, -4),
          fovNear: 0.04,
          fovFar: 100,
        ),
      ),
      ExampleOverlay.bottomLeftPanel(
        child: Card(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'VR example',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                CheckboxListTile(
                  key: const ValueKey('vr-shadows'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Enable shadows'),
                  value: _scene.directionalLight?.castsShadow ?? false,
                  onChanged: _setShadows,
                ),
                const Divider(),
                const ExpansionTile(
                  key: PageStorageKey('vr-example-help'),
                  tilePadding: EdgeInsets.zero,
                  title: Text('Quest controls'),
                  children: [
                    Text(
                      galleryVrControlsHelp,
                      style: TextStyle(fontSize: 18, height: 1.4),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

// Camera navigation belongs to the presentation rig, never to this content.
Scene _createVrScene() {
  final scene = Scene()
    // Preserve the original direct demo's FXAA baseline in both presentations.
    ..antiAliasingMode =
        const bool.fromEnvironment('FLUTTER_SCENE_OPENXR_DISABLE_AA')
        ? AntiAliasingMode.none
        : AntiAliasingMode.fxaa
    ..environmentIntensity = 0.35
    ..exposure = 1.1
    ..directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.5, -1, -0.35),
      color: vm.Vector3(1, 0.94, 0.84),
      intensity: 3.4,
      // Build flags choose the initial value; the example checkbox can change
      // it at runtime without rebuilding the APK or restarting the scene.
      castsShadow: _vrShadowsEnabled,
      shadowCascadeCount: 1,
      shadowMaxDistance: 16,
      shadowMapResolution: 512,
      // Restore the original demo's soft filtered edges and front-face casters.
      // The hard-shadow diagnostic preset exposed the map's square texels.
      shadowSoftness: 0.12,
      shadowFilter: DirectionalShadowFilter.rotatedPoisson,
      shadowCasterFaces: ShadowCasterFaces.front,
    );

  final stage = Node(name: 'VR demo stage')
    ..add(_shadowReceivingFloor())
    ..add(_grid())
    ..add(_cube())
    ..add(_sphere())
    ..add(_cylinder())
    ..add(_spinningTorus())
    ..add(_pointLight());
  scene.add(stage);
  return scene;
}

Node _shadowReceivingFloor() {
  final floor = Node(
    name: 'shadow receiving floor',
    mesh: Mesh(
      PlaneGeometry(width: 18, depth: 18),
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.11, 0.14, 0.19, 1)
        ..metallicFactor = 0
        ..roughnessFactor = 0.92,
    ),
    localTransform: vm.Matrix4.translation(vm.Vector3(0, -1.6, -4.5)),
  );

  // The plane receives scene shadows through its lit material. Excluding it
  // from the shadow map avoids spending work on a surface below all casters.
  floor.castsShadows = false;
  return floor;
}

Node _grid() {
  final positions = <double>[];
  const halfWidth = 6;
  const nearZ = 1;
  const farZ = -11;
  for (var line = -halfWidth; line <= halfWidth; line++) {
    positions.addAll([
      line.toDouble(),
      -1.585,
      nearZ.toDouble(),
      line.toDouble(),
      -1.585,
      farZ.toDouble(),
    ]);
  }
  for (var z = nearZ; z >= farZ; z--) {
    positions.addAll([
      -halfWidth.toDouble(),
      -1.585,
      z.toDouble(),
      halfWidth.toDouble(),
      -1.585,
      z.toDouble(),
    ]);
  }

  return Node(
    name: 'grid',
    mesh: Mesh(
      LineSegmentsGeometry(
        LineSegmentData(positions: Float32List.fromList(positions)),
        width: 0.012,
      ),
      UnlitMaterial()..baseColorFactor = vm.Vector4(0.12, 0.55, 0.75, 0.72),
    ),
  )..castsShadows = false;
}

Node _cube() {
  return Node(
    name: 'cube',
    mesh: Mesh(
      CuboidGeometry(vm.Vector3(0.9, 0.9, 0.9)),
      _material(vm.Vector4(0.16, 0.55, 0.95, 1), metallic: 0.25),
    ),
    localTransform: vm.Matrix4.translation(vm.Vector3(-1.35, -1.13, -3.45)),
  )..shadowStatic = true;
}

Node _sphere() {
  return Node(
    name: 'sphere',
    mesh: Mesh(
      SphereGeometry(radius: 0.56),
      _material(vm.Vector4(0.95, 0.32, 0.25, 1), roughness: 0.3),
    ),
    localTransform: vm.Matrix4.translation(vm.Vector3(0, -1.03, -3.15)),
  )..shadowStatic = true;
}

Node _cylinder() {
  return Node(
    name: 'cylinder',
    mesh: Mesh(
      CylinderGeometry(bottomRadius: 0.48, topRadius: 0.32, height: 1.15),
      _material(vm.Vector4(0.2, 0.82, 0.55, 1), metallic: 0.1),
    ),
    localTransform: vm.Matrix4.translation(vm.Vector3(1.35, -1.02, -3.65)),
  )..shadowStatic = true;
}

Node _spinningTorus() {
  final node = Node(
    name: 'torus',
    mesh: Mesh(
      TorusGeometry(radius: 0.48, tubeRadius: 0.14),
      _material(
        vm.Vector4(0.96, 0.69, 0.18, 1),
        metallic: 0.7,
        roughness: 0.22,
      ),
    ),
    localTransform: vm.Matrix4.translation(vm.Vector3(0, 0.25, -4.2)),
  );
  node.addComponent(_ElapsedTorusRotation());
  return node;
}

Node _pointLight() {
  final light = Node(
    name: 'warm fill light',
    localTransform: vm.Matrix4.translation(vm.Vector3(-1.8, 1.5, -2.5)),
  );
  light.addComponent(
    PointLightComponent(
      PointLight(color: vm.Vector3(0.35, 0.62, 1), intensity: 10, range: 7),
    ),
  );
  return light;
}

PhysicallyBasedMaterial _material(
  vm.Vector4 color, {
  double metallic = 0,
  double roughness = 0.42,
}) {
  return PhysicallyBasedMaterial()
    ..baseColorFactor = color
    ..metallicFactor = metallic
    ..roughnessFactor = roughness;
}

class _ElapsedTorusRotation extends Component {
  double _angle = 0;

  @override
  void update(double deltaSeconds) {
    _angle = (_angle + deltaSeconds * 0.4) % (math.pi * 2);
    node.rotation =
        vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), _angle) *
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi * 0.5);
  }
}

ExampleSettings vrExampleSettings() => ExampleSettings()
  ..antiAliasingMode =
      const bool.fromEnvironment('FLUTTER_SCENE_OPENXR_DISABLE_AA')
      ? AntiAliasingMode.none
      : AntiAliasingMode.fxaa
  ..environmentIntensity = 0.35
  ..exposure = 1.1
  ..lightAzimuthDegrees = math.atan2(-0.35, -0.5) * 180 / math.pi
  ..lightElevationDegrees =
      math.atan2(1, math.sqrt(0.5 * 0.5 + 0.35 * 0.35)) * 180 / math.pi
  ..lightColor.setValues(1, 0.94, 0.84)
  ..lightIntensity = 3.4
  ..lightCastsShadow = _vrShadowsEnabled
  ..shadowCascadeCount = 1
  ..shadowMaxDistance = 16
  ..shadowMapResolution = 512
  ..shadowSoftness = 0.12;
