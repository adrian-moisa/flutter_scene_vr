import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';

import 'open_xr_camera.dart';
import 'open_xr_controller_rays.dart';
import 'open_xr_navigation.dart';
import 'open_xr_session.dart';

/// Renders native-owned eye frames without converting scene textures to images.
class OpenXrDirectEyeRenderer {
  OpenXrDirectEyeRenderer({
    required this.scene,
    OpenXrSession? session,
    this.antiAliasingMode = AntiAliasingMode.fxaa,
    this.onTick,
    this.referenceCamera,
    this.controllerNavigation = false,
    this.showControllerRays = false,
    this.backgroundColor,
  }) : session = session ?? OpenXrSession.instance;

  final Scene scene;
  final OpenXrSession session;
  final AntiAliasingMode? antiAliasingMode;
  final void Function(Duration elapsed, double deltaSeconds)? onTick;
  // Evaluated once per XR frame to preserve callback side effects. Only its
  // first pose places the rig; automatic orbit never replaces head tracking.
  final Camera Function(Duration elapsed)? referenceCamera;
  final bool controllerNavigation;

  // Background behind transparent scene pixels, independent of lighting and
  // tone mapping. The gallery supplies the same display color as its Scaffold.
  final Color? backgroundColor;

  /// Renders tracked aim hints as unlit scene meshes, even with Flutter UI paused.
  final bool showControllerRays;
  OpenXrControllerRays? _controllerRays;
  final OpenXrNavigation _navigation = OpenXrNavigation();
  vm.Matrix4? _worldFromReference;
  double _near = 0.04;
  double _far = 100;
  bool _disposed = false;
  int _lastSequence = -1;
  final Map<int, gpu.GpuExternalSurface> _surfaces = {};
  final Object _shadowGroup = Object();
  final Stopwatch _clock = Stopwatch();
  Duration _lastTick = Duration.zero;
  int _diagnosticFrames = 0;
  static const _diagnosticsEnabled = bool.fromEnvironment(
    'FLUTTER_SCENE_OPENXR_PERF_LOGS',
  );

