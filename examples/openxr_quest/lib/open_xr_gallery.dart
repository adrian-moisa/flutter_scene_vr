import 'dart:async';
import 'dart:ui' as ui;

import 'package:example_app/example_chrome.dart'
    show galleryBackgroundColor, galleryVrControlsHelp;
import 'package:example_app/example_registry.dart';
import 'package:example_app/gallery_resolution.dart';
import 'package:example_app/example_settings.dart';
import 'package:example_app/main.dart' show GallerySettingsSidebar;
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

import 'open_xr_gallery_quad.dart';
import 'open_xr_gallery_quality.dart';
import 'open_xr_gallery_scene.dart';
import 'open_xr_gallery_support.dart';
import 'open_xr_performance_graph.dart';
import 'open_xr_performance_panel.dart';
import 'open_xr_quad_input.dart';

// One selected gallery widget in either process. Enter/exit explicitly restarts
// that example at its authored baseline, so the hidden flat activity owns no
// scene, simulation or audio while the native activity renders it.
enum _GalleryTab { examples, controls, settings, help }

class OpenXrGallery extends StatefulWidget {
  const OpenXrGallery({
    required this.immersive,
    this.initialExample,
    super.key,
  });
  final bool immersive;
  final String? initialExample;

  @override
  State<OpenXrGallery> createState() => _OpenXrGalleryState();
}

class _OpenXrGalleryState extends State<OpenXrGallery> {
  late final Map<String, WidgetBuilder> _examples;
  late String _selected;
  late Future<void> _ready;
  late final OpenXrPerformanceMonitor _monitor;
  OpenXrDirectEyeRenderer? _renderer;
  OpenXrFlutterPerformanceSample _flutter =
      const OpenXrFlutterPerformanceSample.zero();
  List<OpenXrPerformanceGraphPoint> _history = [];
  Scene? _scene;
  String? _error;
  bool _selectorOpen = true;
  _GalleryTab _tab = _GalleryTab.examples;
  double _eyeRenderScale = 1;
  bool _away = false;
  bool _uiPaused = false;
  int _generation = 0;
  int _selectionRequest = 0;
  bool _switching = false;
  Future<double>? _pendingEyeResize;
  void Function(FlutterErrorDetails)? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousAsyncError;

  @override
  void initState() {
    super.initState();
    _examples = galleryExamples();
    _selected = _examples.containsKey(widget.initialExample)
        ? widget.initialExample!
        : _examples.keys.first;
    resetExampleSettings(settingsDefaults[_selected], _selected);
    _ready = _initialize();
    _monitor = OpenXrPerformanceMonitor(
      enabled: const bool.fromEnvironment('FLUTTER_SCENE_OPENXR_PERF_LOGS'),
      sampleInterval: const Duration(seconds: 1),
      onSample: _sample,
    );
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = _flutterError;
    _previousAsyncError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = _asyncError;
    if (widget.immersive) {
      OpenXrSession.instance.frames.addListener(_uiStateChanged);
      unawaited(OpenXrSession.instance.gallerySelection(_selected));
    }
  }

  Future<void> _initialize() async {
    await Future.wait([
      Scene.initializeStaticResources(),
      loadExampleEffects(),
    ]);
    if (widget.immersive) await OpenXrSession.instance.resetPerformance();
  }

  void _flutterError(FlutterErrorDetails details) {
    _previousFlutterError?.call(details);
    _failure(details.exception, details.stack ?? StackTrace.current);
  }

  bool _asyncError(Object error, StackTrace stack) {
    _failure(error, stack);
    return true;
  }

