import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';
import 'package:vector_math/vector_math.dart' as vm;

// Routes two independent controller aim rays into the one Flutter UI surface.
// A visible reticle marks each hit; no flat scene viewport receives these rays.
class OpenXrQuadInput extends StatefulWidget {
  const OpenXrQuadInput({
    required this.configuration,
    required this.child,
    super.key,
  });
  final OpenXrCompositionQuadConfiguration configuration;
  final Widget child;

  @override
  State<OpenXrQuadInput> createState() => _OpenXrQuadInputState();
}

class _OpenXrQuadInputState extends State<OpenXrQuadInput> {
  final _clock = Stopwatch()..start();
  final _positions = ValueNotifier<List<Offset?>>([null, null]);
  final _lastPixels = [Offset.zero, Offset.zero];
  final _pressed = [false, false];
  final _triggerHeld = [false, false];
  final _added = [false, false];
  final _pointers = [0, 0];
  final _capturedPanels = [-1, -1];
  int _nextPointer = 10000;
  Duration _lastFrame = Duration.zero;
  Timer? _trackingWatchdog;

  @override
  void initState() {
    super.initState();
    OpenXrSession.instance.frames.addListener(_frame);
    _trackingWatchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_clock.elapsed - _lastFrame > const Duration(milliseconds: 500)) {
        _cancelAll();
      }
    });
  }

  void _frame() {
    final elapsed = _clock.elapsed;
    final dt = ((elapsed - _lastFrame).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastFrame = elapsed;
    final frame = OpenXrSession.instance.latestFrame;
    if (frame.uiPaused) {
      _cancelAll();
      return;
    }
    final positions = <Offset?>[null, null];
    for (var hand = 0; hand < 2; hand++) {
      final aim = frame.controllers.aims.length > hand
          ? frame.controllers.aims[hand]
          : null;
      final nativeHit = frame.panelHits?[hand];
      // Native hits use the movable panels' current poses and capture rules.
      // A native miss must not fall back to the original, unmoved quad.
      final hit = frame.panelHits != null
          ? (nativeHit == null
                ? null
                : Offset(nativeHit.position.x, nativeHit.position.y))
          : (aim == null || !aim.tracked ? null : _quadHit(frame, aim));
      final panel = nativeHit?.panel ?? 0;
      positions[hand] = hit;
      final held =
          aim != null &&
          aim.tracked &&
          aim.trigger > (_triggerHeld[hand] ? 0.35 : 0.65);
      final rising = held && !_triggerHeld[hand];
      _triggerHeld[hand] = held;
      final device = 4100 + hand;
      // The preserved native UI copy mirrors horizontally. Flutter paints the
      // entire UI flipped; inject its physical surface coordinate, so Flutter's
      // transform hit testing reaches the same logical pixel as the reticle.
      final pixel = hit == null
          ? const Offset(-1, -1)
          : Offset(widget.configuration.textureWidthPixels - hit.dx, hit.dy);
      void emit(PointerEvent event) =>
          GestureBinding.instance.handlePointerEvent(event);
      if (!_added[hand]) {
        emit(
          PointerAddedEvent(
            device: device,
            kind: PointerDeviceKind.mouse,
            position: pixel,
          ),
        );
        _added[hand] = true;
      }
      if (_pressed[hand] && (hit == null || panel != _capturedPanels[hand])) {
        emit(
          PointerCancelEvent(
            pointer: _pointers[hand],
            device: device,
            kind: PointerDeviceKind.mouse,
            position: _lastPixels[hand],
          ),
        );
        _pressed[hand] = false;
      } else if (_pressed[hand] && !held) {
        emit(
          PointerUpEvent(
            pointer: _pointers[hand],
            device: device,
            kind: PointerDeviceKind.mouse,
            position: pixel,
            timeStamp: elapsed,
          ),
        );
        _pressed[hand] = false;
      } else if (_pressed[hand]) {
        emit(
          PointerMoveEvent(
            pointer: _pointers[hand],
            device: device,
            kind: PointerDeviceKind.mouse,
            position: pixel,
            delta: pixel - _lastPixels[hand],
            buttons: kPrimaryMouseButton,
            timeStamp: elapsed,
          ),
        );
      } else {
        emit(
          PointerHoverEvent(
            device: device,
            kind: PointerDeviceKind.mouse,
            position: pixel,
            delta: pixel - _lastPixels[hand],
            timeStamp: elapsed,
          ),
        );
        if (rising && hit != null) {
          _pointers[hand] = _nextPointer++;
          _pressed[hand] = true;
          _capturedPanels[hand] = panel;
          emit(
            PointerDownEvent(
              pointer: _pointers[hand],
              device: device,
              kind: PointerDeviceKind.mouse,
              position: pixel,
              buttons: kPrimaryMouseButton,
              timeStamp: elapsed,
            ),
          );
        }
      }
      if (hit != null && !_pressed[hand]) {
        final stick = hand == 0
            ? frame.controllers.leftThumbstick
            : frame.controllers.rightThumbstick;
        if (stick.y != 0) {
          emit(
            PointerScrollEvent(
              device: device,
              kind: PointerDeviceKind.mouse,
              position: pixel,
              scrollDelta: Offset(0, -stick.y * 700 * dt),
              timeStamp: elapsed,
            ),
          );
        }
      }
      _lastPixels[hand] = pixel;
    }
    if (_positions.value[0] != positions[0] ||
        _positions.value[1] != positions[1]) {
      _positions.value = positions;
    }
  }

  Offset? _quadHit(OpenXrFrame frame, OpenXrControllerAim aim) {
    final quad = widget.configuration;
    var pose = vm.Matrix4.compose(
      vm.Vector3(quad.positionX, quad.positionY, quad.positionZ),
      vm.Quaternion(
        quad.orientationX,
        quad.orientationY,
        quad.orientationZ,
        quad.orientationW,
      ),
      vm.Vector3.all(1),
    );
    if (quad.headLocked) {
      // Both eyes share the head orientation; their midpoint removes IPD.
      final head = vm.Matrix4.compose(
        (frame.leftEye.position + frame.rightEye.position) * 0.5,
        frame.leftEye.orientation,
        vm.Vector3.all(1),
      );
      pose = head * pose;
    }
    final inverse = vm.Matrix4.inverted(pose);
    final origin = inverse.transformed3(aim.position);
    final direction = aim.orientation.conjugated().rotated(
      vm.Vector3(0, 0, -1),
    );
    inverse.rotate3(direction);
    if (direction.z >= -0.00001) return null;
    final distance = -origin.z / direction.z;
    if (distance <= 0 || distance > 8) return null;
    final point = origin + direction * distance;
    final x = point.x / quad.widthMeters + 0.5;
    final y = 0.5 - point.y / quad.heightMeters;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return Offset(x * quad.textureWidthPixels, y * quad.textureHeightPixels);
  }

  void _cancelAll() {
    for (var hand = 0; hand < 2; hand++) {
      if (_pressed[hand]) {
        GestureBinding.instance.handlePointerEvent(
          PointerCancelEvent(
            pointer: _pointers[hand],
            device: 4100 + hand,
            kind: PointerDeviceKind.mouse,
            position: _lastPixels[hand],
          ),
        );
      }
      if (_added[hand]) {
        GestureBinding.instance.handlePointerEvent(
          PointerRemovedEvent(
            device: 4100 + hand,
            kind: PointerDeviceKind.mouse,
          ),
        );
      }
      _pressed[hand] = _added[hand] = _triggerHeld[hand] = false;
    }
    if (_positions.value.any((point) => point != null)) {
      _positions.value = [null, null];
    }
  }

  @override
  void dispose() {
    OpenXrSession.instance.frames.removeListener(_frame);
    _trackingWatchdog?.cancel();
    _cancelAll();
    _positions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: widget.child),
      Positioned.fill(
        child: IgnorePointer(
          child: ValueListenableBuilder<List<Offset?>>(
            valueListenable: _positions,
            builder: (context, points, _) => Stack(
              children: [
                for (var hand = 0; hand < points.length; hand++)
                  if (points[hand] case final point?)
                    Positioned(
                      left: point.dx - 6,
                      top: point.dy - 6,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hand == 0
                              ? const Color(0xFF67E8F9)
                              : const Color(0xFFFFBB44),
                          border: Border.all(
                            color: const Color(0xFF000000),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
