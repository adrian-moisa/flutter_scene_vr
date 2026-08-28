# Direct OpenXR swapchain rendering

Historical design and build record: branch names, UI sizes, defaults, and pending
checks below describe the stages recorded here. Use the [gallery guide](README.md)
and [gallery report](GALLERY_VR_REPORT.md) for the current host and later build evidence.

This document records the starting point and verification contract for moving
the Flutter Scene world from Flutter Canvas presentation to borrowed OpenGL ES
eye targets. Measurements from different artifacts or headset states are kept
separate so an idle runtime, a stale APK, or compositor cadence cannot be
mistaken for fresh Flutter world frames.

## Recorded repository state

The feature branches were created without fetching, pulling, rebasing, or
upgrading any checkout.

| Repository | Starting branch | Starting commit | Starting worktree |
| --- | --- | --- | --- |
| Flutter SDK and Engine | `master` | `b25d94d7c9d86527ccd765751fd5b0abe21db30b` | clean; 314 commits behind `origin/master` |
| Flutter Scene | `master` | `01b163355d712881eef49c2631fd6e2e0efdc563` | clean; 5 commits ahead of `origin/master` |
| Visual Space | `develop` | `c254b8d769837a69f6173e969205e2d2a4b8ebaa` | pre-existing unrelated Poly and live-app notification changes preserved |

All three checkouts now use
`codex/direct-flutter-scene-xr-swapchains` at those exact commits. The Flutter
GPU surface work from `cc6d73260e1f866604c8845fc09a73d2a05fa983` is already
an ancestor of the recorded Flutter Engine commit.

## Existing demo render path

The demo referred to as `fs_vr` is `examples/openxr_quest`, backed by
`packages/flutter_scene_openxr`.

```text
OpenXrSceneView
  -> SceneView and CustomPainter
  -> Scene.renderViews
  -> one renderer-owned Flutter GPU texture per eye
  -> Texture.asImage
  -> Canvas.drawImageRect into a side-by-side stereo surface
  -> Android SurfaceTexture / GL_TEXTURE_EXTERNAL_OES
  -> native full-screen eye crop and copy
  -> acquired OpenXR eye swapchains
```

At the recorded configuration each eye is 1680 by 1760 pixels. The world
producer surface is therefore 3360 by 1760 pixels before the optional 640 by
512 performance quad is appended. Native code correlates each Flutter buffer
with the tracked pose used to render it, then copies a fresh buffer into each
acquired eye image. A stale Flutter buffer reuses the most recently released
OpenXR image.

The implemented immersive-demo path is:

```text
OpenXR acquires and waits for both eye images
  -> a generic Flutter GPU external surface vends borrowed GLES targets
  -> Flutter Scene renders both explicit eye views in one scene tick
  -> the exact final color-writing command buffer presents each frame
  -> Android waits for GLES completion and deletes its per-frame local FBO
  -> both native completion callbacks become ready
  -> OpenXR releases both eye images and submits the projection layer
```

The borrowed target is single-sample and render-target-only. Flutter Scene
continues to own depth, stencil, MSAA, HDR, shadows, and post-processing
attachments. The native owner retains ownership of every FBO, swapchain image,
and frame token.

Flutter Scene exposes this renderer boundary through
`Scene.renderViewsToTargets`. A host supplies one `TargetedRenderView` per eye,
using either a `TextureSceneColorTarget` or a
`SurfaceFrameSceneColorTarget`. All eye views in the call observe the same
scene tick. A surface frame is presented against the exact command buffer that
writes its final display color; an exception or skipped frame discards the
lease. The existing `Scene.renderViews` and `SceneView` image/Canvas route
remains the desktop and web presentation path.

## Context and synchronization boundary

