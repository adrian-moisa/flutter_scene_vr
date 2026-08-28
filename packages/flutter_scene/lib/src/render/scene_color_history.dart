import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'render_graph.dart';
import 'scene_pass.dart' show kSceneColorBlackboardKey;

/// A single view's prior lit color and the transform that produced it. The
/// texture lease keeps history out of the pool's writable attachments, even if
/// that pool advances unusually often or has only one frame in flight.
class SceneColorHistory {
  TransientTextureLease? _lease;
  Matrix4? viewProjection;
  int? _width;
  int? _height;
  int? _layerMask;

  gpu.Texture? get color => _lease?.texture;

  void prepare({
    required int width,
    required int height,
    required int layerMask,
  }) {
    if (_width != width || _height != height || _layerMask != layerMask) {
      clear();
      _width = width;
      _height = height;
      _layerMask = layerMask;
    }
  }

  void clear() {
    _lease?.release();
    _lease = null;
    viewProjection = null;
  }

  void store(
    TransientTexturePool pool,
    gpu.Texture texture,
    Matrix4 currentViewProjection,
  ) {
    final next = pool.retain(texture);
    _lease?.release();
    _lease = next;
    viewProjection = currentViewProjection;
  }
}

/// Retains the completed scene color for this view's next indirect-light
/// gather. Runs after every history reader and ScenePass has submitted, before
/// later post-processing publishes its separate outputs. No GPU copy is needed.
class SceneColorHistoryPass extends RenderGraphPass {
  SceneColorHistoryPass({required this.history, required this.viewProjection});

  final SceneColorHistory history;
  final Matrix4 viewProjection;

  @override
  String get name => 'SceneColorHistoryPass';

  @override
  void execute(RenderGraphContext context) {
    final source = context.blackboard.get<gpu.Texture>(
      kSceneColorBlackboardKey,
    );
    if (source != null) {
      history.store(context.texturePool, source, viewProjection);
    }
  }
}
