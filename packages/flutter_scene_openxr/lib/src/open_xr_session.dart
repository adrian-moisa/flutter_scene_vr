import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;

import 'open_xr_frame.dart';
import 'open_xr_composition_quad_configuration.dart';
import 'open_xr_native_performance_sample.dart';

/// Owns the small platform contract between a Dart renderer and Android OpenXR.
class OpenXrSession {
  OpenXrSession._();

  static final OpenXrSession instance = OpenXrSession._();
  static const MethodChannel _channel = MethodChannel(
    'dev.bdero.flutter_scene_openxr/session',
  );

  OpenXrFrame _latestFrame = OpenXrFrame.preview();
  final ValueNotifier<OpenXrNativePerformanceSample> _nativePerformance =
      ValueNotifier(const OpenXrNativePerformanceSample.zero());
  Future<void> Function(
    int leftSurfaceIdentifier,
    int rightSurfaceIdentifier,
    int sequence,
  )?
  _externalStereoRenderer;

  final ValueNotifier<OpenXrFrame> frames = ValueNotifier(
    OpenXrFrame.preview(),
  );
  int _performanceGeneration = 0;
  int _performanceResetRequest = 0;

  Future<String?> galleryInitialExample() =>
      _channel.invokeMethod<String>('galleryInitialExample');

  Future<void> gallerySelection(String name) =>
      _channel.invokeMethod<void>('gallerySelection', name);

  /// Recreates the eye targets between completed stereo frames. The UI atlas,
  /// camera rig, scene and OpenXR session remain alive. Failure retains the old pair.
  Future<double> setRenderScale(double scale) async {
    if (!scale.isFinite || scale < 0.5 || scale > 1.5) {
      throw ArgumentError.value(scale, 'scale', 'Expected 0.5 through 1.5');
    }
    final result = await _channel.invokeMapMethod<String, num>(
      'setRenderScale',
      scale,
    );
    if (result == null) {
      throw StateError('Missing native resolution acknowledgement');
    }
    return result['scale']!.toDouble();
  }

  Future<void> resetPanels() => _channel.invokeMethod<void>('resetPanels');

  Future<void> exitImmersive() => _channel.invokeMethod<void>('exitImmersive');

  Future<void> resetPerformance() async {
    // Ignore both queued old samples and an older reset's delayed reply.
    // Otherwise the newly selected example could display its predecessor's costs.
    final request = ++_performanceResetRequest;
    _performanceGeneration = -1;
    _nativePerformance.value = const OpenXrNativePerformanceSample.zero();
    final generation =
        await _channel.invokeMethod<int>('resetPerformance') ?? 0;
    if (request == _performanceResetRequest) {
      _performanceGeneration = generation;
    }
  }

  Future<String?> enterGallery({
    required String example,
    required OpenXrCompositionQuadConfiguration compositionQuad,
  }) => _channel.invokeMethod<String>('enterImmersive', {
    'dartEntrypoint': 'openXrMain',
    'dartLibraryUri': 'package:openxr_quest/open_xr_main.dart',
    'example': example,
    'awaitExit': true,
    'compositionQuad': compositionQuad.toPlatformArguments(),
  });

  OpenXrFrame get latestFrame => _latestFrame;

  ValueListenable<OpenXrNativePerformanceSample> get nativePerformance =>
      _nativePerformance;

  /// Returns whether the current Android device exposes an OpenXR runtime.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isOpenXrAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Launches the native immersive activity and its offscreen Dart renderer.
  Future<void> enterImmersive({
    required String dartEntrypoint,
    required String dartLibraryUri,
    OpenXrCompositionQuadConfiguration? compositionQuad,
  }) {
    if (dartEntrypoint.isEmpty || dartLibraryUri.isEmpty) {
      throw ArgumentError('The Dart entrypoint and library URI are required.');
    }

    return _channel.invokeMethod<void>('enterImmersive', {
      'dartEntrypoint': dartEntrypoint,
      'dartLibraryUri': dartLibraryUri,
      if (compositionQuad != null)
        'compositionQuad': compositionQuad.toPlatformArguments(),
    });
  }