An FBO name is local to one GLES context and is not made portable by an EGL
share group. Passing an FBO integer created by the OpenXR context to Impeller
would therefore be invalid. The Android bridge instead exposes Flutter
Impeller's EGL display/config/share-context handles. OpenXR creates its GLES
context in that share group, making each acquired swapchain texture visible to
Flutter. On Flutter's raster thread the bridge creates a new context-local FBO,
attaches the shared texture, and lends that FBO to the generic surface registry
for exactly one frame.

Both eye images are acquired and waited before target delivery. One Dart method
call acquires both frames and calls `Scene.renderViewsToTargets` once, so both
eyes observe one scene tick. Calling Dart `present()` does not make either
image releasable: the engine completes the exact final command buffers' GPU
work before issuing terminal callbacks. Android then deletes both local FBOs
and receives both token-matched terminal callbacks before it releases either
OpenXR image. A timeout
first unregisters both surfaces; if either callback remains unresolved, the
host leaves both images acquired and tears down the session rather than
releasing an image that Flutter may still own.

The generic surface completion callback is issued only after the exact final
command buffer's GLES work has completed, not merely after `glFlush`. Android
therefore does not add a second completion wait before deleting its local FBO.

Direct output also removes the horizontal mirror and color/origin conversion
performed by the current OES copy shader. Eye basis, asymmetric projection,
vertical origin, and sRGB behavior must be validated explicitly rather than
carrying the old camera convention forward.

The generic engine facility is exposed to custom embedders through
`FlutterEngineRegisterExternalGpuSurface`,
`FlutterEnginePushExternalGpuSurfaceFrame`, and
`FlutterEngineUnregisterExternalGpuSurface`; Dart opens the matching identifier
with `GpuContext.openExternalSurface`. This is intentionally not an OpenXR API.
The Android embedding has a parallel generic `FlutterRenderer`/`FlutterJNI`
bridge for a shared GLES texture. It creates the required FBO only while
Impeller's raster context is current and reports presented, discarded,
surface-lost, or error exactly once during orderly engine lifetime. Android
engine teardown uses a bounded raster-thread drain; if forced teardown outlives
that drain, Java callback delivery is not guaranteed and native owners must
destroy rather than reuse the resource. GLES is the only supported backend;
unsupported renderers fail explicitly.

The Quest immersive entrypoint now always selects this direct stereo renderer;
there is no Canvas-world fallback flag. `OpenXrSceneView` remains available for
desktop/web and ordinary image/Canvas presentation, but the Quest demo no
longer mounts it. The Android `SurfaceTexture` is 640 by 512 for the optional
performance/UI quad, or 1 by 1 only to keep Flutter's ordinary onscreen context
available when no quad is configured. It no longer contains the 3360 by 1760
stereo world, and the native OES eye crop/copy function has been removed.

## Building the custom engine

The engine checkout must first have its normal Flutter Engine dependencies,
including `engine/src/flutter/third_party/skia`. From
`/Users/adrian/flutter/engine/src`, generate matching profile device and Apple
Silicon host configurations:

```sh
./flutter/tools/gn --android --android-cpu arm64 --runtime-mode profile --no-lto --no-enable-unittests
./flutter/tools/gn --mac-cpu arm64 --runtime-mode profile --no-lto --no-enable-unittests
ninja -C out/android_profile_arm64 -j 4
ninja -C out/host_profile_arm64 -j 2
```

The host configuration must disable LTO and unit tests for this deployment
build. A default optimized host build enables both link-time optimization and
Flutter's full unit-test and benchmark graph, which can launch many
multi-gigabyte LLVM linkers concurrently and is unnecessary for building the
Quest APK. The bounded job counts above keep compilation within a 24 GB Apple
Silicon machine's practical memory budget. If a previous build used the default
graph, rerun GN with these flags; Ninja retains compatible objects and stops
scheduling the removed test targets.

Then build the demo with the framework, Android embedding, and generated
`dart:ui` artifacts from that same engine revision:

