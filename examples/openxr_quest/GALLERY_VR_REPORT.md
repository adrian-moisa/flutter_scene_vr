# Library gallery through the Quest direct-eye host

Prepared 2026-08-31. This is an implementation and compilation report, not a
headset validation report or evidence of an upstream Flutter Scene defect.

## What changed

The flat gallery and Quest host use the same 44-entry `galleryExamples()` registry,
the same widget implementations, and the same `settingsDefaults` map. Registry
names/order and defaults of the original 43 examples remain unchanged; **VR** is
the first option and contains the original Quest demo.
There is no separate custom-demo launcher or copied VR scene collection.
Optional shared graphics presets are applied only after the user selects one.

`SceneViewPresentation` replaces only a `SceneView`'s presentation/clock. Original
declarative children, resource gates, camera callbacks and update callbacks remain
owned by that example. The direct renderer batches both tracked eyes in one
`Scene.renderViewsToTargets` call. The scene's explicit or implicit update runs
once for that batch. OpenXR retains asymmetric projections and native swapchain
ownership, including the existing engine completion/cancellation callbacks.
There is no captured flat main viewport, CPU readback, or new full-size eye copy.

The first authored camera pose places a rigid, unscaled XR rig. Subsequent camera
callbacks still execute for their side effects, but automatic camera motion does
not drive the headset. Near/far planes come from the authored perspective camera.
Recenter uses the currently resolved authored pose. Car wheel motion was changed
from a per-frame increment to its equivalent elapsed-time rate in both modes.

The 1200×900 Flutter atlas is split into two independently movable compositor
panels at x=560. Each crop has its own bounded Flutter overlay. Native code owns
both panel poses, nearest ray hits, per-hand grip capture, push/pull distance and
far-to-near composition ordering. Grip captures the actual pixel; moving the hand
moves that anchor, and the held hand's stick Y changes depth at 1.2 metres/second.
Released panels remain fixed. The reset-panels button restores their placement.
Left stick rotates the camera rig around its persistent authored target at 42
degrees/second, and right stick moves it and that target at 3 metres/second.
Head tracking remains independent. Panel hover reserves the corresponding stick
for scrolling; active panel grabs suppress scene navigation. Tracking loss cancels
capture and requires release before accepting a held trigger as a new click.

A separate native GPU FPS button toggles UI ON/OFF using native ray/trigger input.
UI OFF omits both panel layers, bypasses SurfaceTexture updates/copies, and gates
framework begin/draw callbacks, including widget tickers, build, layout and paint.
Manual widget-texture captures also respect the gate. One already-started frame
or capture may drain. The button still paints completed stereo FPS once per second.
Dart/Flutter GPU scene rendering, simulation and stats collection remain active;
this is not a benchmark with the Flutter engine removed. The same mounted widgets
resume, and the bounded graph includes UI OFF samples marked with teal bands.
Discard the first one-second sample after each toggle when comparing steady state.
The native host checks for four compositor layers before enabling this mode.

Loading/unsupported/error states keep recovery UI available; a renderer failure
restores UI ON. World-space widget picking and viewport gestures are not mapped
to controller rays. The replaced viewport consumes unadapted gestures.

Switching detaches the direct callback and awaits a native pause barrier before
replacing the selected widget. Kotlin acknowledges only after offered eye leases
have terminal callbacks. Requests queued on either side of the detach explicitly
discard both eyes; native releases them without submitting/counting stale content
or exiting VR. Unresolved ownership and real surface errors remain fatal.
Generation guards reject old renderer failures. Disposed loaders cannot attach
their results to the new widget, and stale load failures are ignored by guarded
loaders. Teardown unmounts scene children, clears auxiliary views and detaches root
components, including physics/audio owners. Native frames already handed to the
engine retain completion ownership. In-flight decoding/baking is not forcibly
cancelled; it exits at a mounted guard. Shared asset caches and GPU finalizers may
retain allocations after a switch, so bounded memory still needs device checks.

## Settings, resolution and web navigation update

