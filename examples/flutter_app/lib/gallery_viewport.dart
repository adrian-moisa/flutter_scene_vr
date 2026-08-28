import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:vector_math/vector_math.dart' as vm;

import 'example_settings.dart';

/// One sampler for the gallery, independent of whether its FPS panel is open.
class GalleryViewportController extends ChangeNotifier {
  GalleryViewportController() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _clock.start();
  }
  late final Timer _timer;
  final _clock = Stopwatch();
  final Map<Scene, _WebCameraRig> _rigs = {};
  Scene? scene;
  final Map<Scene, int> _lastCounts = {};
  int _rasterFrames = 0;
  double sceneFps = 0, flutterFps = 0, rasterMs = 0;
  double _rasterMicros = 0;
  final List<double> _fpsHistory = [];
  List<double> get fpsHistory => List.unmodifiable(_fpsHistory);

  // Start a fresh baseline after a factory reset instead of mixing old FPS
  // and raster timings into the first sample of the restarted example.
  void resetMeasurements() {
    _fpsHistory.clear();
    _lastCounts.clear();
    _rasterFrames = 0;
    _rasterMicros = 0;
    sceneFps = flutterFps = rasterMs = 0;
    _clock.reset();
    notifyListeners();
  }

  void _timings(List<ui.FrameTiming> timings) {
    _rasterFrames += timings.length;
    for (final timing in timings) {
      _rasterMicros += timing.rasterDuration.inMicroseconds;
    }
  }

  void _sample() {
    final seconds = _clock.elapsedMicroseconds / 1e6;
    var submitted = 0;
    for (final current in _lastCounts.keys.toList()) {
      final count = current.screenFrameCount;
      submitted = math.max(submitted, count - _lastCounts[current]!);
      _lastCounts[current] = count;
    }
    sceneFps = seconds > 0 ? submitted / seconds : 0;
    flutterFps = seconds > 0 ? _rasterFrames / seconds : 0;
    rasterMs = _rasterFrames == 0 ? 0 : _rasterMicros / _rasterFrames / 1000;
    _rasterFrames = 0;
    _rasterMicros = 0;
    _clock.reset();
    _fpsHistory.add(sceneFps);
    if (_fpsHistory.length > 30) _fpsHistory.removeAt(0);
    notifyListeners();
  }

  void tick(SceneView view, Scene current, Duration elapsed, double delta) {
    scene = current;
    _lastCounts.putIfAbsent(current, () => current.screenFrameCount);
    applyGalleryGraphics(current);
    _rigs[current]?.step(delta);
  }

  Camera camera(SceneView view, Scene current, Camera authored) =>
      (_rigs[current] ??= _WebCameraRig()).resolve(authored);

  Widget decorate(
    BuildContext context,
    SceneView view,
    Scene current,
    Widget child,
  ) {
    return _CameraInput(rig: _rigs[current] ??= _WebCameraRig(), child: child);
  }

  void detach(Scene current) {
    _rigs.remove(current);
    _lastCounts.remove(current);
    if (identical(scene, current)) {
      scene = null;
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }
}

const galleryCameraHelp =
    'Click scene to focus. Drag (including the middle mouse button) to orbit the camera target. '
    'WASD / arrows: move. Shift: faster. Scroll: zoom toward the pivot. R: authored camera. '
    'Settings keep their own input. In split-screen demos these controls move the primary view.';

class _CameraInput extends StatefulWidget {
  const _CameraInput({required this.rig, required this.child});
  final _WebCameraRig rig;
  final Widget child;
  @override
  State<_CameraInput> createState() => _CameraInputState();
}

class _CameraInputState extends State<_CameraInput> {
  final _focus = FocusNode(debugLabel: 'Gallery camera');
  int? _drag;
  static const _orbitButtons =
      kPrimaryMouseButton | kSecondaryMouseButton | kMiddleMouseButton;

  @override
  void dispose() {
    widget.rig.keys.clear();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onFocusChange: (focused) {
      if (!focused) {
        widget.rig.keys.clear();
        _drag = null;
      }
    },
    onKeyEvent: (_, event) {
      if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.keyR && event is KeyDownEvent) {
        widget.rig.reset();
        return KeyEventResult.handled;
      }
      if (!_WebCameraRig.movementKeys.contains(key)) {
        return KeyEventResult.ignored;
      }
      if (event is KeyUpEvent) {
        widget.rig.keys.remove(key);
      } else {
        widget.rig.keys.add(key);
      }
      return KeyEventResult.handled;
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _focus.requestFocus();
        if (event.kind != ui.PointerDeviceKind.mouse) return;
        if (event.buttons & _orbitButtons != 0) {
          _drag = event.pointer;
          widget.rig.beginOrbit();
        }
      },
      onPointerMove: (event) {
        if (_drag == event.pointer) {
          if (event.buttons & _orbitButtons != 0) {
            widget.rig.orbit(event.localDelta);
          } else {
            _drag = null;
          }
        }
      },
      onPointerUp: (event) {
        if (_drag == event.pointer) _drag = null;
      },
      onPointerCancel: (event) {
        if (_drag == event.pointer) _drag = null;
        widget.rig.keys.clear();
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            (_) => widget.rig.zoom(event.scrollDelta.dy),
          );
        }
      },
      child: widget.child,
    ),
  );
}

