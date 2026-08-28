import 'package:flutter/widgets.dart';

import '../scene.dart';
import '../camera.dart';
import 'scene_view.dart';

// Redirects a SceneView's presentation while retaining its scene, declarative
// children, loading gate and elapsed notifier. A host supplies the frame clock.
// Supplying present removes the flat painter/ticker; camera/decorateView alone
// retain normal flat rendering and its existing frame clock.
class SceneViewPresentation extends InheritedWidget {
  const SceneViewPresentation({
    this.present,
    this.camera,
    this.decorateView,
    this.onTick,
    this.onDetach,
    required super.child,
    super.key,
  });

  final Widget Function(
    BuildContext context,
    SceneView view,
    Scene scene,
    SceneTickCallback tick,
    bool ready,
  )?
  present;

  /// Optional host camera rig applied after the authored camera is resolved.
  final Camera Function(SceneView view, Scene scene, Camera authored)? camera;

  /// Wraps the flat viewport only, leaving example UI outside input handlers.
  final Widget Function(
    BuildContext context,
    SceneView view,
    Scene scene,
    Widget viewport,
  )?
  decorateView;

  // Stop host callbacks when this view changes scenes or unmounts.
  // Scene ownership remains with the existing widget/application; this hook
  // does not imply that native GPU work has finished using the scene's targets.
  final void Function(Scene scene)? onDetach;

  // Observes the normal flat ticker only.
  // A replacement presenter receives its own tick callback through present.
  final void Function(
    SceneView view,
    Scene scene,
    Duration elapsed,
    double deltaSeconds,
  )?
  onTick;

  static SceneViewPresentation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SceneViewPresentation>();

  @override
  bool updateShouldNotify(SceneViewPresentation oldWidget) =>
      camera != oldWidget.camera ||
      decorateView != oldWidget.decorateView ||
      present != oldWidget.present ||
      onTick != oldWidget.onTick ||
      onDetach != oldWidget.onDetach;
}
