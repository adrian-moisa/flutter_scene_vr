import 'package:example_app/example_chrome.dart' show galleryBackgroundColor;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

// Owns only the direct presentation of a gallery SceneView. The example keeps
// ownership of authored contents and callbacks; no second SceneView is built.
class OpenXrGalleryScene extends StatefulWidget {
  const OpenXrGalleryScene({
    required this.view,
    required this.scene,
    required this.tick,
    required this.ready,
    required this.onFrame,
    required this.onError,
    required this.onRenderer,
    super.key,
  });
  final SceneView view;
  final Scene scene;
  final SceneTickCallback tick;
  final bool ready;
  final void Function(Scene scene, Duration elapsed, double delta) onFrame;
  final void Function(Object error, StackTrace stack) onError;
  final void Function(OpenXrDirectEyeRenderer? renderer) onRenderer;

  @override
  State<OpenXrGalleryScene> createState() => _OpenXrGallerySceneState();
}

class _OpenXrGallerySceneState extends State<OpenXrGalleryScene> {
  late final OpenXrDirectEyeRenderer _renderer;
  late final Future<void> Function(int, int, int) _renderCallback;
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _renderer = OpenXrDirectEyeRenderer(
      scene: widget.scene,
      backgroundColor: galleryBackgroundColor,
      controllerNavigation: true,
      showControllerRays: true,
      antiAliasingMode:
          null, // Inherit the actual example, including automatic MSAA.
      referenceCamera: (elapsed) =>
          widget.view.camera ??
          widget.view.cameraBuilder?.call(elapsed) ??
          widget.scene.camera ??
          PerspectiveCamera(),
      onTick: (elapsed, delta) {
        widget.tick(elapsed, delta);
        widget.onFrame(widget.scene, elapsed, delta);
      },
    );
    _renderCallback = (left, right, sequence) async {
      try {
        await _renderer.render(left, right, sequence);
      } catch (error, stack) {
        _detach();
        widget.onError(error, stack);
        rethrow;
      }
    };
  }

  void _detach() {
    if (!_attached) return;
    _attached = false;
    OpenXrSession.instance.detachExternalEyeRenderer(_renderCallback);
    widget.onRenderer(null);
  }

  @override
  void deactivate() {
    _detach();
    super.deactivate();
  }

  @override
  void dispose() {
    _detach();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ready && !_attached) {
      _attached = true;
      OpenXrSession.instance.attachExternalEyeRenderer(_renderCallback);
      widget.onRenderer(_renderer);
    }
    if (!widget.ready) {
      _detach();
      return widget.view.loadingBuilder?.call(context, 0) ??
          const SizedBox.expand();
    }
    // Geometry goes directly to the eye swapchains. This space is only the
    // example's retained Flutter controls and must never paint a flat viewport.
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: const SizedBox.expand(),
    );
  }
}
