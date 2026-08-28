import 'package:example_app/example_car.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart'
    show
        AmbientOcclusionMethod,
        DepthOfFieldQuality,
        ShadowCasterFaces,
        SpecularAmbientOcclusionMode;
import 'package:flutter_scene_rapier/flutter_scene_rapier.dart'
    show RapierWorld;
import 'package:flutter_scene_box3d/flutter_scene_box3d.dart'
    show Box3dPhysicsWorld;
import 'package:example_app/example_animation.dart';
import 'example_area_lights.dart';
import 'example_vr.dart';
import 'example_reflection_probes.dart';

import 'example_accessibility.dart';
import 'example_audio.dart';
import 'example_auto_exposure.dart';
import 'example_cloth.dart';
import 'example_configurator.dart';
import 'example_dicom.dart';
import 'example_kit.dart';
import 'example_lights.dart';
import 'example_spot_shadow.dart';
import 'example_fscene.dart';
import 'example_fscene_animated.dart';
import 'example_fscene_import.dart';
import 'example_fscene_prefab.dart';
import 'example_fscene_stream.dart';
import 'example_lod.dart';
import 'example_logo.dart';
import 'example_materialize.dart';
import 'example_multiplayer.dart';
import 'example_nav_route.dart';
import 'example_physics.dart';
import 'example_physics_box3d.dart';
import 'example_physics_car.dart';
import 'example_render_target.dart';
import 'example_settings.dart';
import 'example_shapes.dart';
import 'example_explosion.dart';
import 'example_external_texture.dart';
import 'example_particles.dart';
import 'example_planar_mirror.dart';
import 'example_splats.dart';
import 'example_skybox.dart';
import 'example_ssr.dart';
import 'example_widget_inset.dart';
import 'example_widget_texture.dart';
import 'example_split_screen.dart';
import 'example_stress_tests.dart';
import 'example_raw_shader.dart';
import 'example_toon.dart';
import 'example_toon_fmat.dart';
import 'example_vertex_curve.dart';

