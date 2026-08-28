// Covers direct final-color targets: raw texture ownership, one-tick
// multi-view rendering, per-view transient isolation, and the
// GpuSurfaceFrame present-before-submit contract.
// Image surfaces exercise Dart submission ordering without an OpenXR runtime.
// They do not prove borrowed native-image completion, stereo pixels, or timing.

import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

gpu.Texture _targetTexture({int width = 8, int height = 8}) =>
    gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
    );

RenderView _view({AntiAliasingMode antiAliasing = AntiAliasingMode.none}) =>
    RenderView(
      camera: PerspectiveCamera(position: Vector3(0, 0, 5)),
      antiAliasingMode: antiAliasing,
    );

final class _TickCounter extends Component {
  int count = 0;

  @override
  void update(double deltaSeconds) {
    count++;
  }
}

final class _DoubleFullscreenPass extends CustomRenderPass {
  @override
  String get name => 'double_fullscreen';

  @override
  RenderStage get stage => RenderStage.afterAntiAliasing;

  @override
  void execute(RenderPassContext context) {
    final shader = baseShaderLibrary['SsrCompositeFragment']!;
    final input = context.currentColor;
    final uniforms = <String, ByteData>{'CompositeInfo': ByteData(16)};
    final textures = <String, gpu.Texture>{'ssr_reflection': input};
    context.applyShader(shader, textures: textures, uniforms: uniforms);
    context.applyShader(shader, textures: textures, uniforms: uniforms);
  }
}

void main() {
  if (!_gpuAvailable()) {
    test(
      'direct render target suite (skipped: no GPU device)',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets('two raw targets render from one shared scene tick', (
    tester,
  ) async {
    await Scene.initializeStaticResources();

    final scene = Scene();
    final counter = _TickCounter();
    scene.add(Node()..addComponent(counter));
    // Component loading completes asynchronously when the node is mounted.
    await tester.pump();

    final left = _targetTexture(width: 12, height: 10);
    final right = _targetTexture(width: 14, height: 10);
    final statuses = scene.renderViewsToTargets([
      TargetedRenderView(
        view: _view(),
        colorTarget: TextureSceneColorTarget(left),
      ),
      TargetedRenderView(
        view: _view(),
        colorTarget: TextureSceneColorTarget(right),
      ),
    ]);

    expect(statuses, [isNull, isNull]);
    expect(counter.count, 1);
    expect(left.isValid, isTrue);
    expect(right.isValid, isTrue);
    // Direct rendering must not allocate or publish the Canvas presentation
    // ring used by SceneView/renderViews.
    expect(scene.surface.lastSwapchainColorTexture(), isNull);
  });

  test('external views retain distinct renderer-owned transient pools', () {
    final scene = Scene();
    const size = ui.Size(16, 12);

    final TransientTexturePool left = scene.surface.prepareExternalFrame(
      size,
      0,
    );
    final TransientTexturePool right = scene.surface.prepareExternalFrame(
      size,
      1,
    );
    final TransientTexturePool leftNextFrame = scene.surface
        .prepareExternalFrame(size, 0);

    expect(right, isNot(same(left)));
    expect(leftNextFrame, same(left));
    expect(scene.surface.lastSwapchainColorTexture(), isNull);
  });

  for (final antiAliasing in <AntiAliasingMode>[
    AntiAliasingMode.none,
    AntiAliasingMode.fxaa,
    AntiAliasingMode.smaa,
  ]) {
    testWidgets(
      'surface frame is presented by the final ${antiAliasing.name} command buffer',
      (tester) async {
        await Scene.initializeStaticResources();

        final scene = Scene();
        final surface = gpu.gpuContext.createImageSurface(8, 8);
        final frame = surface.acquireNextFrame();
        final statuses = scene.renderViewsToTargets([
          TargetedRenderView(
            view: _view(antiAliasing: antiAliasing),
            colorTarget: SurfaceFrameSceneColorTarget(frame),
          ),
        ]);

        expect(statuses, [gpu.GpuPresentStatus.success]);
        expect(surface.currentImage, isNotNull);

        // Acquiring again checks the engine's pending-present guard. It throws
        // when the command buffer passed to present was not subsequently
        // submitted, so success here covers the ordering contract.
        final nextFrame = surface.acquireNextFrame();
        nextFrame.discard();
        surface.currentImage?.dispose();
      },
    );
  }

  testWidgets('surface frame presents on a custom pass last write', (
    tester,
  ) async {
    await Scene.initializeStaticResources();

    final scene = Scene()..addRenderPass(_DoubleFullscreenPass());
    final surface = gpu.gpuContext.createImageSurface(8, 8);
    final frame = surface.acquireNextFrame();
    final statuses = scene.renderViewsToTargets([
      TargetedRenderView(
        view: _view(),
        colorTarget: SurfaceFrameSceneColorTarget(frame),
      ),
    ]);

    expect(statuses, [gpu.GpuPresentStatus.success]);
    expect(surface.currentImage, isNotNull);
    final nextFrame = surface.acquireNextFrame();
    nextFrame.discard();
    surface.currentImage?.dispose();
  });

  testWidgets(
    'invalid targeted view is rejected without consuming raw texture',
    (tester) async {
      await Scene.initializeStaticResources();

      final scene = Scene();
      final texture = _targetTexture();
      final renderTexture = RenderTexture(width: 8, height: 8);

      expect(
        () => scene.renderViewsToTargets([
          TargetedRenderView(
            view: RenderView(
              camera: PerspectiveCamera(position: Vector3(0, 0, 5)),
              target: renderTexture,
            ),
            colorTarget: TextureSceneColorTarget(texture),
          ),
        ]),
        throwsArgumentError,
      );
      expect(texture.isValid, isTrue);
    },
  );
}
