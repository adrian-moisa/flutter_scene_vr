import 'package:flutter/widgets.dart';

/// Keeps the mounted gallery owner while bypassing the framework frame chain.
/// Native OpenXR still calls the direct GPU renderer through its method channel;
/// it does not rely on these vsync callbacks. Timers collecting stats also live
/// outside this gate. This is UI suspension, not a second isolate or scene.
class OpenXrUiBinding extends WidgetsFlutterBinding {
  bool _uiPaused = false;
  bool _beganFrame = false;

  bool get uiPaused => _uiPaused;
  set uiPaused(bool value) {
    if (_uiPaused == value) return;
    _uiPaused = value;
    if (!value) {
      // A skipped begin-frame leaves SchedulerBinding's private scheduled bit
      // set. Ask the dispatcher directly so the next real begin clears it.
      // Do not remount the tree or reset the graph/scene to resume painting.
      platformDispatcher.scheduleFrame();
    }
  }

  @override
  void scheduleFrame() {
    if (!_uiPaused) super.scheduleFrame();
  }

  @override
  void scheduleForcedFrame() {
    if (!_uiPaused) super.scheduleForcedFrame();
  }

  @override
  void scheduleWarmUpFrame() {
    if (!_uiPaused) super.scheduleWarmUpFrame();
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    if (_uiPaused) return;
    _beganFrame = true;
    super.handleBeginFrame(rawTimeStamp);
  }

  @override
  void handleDrawFrame() {
    // Finish an already-started pair even if the native toggle arrived between
    // its phases. Subsequent frames perform no tickers, build, layout or paint.
    if (!_beganFrame) return;
    try {
      super.handleDrawFrame();
    } finally {
      _beganFrame = false;
    }
  }

  @override
  bool get framesEnabled => !_uiPaused && super.framesEnabled;
}