```sh
cd /Users/adrian/Projects/flutter_scene_vr/examples/openxr_quest
/Users/adrian/flutter/bin/flutter \
  --local-engine-src-path /Users/adrian/flutter/engine/src \
  --local-engine android_profile_arm64 \
  --local-engine-host host_profile_arm64 \
  build apk --profile --target-platform android-arm64 \
  --dart-define=FLUTTER_SCENE_OPENXR_PERF_LOGS=true \
  --dart-define=FLUTTER_SCENE_PROFILE=true
```

The initial checkout could not generate those targets because
`engine/src/flutter/third_party/skia` was absent. A subsequent `gclient sync`
completed and populated that dependency; no successful local-engine build is
claimed until both Ninja targets below finish.

The integration-ready deployment helper uses the ordinary Flutter CLI and
assumes the Flutter Engine and Flutter Scene changes have both landed in the
selected SDK and package release:

```sh
cd /Users/adrian/Projects/flutter_scene_vr/examples/openxr_quest
QUEST_BUILD_MODE=profile QUEST_PERF_LOGS=1 QUEST_SHADOWS=0 \
  ./tool/quest-build-and-deploy.sh
```

Until those changes are integrated, use the local-forks helper. It defaults to
the checked-out Flutter SDK at `/Users/adrian/flutter`, the engine source at
`/Users/adrian/flutter/engine/src`, and the completed
`android_profile_arm64`/`host_profile_arm64` outputs. The paths and target names
remain overridable with the corresponding `QUEST_*` variables. The helper
defaults to a profile build with performance diagnostics enabled and directional
shadows disabled. It checks the engine artifacts and runtime mode before
touching the connected headset:

```sh
cd /Users/adrian/Projects/flutter_scene_vr/examples/openxr_quest
./tool/quest-build-and-deploy-local-forks.sh
```

## Pre-change build checkpoint

The exact recorded Flutter Scene commit successfully produced a profile ARM64
APK on 2026-08-30 with performance logging enabled:

```text
Artifact: build/app/outputs/flutter-apk/app-profile.apk
Size: 41,128,124 bytes
SHA-256: 216a4cb8087d09a38b822958489a8e6659103d5a9c29d073996a661b2ddb83fd
Build result: assembleProfile passed in 20.0 seconds
```

The connected device is a Meta Quest 3 (`eureka`, serial
`2G97C5ZJ0X030H`). Its active display mode was read as 4128 by 2208 at
72.00001 Hz, with 90 Hz and 120 Hz modes also advertised. The APK currently
installed on the headset was last updated on 2026-08-29 at 17:25:35 +0300 and
has SHA-256
`671272875381b5598653e9e56f34c16334a05224fa215cabe7aa9746392d7754`.
It is not the freshly built artifact, so it cannot supply the current baseline.

Installing and launching the fresh APK was blocked by the execution safety
gate pending explicit device-mutation approval. No fresh on-headset performance
claim is made here.

## Historical performance evidence

The detailed chronological evidence remains in `PERFORMANCE.md`. The closest
controlled active-wear results used Quest 3, profile ARM64, GLES Impeller,
1680 by 1760 pixels per eye, the same four-object scene, floor/grid, FXAA, and
72 Hz display mode.

- OpenXR submission stayed near 72 to 73 Hz.
- Flutter scene/completed-frame cadence reached about 71 to 72 Hz.
- Fresh `SurfaceTexture` buffers remained about 54 to 57 per second.
- Flutter raster CPU p95 was about 1.3 ms and native active work remained below
  about 1.15 ms mean.
- Oculus GPU utilization was about 83 to 85 percent in the later shadow-off
  comparison.
- Removing directional shadows did not materially improve the reported
  head-motion discomfort.

The previously observed below-70 result therefore refers to fresh world
texture delivery, not OpenXR submission cadence. These values are historical,
not a substitute for a same-artifact before/after run.

## Fresh comparison protocol

Use the same scene, camera behavior, runtime eye dimensions, FXAA setting,
shadow setting, profile mode, display refresh rate, and measurement duration
before and after the renderer change. The source conversion is complete, but
the post-change custom-engine build and headset run have not yet occurred.

