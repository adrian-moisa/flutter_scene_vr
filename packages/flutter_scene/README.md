# Flutter Scene VR fork

**Experimental VR fork of [bdero/flutter_scene](https://github.com/bdero/flutter_scene),
maintained by [Adrian Moisa](https://github.com/adrian-moisa).** This repository
works with the companion [flutter_vr engine fork](https://github.com/adrian-moisa/flutter_vr)
to demonstrate Flutter Scene on the web and in native Meta Quest VR. The
original Flutter Scene README is preserved below this addendum.

Demo setup snapshot: **31 August 2026**.

## Why we forked Flutter and Flutter Scene

While adding VR to Visual Space, we wanted to keep one 3D engine across the
ordinary application and the headset. Maintaining Flutter Scene on web/desktop
and a second native world renderer on Quest would duplicate scene features,
materials, lighting, shadows, and performance work.

The first Flutter Scene VR path rendered stereo images through Flutter's
compositor into an Android surface, then copied them into the headset's eye
images. Flutter Scene was already drawing real GPU geometry; the extra cost
was in presentation, buffering, copies, and synchronization.

These two forks let Flutter Scene render directly into OpenXR-owned eye targets.
The Flutter fork supplies generic external GPU surfaces and Android GLES
interoperation. This fork supplies render-to-target support, stereo frame
coordination, an OpenXR plugin, and the demo. OpenXR owns tracking, controllers,
swapchains, and headset presentation. Flutter still supplies the widget panels.

| Start the example on… | Scene rendering and presentation |
| --- | --- |
| **Chrome / web** | Flutter Scene's WebGL2 backend inside the ordinary Flutter gallery. No headset or native engine compilation is needed for this mode. |
| **Meta Quest VR** | Flutter Scene → Flutter GPU/Impeller GLES → borrowed OpenXR eye images → native stereo presentation. Widgets use separate floating UI surfaces. Requires the custom compiled Flutter engine. |

The native Quest world is not a web page or a flat screenshot placed in front
of the user. Conversely, opening Chrome does not start a native OpenXR session
or promise WebXR support. The shared renderer and examples have different
platform presentation paths.

## 1. Get the forks and select Flutter

The documented engine-build host is **macOS on Apple Silicon**, targeting an
**ARM64 Meta Quest 3**. Start with the
[Flutter VR setup guide](https://github.com/adrian-moisa/flutter_vr/tree/vr#flutter-vr-fork):
it covers SDK installation, `PATH`/IDE selection, engine dependencies, and the
memory-conscious Android/host build. Keep stock Flutter installed separately.
For a web-only first look, you can stop before compiling the native engine,
but still use the fork SDK and matching Dart GPU source override below.

Use the same directory layout as that guide:

```text
~/Projects/flutter_vr/         Flutter SDK and engine source
~/Projects/depot_tools/        Engine dependency/build tools
~/Projects/flutter_scene_vr/   This workspace and examples
```

```sh
export FLUTTER_VR_ROOT="$HOME/Projects/flutter_vr"
export PATH="$FLUTTER_VR_ROOT/bin:$PATH"
git clone --branch vr https://github.com/adrian-moisa/flutter_scene_vr.git "$HOME/Projects/flutter_scene_vr"
cd "$HOME/Projects/flutter_scene_vr"
git remote add upstream https://github.com/bdero/flutter_scene.git
```

Both forks keep their maintained VR changes on `vr`. Commit and push fork work
only to `origin/vr`; leave `master` untouched. Explicitly select `vr` when cloning
either fork, even if GitHub opens a different default branch.
Maintainers should select `vr` as each fork's default branch in GitHub repository
settings so repository visitors see the maintained code too.

For an existing clone, first commit or otherwise preserve any local work, then
fetch `origin`. If local `vr` does not exist, create it with
`git switch --create vr --track origin/vr`. If it exists, use `git switch vr`
and `git branch --set-upstream-to=origin/vr vr`. Do not reclone or discard local
changes. If `origin/vr` is missing, the maintainer must publish it first.

Use the fork revisions containing the VR changes. A stock Flutter installation
meeting the upstream README's version requirement does not include the external
surface API needed here. Do not switch channels or run `flutter upgrade` to
resolve a missing VR API.

### Select the matching `flutter_gpu` Dart sources

At this workspace's root, create a local `pubspec_overrides.yaml` containing:

```yaml
dependency_overrides:
  flutter_gpu:
    path: /absolute/path/to/flutter_vr/engine/src/flutter/lib/gpu
```

Replace that path with the absolute path to your Flutter fork. YAML does not
expand `$HOME`, `$FLUTTER_VR_ROOT`, or `~`. If the file already exists, merge
the `flutter_gpu` entry into its existing `dependency_overrides`; do not replace
other overrides. This machine-specific file is ignored by Git.

```sh
flutter pub get
```

This resolves the monorepo's local workspace packages. The native deployment
helper also creates this override when absent, but does not overwrite or repair
an existing file. Set it up here so the web gallery works before native deployment.
**`--local-engine` selects native binaries; it does not select this Dart package.**

The existing build hooks compile engine/gallery shaders, models, textures, and
materials during the app build. You do not need to run a separate shader script
or `flutter_scene:init` in these already configured examples. On the native
local-engine path, the host output must contain `impellerc` and its sibling
`shader_lib` directory. Do not copy in a compiler from an unrelated SDK.
Rapier normally downloads a prebuilt physics library; a source fallback needs
Rust/Cargo. Some gallery entries fetch external assets or require network access.

## 2. Start the main gallery on web

`examples/flutter_app` is the main example. Its platform scaffolding is generated
locally; create the web files once in a fresh clone:

```sh
cd "$HOME/Projects/flutter_scene_vr/examples/flutter_app"
flutter create . --platforms=web
flutter run -d chrome
```

No local-engine flags are needed for Chrome. Select **VR** in the gallery to
open the original VR demonstration scene as an ordinary interactive web scene;
the gallery also contains the upstream material, lighting, model, and effect
examples. Click the scene to focus it, drag to look around, use WASD or arrow
keys to move, Shift to move faster, the wheel to dolly, and R to restore the
authored camera. Overlays and settings keep their own input.

For Android Studio, open `examples/flutter_app`, set its Flutter SDK to the
`flutter_vr` root, and use `lib/main.dart` as the entrypoint. If Dart is not
detected, select `<flutter_vr>/bin/cache/dart-sdk`. Choose **Chrome** in the
toolbar device selector and leave additional run arguments empty. Opening the
whole Flutter engine source tree is unnecessary for running the gallery and
can trigger expensive IDE indexing.

## 3. Connect a Meta Quest

Install Android SDK Platform Tools and put `adb` on `PATH`. The current Android
plugin uses SDK 36, NDK `28.2.13676358`, CMake 3.22.1 or newer, and ARM64; follow
the companion Flutter guide for the host/toolchain setup.

1. Complete Meta's developer account/device setup and enable Developer Mode
   for the headset in the Meta Horizon app. Follow
   [Meta's device setup instructions](https://developers.meta.com/horizon/documentation/native/android/mobile-device-setup/)
   for the current account requirements and menus.
2. Connect Quest with a USB **data** cable, wake/unlock it, and accept the
   **USB debugging** authorization inside the headset. File-transfer permission
   is not the same authorization.
3. Check the connection:

```sh
adb devices -l
```

Your headset must be listed as `device`, not `unauthorized` or `offline`.
For `unauthorized`, put the headset on and approve debugging. If nothing appears,
check Developer Mode, the cable/USB port, and whether another ADB installation
is conflicting. Select a particular headset when several are connected:

```sh
export ANDROID_SERIAL='YOUR_HEADSET_SERIAL'
adb -s "$ANDROID_SERIAL" shell getprop ro.product.model
```

USB is the simplest first-run connection. For wireless development, connect and
authorize over USB first, put the headset and computer on the same trusted
network, then enable **ADB over Wi-Fi** in Meta Quest Developer Hub's Device
Manager. Use the `IP:port` entry from `adb devices -l` as `ANDROID_SERIAL`, since
the helper's automatic discovery looks for USB devices. Reconnect USB if the
wireless session disappears after a restart. See
[Meta's ADB guide](https://developers.meta.com/horizon/documentation/unity/ts-adb/)
and [MQDH device management](https://developers.meta.com/horizon/documentation/unity/ts-mqdh-basic-usage/).

## 4. Build, install, and enter native VR

First finish **both** engine builds in the Flutter fork guide. The native host
is `examples/openxr_quest`; it reuses the main gallery's registry and examples.
Its Android project is already checked in, so do not run `flutter create` there.

From this repository root:

```sh
cd "$HOME/Projects/flutter_scene_vr"
export QUEST_FLUTTER="$FLUTTER_VR_ROOT/bin/flutter"
export QUEST_LOCAL_ENGINE_SRC_PATH="$FLUTTER_VR_ROOT/engine/src"
export QUEST_LOCAL_ENGINE=android_profile_arm64
export QUEST_LOCAL_ENGINE_HOST=host_profile_arm64
export QUEST_BUILD_MODE=profile

./examples/openxr_quest/tool/quest-build-and-deploy-local-forks.sh
```

Set these paths explicitly: the helper's fallback paths refer to the maintainer's
machine. It checks the engine artifacts, resolves dependencies, builds the ARM64
profile APK, stops the previous demo, installs the new APK, and launches the
immersive OpenXR activity. It does **not** compile Flutter's engine for you.
Keep the headset awake and its controllers available while starting.

The APK is written to
`examples/openxr_quest/build/app/outputs/flutter-apk/app-profile.apk`.
It is a development demo, not a store-ready distribution. Use the
**local-forks** helper; the other deployment helper is for an environment where
the required engine APIs are already integrated.

The same Android app also has a flat gallery and an Enter VR action. Switching
between **Flat mode** and VR retains the selected example, but restarts its
authored settings: tuned slider state does not transfer between the separate
Android processes.

### Inside the headset

| Control | What it does |
| --- | --- |
| **Examples** | Select a scene without leaving the immersive session. Choose **VR** for the original demonstration. |
| **Controls** | Show that example's Flutter controls; **VR → Controls → Enable shadows** toggles shadows live. |
| **Settings** | Open shared graphics and resolution controls. |
| Aim + trigger | Click panel buttons, checkboxes, and other controls. |
| Aim at a panel + that hand's stick | Scroll the panel. Point away from panels to navigate the scene. |
| Left stick / right stick | Orbit the scene target / move the camera rig and target. Physical head tracking remains independent. |
| Aim + hold grip | Move a floating panel; use the same hand's stick to push it away or pull it closer, then release to leave it there. |
| **Recenter** / panel-reset icon | Reset the camera / restore the floating-panel layout. |
| Small native **FPS / UI ON** button | Hide/suspend Flutter widget panels; trigger again to restore them. Scene rendering and statistics continue. |

Not every gallery example or interaction has a native VR mapping. The current
registry keeps Multiplayer, DICOM Volume, External Texture, and Split Screen
flat-only; other examples can have interaction or device-service limitations.
The [gallery report](https://github.com/adrian-moisa/flutter_scene_vr/blob/vr/examples/openxr_quest/GALLERY_VR_REPORT.md)
separates adapted examples from physically verified ones.

## 5. Show the demo on a laptop

Use **Meta Quest Developer Hub (MQDH)** to connect the headset and cast/record
the running VR experience on your computer. Its Device Manager provides
casting, screenshots, and video capture; see
[Meta's MQDH debugging tools](https://developers.meta.com/horizon/documentation/spatial-sdk/ts-mqdh-media/).
If MQDH and the terminal disagree about connected devices, configure MQDH to
use the same Android SDK `adb` executable.

Casting is a view of the application running on Quest; this workflow does not
require Quest Link or PC VR streaming. Operate VR with the headset controllers.
For a laptop-only interactive presentation, run the Chrome gallery and select
the same example. The browser and headset are separate app sessions, not
automatically synchronized controls. A cast is useful for explaining the demo,
but headset comfort, stereo depth, sharpness, and tracking must be judged while
wearing the headset. Keep the headset's safety boundary enabled when using VR.

## Settings and performance

This is a working rendering demo, **not yet a highly optimized VR engine**.
Some demanding gallery scenes remain slow. In the maintainer's original VR
demo, enabling shadows reduced the observed frame rate from roughly **70 FPS
to 40 FPS**. This is a scene/device/settings-specific observation, not a
controlled benchmark or a promise for other machines and examples.

Start with **VR**, compare shadows off/on, then explore heavier examples.
Shadows currently start enabled. To build with the original VR entry's shadows
initially disabled (other entries retain their authored defaults):

```sh
QUEST_SHADOWS=0 ./examples/openxr_quest/tool/quest-build-and-deploy-local-forks.sh
```

You can also use its live checkbox without rebuilding. **Settings** exposes
50%, 67%, 75%, and 100% resolution, plus **Low / Medium / High / Ultra / Custom**
graphics presets. On Quest those percentages scale the runtime-recommended eye
dimensions; on web they scale the current physical viewport render size. They
do not resize Flutter's UI to the same percentage. Half the width and height
means about one quarter of the scene pixels.

Presets change resolution and effects together. For an isolated comparison,
hold resolution and all other settings fixed while changing one effect.
Manual changes select **Custom**, saved per example for the current app session;
restarts and flat/VR process transitions do not preserve it. Ultra is a quality
comparison, not a recommended Quest performance baseline. See the
[Quest gallery guide](https://github.com/adrian-moisa/flutter_scene_vr/blob/vr/examples/openxr_quest/README.md)
for the current preset values.

The performance panel reports frame rates, timing, and actual render/atlas
sizes. The web **FPS** button is beside Settings. Distinguish scene submissions,
completed stereo frames, Flutter widget frames, runtime refresh rate, and GPU
time: a 72 Hz OpenXR loop alone does not prove 72 fresh displayed scene frames.
Runtime-recommended eye dimensions are not the headset's physical panel size.
Compare the same scene, viewpoint, resolution, effects, build mode, and warmed-up
headset conditions; exclude scene-switch and resolution-transition samples.

The native **FPS / UI** button helps isolate widget/panel cost by suspending
framework frame callbacks and panel texture work. It keeps the Flutter engine,
Dart isolate, Flutter GPU scene rendering, simulation, and stats alive. It does
not measure a renderer with Flutter removed. Widget-texture examples retain
their last captured widget image while UI is suspended.

Work already present in this fork includes:

- Direct eye output, removing the old full-size stereo Flutter surface and
  native eye-copy stage while keeping widget surfaces separate.
- One scene update for both eye views, bounded diagnostic history, and the
  ability to suspend UI work for comparisons.
- Conditional sharing of compatible shadow work between eyes, static shadow
  caster hints, and a bounded shadow setup for the original VR scene.
- Reduced intermediate work through single-channel depth passes, retained
  per-eye scene-color history, and shader/material changes that avoid some
  redundant texture sampling and depth-of-field calculations.

These are implemented changes, not a claimed measured speedup for every scene.
Sharing shadows has already been attempted and exists for compatible views,
but it does not remove shadow receiver sampling, filtering, or all update costs.
Shadows remain a major area for investigation. Next steps include profiling
individual GPU passes, improving shadow reuse/filtering, reducing intermediate
buffer bandwidth, tuning expensive effects for mobile GPUs, and investigating
multiview/foveation and less blocking synchronization. Those are ongoing or
future directions, not completed performance guarantees.

## Troubleshooting and keeping the forks current

| Symptom | Check first |
| --- | --- |
| Missing `Surface`, `SurfaceFrame`, or `openExternalSurface` | The local `flutter_gpu` override, selected Flutter SDK, and compatible fork revisions; then rerun `flutter pub get`. |
| Helper reports missing engine artifacts | Build both full engine targets; confirm source path, output names, and profile/debug/release agreement. |
| Shader compiler or asset build fails | Read the first hook error. Keep the matching host `impellerc` and `shader_lib` together; let the existing package hooks own generated assets. |
| No authorized Quest | Developer Mode, the in-headset debugging prompt, USB data cable, `adb devices -l`, and `ANDROID_SERIAL`. |
| App opens only as a flat Android window | Enter VR or use the local-forks helper's immersive launch. A normal Android launch alone is not an OpenXR session. |
| Poor FPS | Begin with the VR entry at lower resolution/effects, compare shadows and UI independently, and inspect timing rather than refresh rate alone. |

The intent is to contribute both forks upstream and periodically rebase them
while that work proceeds. The Flutter engine API requires broader design,
lifecycle, backend, and test review; the Scene changes are more contained but
depend on that engine work. Neither upstream acceptance nor timing is promised.
Performance and interaction validation remain part of the demo's development.

For a reproducible showcase, record both fork commit IDs. Preserve local work
before updating, follow compatible fork revisions, and rebuild both engine
outputs after engine/dependency changes. Refresh Scene dependencies and rebuild
the app so its hooks regenerate the appropriate assets. Do not publish local
SDK paths or assume an arbitrary upstream rebase remains compatible.

### Update or publish `vr`

For developers consuming the published fork, run from this checkout:

```sh
git switch vr
git pull --ff-only origin vr
flutter pub get
```

Maintainers commit changes on `vr` and publish ordinary new commits with
`git push -u origin vr`. To incorporate official changes, start from a clean
working tree, fetch both remotes, review any remote-only commits, then rebase:

```sh
git switch vr
git fetch origin
git log --oneline --left-right vr...origin/vr
git fetch upstream
git rebase upstream/master
```

Use `upstream` for `https://github.com/bdero/flutter_scene.git`; add that remote
if an older clone lacks it. Reconcile unexpected divergence before rebasing.
After checking compatibility with the Flutter `vr` checkout, publish a rewritten
history with `git push --force-with-lease origin vr`. Never push to `master`,
`main`, or `upstream`. A failed lease requires reviewing the remote changes.
Consumers whose fast-forward pull fails after a rebase or amend must reconcile
with the published `vr` history; switching to `master` is not a fix.

For implementation details, see the
[direct-rendering design/history](https://github.com/adrian-moisa/flutter_scene_vr/blob/vr/examples/openxr_quest/DIRECT_SWAPCHAIN_RENDERING.md).
Its dated measurements and earlier defaults are historical; use this addendum,
the current gallery guide, and the current helper for setup and launch.

## Original Flutter Scene README

The material below is preserved from upstream. Its published-package setup
describes ordinary Flutter Scene use; use the fork instructions above for this
VR demo.

---

<p align="center">
  <a href="https://fscene.dev">
    <img alt="Flutter Scene" width="220px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/DashColorTransparent.svg">
  </a>
</p>

<h1 align="center">Scene</h1>

<p align="center"><b>A realtime 3D engine for Flutter</b></p>

<p align="center">Scene extends Flutter into a complete toolkit for building incredible 3D multiplatform apps. Rendering, physics, audio, tooling, and a full asset pipeline.</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/flutter_scene"><img src="https://img.shields.io/pub/v/flutter_scene.svg?style=popout"/></a>
  <a title="Test" href="https://github.com/bdero/flutter_scene/actions/workflows/flutter.yml?query=event%3Apush+branch%3Amaster"><img src="https://github.com/bdero/flutter_scene/actions/workflows/flutter.yml/badge.svg?branch=master&event=push"/></a>
  <a title="Codemagic build status" href="https://codemagic.io/app/6a758ce0a34611cf3c8db6ae/smoke-macos/latest_build"><img src="https://api.codemagic.io/apps/6a758ce0a34611cf3c8db6ae/smoke-macos/status_badge.svg"/></a>
  <a title="Covered by Argos Visual Testing" href="https://app.argos-ci.com/scene/flutter_scene"><img src="https://argos-ci.com/badge.svg" alt="Covered by Argos Visual Testing"/></a>
  <a title="Discord" href="https://discord.gg/BfGKrcheRj"><img src="https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white"/></a>
</p>

<p align="center"><a href="https://fscene.dev">Website</a> · <a href="https://fscene.dev/getting-started">Docs </a>· <a href="https://github.com/bdero/flutter_scene/tree/master/examples">Examples App</a> · <a href="https://github.com/bdero/flutter_scene?tab=readme-ov-file#faq">FAQ</a></p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/HelmetPhase2.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/dashgameported2.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/dashsurfers_run.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/DamagedHelmet2.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/dash_physics.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/editor_mcp.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/hexagons3.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/menger_sky.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/cloning.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/gaussian_splats_strawberry.webp">
</p>

<p align="center">
  <img alt="Flutter Scene" width="600px" src="https://raw.githubusercontent.com/bdero/flutter_scene_media/main/dashmap.webp">
</p>

## Why Scene exists

Scene began its life inside the Flutter Engine, as a C++ module for Impeller with a declarative widget interface exposed through a 3D API in the Flutter SDK. Flutter GPU was built initially to set this project free, providing the low-level GPU access needed to develop Scene outside the engine, as an ordinary ecosystem of Dart packages.

That origin shapes the project's philosophy. Scene is a full 3D engine and toolkit that makes Flutter GPU practical to build on, spanning rendering, physics, audio, editor tooling, and asset support across every target Flutter runs on. And the relationship flows both ways by design. The work of building Scene continually exercises and improves Flutter's internal graphics stack, so Impeller and Flutter GPU get better because Scene exists.

The goal has always been to pave the way for advanced graphics in Flutter. In line with the goals set out in Flutter GPU's original design doc, Scene aims to de-fracture, unite, and elevate Flutter's graphics ecosystem, so that building incredible 3D experiences with Flutter and Dart no longer requires engine forks, complicated external renderer integrations, or giving up platforms to get advanced features.

Scene is built by a former core Flutter engine team member who spent four years on Flutter, most of it building Impeller and Flutter GPU.

## Getting started

```sh
flutter pub add flutter_scene
dart run flutter_scene:init
```

`init` sets up the asset pipeline, which is the recommended way to use Scene.
Drop sources under `assets/`, load them by their source path, and render:

```dart
final level = await loadScene('assets/level.glb');
scene.add(level);
// ...
SceneView(scene, cameraBuilder: (elapsed) => PerspectiveCamera(...));
```

The same code runs on web, and the engine's shaders are compiled for you during
the build by flutter_scene's own build hook. Rendering goes through Flutter GPU,
which is off by default, so enable it once per platform (below). The web needs
nothing.

Impeller, which Flutter GPU builds on, is the default renderer on every native
platform as of 3.47, so there is nothing to do for it.

### Coding agents

This package ships a set of agent skills so a coding assistant writes idiomatic
Scene instead of guessing: correct usage and traps, the run-settle-capture
verification loop, copy-paste look presets, procedural content, and
performance. `dart run
flutter_scene:init` offers to install them, and `dart run flutter_scene:skills`
installs, updates, or checks them on their own without touching your build hook.
Upgrading Scene can carry newer revisions; `dart run flutter_scene:skills
--check` reports whether any are available.

### Enable Flutter GPU

While developing, pass the flags on the command line:

```sh
flutter run --enable-flutter-gpu
```

To turn it on permanently, for every run and for the app you ship, edit the
platform file:

| Platform | File | Add |
| --- | --- | --- |
| iOS | `ios/Runner/Info.plist` | `<key>FLTEnableFlutterGPU</key><true/>` |
| Android | `android/app/src/main/AndroidManifest.xml`, in `<application>` | `<meta-data android:name="io.flutter.embedding.android.EnableFlutterGPU" android:value="true" />` |
| macOS | `macos/Runner/Info.plist` | `<key>FLTEnableFlutterGPU</key><true/>` |
| Web | nothing | |

Windows and Linux set it on the `DartProject` their runner builds. This needs Flutter 3.47.1.

```c
// linux/runner/my_application.cc
g_autoptr(FlDartProject) project = fl_dart_project_new();
fl_dart_project_set_enable_flutter_gpu(project, TRUE);
```

```cpp
// windows/runner/main.cpp
flutter::DartProject project(L"data");
project.set_enable_flutter_gpu(true);
```

On 3.47.0 there is no such setting, so desktop takes the command-line flags per run, and release builds compile the engine's environment switches out, meaning a shipped Windows or Linux release needs 3.47.1.

### A scene with no assets

The built-in geometry needs no asset pipeline, so a cube renders straight after `flutter pub add flutter_scene`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() => runApp(const MaterialApp(home: CubeView()));

class CubeView extends StatefulWidget {
  const CubeView({super.key});

  @override
  State<CubeView> createState() => _CubeViewState();
}

class _CubeViewState extends State<CubeView> {
  final Scene scene = Scene();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    // Geometry and materials touch the shader bundle, so build them once the
    // engine's static resources are up.
    Scene.initializeStaticResources().then((_) {
      scene.add(
        Node(
          mesh: Mesh(
            CuboidGeometry(vm.Vector3(1, 1, 1)),
            PhysicallyBasedMaterial(),
          ),
        ),
      );
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SizedBox.expand();
    return SceneView(
      scene,
      camera: PerspectiveCamera(position: vm.Vector3(2, 2, -4)),
    );
  }
}
```

The scene's default studio environment lights it, so there is nothing else to set up.

### Moving a node

Every `Node` carries a transform relative to its parent. Read and write it one
component at a time, or as a whole matrix through `node.localTransform`.

```dart
node.position = vm.Vector3(0, 1, 0);
node.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), 0.5);
node.scale = vm.Vector3.all(2);
node.position += vm.Vector3(0, 0.1, 0);
```

Each getter returns a copy, so `node.position.y = 1` moves nothing. Assign the
value back instead. Debug builds throw on an edit that cannot reach the node,
whether it is to a returned copy or to `localTransform` in place.

### Built-in geometry

Every class below builds vertex data for you and drops into a `Mesh` the same way `CuboidGeometry` does above.

- Primitives: `CuboidGeometry`, `SphereGeometry`, `IcosphereGeometry`, `CapsuleGeometry`, `CylinderGeometry`, `TorusGeometry`, `PlaneGeometry`, `DiscGeometry`, `RingGeometry`, `WedgeGeometry`.
- Swept along a path or profile: `ExtrudeGeometry`, `TubeGeometry`, `RibbonGeometry`.
- Lines and camera-facing quads: `PolylineGeometry`, `LineSegmentsGeometry`, `BillboardGeometry`.
- Your own vertex data: `MeshGeometry` and `GeometryBuilder`.

### The asset pipeline

`init` writes a `hook/build.dart` that converts your assets at build time,
creates `flutter_scene_generated/` with a `.gitignore` for its outputs, and adds
that one directory to `flutter.assets` in your `pubspec.yaml`. It is safe to run
again, and it will not overwrite a `hook/build.dart` you wrote yourself. It
prints a block to paste into your existing `build()` callback instead.

The hook it writes discovers `.glb` and `.fscene` models, `.fmat` materials, and
loose images under `assets/`, and converts each one:

```dart
// hook/build.dart
import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    buildScenes(buildInput: input, buildOutput: output);
    await buildMaterials(buildInput: input, buildOutput: output);
  });
}
```

The one line it adds to your `pubspec.yaml`:

```yaml
flutter:
  assets:
    - flutter_scene_generated/
```

Upgrading from an earlier version, run it again. Generated assets now go into
that directory on every Flutter release, so re-running `init` migrates the hook
it wrote and adds the pubspec entry. A hook still asking for a removed asset
mode fails the build and names its replacement.

From then on, drop sources under `assets/` and load them by source path:

```dart
final level = await loadScene('assets/level.glb');
final toon = await loadFmatMaterial('assets/toon.fmat');
final ground = await loadTexture('assets/ground.png');
```

A `.glb` has to be parsed and unpacked into GPU-ready form every time the app
loads it. The pipeline does that work once, at build time, into the `.fsceneb`
format the engine reads directly, so loading a model at runtime costs far less.
Prefer it for anything that ships with your app. It is also how `.fmat` custom
materials and block-compressed textures with full mip chains reach you, and
editing any source reconverts just that source and hot reloads it.

Keep your sources in version control. The generated directory holds compiled
output tied to the Flutter engine that built it, which is why the hook manages
its `.gitignore` for you.

For a model that only exists once the app is running, because you download it or
the user supplies it, import the `.glb` directly with
`Node.fromGlbAsset('assets/model.glb')`. That needs no hook, and it parses the
glTF on every load, so prefer the pipeline whenever the model ships with you.

### Where to go next

[fscene.dev](https://fscene.dev) carries the full documentation. [Your first
scene](https://fscene.dev/getting-started/your-first-scene/) renders something on
screen from here, and the [guides](https://fscene.dev/guides/) cover each
subsystem in depth with live demos, including [assets and
loading](https://fscene.dev/guides/assets-and-loading/), [materials](https://fscene.dev/guides/materials/),
[lighting and environment](https://fscene.dev/guides/lighting-and-environment/),
[animation](https://fscene.dev/guides/animation/), and [cameras](https://fscene.dev/guides/cameras/).
The [API reference](https://fscene.dev/api/flutter_scene/latest/) documents every
public symbol.

## Requirements

Flutter Scene is pre-1.0 and evolving quickly. Minor releases can carry breaking changes, and every change is documented in the [CHANGELOG](https://github.com/bdero/flutter_scene/blob/master/packages/flutter_scene/CHANGELOG.md).

- Flutter 3.47 (stable) or newer. Rendering is built on [Flutter GPU](https://github.com/flutter/flutter/blob/main/docs/engine/impeller/Flutter-GPU.md), which every platform except the web needs turned on once (see [Enable Flutter GPU](#enable-flutter-gpu)).
- On native platforms rendering runs on [Impeller](https://docs.flutter.dev/perf/impeller#availability), Flutter's default renderer on every native platform as of 3.47. The web has no Impeller, so the package ships its own WebGL2 backend and runs there without flags.

## Features

### Rendering

* Physically based materials with image-based lighting, plus a built-in procedural studio environment so an imported model looks good with zero lighting setup.
* Directional, point, and spot lights. Directional and spot lights cast shadows, with cached shadow tiles for static geometry and alpha-masked shadow casters.
* A full post-processing stack, with HDR tone mapping, physical camera exposure, automatic eye adaptation, bloom, fog, god rays, screen-space reflections, depth of field with bokeh, and anti-aliasing with resolution scaling.
* Sky materials with live IBL rebaking, HDR/EXR environment import, and smooth environment cross-fades.
* 3D Gaussian splatting, loading `.ply` and `.splat` captures as scene nodes.
* Instanced rendering, automatic geometry LODs, and an allocation-light frame loop.
* A particle system driven by configurable emitter and behavior modules.

### Materials and shaders

* A custom-material workflow (`.fmat`) covering both fragment and vertex stages, with shader hot reload.
* Per-frame scene inputs for custom shaders, including scene depth and shadow data, plus a depth-aware and shadow-aware custom post-pass API.
* A noise library with matched CPU and GPU implementations.

### Assets and animation

* glTF (`.glb`) import at runtime, or pre-converted at build time into the engine's `.fsceneb` format through build hooks, loaded by source path.
* The `.fscene`/`.fsceneb` scene description format, human-readable as text and fast to load as binary, with prefab support.
* KTX2 compressed textures with full mip chains, `.fstex` texture builds, and HDR/EXR environment decoding.
* Skinned meshes and a blended animation system, with declarative per-clip playback control.
* `KHR_materials_variants` support in both import paths, with instant variant switching.
* Hot reload for models, shaders, textures, and environments.

### App integration

* A `SceneView` widget with both an imperative scene-graph API and a fully declarative widget API (`SceneNode`, `SceneMesh`, and `SceneModel` with async loading placeholders).
* Interactive Flutter widgets embedded on 3D surfaces, with pointer raycasting into the scene.
* Screen-reader accessibility, exposing scene content through Flutter semantics.
* Render-target control, split-screen and multi-view layouts, and synchronous frame capture as `ui.Image`.
* Geometry readback and procedural geometry builders with derivation operations.

### Ecosystem

* Physics through [`flutter_scene_rapier`](https://pub.dev/packages/flutter_scene_rapier) or [`flutter_scene_box3d`](https://pub.dev/packages/flutter_scene_box3d), both implementing the engine's shared physics contract.
* Audio components with SoLoud and FMOD backends, developed in this repository.
* The Flutter Scene Editor, a desktop scene-editing app with an MCP server for agent-driven editing, in development in this repository.

## FAQ

### **Q:** What platforms does this package support?

On native platforms `flutter_scene` runs anywhere [Impeller](https://docs.flutter.dev/perf/impeller#availability) does. On the web it runs on a built-in WebGL2 backend.

Every native platform needs Flutter GPU turned on. Impeller, which it builds on, is already the default everywhere. [Enable Flutter GPU](#enable-flutter-gpu) has the file and the key for each.

On the web, no flags are needed; it works under both the CanvasKit and Skwasm renderers.

|         Platform | Status                          |
| ---------------: | :------------------------------ |
|              iOS | 🟢 Supported                     |
|          Android | 🟢 Supported                     |
|              Web | 🟢 Supported                     |
|            MacOS | 🟢 Supported                     |
|          Windows | 🟢 Supported (3.47.1 to ship a release) |
|            Linux | 🟢 Supported (3.47.1 to ship a release) |
| Custom embedders | 🟢 Supported                     |

### **Q:** How does web support work?

Impeller and Flutter GPU aren't available on the web, so `flutter_scene` ships a built-in WebGL2 backend (a drop-in for `flutter_gpu`) and renders through it there. It works under both the CanvasKit and Skwasm web renderers, with no extra flags or configuration.

## Sponsors

Scene's development infrastructure is supported by:

- [Codemagic](https://codemagic.io) - macOS CI on Apple silicon hardware

Interested in supporting Scene's development? Reach out: x@bdero.me

## Repository

This repository is a [pub workspace](https://dart.dev/tools/pub/workspaces) containing the engine, its companion packages, and the example apps:

| Path | Description |
| --- | --- |
| [`packages/flutter_scene`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene) | The 3D engine, including the glTF importer, the `.fscene` format, and the web (WebGL2) backend. Published to pub.dev as [`flutter_scene`](https://pub.dev/packages/flutter_scene). |
| [`packages/flutter_scene_rapier`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_rapier) | Rapier physics backend, shipping prebuilt native binaries and a wasm module. Published to pub.dev as [`flutter_scene_rapier`](https://pub.dev/packages/flutter_scene_rapier). |
| [`packages/flutter_scene_box3d`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_box3d) | box3d physics backend. Published to pub.dev as [`flutter_scene_box3d`](https://pub.dev/packages/flutter_scene_box3d). |
| [`packages/flutter_scene_soloud`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_soloud) | SoLoud audio backend. Not yet published. |
| [`packages/flutter_scene_fmod`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_fmod) | FMOD Studio audio backend. Not yet published. |
| [`packages/flutter_scene_editor_core`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_editor_core), [`packages/flutter_scene_editor`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_editor), [`packages/flutter_scene_mcp`](https://github.com/bdero/flutter_scene/tree/master/packages/flutter_scene_mcp) | The Flutter Scene Editor stack (headless command core, Flutter UI, and MCP tool surface). Shipped as the desktop app under `apps/`, not as pub.dev libraries. In active development. |
| [`apps/flutter_scene_editor_app`](https://github.com/bdero/flutter_scene/tree/master/apps/flutter_scene_editor_app) | The standalone Flutter Scene Editor desktop app. |
| [`examples/flutter_app`](https://github.com/bdero/flutter_scene/tree/master/examples/flutter_app) | Runnable example app with 40 feature examples. |

The remaining `examples/` folders are dev-only test harnesses (the web-backend smoke test, deterministic smoke renders, and a CPU stress bench).

To run the example app from a fresh clone:

```sh
flutter pub get                                             # resolves the workspace

cd examples/flutter_app
flutter create . --platforms=macos,ios,android,linux,windows,web  # generate gitignored platform stubs
flutter run --enable-flutter-gpu                              # native; add `-d <device>` if needed
flutter run -d chrome                                         # web
```

Pass `--dart-define=FLUTTER_SCENE_PROFILE=true` to print 120-frame render graph, culling, encoding, instance packing, binding, byte, draw, and instance summaries. Multiple active `RenderView`s share the counters.
