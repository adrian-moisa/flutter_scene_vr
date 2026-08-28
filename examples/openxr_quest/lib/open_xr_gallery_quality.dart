import 'package:flutter_scene/scene.dart';
// Diagnostics share the renderer's spot selection and atlas budget.
// This fork-local probe deliberately follows the renderer implementation.
// ignore: implementation_imports
import 'package:flutter_scene/src/render/spot_shadow.dart';

// Read what the active scene actually uses, not the gallery's mutable defaults.
String gallerySceneQuality(Scene scene, {bool immersive = true}) {
  final light = scene.renderScene.primaryDirectionalLight?.light;
  final directional = light != null && light.castsShadow;
  final spots = collectSpotShadows(
    scene.renderScene.spotLights.where((c) => _visible(c.node)).toList(),
  );
  final shadowDetails = directional
      ? '${light.shadowMapResolution}px/${light.shadowCascadeCount} cascades/${light.shadowFilter.name}'
      : 'off';
  final effects = <String>[
    if (scene.ambientOcclusion.enabled)
      'AO ${scene.ambientOcclusion.method.name}',
    if (scene.postProcess.bloom.enabled) 'Bloom',
    if (scene.depthOfField.enabled) 'DoF ${scene.depthOfField.quality.name}',
    if (scene.screenSpaceReflections.enabled) 'SSR',
    if (scene.globalIllumination.enabled) 'GI',
    if (scene.godRays.enabled) 'God rays',
    if (scene.fog.enabled) 'Fog',
    if (scene.autoExposure.enabled) 'Auto exposure',
    if (scene.postProcess.colorGrading.enabled) 'Grade',
    if (scene.postProcess.chromaticAberration.enabled) 'Chromatic aberration',
    if (scene.postProcess.vignette.enabled) 'Vignette',
    if (scene.postProcess.filmGrain.enabled) 'Grain',
  ];
  return 'AA ${scene.antiAliasingMode.name} → ${scene.effectiveAntiAliasingMode.name}; '
      '${immersive ? "resolution: native eye targets" : "scale ${scene.renderScale}"}; '
      'exposure ${scene.exposure.toStringAsFixed(2)}; environment ${scene.environmentIntensity.toStringAsFixed(2)}\n'
      'Selected shadows: directional $shadowDetails; spots ${spots?.casters.length ?? 0}'
      '${spots == null ? "" : " × ${spots.tileResolution}px"}\n'
      '${effects.isEmpty ? "Listed post effects disabled" : effects.join(" · ")}; '
      'custom effects ${scene.postProcess.customEffects.length}; auxiliary targets ${scene.views.where((view) => view.target != null).length}';
}

bool gallerySceneShadows(Scene? scene) =>
    scene != null &&
    ((scene.renderScene.primaryDirectionalLight?.light.castsShadow ?? false) ||
        scene.renderScene.spotLights.any(
          (c) => c.light.castsShadow && _visible(c.node),
        ));

bool _visible(Node node) {
  for (Node? ancestor = node; ancestor != null; ancestor = ancestor.parent) {
    if (!ancestor.visible) return false;
  }
  return true;
}