```sh
cd /Users/adrian/Projects/flutter_scene_vr/examples/openxr_quest
./tool/quest-build-and-deploy-local-forks.sh
```

After launch, wear the headset, allow 10 seconds for warm-up, then capture at
least 60 seconds containing a static interval and the same slow yaw/pitch head
motion. Record thermal state before and after. Capture bounded Flutter/OpenXR
logs and OVR Metrics evidence for:

- OpenXR and submitted-layer cadence;
- completed Flutter frames, scene ticks, and fresh world frames;
- Flutter build, raster, and total p95 plus frame-budget misses;
- native active time, swapchain waits, direct-render completion time, and pose age;
- application/compositor FPS, stale or dropped frames, GPU/CPU level and
  utilization, and thermal state.

The live panel's `FRESH CONTENT` series is completed direct stereo frames and
`DIRECT` is the wall time through both terminal eye callbacks. `UI FRAMES`,
`UI RASTER`, and the small `flutter_texture_hz` native log describe only the
optional Flutter composition quad; they are not world-render cadence.

For the direct path, verify that the world stereo `SurfaceTexture`, OES eye
copy, and full-resolution Canvas atlas logs and counters are absent. The small
Flutter performance/UI surface may remain. Require sustained 72 Hz rather than
a brief peak. Investigate 90 Hz only after the same workload is stable at
72 Hz and the runtime confirms the selected refresh rate.

## Visual Space integration boundary

Visual Space production Quest does not currently use the demo's Canvas stereo
world. Its native OpenXR renderer derives world geometry from the authoritative
portable Poly projection and uses the retained Flutter `SurfaceTexture` atlas
for ordinary widgets, HUDs, menus, and floating panels.

The direct Flutter Scene integration must therefore replace only the native
world draw between eye acquire/wait and eye release. It must preserve the
authoritative route/document owner, portable scene projection, OpenXR session,
tracking and input, and the smaller Flutter UI atlas. Native world geometry,
materials, lighting, shadows, picking, and FXAA can be removed only after the
Flutter Scene path reaches feature and interaction parity. The UI atlas and its
panel compositor copies are not part of the dead full-resolution world route.

The production host is in Visual Space itself:

- `VisualSpaceXrActivity.kt` retains the authenticated primary Flutter engine;
- `visual_space_xr_native.cpp::RenderProjectionLayer` owns view location,
  tracking, eye swapchain acquire/wait, native world rendering, release, and
  submission;
- `QuestSpatialSessionCoordinator` redirects that same engine to the
  authoritative Flutter UI atlas.

Quest currently unmounts both the normal spatial scene and the Poly viewport,
so there is no live Flutter Scene tree that can be handed the eye targets. The
safe production order is therefore:

1. Pin Flutter Scene to the direct-target revision and run Visual Space with
   the custom GLES engine.
2. Add a feature-owned headless Quest scene factory through the generated lazy
   module boundary. It must derive a separate node tree from the existing
   authoritative Poly services; nodes cannot have both flat and Quest parents.
3. Retain one route/document/session, autosave, presence, tools, and asset
   owner. Publish immutable stereo eye data and the exact native stage transform
   to the headless scene.
4. Expose the primary engine's GLES share-context descriptor, acquire and wait
   both eye images, push both shared textures, render both targets in one scene
   tick, wait for both GPU-complete callbacks, and only then release either eye.
5. Keep native geometry temporarily as invisible hit proxies. Preserve native
   panels and interaction overlays without clearing the Flutter Scene color;
   remove native world shaders only after visual and interaction parity.
6. Keep the Flutter UI atlas and its SurfaceTexture compositor path unchanged.

The first-stage package, lazy-slot, Poly adapter, synchronization, and lighting
files were concurrently modified during this work. No Visual Space edits were
made, so those changes remain intact and the production migration can start
from their settled state rather than forking scene ownership prematurely.