  void _failure(Object error, StackTrace stack) {
    if (!mounted || _away) return;
    final generation = _generation;
    debugPrint('Gallery $_selected failed: $error\n$stack');
    unawaited(OpenXrSession.instance.suspendExternalEyeRenderer());
    scheduleMicrotask(() {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error.toString();
        _selectorOpen = true;
        _tab = _GalleryTab.examples;
      });
    });
  }

  void _uiStateChanged() {
    final paused = OpenXrSession.instance.latestFrame.uiPaused;
    if (_uiPaused == paused) return;
    _uiPaused = paused;
    // The binding has already opened its scheduler gate. Refresh retained
    // values once on resume; no widget rebuild is requested while paused.
    if (!paused && mounted) setState(() {});
  }

  void _sample(OpenXrFlutterPerformanceSample sample) {
    if (!mounted || _away) return;
    final native = OpenXrSession.instance.nativePerformance.value;
    _flutter = sample;
    _history = [
      ..._history,
      OpenXrPerformanceGraphPoint(
        xrHz: widget.immersive ? native.xrHz : 0,
        contentHz: widget.immersive ? native.directStereoHz : sample.sceneHz,
        flutterHz: sample.flutterHz,
        uiPaused: _uiPaused,
      ),
    ];
    if (_history.length > 30) _history.removeAt(0);
    if (!_uiPaused) setState(() {});
  }

  void _frame(Scene scene, Duration elapsed, double delta) {
    if (_scene != null && !identical(scene, _scene)) {
      // A sub-demo can replace its Scene without changing the registry entry.
      _monitor.reset();
      _history = [];
      _flutter = const OpenXrFlutterPerformanceSample.zero();
      if (widget.immersive) {
        unawaited(OpenXrSession.instance.resetPerformance());
      }
    }
    _scene = scene;
    applyGalleryGraphics(scene);
    _monitor.recordSceneTick(elapsed, delta);
  }

  Future<void> _select(String name, {bool factorySettings = false}) async {
    if (_switching) return;
    final request = ++_selectionRequest;
    debugPrint(
      'Gallery switch request=$request from=$_selected to=$name '
      'preset=${galleryGraphicsPreset.value} eyeScale=$_eyeRenderScale '
      'resizing=${_pendingEyeResize != null}',
    );
    setState(() => _switching = true);
    try {
      final resize = _pendingEyeResize;
      if (resize != null) {
        try {
          await resize;
        } catch (_) {
          // The settings panel reports resize failures. A new example can
          // still use the previous native eye size and fresh authored settings.
        }
      }
      if (!mounted || request != _selectionRequest) return;
      if (widget.immersive) {
        if (factorySettings) {
          // Restore runtime-recommended eye pixels while the previous scene
          // still owns its renderer. Resize failure leaves that scene usable.
          await _applyEyeRenderScale(1.0);
          if (!mounted || request != _selectionRequest) return;
        }
        // Drain any graphics change first, then stop native offers before
        // unmounting the old SceneView. Queued frames are explicitly discarded.
        await OpenXrSession.instance.suspendExternalEyeRenderer();
        if (!mounted || request != _selectionRequest) return;
        debugPrint('Gallery switch request=$request old renderer drained');
      }
      // Keep the old presentation key until the native pause has drained.
      final generation = ++_generation;
      _renderer = null;
      setState(() {
        _selected = name;
        _scene = null;
        _error = null;
        _flutter = const OpenXrFlutterPerformanceSample.zero();
        _history = [];
        resetExampleSettings(settingsDefaults[name], name);
        if (widget.immersive) exampleSettings.renderScale = _eyeRenderScale;
        _monitor.reset();
      });
      if (widget.immersive) {
        await OpenXrSession.instance.resetPerformance();
        if (!mounted || generation != _generation) return;
        await OpenXrSession.instance.gallerySelection(name);
      }
      debugPrint(
        'Gallery switch request=$request selected=$name generation=$generation',
      );
    } catch (error, stack) {
      // Settings reset failures belong in the sidebar, not a fatal scene state.
      if (factorySettings) rethrow;
      if (mounted && request == _selectionRequest) _failure(error, stack);
    } finally {
      if (mounted && request == _selectionRequest) {
        setState(() => _switching = false);
      }
    }
  }

  Future<void> _enterVr() async {
    // Remove the old widget before creating the separate native-process owner.
    setState(() => _away = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final selected = await OpenXrSession.instance.enterGallery(
        example: _selected,
        compositionQuad: openXrGalleryQuad,
      );
      if (!mounted) return;
      await _select(_examples.containsKey(selected) ? selected! : _selected);
    } catch (error, stack) {
      if (!mounted) return;
      _away = false;
      _failure(error, stack);
    } finally {
      if (mounted) setState(() => _away = false);
    }
  }

  Widget _immersiveScene(
    BuildContext context,
    SceneView view,
    Scene scene,
    SceneTickCallback tick,
    bool ready,
  ) {
    if (view.key == const ValueKey('gallery-shape-preview')) {
      // This thumbnail is a second SceneView inside the example's controls.
      // It must not replace the main scene as owner of the stereo callback.
      return const Center(
        child: Text('Preview:\nflat only', textAlign: TextAlign.center),
      );
    }
    if (view.viewsBuilder != null) {
      return const Center(
        child: Text('Multi-view requires a dedicated VR adaptation.'),
      );
    }
    final generation = _generation;
    return OpenXrGalleryScene(
      key: ObjectKey(scene),
      view: view,
      scene: scene,
      tick: tick,
      ready: ready,
      onFrame: _frame,
      onRenderer: (renderer) {
        if (generation == _generation) _renderer = renderer;
      },
      onError: (error, stack) {
        if (generation == _generation) _failure(error, stack);
      },
    );
  }

  Widget _example() {
    if (_away || _error != null) return const SizedBox.expand();
    if (widget.immersive && !galleryVrSupported(_selected)) {
      return const Center(
        child: Text('This example remains available in flat mode.'),
      );
    }
    return SceneViewPresentation(
      key: ValueKey('$_selected/$_generation'),
      present: widget.immersive ? _immersiveScene : null,
      onTick: widget.immersive
          ? null
          : (view, scene, elapsed, delta) {
              if (view.key != const ValueKey('gallery-shape-preview')) {
                _frame(scene, elapsed, delta);
              }
            },
      onDetach: _retireScene,
      child: Builder(builder: _examples[_selected]!),
    );
  }

  void _retireScene(Scene scene) {
    // Defer until declarative children have unmounted. This runs in flat mode
    // too, before the next process becomes the sole example owner.
    scheduleMicrotask(() {
      scene.removeAll();
      scene.views.clear();
      for (final component in scene.root.getComponents<Component>().toList()) {
        scene.root.removeComponent(component);
      }
    });
  }

  Widget _selector() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Examples (${_examples.length})',
        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        widget.immersive
            ? 'Trigger: open · Stick: scroll\nOpens with original settings.'
            : 'Select an example to restart its original settings.',
        style: TextStyle(fontSize: widget.immersive ? 18 : 14, height: 1.35),
      ),
      const SizedBox(height: 10),
      Expanded(
        child: Scrollbar(
          child: ListView(
            key: const PageStorageKey('gallery-examples'),
            children: [
              for (final name in _examples.keys)
                ListTile(
                  key: ValueKey(name),
                  minTileHeight: widget.immersive ? 72 : null,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  selected: name == _selected,
                  title: Text(
                    name,
                    style: TextStyle(fontSize: widget.immersive ? 22 : 16),
                  ),
                  trailing: widget.immersive && !galleryVrSupported(name)
                      ? const Text(
                          'Flat only',
                          style: TextStyle(
                            fontSize: 18,
                            color: Color(0xFFC5D0DF),
                          ),
                        )
                      : null,
                  onTap: _switching ? null : () => unawaited(_select(name)),
                ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _controls() {
    if (widget.immersive) {
      // Wrap at panel width; larger text must not squeeze four actions into
      // one row. Labels distinguish view, panel and example resets.
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton.icon(
            onPressed: _switching ? null : () => unawaited(_select(_selected)),
            icon: const Icon(Icons.refresh),
            label: const Text('Restart'),
          ),
          TextButton.icon(
            onPressed: () => unawaited(OpenXrSession.instance.resetPanels()),
            icon: const Icon(Icons.dashboard_customize),
            label: const Text('Reset panels'),
          ),
          TextButton(
            onPressed: () => _renderer?.recenter(),
            child: const Text('Recenter'),
          ),
          TextButton(
            onPressed: () => unawaited(OpenXrSession.instance.exitImmersive()),
            child: const Text('Exit VR'),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            key: const ValueKey('scene-selector'),
            onPressed: () => setState(() => _selectorOpen = !_selectorOpen),
            icon: Icon(_selectorOpen ? Icons.tune : Icons.list),
            label: Text(_selectorOpen ? 'Example controls' : 'Scene selector'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Restart authored baseline',
          onPressed: _switching ? null : () => unawaited(_select(_selected)),
          icon: const Icon(Icons.refresh),
        ),
        FilledButton(
          onPressed: _away ? null : _enterVr,
          child: const Text('Enter VR · restart baseline'),
        ),
      ],
    );
  }

  Widget _help() => SingleChildScrollView(
    key: const PageStorageKey('vr-gallery-help'),
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _selected,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(galleryVrNotes[_selected] ?? 'Not audited for VR yet.'),
        const Divider(height: 32),
        const Text(
          'Quest controls',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          galleryVrControlsHelp,
          style: TextStyle(fontSize: 20, height: 1.4),
        ),
      ],
    ),
  );

  // Each crop has its own bounded overlay so authored menus cannot escape
  // onto the other independently positioned panel. The example is mounted once.
  Widget _panel(double width, Widget child) => SizedBox(
    width: width,
    child: ClipRect(
      child: Navigator(
        pages: [
          MaterialPage(
            child: Material(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ],
        onDidRemovePage: (_) {},
      ),
    ),
  );

  Widget _immersiveBody() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _panel(
        openXrGalleryQuad.panelSplitPixels.toDouble(),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_GalleryTab>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                minimumSize: WidgetStatePropertyAll(Size(0, 56)),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
              segments: const [
                ButtonSegment(
                  value: _GalleryTab.examples,
                  label: Text('Examples'),
                ),
                ButtonSegment(
                  value: _GalleryTab.controls,
                  label: Text('Controls'),
                ),
                ButtonSegment(
                  value: _GalleryTab.settings,
                  label: Text('Settings'),
                ),
                ButtonSegment(value: _GalleryTab.help, label: Text('Help')),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) =>
                  setState(() => _tab = selection.single),
            ),
            _controls(),
            const SizedBox(height: 8),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Offstage(
                      offstage: _tab != _GalleryTab.controls,
                      // Keep the scene and its native callback mounted across tabs.
                      // Only the controls are hidden; OpenXR still drives rendering.
                      child: _example(),
                    ),
                  ),
                  if (_tab == _GalleryTab.examples)
                    Positioned.fill(child: _selector()),
                  if (_tab == _GalleryTab.help) Positioned.fill(child: _help()),
                  Positioned.fill(
                    child: Offstage(
                      offstage: _tab != _GalleryTab.settings,
                      child: IgnorePointer(
                        ignoring: _switching,
                        child: GallerySettingsSidebar(
                          onResetSettings: () =>
                              _select(_selected, factorySettings: true),
                          key: ValueKey('settings-$_selected-$_generation'),
                          embedded: true,
                          resolutionBase: Size(
                            OpenXrSession
                                .instance
                                .nativePerformance
                                .value
                                .recommendedEyeWidth
                                .toDouble(),
                            OpenXrSession
                                .instance
                                .nativePerformance
                                .value
                                .recommendedEyeHeight
                                .toDouble(),
                          ),
                          onRenderScale: _setEyeRenderScale,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Text(
              _selected,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (_error != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 18, color: Colors.orange),
                  ),
                ),
              ),
          ],
        ),
      ),
      _panel(
        (openXrGalleryQuad.textureWidthPixels -
                openXrGalleryQuad.panelSplitPixels)
            .toDouble(),
        Column(
          children: [
            Expanded(
              child: OpenXrPerformancePanel(
                nativePerformance:
                    OpenXrSession.instance.nativePerformance.value,
                flutterPerformance: _flutter,
                history: _history,
                exampleName: _selected,
                shadowsEnabled: gallerySceneShadows(_scene),
                resolutionDetails: _resolutionDetails(),
                quality: _scene == null
                    ? 'Awaiting active scene settings'
                    : gallerySceneQuality(_scene!),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Trigger the FPS button to hide/show UI.\nScene and stats keep running.',
                style: TextStyle(
                  fontSize: 20,
                  height: 1.35,
                  color: Color(0xFFC5D0DF),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Future<double> _setEyeRenderScale(double scale) {
    if (_switching || _pendingEyeResize != null) {
      return Future.error(
        StateError('Wait for the current scene or resolution change.'),
      );
    }
    final resize = _applyEyeRenderScale(scale);
    _pendingEyeResize = resize;
    return resize.whenComplete(() {
      if (identical(_pendingEyeResize, resize)) _pendingEyeResize = null;
    });
  }

  Future<double> _applyEyeRenderScale(double scale) async {
    final previousSettings = exampleSettings;
    final applied = await OpenXrSession.instance.setRenderScale(scale);
    _eyeRenderScale = applied;
    // Do not mutate a saved Custom instance while selecting another preset.
    // Only synchronize here if its sidebar was replaced during the await.
    if (!identical(previousSettings, exampleSettings)) {
      exampleSettings.renderScale = applied;
    }
    return applied;
  }

  Widget _resolutionDetails() {
    final native = OpenXrSession.instance.nativePerformance.value;
    final view = View.of(context);
    final actual = native.eyeWidth * native.eyeHeight;
    final baseline = native.recommendedEyeWidth * native.recommendedEyeHeight;
    return Text(
      [
        'Recommended: ${native.recommendedEyeWidth}×${native.recommendedEyeHeight} px / eye',
        if (baseline > 0)
          'Eye scale: ${(native.renderScale * 100).round()}% · pixels: ${(actual / baseline * 100).round()}% of recommended',
        'Flutter surface: ${pixelDimensions(view.physicalSize)}',
        'Logical UI: ${pixelDimensions(view.physicalSize / view.devicePixelRatio)} · DPR ${view.devicePixelRatio.toStringAsFixed(2)}',
        'Panel atlas: ${openXrGalleryQuad.textureWidthPixels}×${openXrGalleryQuad.textureHeightPixels} px · FPS HUD: 460×130 px',
        'Eye targets ≠ physical display resolution (not exposed by OpenXR).',
      ].join('\n\n'),
      style: const TextStyle(fontSize: 18, height: 1.4),
    );
  }

  Widget _flatBody(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: _example()),
      Positioned(top: 12, left: 12, right: 12, child: _controls()),
      if (_selectorOpen)
        Positioned(
          top: 80,
          left: 12,
          bottom: 90,
          width: 360,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _selector(),
            ),
          ),
        ),
      Positioned(
        top: 80,
        right: 12,
        bottom: 180,
        child: Align(
          alignment: Alignment.topRight,
          child: IgnorePointer(
            ignoring: _switching,
            child: GallerySettingsSidebar(
              onResetSettings: () => _select(_selected, factorySettings: true),
            ),
          ),
        ),
      ),
      Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error ??
                  'Flat · $_selected · scene ${_flutter.sceneHz.toStringAsFixed(1)} Hz · '
                      'UI ${_flutter.flutterHz.toStringAsFixed(1)} Hz · raster p95 ${_flutter.rasterP95Ms.toStringAsFixed(1)} ms\n'
                      'Viewport ${MediaQuery.sizeOf(context)} logical · DPR ${MediaQuery.devicePixelRatioOf(context)} · '
                      '${_scene == null ? "loading scene" : gallerySceneQuality(_scene!, immersive: false)}',
            ),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    OpenXrSession.instance.frames.removeListener(_uiStateChanged);
    _monitor.dispose();
    if (FlutterError.onError == _flutterError) {
      FlutterError.onError = _previousFlutterError;
    }
    if (ui.PlatformDispatcher.instance.onError == _asyncError) {
      ui.PlatformDispatcher.instance.onError = _previousAsyncError;
    }
    super.dispose();
  }

  // Raise the ordinary Material text ladder only for headset panels.
  // Do not scale the atlas or its hit coordinates to make text larger.
  ThemeData _vrPanelTheme() {
    final theme = ThemeData.dark(useMaterial3: true);
    const body = TextStyle(
      fontSize: 20,
      height: 1.35,
      color: Color(0xFFF4F7FB),
    );
    const small = TextStyle(
      fontSize: 18,
      height: 1.35,
      color: Color(0xFFC5D0DF),
    );
    const label = TextStyle(fontSize: 20, fontWeight: FontWeight.w600);
    return theme.copyWith(
      textTheme: theme.textTheme.copyWith(
        bodyLarge: body.copyWith(fontSize: 22),
        bodyMedium: body,
        bodySmall: small,
        titleLarge: body.copyWith(fontSize: 28, fontWeight: FontWeight.w600),
        titleMedium: body.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
        titleSmall: body.copyWith(fontWeight: FontWeight.w600),
        labelLarge: label,
        labelMedium: label.copyWith(fontSize: 18),
        labelSmall: label.copyWith(fontSize: 18),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFF4F7FB),
          minimumSize: const Size(0, 48),
          textStyle: label,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        textStyle: TextStyle(fontSize: 18, color: Colors.black),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: widget.immersive
          ? _vrPanelTheme()
          : ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: galleryBackgroundColor,
        body: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Gallery initialization failed: ${snapshot.error}'),
                    TextButton(
                      onPressed: () => setState(() => _ready = _initialize()),
                      child: const Text('Retry'),
                    ),
                    if (widget.immersive)
                      TextButton(
                        onPressed: () =>
                            unawaited(OpenXrSession.instance.exitImmersive()),
                        child: const Text('Return to flat'),
                      ),
                  ],
                ),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return widget.immersive ? _immersiveBody() : _flatBody(context);
          },
        ),
      ),
    );
    if (!widget.immersive) return app;
    return Transform.flip(
      flipX: true,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: OpenXrQuadInput(configuration: openXrGalleryQuad, child: app),
      ),
    );
  }
}
