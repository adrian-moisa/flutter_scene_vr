import 'dart:ui' as ui;

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

import 'render_view.dart';

/// A caller-supplied final color destination for one [RenderView].
///
/// The scene renderer owns and reuses all intermediate attachments, including
/// HDR color, depth, stencil, multisample, and post-processing textures. Only
/// the final display-referred color write is directed to this target.
///
/// Use [TextureSceneColorTarget] for an application-owned texture or
/// [SurfaceFrameSceneColorTarget] for a temporary frame acquired from a
/// platform surface.
/// {@category Rendering}
sealed class SceneColorTarget {
  const SceneColorTarget({this.backgroundColor});

  // Composites behind the finished scene in display sRGB, just like a Flutter
  // background behind SceneView. Null preserves transparency. This color is
  // unaffected by scene lighting, exposure, grading, or authored skyboxes.
  final ui.Color? backgroundColor;

  // Receives the final display image. The renderer adapts to the texture's
  // pixel format so sRGB attachments do not encode the image a second time.
  gpu.Texture get colorTexture;
}

/// A final color target backed by an application-owned [gpu.Texture].
///
/// [Scene.renderViewsToTargets] records and submits writes to [texture], but
/// never presents, discards, retains, or otherwise takes ownership of it. The
/// caller must keep the texture valid until the submitted GPU work completes
/// and must not concurrently write it from another renderer.
///
/// The texture must be valid, single-sample, and render-target capable.
/// {@category Rendering}
final class TextureSceneColorTarget extends SceneColorTarget {
  const TextureSceneColorTarget(this.texture, {super.backgroundColor});

  /// The application-owned final color texture.
  final gpu.Texture texture;

  @override
  gpu.Texture get colorTexture => texture;
}

/// A final color target backed by a temporary [gpu.GpuSurfaceFrame].
///
/// Passing this target to [Scene.renderViewsToTargets] transfers responsibility
/// for consuming [frame] to the scene for that call. The scene presents it on
/// the exact command buffer containing the final color write, immediately
/// before submitting that command buffer. If rendering is skipped or fails
/// before presentation, the frame is discarded.
///
/// A surface frame is single-use. Do not reuse this target in another render
/// call; acquire a fresh frame from the platform host instead.
/// {@category Rendering}
final class SurfaceFrameSceneColorTarget extends SceneColorTarget {
  const SurfaceFrameSceneColorTarget(this.frame, {super.backgroundColor});

  /// The platform-host frame consumed by the next render call.
  final gpu.GpuSurfaceFrame frame;

  @override
  gpu.Texture get colorTexture => frame.colorTexture;
}

/// Associates one explicitly configured [view] with its final [colorTarget].
///
/// Unlike canvas rendering, each binding fills its own target. The view's
/// `viewport`, `renderScale`, and `filterQuality` are therefore ignored; the
/// target texture's physical dimensions define the render size. The view's
/// camera, projection, anti-aliasing mode, culling planes, and layer mask are
/// honored normally.
///
/// A view whose `RenderView.target` is non-null is invalid here because that
/// property selects the separate renderer-owned [RenderTexture] path.
/// {@category Rendering}
final class TargetedRenderView {
  const TargetedRenderView({
    required this.view,
    required this.colorTarget,
    this.shadowGroup,
  });

  /// The camera and per-view rendering configuration.
  final RenderView view;

  /// The caller-supplied final color destination.
  final SceneColorTarget colorTarget;

  /// Optional identity token for adjacent views that share shadow rendering.
  ///
  /// Give a stereo eye pair the same stable token to fit directional cascades
  /// to both eye frusta and render the directional/spot atlas once. Resolution,
  /// filtering, and cascade splits retain the light's settings. The union
  /// covers slightly more world space than an individual eye's cascade.
  ///
  /// Views must have matching layers and perspective near planes. Sharing is
  /// conservatively skipped for custom shadow vertex shaders or enabled custom
  /// render passes, which can depend on the eye or mutate shadow inputs. The
  /// caller must not otherwise change shadow inputs during a grouped render.
  /// Unrelated captures should leave this null. Reuse the token across frames
  /// to retain the group's static-shadow cache; tokens compare by identity.
  final Object? shadowGroup;
}