The left panel now has **Examples / Controls / Settings** tabs. Switching tabs
keeps the same mounted example/direct renderer. Settings embeds the original
gallery sidebar, including resolution and Low/Medium/High/Ultra/Custom controls.
The right performance panel scrolls so resolution diagnostics do not overflow.

Resolution changes are native requests consumed at the next frame boundary,
after the preceding stereo leases and xrEndFrame complete. Replacement eye
swapchains are created transactionally; failures retain the old pair and return
an inline error. No additional eye-copy pass is introduced. UI atlas size stays
constant, and FPS history continues across changes. Eye scale is independent of
the per-example settings reset. New performance payloads append recommended/max
eye dimensions and actual scale, with legacy payloads still accepted by Dart.

The web host keeps SceneView's existing painter/ticker and adds a camera rig only
when the user interacts. Settings input lies outside the viewport's focus/pointer
wrapper. FPS samples screen render submissions independently of panel visibility;
render/output sizes come from actual renderer allocations, not screen estimates.
Resolution-only edits preserve the current authored light rig. Restoring Custom
after a standard preset restores the saved global settings, including resolution.
See README for the preset matrix and Custom's session-only persistence scope.

## Orbit, performance panel and controller aim update

The shared web camera now orbits its persistent target for all mouse drags,
including the middle button. Keyboard translation carries the target with the
camera; wheel zoom changes its distance without crossing the pivot. The movement
basis matches Flutter Scene's view matrix, correcting inverted Left/A and Right/D.
Authored camera motion resumes on R. Quest stick orbit and head tracking remain
unchanged.

The web performance panel groups scene FPS, Flutter timing and actual resolution
rows, with a bounded 30-sample trace. Detailed measurement notes and the shortcut
guide expand on demand. Sampling continues when the panel is closed.

The Quest gallery opts into two renderer-owned controller rays: shared low-segment
cylinder/sphere geometry with separate unlit hand colors and trigger feedback.
They use the same tracked frame and world transform as the eyes, update even with
UI OFF, hide on tracking loss, and detach on renderer disposal. They cast no shadows
and do not participate in scene picking. Beam tips mark a fixed 1.5-metre length,
not scene/panel intersections; actual panel input still uses native hit testing.

## Final build verification

Scoped static analysis passed with no issues. The final reviewed source compiled
successfully as a web release and an ARM64 Quest profile APK using the local
engine artifacts. `git diff --check` passed. No tests, previews, installation or
device launches were run; the live interaction checks below remain unverified.

- `examples/openxr_quest/build/app/outputs/flutter-apk/app-profile.apk`: 269,986,496 bytes; SHA-256 `cbc9a25a628792962b65f7fac5b46b286ce369c9fddcfceae481891e3bcfe8ea`.
- `examples/flutter_app/build/web/main.dart.js`: 5,044,988 bytes; SHA-256 `3f3368563499f47c6708e93fda138ed3d68805321602ccabf49e78c200d2c175`.

The web artifact is the complete `examples/flutter_app/build/web` directory;
`main.dart.js` is fingerprinted here only to identify this build.

## Audit of all registry entries

“Adapted” means a source-level VR adapter exists, **not** verified headset parity.
Every row remains visible in the selector. Detailed live notes are maintained in
`lib/open_xr_gallery_support.dart` alongside the adapter.

