library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart';

export 'package:flutter_gpu/gpu.dart';

part 'present.dart';
part 'shader_library_inline.dart';
part 'surface.dart';

// Uploads one tightly packed pixel rectangle without replacing the complete
// texture. Interactive paint uses this to keep brush latency proportional to
// the changed area; callers must use a texture without generated mip levels.
void overwriteTextureRegion(
  Texture texture,
  ByteData sourceBytes, {
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  final source = gpuContext.createDeviceBufferWithCopy(sourceBytes);
  final commandBuffer = gpuContext.createCommandBuffer();
  commandBuffer.copyBufferToTexture(
    BufferView(
      source,
      offsetInBytes: 0,
      lengthInBytes: sourceBytes.lengthInBytes,
    ),
    TextureRegion(texture, x: x, y: y, width: width, height: height),
  );
  commandBuffer.submit();
}