  /// Acquires and fills both eye frames supplied by the native OpenXR host.
  Future<void> render(
    int leftSurfaceIdentifier,
    int rightSurfaceIdentifier,
    int sequence,
  ) {
    if (_disposed || sequence <= _lastSequence) {
      throw StateError('A detached or repeated OpenXR frame cannot render.');
    }
    _lastSequence = sequence;
    // Keep the startup trace bounded even when the headset runs at full cadence.
    final trace = _diagnosticsEnabled && _diagnosticFrames++ < 3;
    var stage = 'receive';
    gpu.GpuExternalSurfaceFrame? leftSurfaceFrame;
    gpu.GpuExternalSurfaceFrame? rightSurfaceFrame;
    var ownershipTransferred = false;
    try {
      final frame = session.latestFrame;
      if (trace) {
        debugPrint(
          'OpenXrDirectEyeRenderer - receive seq=$sequence pose=${frame.sequence}',
        );
      }
      if (sequence != frame.sequence) {
        throw StateError(
          'OpenXR direct target sequence $sequence does not match ${frame.sequence}.',
        );
      }
      stage = 'open surfaces';
      final leftSurface = _surface(leftSurfaceIdentifier);
      final rightSurface = _surface(rightSurfaceIdentifier);
      stage = 'acquire left';
      leftSurfaceFrame = leftSurface.acquireNextFrame();
      if (leftSurfaceFrame == null) {
        throw StateError('Native OpenXR did not supply the left-eye frame.');
      }
      if (trace) {
        debugPrint('OpenXrDirectEyeRenderer - acquired left seq=$sequence');
      }
      stage = 'acquire right';
      rightSurfaceFrame = rightSurface.acquireNextFrame();
      if (rightSurfaceFrame == null) {
        throw StateError('Native OpenXR did not supply the right-eye frame.');
      }
      if (trace) {
        debugPrint('OpenXrDirectEyeRenderer - acquired right seq=$sequence');
      }
      stage = 'create color targets';

      // The analyzer resolves flutter_scene's fallback GPU shim while the
      // device resolves flutter_gpu. Keep these constructor calls dynamic and
      // immediately restore the public SceneColorTarget type.
      final dynamic createSurfaceTarget = SurfaceFrameSceneColorTarget.new;
      final SceneColorTarget leftColorTarget =
          createSurfaceTarget(
                leftSurfaceFrame,
                backgroundColor: backgroundColor,
              )
              as SceneColorTarget;
      final SceneColorTarget rightColorTarget =
          createSurfaceTarget(
                rightSurfaceFrame,
                backgroundColor: backgroundColor,
              )
              as SceneColorTarget;

      stage = 'scene tick';
      if (!_clock.isRunning) _clock.start();
      final elapsed = _clock.elapsed;
      final delta =
          (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
      onTick?.call(elapsed, delta);
      _lastTick = elapsed;
      final authoredCamera = referenceCamera?.call(elapsed);
      if (authoredCamera != null && _worldFromReference == null) {
        final tracked = OpenXrCamera(
          eye: frame.leftEye,
          mirrorForSurfaceTexture: false,
        );
        final center = (frame.leftEye.position + frame.rightEye.position) * 0.5;
        _worldFromReference =
            _cameraPose(authoredCamera, authoredCamera.position) *
            vm.Matrix4.inverted(_cameraPose(tracked, center));
        final projection = authoredCamera.projection;
        if (projection is! PerspectiveProjection) {
          throw UnsupportedError(
            'This example needs a perspective VR adaptation.',
          );
        }
        _near = projection.near;
        _far = projection.far;
      }
      if (controllerNavigation &&
          authoredCamera != null &&
          _worldFromReference != null) {
        _worldFromReference = _navigation.update(
          frame,
          authoredCamera,
          _worldFromReference!,
          delta,
        );
      }
      if (showControllerRays) {
        // Lazily build geometry after the host has initialized Scene resources.
        (_controllerRays ??= OpenXrControllerRays(
          scene,
        )).update(frame.controllers, _worldFromReference);
      }
      // Transfer both leases together: the scene batch owns presentation or
      // discard from here, including failures while preparing either eye.
      // Before this point the local finally block must return acquired leases.
      ownershipTransferred = true;
      stage = 'render and submit';
      if (trace) {
        debugPrint('OpenXrDirectEyeRenderer - submit begin seq=$sequence');
      }
      final statuses = scene.renderViewsToTargets([
        TargetedRenderView(
          view: RenderView(
            camera: OpenXrCamera(
              eye: frame.leftEye,
              near: _near,
              far: _far,
              worldFromReference: _worldFromReference,
              mirrorForSurfaceTexture: false,
            ),
            antiAliasingMode: antiAliasingMode,
          ),
          colorTarget: leftColorTarget,
          shadowGroup: _shadowGroup,
        ),
        TargetedRenderView(
          view: RenderView(
            camera: OpenXrCamera(
              eye: frame.rightEye,
              near: _near,
              far: _far,
              worldFromReference: _worldFromReference,
              mirrorForSurfaceTexture: false,
            ),
            antiAliasingMode: antiAliasingMode,
          ),
          colorTarget: rightColorTarget,
          shadowGroup: _shadowGroup,
        ),
      ]);
      // These are submission results. Only the engine's native callbacks
      // confirm that the GPU has stopped using the borrowed eye textures.
      if (trace) {
        debugPrint(
          'OpenXrDirectEyeRenderer - submit returned seq=$sequence statuses=$statuses',
        );
      }
    } catch (error, stack) {
      debugPrint(
        'OpenXrDirectEyeRenderer - failed seq=$sequence stage=$stage error=$error',
      );
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      rethrow;
    } finally {
      if (!ownershipTransferred) {
        try {
          leftSurfaceFrame?.discard();
        } finally {
          rightSurfaceFrame?.discard();
        }
      }
    }
    return Future.value();
  }

  // Detach the session callback before disposal. Surface frames already handed
  // to the engine keep their native completion ownership until GPU completion.
  void dispose() {
    _disposed = true;
    _clock.stop();
    _controllerRays?.dispose();
    _controllerRays = null;
    _surfaces.clear();
  }

  void recenter() {
    _worldFromReference = null;
    _navigation.reset();
  }

  static vm.Matrix4 _cameraPose(Camera camera, vm.Vector3 position) {
    final forward = camera.forward.normalized();
    final right = forward.cross(camera.up).normalized();
    final up = right.cross(forward).normalized();
    return vm.Matrix4.columns(
      vm.Vector4(right.x, right.y, right.z, 0),
      vm.Vector4(up.x, up.y, up.z, 0),
      vm.Vector4(-forward.x, -forward.y, -forward.z, 0),
      vm.Vector4(position.x, position.y, position.z, 1),
    );
  }

  gpu.GpuExternalSurface _surface(
    int surfaceIdentifier,
  ) => _surfaces.putIfAbsent(surfaceIdentifier, () {
    // This path requires the matching fork's Dart GPU package as well as
    // its native engine. A typed call rejects a stock package at build time.
    return gpu.gpuContext.openExternalSurface(surfaceIdentifier);
  });
}

/// Renders one Flutter Scene into the side-by-side surface consumed by OpenXR.
// Retained for the earlier SurfaceTexture presentation contract.
// The current Quest host uses OpenXrDirectEyeRenderer and a UI-only surface;
// mounting this widget there does not turn its two flat viewports into direct eyes.
class OpenXrSceneView extends StatelessWidget {
  const OpenXrSceneView({
    required this.scene,
    this.session,
    this.near = 0.04,
    this.far = 100.0,
    this.renderScale = 1.0,
    this.antiAliasingMode = AntiAliasingMode.fxaa,
    this.onTick,
    super.key,
  }) : assert(renderScale > 0);

  final Scene scene;
  final OpenXrSession? session;
  final double near;
  final double far;

  /// Scales each eye's internal scene target before the full-size stereo
  /// surface presents it. The default preserves the runtime-recommended
  /// per-eye resolution; applications can opt into dynamic scaling if needed.
  final double renderScale;

  /// Uses one bounded post-process pass by default instead of automatic 4x
  /// MSAA on each eye. Applications can still select another supported mode.
  final AntiAliasingMode antiAliasingMode;

  final void Function(Duration elapsed, double deltaSeconds)? onTick;

  @override
  Widget build(BuildContext context) {
    final activeSession = session ?? OpenXrSession.instance;

    return SceneView(
      scene,
      viewsBuilder: (elapsed) {
        final frame = activeSession.latestFrame;
        unawaited(activeSession.markFrameRendering(frame.sequence));

        return [
          RenderView(
            camera: OpenXrCamera(eye: frame.leftEye, near: near, far: far),
            viewport: const Rect.fromLTWH(0, 0, 0.5, 1),
            renderScale: renderScale,
            antiAliasingMode: antiAliasingMode,
          ),
          RenderView(
            camera: OpenXrCamera(eye: frame.rightEye, near: near, far: far),
            viewport: const Rect.fromLTWH(0.5, 0, 0.5, 1),
            renderScale: renderScale,
            antiAliasingMode: antiAliasingMode,
          ),
        ];
      },
      onTick: onTick,
    );
  }
}