| Example | Status and adaptation |
| --- | --- |
| VR | Adapted; original geometry/lighting, live shadow checkbox, scrollable controls guide and shared camera/panel controls. |
| Car | Adapted; initial showroom camera, elapsed-time wheel motion. |
| Animation | Adapted; original declarative Dash and blend controls. |
| Flutter Logo | Adapted; original generated model and ground texture. |
| Multiplayer | **Flat only**; networking clocks and gameplay input need an XR contract. |
| Configurator | Adapted; camera breathing does not move the headset. |
| Lights | Adapted; authored lights and controls. |
| Area Lights | Adapted; authored area-light rig. |
| Reflection Probes | Adapted; original capture and re-capture work retained. |
| Planar Mirror | Adapted with limitation: first-eye reflection capture is shared by both eyes. |
| Spot Shadow | Adapted; authored spot shadow resolution and bias. |
| Cloth | Adapted; panel controls retained, viewport dragging/fly keys flat only. |
| Gameplay Kit | Adapted; panel controls retained, viewport picking/camera rigs not XR input. |
| Particles | Adapted; complete authored campfire and cinematic effects. |
| Explosions | Adapted; original effects and controls. |
| Gaussian Splats | Adapted; both source captures bundled, free/orbit navigation flat only. |
| Geometry LOD | Adapted; tracked eye distance, original LOD thresholds. |
| Screen-space Reflections | Adapted; SSR retained, stereo/temporal artifacts need comparison. |
| Auto Exposure | Adapted; authored auto-walk does not move the headset. |
| Navigation Route | Adapted; follow camera and screen-space marker sizing lack XR parity. |
| Toon | Adapted; original custom shader and model. |
| Raw shader | Adapted; original generated shader bundle and timed uniforms. |
| Toon (.fmat) | Adapted; original compiled material. |
| Custom vertices (.fmat) | Adapted; both authored sub-demos and parameters. |
| Materialize (.fmat) | Adapted; original timeline/effects; runtime downloads may be needed. |
| DICOM Volume | **Flat only**; one flat-camera `cam_uvw` uniform needs per-eye adaptation. |
| Custom Skybox | Adapted; original shaders; free/orbit navigation flat only. |
| Audio | Adapted; original SoLoud sources; listener follows primary eye, not eye midpoint. |
| Widget Texture | Adapted geometry; no world-widget ray input; leave Recursive off. |
| Widget Input (inset view) | Adapted geometry; flat viewport-offset input test has no XR equivalent yet. |
| External Texture | **Flat only**; camera/video textures and native activity binding need adaptation. |
| Accessibility | Adapted geometry; screen-space semantics and picking remain flat diagnostics. |
| Render Targets | Adapted; authored auxiliary captures/minimap/comparison textures retained. |
| Physics | Adapted; original Rapier/cloth; panel input retained, third-person camera not XR navigation. |
| Physics (box3d) | Adapted; original simulation; viewport tap-to-drop/fly controls flat only. |
| Car Physics | Adapted simulation; keyboard driving/follow camera not mapped to Quest sticks. |
| Shapes | Adapted main world; auxiliary 118px preview omitted in VR; viewport dropping flat only. |
| fscene | Adapted; original document realization and round trip. |
| fscene (import) | Adapted; original import and asset corpus. |
| fscene (animated) | Adapted; original imported animation clips. |
| fscene (prefab) | Adapted; original prefab expansion. |
| fscene (stream) | Adapted; original subtree load/unload controls. |
| Split Screen | **Flat only**; two authored cameras/viewports/layer masks are not stereo eyes. |
| Stress Tests | Adapted; original case picker and assets; focus-lock/fly input flat only; large cases may exhaust memory. |

Additional limitations: flat `Scene.warmUp` is skipped for external presentation,
so first-eye frames may include pipeline compilation. The global settings sidebar
is available in VR's Settings tab. Per-example Flutter controls remain where practical;
camera navigation, native cursor locking and screen-space overlays are not
equivalent to world controls. Source render-target captures remain intentional
workloads. The Shapes preview is the sole explicitly omitted secondary view.
Screen-space post effects, including expensive authored AO/DoF/bloom/SSR, are not
silently disabled. Their per-eye appearance and temporal history are unverified.

## Comparison and metric meanings

Select an example, wait for loading, and record a complete 30-second window. Use
**Flat mode** and **Enter VR · restart baseline** to compare the same selected
example at the same authored defaults. Both transitions restart simulation and
controls; they do not transfer tuned slider state between processes. The hidden
flat activity removes its example before launching VR. The restart button also
restores defaults. Any controlled non-default comparison must set and record
matching values manually in each mode where those controls exist.