/// Per-example overrides of the stock [ExampleSettings] defaults, keyed by
/// the example's name in the picker. Examples not listed start from the
/// stock defaults. Every example gets its own fresh instance either way
/// (see [resetExampleSettings]), so tuning one scene never leaks into
/// another.
final Map<String, ExampleSettings Function()> settingsDefaults = {
  'VR': vrExampleSettings,
  // The campfire's night look: a soft blue moonlight key from the south,
  // ambient occlusion grounding the logs, rocks, and grass, and a warm
  // saturated grade that leans into the firelight.
  'Particles': () => ExampleSettings()
    ..lightAzimuthDegrees = 190.70
    ..lightElevationDegrees = 16.79
    ..lightIntensity = 0.97
    ..lightColor.setValues(1.0, 0.80, 1.0)
    ..ambientOcclusion.enabled = true
    ..ambientOcclusion.halfResolution = true
    ..ambientOcclusion.radius = 0.66
    ..ambientOcclusion.intensity = 1.01
    ..ambientOcclusion.bias = 0.053
    ..ambientOcclusion.sampleCount = 17
    ..colorGrading.enabled = true
    ..colorGrading.brightness = 1.39
    ..colorGrading.contrast = 0.93
    ..colorGrading.saturation = 1.36
    ..colorGrading.temperature = 0.35
    ..colorGrading.tint = -0.31
    ..bloom.enabled = true
    ..bloom.threshold = 3.63
    ..bloom.intensity = 0.089
    ..bloom.scatter = 1.0
    ..godRays.enabled = true
    ..godRays.intensity = 1.24
    ..godRays.density = 0.63
    ..godRays.anisotropy = 0.40
    ..godRays.stepCount = 5
    ..godRays.maxDistance = 141.70
    ..godRays.jitter = 1.0
    ..godRays.color.setValues(0.77, 0.90, 1.0)
    ..depthOfField.enabled = true
    ..depthOfField.focusDistance = 7.07
    ..depthOfField.fStop = 8.98
    ..depthOfField.focalLength = 0.178
    ..depthOfField.blurScale = 1.0
    ..depthOfField.quality = DepthOfFieldQuality.medium
    ..chromaticAberration.enabled = true
    ..chromaticAberration.intensity = 0.151
    ..vignette.enabled = true
    ..vignette.intensity = 0.71
    ..vignette.radius = 0.71
    ..vignette.smoothness = 0.5,
  // The car's showroom look, a softened key with contact shadows, ground-truth
  // occlusion carrying bounce light into the arches, a cool contrasty grade,
  // and a wide-open lens flaring off the bodywork highlights. Chromatic
  // aberration and god rays are tuned but left switched off, so turning either
  // back on picks up where it was rather than at the stock value.
  'Car': () => ExampleSettings()
    ..lightIntensity = 2.043
    ..shadowSoftness = 0.053
    ..contactShadows = true
    ..exposure = 1.954
    ..environmentIntensity = 1.022
    ..ambientOcclusion.enabled = true
    ..ambientOcclusion.method = AmbientOcclusionMethod.groundTruth
    ..ambientOcclusion.visibilityBitmask = true
    ..ambientOcclusion.thickness = 0.338
    ..ambientOcclusion.multiBounce = 0.611
    ..ambientOcclusion.indirectLight = 7.148
    ..ambientOcclusion.specularMode = SpecularAmbientOcclusionMode.simple
    ..colorGrading.enabled = true
    ..colorGrading.brightness = 1.007
    ..colorGrading.contrast = 1.203
    ..colorGrading.saturation = 1.110
    ..colorGrading.temperature = -0.118
    ..colorGrading.tint = -0.161
    ..bloom.enabled = true
    ..bloom.threshold = 0.876
    ..bloom.intensity = 0.191
    ..bloom.lensFlare.enabled = true
    ..bloom.lensFlare.intensity = 0.300
    ..bloom.lensFlare.ghostCount = 5
    ..depthOfField.enabled = true
    ..depthOfField.focusDistance = 7.94
    ..depthOfField.fStop = 0.7
    ..depthOfField.focalLength = 0.077
    ..depthOfField.quality = DepthOfFieldQuality.high
    ..vignette.enabled = true
    ..chromaticAberration.intensity = 0.132
    ..godRays.density = 1.764
    ..godRays.anisotropy = 0.506
    ..autoExposure.strength = 0.663
    ..autoExposure.compensation = 1.265
    ..autoExposure.minEv = -4.455
    ..autoExposure.maxEv = 2.499
    ..autoExposure.speedDown = 0.1,
  // The cloth corridor is one-sided open sheets, which only cast a shadow when
  // the shadow pass keeps both faces.
  'Physics': () =>
      ExampleSettings()..shadowCasterFaces = ShadowCasterFaces.both,
  // Same for the cloth example, plus occlusion to ground the folds where they
  // stack.
  'Cloth': () => ExampleSettings()
    ..shadowCasterFaces = ShadowCasterFaces.both
    ..ambientOcclusion.enabled = true
    ..ambientOcclusion.radius = 0.35
    ..ambientOcclusion.intensity = 1.4,
  // A strong sun for the adaptation walk: the outdoor half of the path
  // should overexpose while the meter is adapted to the room.
  'Auto Exposure': () => ExampleSettings()..lightIntensity = 7.0,
  'Stress Tests': () => ExampleSettings()..directionalLightEnabled = false,
  // A cinematic grade for the dark materialize stage: no key light (the
  // effect's own emissives and the environment carry it), bloom for the hot
  // seam and shard glows, and a subtle lens treatment.
  'Materialize (.fmat)': () => ExampleSettings()
    ..directionalLightEnabled = false
    ..colorGrading.enabled = true
    ..colorGrading.brightness = 1.05
    ..colorGrading.contrast = 1.19
    ..colorGrading.saturation = 1.16
    ..colorGrading.temperature = -0.20
    ..colorGrading.tint = 0.01
    ..bloom.enabled = true
    ..bloom.intensity = 0.06
    ..chromaticAberration.enabled = true
    ..chromaticAberration.intensity = 0.14
    ..vignette.enabled = true,
  // The Menger sky's look: no key light (the sky's emitters and the baked
  // environment carry it), a bright cool saturated grade, bloom for the neon
  // bracing, and a lens treatment.
  'Custom Skybox': () => ExampleSettings()
    ..directionalLightEnabled = false
    ..colorGrading.enabled = true
    ..colorGrading.brightness = 1.15
    ..colorGrading.contrast = 1.07
    ..colorGrading.saturation = 1.19
    ..colorGrading.temperature = -0.37
    ..colorGrading.tint = -0.05
    ..bloom.enabled = true
    ..bloom.threshold = 1.35
    ..chromaticAberration.enabled = true
    ..chromaticAberration.intensity = 0.32
    ..vignette.enabled = true,
};