  /// Connects the current Dart isolate to the tracked native eye-view stream.
  Future<void> attachToNativeViewStream() async {
    _channel.setMethodCallHandler((call) async {
      try {
        switch (call.method) {
          case 'viewsChanged':
            _latestFrame = OpenXrFrame.fromPlatform(call.arguments);
            frames.value = _latestFrame;
            return;
          case 'performanceChanged':
            final sample = OpenXrNativePerformanceSample.fromPlatform(
              call.arguments,
            );
            if (sample.generation == _performanceGeneration) {
              _nativePerformance.value = sample;
            }
            return;
          case 'renderExternalStereo':
            final values = call.arguments;
            if (values is! List || values.length != 3) {
              throw const FormatException(
                'Direct OpenXR stereo request must contain two surfaces and a sequence.',
              );
            }
            final renderer = _externalStereoRenderer;
            if (renderer == null) {
              // A native request may already be queued when an example is
              // detached. Return both unrendered leases through the GPU API;
              // throwing would recycle the surfaces and close the XR session.
              _discardExternalStereo(
                (values[0] as num).toInt(),
                (values[1] as num).toInt(),
              );
              return;
            }
            await renderer(
              (values[0] as num).toInt(),
              (values[1] as num).toInt(),
              (values[2] as num).toInt(),
            );
            return;
          default:
            throw MissingPluginException(
              'Unknown OpenXR method ${call.method}.',
            );
        }
      } on FormatException catch (error) {
        debugPrint('Ignored malformed OpenXR update: $error');
      }
    });
  }

  /// Attaches the renderer that consumes native-owned eye surface frames.
  void attachExternalEyeRenderer(
    Future<void> Function(
      int leftSurfaceIdentifier,
      int rightSurfaceIdentifier,
      int sequence,
    )
    renderer,
  ) {
    _externalStereoRenderer = renderer;
    unawaited(_reportExternalEyeRendererReady(true));
  }

  /// Detaches [renderer] without disturbing a replacement renderer.
  void detachExternalEyeRenderer(
    Future<void> Function(
      int leftSurfaceIdentifier,
      int rightSurfaceIdentifier,
      int sequence,
    )
    renderer,
  ) {
    if (identical(_externalStereoRenderer, renderer)) {
      _externalStereoRenderer = null;
      unawaited(_reportExternalEyeRendererReady(false));
    }
  }

  // Clearing the callback handles requests already queued in Dart.
  // The native acknowledgement also drains imported leases before the caller
  // unmounts a scene; merely removing its widget is not a GPU lifetime barrier.
  Future<void> suspendExternalEyeRenderer() {
    _externalStereoRenderer = null;
    return _reportExternalEyeRendererReady(false);
  }

  static void _discardExternalStereo(int leftIdentifier, int rightIdentifier) {
    gpu.GpuExternalSurfaceFrame? left;
    gpu.GpuExternalSurfaceFrame? right;
    try {
      left = gpu.gpuContext
          .openExternalSurface(leftIdentifier)
          .acquireNextFrame();
      right = gpu.gpuContext
          .openExternalSurface(rightIdentifier)
          .acquireNextFrame();
      if (left == null || right == null) {
        throw StateError('An offered OpenXR stereo frame is missing an eye.');
      }
    } finally {
      try {
        left?.discard();
      } finally {
        right?.discard();
      }
    }
  }

  Future<void> _reportExternalEyeRendererReady(bool ready) async {
    try {
      await _channel.invokeMethod<void>('directEyeRendererReady', ready);
    } on MissingPluginException {
      // Flat previews do not install the immersive engine channel.
    } on PlatformException {
      // Native teardown can race the renderer's final detach.
    }
  }

  /// Associates the next stereo surface buffer with the tracked frame used
  /// to render it.
  ///
  /// [OpenXrSceneView] calls this while resolving its views. The native host
  /// retains that frame's original poses when it submits the resulting
  /// texture, allowing the OpenXR compositor to reproject it correctly.
  Future<void> markFrameRendering(int sequence) async {
    if (sequence <= 0 ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('markFrameRendering', sequence);
    } on MissingPluginException {
      // A flat Android preview does not install the immersive engine channel.
    } on PlatformException {
      // Native teardown can race the final Flutter frame.
    }
  }
}
