import 'package:flutter/material.dart';
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

import 'open_xr_performance_graph.dart';

// Keep the live overview readable at panel distance. Detailed timings and
// renderer settings remain available in a scrolling disclosure below it.
class OpenXrPerformancePanel extends StatelessWidget {
  const OpenXrPerformancePanel({
    required this.nativePerformance,
    required this.flutterPerformance,
    required this.history,
    required this.shadowsEnabled,
    this.exampleName = 'Custom demo',
    this.quality = '',
    this.resolutionDetails,
    super.key,
  });

  final OpenXrNativePerformanceSample nativePerformance;
  final OpenXrFlutterPerformanceSample flutterPerformance;
  final List<OpenXrPerformanceGraphPoint> history;
  final bool shadowsEnabled;
  final String exampleName;
  final String quality;
  final Widget? resolutionDetails;

  static const _panelColor = Color(0xFF0A101B);
  static const _primaryTextColor = Color(0xFFF4F7FB);
  static const _secondaryTextColor = Color(0xFFC5D0DF);
  static const _dividerColor = Color(0x33FFFFFF);
  static const _displayColor = Color(0xFF67E8F9);
  static const _contentColor = Color(0xFFFBBF24);
  static const _flutterColor = Color(0xFFC084FC);

  @override
  Widget build(BuildContext context) {
    final freshFramePercent = nativePerformance.xrHz <= 0
        ? 0
        : (nativePerformance.directStereoHz / nativePerformance.xrHz * 100)
              .clamp(0, 100)
              .round();
    final hasLiveFrames = nativePerformance.xrHz > 1;

    return SingleChildScrollView(
      key: const PageStorageKey('vr-performance-scroll'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _panelColor,
          border: Border.all(color: _dividerColor),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: _primaryTextColor,
              fontSize: 20,
              height: 1.35,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  exampleName,
                  style: const TextStyle(color: _secondaryTextColor),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Performance',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      hasLiveFrames ? 'Live' : 'Waiting',
                      style: TextStyle(
                        color: hasLiveFrames
                            ? const Color(0xFF4ADE80)
                            : _secondaryTextColor,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _headlineMetric(
                      label: 'XR loop',
                      value: nativePerformance.xrHz,
                      color: _displayColor,
                    ),
                    const SizedBox(width: 16),
                    _headlineMetric(
                      label: 'Scene',
                      value: nativePerformance.directStereoHz,
                      color: _contentColor,
                    ),
                    const SizedBox(width: 16),
                    _headlineMetric(
                      label: 'UI',
                      value: flutterPerformance.flutterHz,
                      color: _flutterColor,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    Text(
                      'Fresh frames: $freshFramePercent%',
                      style: const TextStyle(fontSize: 18),
                    ),
                    Text(
                      shadowsEnabled ? 'Shadows on' : 'Shadows off',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ],
                ),
                const Divider(height: 32, color: _dividerColor),
                const Text(
                  'Frame rates · last 30 seconds',
                  style: TextStyle(fontSize: 18, color: _secondaryTextColor),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 200,
                  child: OpenXrPerformanceGraph(
                    points: history,
                    refreshRateHz: nativePerformance.refreshRateHz > 0
                        ? nativePerformance.refreshRateHz
                        : 72,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Teal bands: UI paused.',
                  style: TextStyle(fontSize: 18, color: _secondaryTextColor),
                ),
                const SizedBox(height: 16),
                Text(
                  nativePerformance.eyeWidth > 0
                      ? 'Per eye: ${nativePerformance.eyeWidth}×${nativePerformance.eyeHeight} px'
                      : 'Waiting for eye resolution…',
                ),
                Text(
                  nativePerformance.refreshRateHz > 0
                      ? 'Headset: ${nativePerformance.refreshRateHz.toStringAsFixed(0)} Hz (runtime)'
                      : 'Headset refresh rate unavailable',
                  style: const TextStyle(
                    fontSize: 18,
                    color: _secondaryTextColor,
                  ),
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  key: const PageStorageKey('vr-performance-details'),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  iconColor: _primaryTextColor,
                  collapsedIconColor: _primaryTextColor,
                  title: const Text(
                    'Timing & render details',
                    style: TextStyle(color: _primaryTextColor, fontSize: 22),
                  ),
                  children: [
                    _detailPair(
                      _detailMetric(
                        label: 'Submitted',
                        value: _compactHz(nativePerformance.submittedHz),
                      ),
                      _detailMetric(
                        label: 'Scene ticks',
                        value: _compactHz(flutterPerformance.sceneHz),
                      ),
                    ),
                    _detailPair(
                      _detailMetric(
                        label: 'Direct frame',
                        value:
                            '${nativePerformance.directRenderMeanMs.toStringAsFixed(1)} ms',
                        note:
                            'Max ${nativePerformance.directRenderMaxMs.toStringAsFixed(1)} ms',
                      ),
                      _detailMetric(
                        label: 'Native loop',
                        value:
                            '${nativePerformance.activeMeanMs.toStringAsFixed(1)} ms',
                        note:
                            'Max ${nativePerformance.activeMaxMs.toStringAsFixed(1)} ms',
                      ),
                    ),
                    _detailPair(
                      _detailMetric(
                        label: 'UI raster · p95',
                        value:
                            '${flutterPerformance.rasterP95Ms.toStringAsFixed(1)} ms',
                      ),
                      _detailMetric(
                        label: 'Device GPU',
                        value: nativePerformance.gpuUtilizationPercent == null
                            ? 'Unavailable'
                            : '${nativePerformance.gpuUtilizationPercent!.toStringAsFixed(0)}%',
                      ),
                    ),
                    _detailPair(
                      _detailMetric(
                        label: 'App GPU',
                        value: _runtimeCost(nativePerformance.appGpuMs),
                        note: 'Runtime sample',
                      ),
                      _detailMetric(
                        label: 'App CPU',
                        value: _runtimeCost(nativePerformance.appCpuMs),
                        note: 'Runtime sample',
                      ),
                    ),
                    _detailPair(
                      _detailMetric(
                        label: 'Compositor GPU',
                        value: _runtimeCost(nativePerformance.compositorGpuMs),
                      ),
                      const SizedBox.shrink(),
                    ),
                    if (resolutionDetails != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: resolutionDetails!,
                      ),
                    if (quality.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          quality,
                          style: const TextStyle(
                            color: _primaryTextColor,
                            fontSize: 18,
                            height: 1.4,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'XR loop measures app timing, not display refresh. '
                      'Scene counts fresh stereo frames; it does not guarantee deadlines. '
                      'Direct includes handoff/wait; Native loop includes Direct. Pose age is unavailable.',
                      style: TextStyle(
                        fontSize: 18,
                        height: 1.4,
                        color: _secondaryTextColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _headlineMetric({
    required String label,
    required double value,
    required Color color,
  }) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value.toStringAsFixed(1),
          style: const TextStyle(
            color: _primaryTextColor,
            fontSize: 42,
            height: 1.1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Text(
          'Hz',
          style: TextStyle(color: _secondaryTextColor, fontSize: 18),
        ),
      ],
    ),
  );

  static Widget _detailPair(Widget left, Widget right) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 24),
        Expanded(child: right),
      ],
    ),
  );

  static Widget _detailMetric({
    required String label,
    required String value,
    String? note,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: _secondaryTextColor, fontSize: 18),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: _primaryTextColor,
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (note != null)
        Text(
          note,
          style: const TextStyle(color: _secondaryTextColor, fontSize: 18),
        ),
    ],
  );

  static String _runtimeCost(double? value) =>
      value == null ? 'Unavailable' : '${value.toStringAsFixed(1)} ms';

  static String _compactHz(double value) => '${value.toStringAsFixed(1)} Hz';
}