class _WebCameraRig {
  static final movementKeys = {
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };
  final keys = <LogicalKeyboardKey>{};
  Camera? _authored;
  vm.Vector3? _position;
  vm.Vector3? _pivot;
  double _yaw = 0, _pitch = 0, _distance = 4;

  void reset() {
    _position = null;
    _pivot = null;
    keys.clear();
  }

  void _activate() {
    final camera = _authored;
    if (_position != null || camera == null) return;
    _position = camera.position.clone();
    final forward = camera.forward.normalized();
    _yaw = math.atan2(forward.x, -forward.z);
    _pitch = math.asin(forward.y.clamp(-1.0, 1.0));
    _distance = camera is PerspectiveCamera
        ? math.max(0.000001, (camera.target - camera.position).length)
        : 4;
    _pivot = _position! + forward * _distance;
  }

  vm.Vector3 get _forward => vm.Vector3(
    math.sin(_yaw) * math.cos(_pitch),
    math.sin(_pitch),
    -math.cos(_yaw) * math.cos(_pitch),
  );
  void beginOrbit() => _activate();

  void orbit(Offset delta) {
    if (delta == Offset.zero) return;
    _activate();
    if (_position == null || _pivot == null) return;
    // Keep the orbit target and radius stable; clamp pitch before the poles
    // where the world-up camera basis becomes degenerate.
    final offset = _position! - _pivot!;
    final radius = offset.length;
    if (radius < 0.000001) return;
    final yaw = math.atan2(offset.x, offset.z) + delta.dx * 0.0045;
    final pitch =
        (math.asin((offset.y / radius).clamp(-1.0, 1.0)) + delta.dy * 0.0045)
            .clamp(-1.35, 1.35);
    final horizontal = math.cos(pitch) * radius;
    _position =
        _pivot! +
        vm.Vector3(
          math.sin(yaw) * horizontal,
          math.sin(pitch) * radius,
          math.cos(yaw) * horizontal,
        );
    final forward = (_pivot! - _position!).normalized();
    _yaw = math.atan2(forward.x, -forward.z);
    _pitch = math.asin(forward.y.clamp(-1.0, 1.0));
    _distance = radius;
  }

  void zoom(double delta) {
    if (delta == 0) return;
    _activate();
    if (_position == null || _pivot == null) return;
    // Exponential zoom cannot cross the pivot. Bounds cover the gallery's
    // different world scales instead of the lobby's fixed room dimensions.
    _distance = (_distance * math.exp(delta.clamp(-500, 500) * 0.0015)).clamp(
      0.01,
      1e6,
    );
    _position = _pivot! - _forward * _distance;
  }

  void step(double delta) {
    bool down(LogicalKeyboardKey a, LogicalKeyboardKey b) =>
        keys.contains(a) || keys.contains(b);
    final x =
        (down(LogicalKeyboardKey.keyD, LogicalKeyboardKey.arrowRight)
            ? 1.0
            : 0.0) -
        (down(LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft)
            ? 1.0
            : 0.0);
    final y =
        (down(LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp)
            ? 1.0
            : 0.0) -
        (down(LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown)
            ? 1.0
            : 0.0);
    if (x == 0 && y == 0) return;
    _activate();
    final fast =
        down(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight)
        ? 4
        : 1;
    // Match PerspectiveCamera's view basis: screen-right is up × forward.
    // The opposite cross-product silently reverses A/D and the arrow keys.
    final right = vm.Vector3(0, 1, 0).cross(_forward).normalized();
    final move = (right * x + _forward * y).normalized();
    final translation = move * (_distance * 0.75 * delta.clamp(0, 0.1) * fast);
    _position?.add(translation);
    _pivot?.add(translation);
  }

  Camera resolve(Camera authored) {
    _authored = authored;
    // Leave authored camera animation intact until the user takes control.
    // Reset clears that override, so the example can resume its own camera.
    if (_position == null) return authored;
    return _RigCamera(
      position: _position!.clone(),
      forward: _forward,
      projection: authored.projection,
    );
  }
}

class _RigCamera extends Camera {
  _RigCamera({
    required this.position,
    required this.forward,
    required this.projection,
  });
  @override
  final vm.Vector3 position;
  @override
  final vm.Vector3 forward;
  @override
  vm.Vector3 get up => vm.Vector3(0, 1, 0);
  @override
  final CameraProjection projection;
  @override
  vm.Matrix4 getViewMatrix() => PerspectiveCamera(
    position: position,
    target: position + forward,
  ).getViewMatrix();
}