// One registry for the desktop gallery and the Quest host.
// Keep widgets as widgets: they own scene loading, controls and simulation.
Map<String, WidgetBuilder> galleryExamples() {
  final physicsReady = RapierWorld.ensureInitialized();
  final box3dReady = Box3dPhysicsWorld.ensureInitialized();
  return {
    'VR': (context) => const ExampleVr(),
    'Car': (context) => const ExampleCar(),
    'Animation': (context) => const ExampleAnimation(),
    'Flutter Logo': (context) => const ExampleLogo(),
    'Multiplayer': (context) => const ExampleMultiplayer(),
    'Configurator': (context) => const ExampleConfigurator(),
    'Lights': (context) => const ExampleLights(),
    'Area Lights': (context) => const ExampleAreaLights(),
    'Reflection Probes': (context) => const ExampleReflectionProbes(),
    'Planar Mirror': (context) => const ExamplePlanarMirror(),
    'Spot Shadow': (context) => const ExampleSpotShadow(),
    'Cloth': (context) => const ExampleCloth(),
    'Gameplay Kit': (context) => const ExampleKit(),
    'Particles': (context) => const ExampleParticles(),
    'Explosions': (context) => const ExampleExplosion(),
    'Gaussian Splats': (context) => const ExampleSplats(),
    'Geometry LOD': (context) => const ExampleLod(),
    'Screen-space Reflections': (context) => const ExampleSsr(),
    'Auto Exposure': (context) => const ExampleAutoExposure(),
    'Navigation Route': (context) => const ExampleNavRoute(),
    'Toon': (context) => const ExampleToon(),
    'Raw shader': (context) => const ExampleRawShader(),
    'Toon (.fmat)': (context) => const ExampleToonFmat(),
    'Custom vertices (.fmat)': (context) => const ExampleVertexCurve(),
    'Materialize (.fmat)': (context) => const ExampleMaterialize(),
    'DICOM Volume': (context) => const ExampleDicom(),
    'Custom Skybox': (context) => const ExampleSkybox(),
    'Audio': (context) => const ExampleAudio(),
    'Widget Texture': (context) => const ExampleWidgetTexture(),
    'Widget Input (inset view)': (context) => const ExampleWidgetInset(),
    'External Texture': (context) => const ExampleExternalTexture(),
    'Accessibility': (context) => const ExampleAccessibility(),
    'Render Targets': (context) => const ExampleRenderTarget(),
    'Physics': (context) => FutureBuilder<void>(
      // The Rapier backend needs its wasm module loaded before a world
      // can be built on the web; wait on it here so only this example
      // pays the cost.
      future: physicsReady,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Physics initialization failed: ${snapshot.error}'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return const ExamplePhysics();
      },
    ),
    'Physics (box3d)': (context) => FutureBuilder<void>(
      // The box3d backend readiness (a no-op on native; the wasm load on
      // the web) before a world can be built.
      future: box3dReady,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Physics initialization failed: ${snapshot.error}'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return const ExamplePhysicsBox3d();
      },
    ),
    'Car Physics': (context) => FutureBuilder<void>(
      // Shares the Rapier backend with the Physics example, so it waits on
      // the same wasm load before building its world.
      future: physicsReady,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Physics initialization failed: ${snapshot.error}'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return const ExamplePhysicsCar();
      },
    ),
    'Shapes': (context) => FutureBuilder<void>(
      // Shares the Rapier backend with the Physics example, so it waits on
      // the same wasm load before building its world.
      future: physicsReady,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Physics initialization failed: ${snapshot.error}'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return const ExampleShapes();
      },
    ),
    'fscene': (context) => const ExampleFscene(),
    'fscene (import)': (context) => const ExampleFsceneImport(),
    'fscene (animated)': (context) => const ExampleFsceneAnimated(),
    'fscene (prefab)': (context) => const ExampleFscenePrefab(),
    'fscene (stream)': (context) => const ExampleFsceneStream(),
    'Split Screen': (context) => const ExampleSplitScreen(),
    'Stress Tests': (context) => const ExampleStressTests(),
  };
}
