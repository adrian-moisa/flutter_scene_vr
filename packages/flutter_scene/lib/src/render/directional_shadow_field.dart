import 'dart:typed_data';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:flutter_scene/src/light.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/render/shadow_encoder.dart';
import 'package:flutter_scene/src/render/shadow_pass.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:vector_math/vector_math.dart';

/// Immutable, camera-independent directional coverage. One sun may have a
/// precise layer and a soft layer; optional contact views follow in the atlas.
class DirectionalShadowField {
  DirectionalShadowField({
    required this.texture,
    required this.cascades,
    required this.center,
    required this.radius,
    required this.sunLayers,
    required this.hasContact,
  });
  final gpu.Texture texture;
  final List<ShadowCascade> cascades;
  final Vector3 center;
  final double radius;
  final int sunLayers;
  final bool hasContact;
}

/// Publishes retained coverage without rasterizing casters during navigation.
class DirectionalShadowFieldPass extends RenderGraphPass {
  DirectionalShadowFieldPass(this.field);
  final DirectionalShadowField field;
  @override
  String get name => 'RetainedDirectionalShadows';
  @override
  void execute(RenderGraphContext context) =>
      context.blackboard.set(kShadowMapBlackboardKey, field.texture);
}

/// Incremental raster baker. Each step renders one direction; a final step
/// assembles the atlas. Geometry edits replace queued work, sun edits retain
/// completed contact views. The owner chooses a bounded region and resolution.
class DirectionalShadowBaker {
  final _pool = TransientTexturePool(framesInFlight: 2);
  final _contact = <gpu.Texture>[];
  final _sun = <gpu.Texture>[];
  final _jobs = <void Function()>[];
  String? _contactKey;
  DirectionalShadowField? field;
  int get pendingCount => _jobs.length;
  int get cacheBytes => [
    ..._contact,
    ..._sun,
    if (field != null) field!.texture,
  ].fold(0, (sum, texture) => sum + texture.width * texture.height * 4);
  static final _directions = [
    for (final x in [-1.0, 1.0])
      for (final y in [-1.0, 1.0])
        for (final z in [-1.0, 1.0]) Vector3(x, y, z).normalized(),
  ];

  void schedule({
    required List<RenderItem> precise,
    required List<RenderItem> soft,
    required List<RenderItem> occluders,
    required String contactKey,
    required bool contact,
    required Vector3 center,
    required double radius,
    required DirectionalLight light,
    int resolution = 256,
  }) {
    _jobs.clear();
    _sun.clear();
    final size = resolution.clamp(64, 512);
    final direction = light.direction.normalized();
    final projectionLight = DirectionalLight(shadowMapResolution: size);
    final matrix = projectionLight.cascadeLightSpaceMatrix(
      direction,
      center,
      radius,
    );
    final layers = precise.isNotEmpty && soft.isNotEmpty
        ? [precise, soft]
        : [precise.isNotEmpty ? precise : soft];
    for (final items in layers) {
      _jobs.add(
        () => _sun.add(
          _raster(items, matrix, center - direction * radius * 12, size),
        ),
      );
    }
    final key = '$contactKey/$center/$radius/$size';
    if (!contact || key != _contactKey || _contact.length != 8) {
      _contact.clear();
      _contactKey = key;
      if (contact) {
        for (final d in _directions) {
          final m = projectionLight.cascadeLightSpaceMatrix(
            d,
            center,
            radius,
            snapToTexels: false,
          );
          _jobs.add(
            () => _contact.add(
              _raster(occluders, m, center - d * radius * 12, size),
            ),
          );
        }
      }
    }
    _jobs.add(() {
      final textures = [..._sun, if (contact) ..._contact];
      final texture = _assemble(textures, size);
      field = DirectionalShadowField(
        texture: texture,
        cascades: [
          ShadowCascade(
            lightSpaceMatrix: matrix,
            splitDistance: 1e12,
            boxSize: radius * 2,
          ),
        ],
        center: center.clone(),
        radius: radius,
        sunLayers: layers.length,
        hasContact: contact,
      );
      _sun.clear();
    });
  }

  bool step() {
    if (_jobs.isEmpty) return false;
    _jobs.removeAt(0)();
    return true;
  }

  gpu.Texture _raster(
    List<RenderItem> items,
    Matrix4 matrix,
    Vector3 eye,
    int size,
  ) {
    _pool.beginFrame();
    final color = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      size,
      size,
      format: gpu.PixelFormat.r32Float,
    );
    final depth = _pool.acquire(
      TransientTextureDescriptor.depth(
        width: size,
        height: size,
        format: gpu.gpuContext.defaultDepthStencilFormat,
        debugName: 'regional_depth',
      ),
    );
    final commands = gpu.gpuContext.createCommandBuffer();
    final pass = commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: color, clearValue: Vector4.all(1)),
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: depth,
          depthClearValue: 1,
        ),
      ),
    );
    final encoder = ShadowEncoder(
      pass,
      uniformTransients,
      matrix,
      eye,
      ShadowCasterFaces.both,
    );
    for (final item in items) {
      encoder.submit(item);
    }
    encoder.flush();
    rendererSubmissions.submit(commands);
    return color;
  }

  static final _quad = gpu.BufferView(
    gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(
        Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
      ),
    ),
    offsetInBytes: 0,
    lengthInBytes: 48,
  );

  gpu.Texture _assemble(List<gpu.Texture> tiles, int size) {
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      tiles.length * size,
      size,
      format: gpu.PixelFormat.r32Float,
    );
    final commands = gpu.gpuContext.createCommandBuffer();
    final pass = commands.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: texture, clearValue: Vector4.all(1)),
      ),
    );
    final vertex = baseShaderLibrary['FullscreenVertex']!,
        fragment = baseShaderLibrary['ShadowCopyFragment']!;
    for (var i = 0; i < tiles.length; i++) {
      pass.setViewport(
        gpu.Viewport(x: i * size, y: 0, width: size, height: size),
      );
      pass.clearBindings();
      pass.bindPipeline(resolvePipeline(vertex, fragment));
      pass.setColorBlendEnable(false);
      pass.setCullMode(gpu.CullMode.none);
      pass.setDepthWriteEnable(false);
      bindVertexBufferCompat(pass, _quad, 6);
      pass.bindTexture(fragment.getUniformSlot('source_texture'), tiles[i]);
      drawCompat(pass, 6);
    }
    rendererSubmissions.submit(commands);
    return texture;
  }

  void clear() {
    _jobs.clear();
    _sun.clear();
    _contact.clear();
    _contactKey = null;
    field = null;
    _pool.clear();
  }
}
