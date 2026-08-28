class OpenXrNativePerformanceSample {
  const OpenXrNativePerformanceSample({
    this.generation = 0,
    this.recommendedEyeWidth = 0,
    this.recommendedEyeHeight = 0,
    this.maxEyeWidth = 0,
    this.maxEyeHeight = 0,
    this.renderScale = 1,
    this.eyeWidth = 0,
    this.eyeHeight = 0,
    this.refreshRateHz = 0,
    this.appCpuMs,
    this.appGpuMs,
    this.compositorGpuMs,
    this.gpuUtilizationPercent,
    required this.xrHz,
    required this.submittedHz,
    required this.flutterTextureHz,
    required this.reusedFrameHz,
    required this.poseAgeMeanFrames,
    required this.poseAgeMaxFrames,
    required this.activeMeanMs,
    required this.activeMaxMs,
    required this.directStereoHz,
    required this.directRenderMeanMs,
    required this.directRenderMaxMs,
  });

  const OpenXrNativePerformanceSample.zero()
    : generation = 0,
      recommendedEyeWidth = 0,
      recommendedEyeHeight = 0,
      maxEyeWidth = 0,
      maxEyeHeight = 0,
      renderScale = 1,
      eyeWidth = 0,
      eyeHeight = 0,
      refreshRateHz = 0,
      appCpuMs = null,
      appGpuMs = null,
      compositorGpuMs = null,
      gpuUtilizationPercent = null,
      xrHz = 0,
      submittedHz = 0,
      flutterTextureHz = 0,
      reusedFrameHz = 0,
      poseAgeMeanFrames = 0,
      poseAgeMaxFrames = 0,
      activeMeanMs = 0,
      activeMaxMs = 0,
      directStereoHz = 0,
      directRenderMeanMs = 0,
      directRenderMaxMs = 0;

  final int generation;
  final int recommendedEyeWidth;
  final int recommendedEyeHeight;
  final int maxEyeWidth;
  final int maxEyeHeight;
  final double renderScale;
  final int eyeWidth;
  final int eyeHeight;
  final double refreshRateHz;
  // Runtime sample intervals are independent of this HUD's one-second cadence.
  // Null means unavailable; Flutter UI timings must never stand in for these.
  final double? appCpuMs;
  final double? appGpuMs;
  final double? compositorGpuMs;
  final double? gpuUtilizationPercent;
  final double xrHz;
  final double submittedHz;
  final double flutterTextureHz;
  final double reusedFrameHz;
  final double poseAgeMeanFrames;
  final double poseAgeMaxFrames;
  final double activeMeanMs;
  final double activeMaxMs;
  final double directStereoHz;
  final double directRenderMeanMs;
  final double directRenderMaxMs;

  factory OpenXrNativePerformanceSample.fromPlatform(Object? value) {
    if (value is! List ||
        (value.length != 8 &&
            value.length != 11 &&
            value.length != 15 &&
            value.length != 19 &&
            value.length != 24)) {
      throw const FormatException(
        'Expected eight, eleven, fifteen, nineteen or twenty-four OpenXR performance values.',
      );
    }

    final values = value
        .map((item) {
          if (item is! num) {
            throw const FormatException(
              'OpenXR performance values must be numeric.',
            );
          }
          return item.toDouble();
        })
        .toList(growable: false);

    return OpenXrNativePerformanceSample(
      generation: values.length >= 15 ? values[11].toInt() : 0,
      recommendedEyeWidth: values.length >= 24 ? values[19].toInt() : 0,
      recommendedEyeHeight: values.length >= 24 ? values[20].toInt() : 0,
      maxEyeWidth: values.length >= 24 ? values[21].toInt() : 0,
      maxEyeHeight: values.length >= 24 ? values[22].toInt() : 0,
      renderScale: values.length >= 24 ? values[23] : 1,
      eyeWidth: values.length >= 15 ? values[12].toInt() : 0,
      eyeHeight: values.length >= 15 ? values[13].toInt() : 0,
      refreshRateHz: values.length >= 15 ? values[14] : 0,
      appCpuMs: _runtimeCounter(values, 15),
      appGpuMs: _runtimeCounter(values, 16),
      compositorGpuMs: _runtimeCounter(values, 17),
      gpuUtilizationPercent: _runtimeCounter(values, 18),
      xrHz: values[0],
      submittedHz: values[1],
      flutterTextureHz: values[2],
      reusedFrameHz: values[3],
      poseAgeMeanFrames: values[4],
      poseAgeMaxFrames: values[5],
      activeMeanMs: values[6],
      activeMaxMs: values[7],
      directStereoHz: values.length >= 11 ? values[8] : 0,
      directRenderMeanMs: values.length >= 11 ? values[9] : 0,
      directRenderMaxMs: values.length >= 11 ? values[10] : 0,
    );
  }

  static double? _runtimeCounter(List<double> values, int index) {
    if (index >= values.length) return null;
    final value = values[index];
    return value.isFinite && value >= 0 ? value : null;
  }
}