Record the eye dimensions and runtime refresh rate from the panel, plus flat
viewport logical size, DPR and scene render scale from the flat footer. Direct
eyes use native swapchain resolution; flat render-scale/filter settings cannot
resize those external targets. Flat and stereo workloads are therefore unequal.
The panel reads the scene's requested/effective AA, exposure, environment,
renderer-selected directional/spot shadows, enabled effects and auxiliary target
count. The Shapes flat preview still contributes rendering cost but is excluded
from the primary-scene update counter.

- **XR LOOP / SUBMIT:** application XR loop and submission cadence. The runtime
  refresh rate is queried separately; no physical display measurement is made.
- **FRESH CONTENT / FRESH %:** fresh stereo content per counted application frame;
  100% does not establish that headset refresh deadlines were met.
- **SCENE / UI FRAMES:** example update callbacks and Flutter frame cadence.
- **DIRECT mean/max:** rendering handoff and completion wait, not a pure GPU timer.
- **NATIVE LOOP mean/max:** active native loop time, already including Direct.
- **UI RASTER p95:** Flutter UI raster timing, not stereo GPU work.
- **POSE AGE:** unavailable; the direct path does not populate a pose-age metric.

Selection resets Flutter history/counters and native windows. Native samples carry
an epoch so delayed previous-scene samples are rejected. Scene replacement inside
a sub-demo resets the windows as well. The graph holds 30 one-second samples.

## Reproduction and build evidence

Use the usual helper, with no extra parameters:

```sh
cd /Users/adrian/Projects/flutter_scene_vr
./examples/openxr_quest/tool/quest-build-and-deploy-local-forks.sh
```

Select **VR** in the same gallery for the original demo; there is no separate custom launcher.
`QUEST_SHADOWS=0` affects the VR entry only, not other gallery entries.

Verified in the gallery integration: formatting of changed Dart files; scoped Flutter static
analysis with **no issues**; shell syntax and diff-whitespace checks; successful
ARM64 profile APK compilation using existing engine artifacts. No engine build,
tests, app preview, installation or device launch was performed.

The build command, from `examples/openxr_quest`, was:

```sh
/Users/adrian/flutter/bin/flutter \
  --local-engine-src-path /Users/adrian/flutter/engine/src \
  --local-engine android_profile_arm64 \
  --local-engine-host host_profile_arm64 \
  build apk --profile --target-platform android-arm64 --no-pub \
  --target lib/main.dart \
  --dart-define=FLUTTER_SCENE_OPENXR_PERF_LOGS=true \
  --dart-define=FLUTTER_SCENE_PROFILE=true
```

Previous controls/UI-suspension APK (before tabs/resolution/presets): `build/app/outputs/flutter-apk/app-profile.apk`.
Size: 269,986,496 bytes. SHA-256: `994716199961cc5b243ce6a9c2a6b21dde5b8b424205f771a82460f92a838b88`.
Final controls/UI-suspension and scene-switch verification: scoped Dart analysis found no issues;
ARM64 profile APK compiled; shell syntax and diff-whitespace checks passed.
No tests, app preview, installation, or device launch were performed.
The APK contains Rapier, Box3D, SoLoud, OpenXR and Flutter ARM64 libraries, generated
shader/material manifests, models, audio/video and both splat datasets. Splat bytes
were compared with the source files. Assets remain authoritative in the original
gallery through relative links and its package build hook. Generated gallery
assets are packaged only under `example_app`, and engine assets under
`flutter_scene`. The Quest host has no duplicate build hook or generated-tree
asset entry. Raw root asset keys and dependency-qualified copies are still
packaged to preserve existing `rootBundle` calls; this increases APK size.
The existing `tool/fetch_splat_asset.sh` fetched the two
optional captures for this build. Some other examples still download resources at
runtime. Internet permission and generated native plugin registration are present;
registration alone does not prove plugin behavior in the immersive activity.

Relevant revisions/settings:

