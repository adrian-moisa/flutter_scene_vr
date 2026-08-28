import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/resolve_pass.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';

// Display effects operate on encoded sRGB values in plain textures, regardless
// of the final attachment. Using an sRGB attachment here would encode every
// write and decode every sample, changing the image and alpha-edge filtering.
// Only map formats exposed by native Flutter GPU; the web/analyzer shim also
// lists 10-bit XR formats that the local Quest engine does not provide.
gpu.PixelFormat displayIntermediateFormat(gpu.PixelFormat format) =>
    switch (format) {
      gpu.PixelFormat.r8g8b8a8UNormIntSRGB => gpu.PixelFormat.r8g8b8a8UNormInt,
      gpu.PixelFormat.b8g8r8a8UNormIntSRGB => gpu.PixelFormat.b8g8r8a8UNormInt,
      _ => format,
    };

// Adapts the completed display image to a caller's color attachment.
// Background composition happens after all scene effects, matching SceneView
// over Flutter chrome. sRGB attachments need linear shader output because the
// GPU encodes their writes; plain attachments keep the already encoded image.
// The acquired surface is presented only on this final command buffer.
class DisplayOutputPass extends RenderGraphPass {
  DisplayOutputPass({
    required gpu.Texture output,
    ui.Color? backgroundColor,
    FinalCommandBufferCallback? beforeSubmit,
  }) : _output = output,
       _backgroundColor = backgroundColor,
       _beforeSubmit = beforeSubmit;

  final gpu.Texture _output;
  final ui.Color? _backgroundColor;
  final FinalCommandBufferCallback? _beforeSubmit;

  static final gpu.Shader _vertexShader =
      baseShaderLibrary['FullscreenVertex']!;
  static final gpu.Shader _fragmentShader =
      baseShaderLibrary['DisplayOutputFragment']!;
  static final gpu.DeviceBuffer _quadBuffer = gpu.gpuContext
      .createDeviceBufferWithCopy(
        ByteData.sublistView(
          Float32List.fromList(<double>[
            -1, -1, 1, -1, -1, 1, //
            -1, 1, 1, -1, 1, 1, //
          ]),
        ),
      );
  static final gpu.BufferView _quadView = gpu.BufferView(
    _quadBuffer,
    offsetInBytes: 0,
    lengthInBytes: 6 * 2 * 4,
  );
  static final gpu.SamplerOptions _nearestClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.nearest,
    magFilter: gpu.MinMagFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  @override
  String get name => 'DisplayOutputPass';

  @override
  void execute(RenderGraphContext context) {
    final input = context.blackboard.require<gpu.Texture>(
      kDisplayColorBlackboardKey,
    );
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: _output)),
    );
    renderPass.bindPipeline(resolvePipeline(_vertexShader, _fragmentShader));
    // This pass writes every pixel, including alpha. Do not blend against the
    // borrowed swapchain's previous contents or apply alpha a second time.
    renderPass.setColorBlendEnable(false);
    bindVertexBufferCompat(renderPass, _quadView, 6);
    renderPass.bindTexture(
      _fragmentShader.getUniformSlot('display_color'),
      input,
      sampler: _nearestClamp,
    );

    final background = _backgroundColor?.withValues(
      colorSpace: ui.ColorSpace.sRGB,
    );
    final alpha = background?.a ?? 0.0;
    // DisplayOutputInfo: premultiplied sRGB background, decode flag, padding.
    final info = Float32List(8)
      ..[0] = (background?.r ?? 0.0) * alpha
      ..[1] = (background?.g ?? 0.0) * alpha
      ..[2] = (background?.b ?? 0.0) * alpha
      ..[3] = alpha
      ..[4] = displayIntermediateFormat(_output.format) != _output.format
          ? 1.0
          : 0.0;
    renderPass.bindUniform(
      _fragmentShader.getUniformSlot('DisplayOutputInfo'),
      context.transientsBuffer.emplace(ByteData.sublistView(info)),
    );
    drawCompat(renderPass, 6);
    _beforeSubmit?.call(commandBuffer);
    rendererSubmissions.submit(commandBuffer);
    context.blackboard.set(kDisplayColorBlackboardKey, _output);
  }
}
