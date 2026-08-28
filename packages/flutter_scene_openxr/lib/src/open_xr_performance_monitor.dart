import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

class OpenXrFlutterPerformanceSample {
  const OpenXrFlutterPerformanceSample({
    required this.sceneHz,
    required this.flutterHz,
    required this.buildP95Ms,
    required this.rasterP95Ms,
    required this.totalP95Ms,
    required this.totalMaxMs,
    required this.overBudgetFrames,
    required this.maximumTickGapMs,
  });

  const OpenXrFlutterPerformanceSample.zero()
    : sceneHz = 0,
      flutterHz = 0,
      buildP95Ms = 0,
      rasterP95Ms = 0,
      totalP95Ms = 0,
      totalMaxMs = 0,
      overBudgetFrames = 0,
      maximumTickGapMs = 0;

  final double sceneHz;
  final double flutterHz;
  final double buildP95Ms;
  final double rasterP95Ms;
  final double totalP95Ms;
  final double totalMaxMs;
  final int overBudgetFrames;
  final double maximumTickGapMs;
}

/// Aggregates Flutter frame and scene-cadence diagnostics for an OpenXR view.
///
/// Logging is explicitly enabled by the application so importing the package
/// never adds callbacks or output to production builds. Samples are bounded
/// and emitted once per [sampleInterval], rather than on every XR frame.
class OpenXrPerformanceMonitor {
  OpenXrPerformanceMonitor({
    this.enabled = false,
    this.displayRefreshRateHz = 72,
    this.sampleInterval = const Duration(seconds: 5),
    this.maximumBufferedFrames = 600,
    this.onSample,
  }) {
    if (_collecting) {
      SchedulerBinding.instance.addTimingsCallback(_recordFlutterFrames);
      _clock.start();
      // A wall-clock timer keeps collecting while the host suspends widget frames.
      // Scene cadence and Flutter frame cadence intentionally remain separate.
      _timer = Timer.periodic(sampleInterval, (_) {
        _emitSample();
        _resetWindow();
      });
    }
  }

  final bool enabled;
  final double displayRefreshRateHz;
  final Duration sampleInterval;
  final int maximumBufferedFrames;
  final ValueChanged<OpenXrFlutterPerformanceSample>? onSample;

  bool get _collecting => enabled || onSample != null;

  final List<FrameTiming> _frameTimings = <FrameTiming>[];
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _sceneFrameCount = 0;
  double _maximumTickGapMs = 0;
  bool _disposed = false;

  /// Records the cadence delivered to [SceneView.onTick].
  void recordSceneTick(Duration _, double deltaSeconds) {
    if (!_collecting || _disposed) return;
    _sceneFrameCount++;
    _maximumTickGapMs = _maximumTickGapMs < deltaSeconds * 1000
        ? deltaSeconds * 1000
        : _maximumTickGapMs;
  }

  // Starts a clean comparison window without retaining a previous scene.
  void reset() => _resetWindow();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _clock.stop();
    if (_collecting) {
      SchedulerBinding.instance.removeTimingsCallback(_recordFlutterFrames);
    }
    _frameTimings.clear();
  }

  void _recordFlutterFrames(List<FrameTiming> timings) {
    _frameTimings.addAll(timings);
    final overflow = _frameTimings.length - maximumBufferedFrames;
    if (overflow > 0) _frameTimings.removeRange(0, overflow);
  }

  void _emitSample() {
    final elapsedSeconds = _clock.elapsedMicroseconds / 1e6;
    final builds = _durations((timing) => timing.buildDuration);
    final rasters = _durations((timing) => timing.rasterDuration);
    final totals = _durations((timing) => timing.totalSpan);
    final frameBudgetMs = 1000 / displayRefreshRateHz;
    final flutterHz = elapsedSeconds == 0
        ? 0.0
        : _frameTimings.length / elapsedSeconds;
    final sceneHz = elapsedSeconds == 0
        ? 0.0
        : _sceneFrameCount / elapsedSeconds;

    final sample = OpenXrFlutterPerformanceSample(
      sceneHz: sceneHz,
      flutterHz: flutterHz,
      buildP95Ms: _percentile(builds, 0.95),
      rasterP95Ms: _percentile(rasters, 0.95),
      totalP95Ms: _percentile(totals, 0.95),
      totalMaxMs: _maximum(totals),
      overBudgetFrames: totals.where((value) => value > frameBudgetMs).length,
      maximumTickGapMs: _maximumTickGapMs,
    );
    onSample?.call(sample);

    if (!enabled) return;

    debugPrint(
      '+++ OpenXR Flutter perf | '
      'scene_hz=${sceneHz.toStringAsFixed(1)} '
      'flutter_hz=${flutterHz.toStringAsFixed(1)} '
      'frames=${_frameTimings.length} '
      'build_p95_ms=${sample.buildP95Ms.toStringAsFixed(2)} '
      'raster_p95_ms=${sample.rasterP95Ms.toStringAsFixed(2)} '
      'total_p95_ms=${sample.totalP95Ms.toStringAsFixed(2)} '
      'total_max_ms=${sample.totalMaxMs.toStringAsFixed(2)} '
      'over_budget=${sample.overBudgetFrames} '
      'max_tick_gap_ms=${sample.maximumTickGapMs.toStringAsFixed(2)}',
    );
  }

  List<double> _durations(Duration Function(FrameTiming timing) select) =>
      _frameTimings
          .map((timing) => select(timing).inMicroseconds / 1000)
          .toList(growable: false);

  double _percentile(List<double> values, double fraction) {
    if (values.isEmpty) return 0;
    values.sort();
    return values[((values.length - 1) * fraction).round()];
  }

  double _maximum(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((left, right) => left > right ? left : right);
  }

  void _resetWindow() {
    _clock.reset();
    _sceneFrameCount = 0;
    _maximumTickGapMs = 0;
    _frameTimings.clear();
  }
}