| Component | Revision/configuration |
| --- | --- |
| Flutter Scene baseline before gallery work | `d7dc06dc1657a5ec8b013ab187340d73d4367236` |
| Gallery integration | `663011d5`, packaging correction, and the current controls/UI-suspension working changes |
| Local Flutter/engine HEAD | `643047b9579a44f2aa669de27b798c5870d5878c` |
| Device / host outputs | `android_profile_arm64` / `host_profile_arm64` |
| Dart GPU override | `/Users/adrian/flutter/engine/src/flutter/lib/gpu` |
| Build / performance defines | Profile; both performance defines above enabled |

Both forks include local changes. These hashes alone do not reproduce the build;
retain the working-tree diff and matching engine artifacts when sharing evidence.
Existing direct-eye projection, winding and lifecycle work was preserved.

## Headset checks and findings discipline

The operator supplied a screenshot of gallery initialization failing after
commit `663011d5`: the `example` shader bundle was registered by both
`openxr_quest` and `example_app`. Inspection of that APK also confirmed duplicate
model, texture and material ownership. This was a host packaging error, not an
upstream renderer finding. The fix removes the host's duplicate generation and
asset registration, retaining package-owned generated assets and the resolver's
strict ambiguity checks. It does not alter direct-eye rendering or scene content.
Old ignored host-generated files need no manual deletion because the host no
longer packages that directory.

The rebuilt APK contains only the `example_app` and `flutter_scene` generated
manifests, with no conflicting generated owners and no missing referenced outputs.
Scoped static analysis and profile APK compilation passed after this correction.
No post-fix headset result has been collected. The working direct rendering setup
and recent stereo/winding fixes were supplied as prior operator context.
Compilation does not verify their behavior with these examples.

1. Confirm selector readability, both trigger cursors, list scrolling to the final
   entry, example controls, and recovery from a loading/error/flat-only selection.
2. Check Car, Animation and Lights for stereo alignment, tracked rotation and
   translation, initial scale/pose, no orbit-driven headset motion, and Recenter.
3. Check Particles, Physics/Box3D, Audio, shader examples and splats. Switch rapidly
   during loads and return repeatedly; listen for old audio and watch memory,
   stale callbacks, freezes and native frame-cancellation errors.
4. Inspect mirrors, render targets, SSR and widget surfaces against their stated
   limitations. Confirm unsupported examples remain selectable in flat mode.
5. Exercise Flat mode → VR, system pause/resume, controller tracking loss and exit.
   Confirm retained selection, restarted defaults, and no hidden simulation.
6. Capture one full window per baseline with example/subcase, changed controls,
   resolution, AA/shadows/effects, refresh rate, scene/UI/native timings, device
   model, thermal state and matching revisions. Keep cold-load and steady-state
   measurements separate.

Additional checks for the settings/navigation update (not run here):

- In VR, switch Examples → Controls → Settings repeatedly. The camera, scene
  animation and OpenXR session should remain alive, including while scrolling.
- Switch each resolution down and back up. Confirm eye dimensions and relative
  pixel counts update while atlas dimensions stay 1200×900. Ignore the allocation
  transition in the FPS graph; compare later samples with UI both on and off.
- Compare Low/Medium/High/Ultra, edit a nested effect to enter Custom, choose a
  standard preset, then restore Custom. Repeat after switching away and back to
  the example. Custom should include its previous resolution, not the last preset.
- Switch examples during a pending resize and immediately reopen Settings. Check
  the selector matches native eye dimensions and no stale settings overwrite the
  newly selected example. Failed allocations should keep VR and its old targets.
- On web, open/close FPS, resize the browser, change resolution, and compare actual
  target sizes against the viewport and Flutter backing dimensions. Exercise
  drag-look, WASD/arrows, Shift and R; ensure inputs in Settings do not navigate.

Potential causes to investigate include stereo workload, engine integration,
frame synchronization, asset loading, UI scheduling, thermal state, and individual
effects. Slowness across the gallery alone cannot establish an upstream defect:
all VR entries still share this custom Flutter engine and OpenXR integration.
