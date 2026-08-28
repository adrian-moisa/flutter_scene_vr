part of '_gpu.dart';

enum GpuPresentStatus { success, suboptimal, outOfDate }

abstract interface class GpuSurfaceFrame {
  Texture get colorTexture;

  GpuPresentStatus present(CommandBuffer commandBuffer);

  void discard();
}

class GpuImageSurface {
  GpuSurfaceFrame acquireNextFrame() => _stub();

  ui.Image? get currentImage => _stub();
}

class Surface {
  Surface({required int width, required int height}) {
    throw UnimplementedError(
      'flutter_gpu_shim is not implemented for this platform.',
    );
  }

  int get width => throw UnimplementedError();
  int get height => throw UnimplementedError();

  bool isLost = false;
  void Function()? onContextLost;
  void Function()? onContextRestored;

  void clearToColor(double r, double g, double b, double a) =>
      throw UnimplementedError();

  Future<ui.Image> snapshot({bool transferOwnership = false}) =>
      throw UnimplementedError();

  bool forceContextLoss() => throw UnimplementedError();
  bool forceContextRestore() => throw UnimplementedError();

  void dispose() {}
}
