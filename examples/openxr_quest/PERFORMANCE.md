# OpenXR Quest Demo Performance Investigation

This is the historical Canvas/SurfaceTexture investigation, not a benchmark of
the current direct-eye gallery. See [direct rendering](DIRECT_SWAPCHAIN_RENDERING.md)
for the replacement path and the [gallery report](GALLERY_VR_REPORT.md) for current coverage.

Scope: the profile-mode Meta Quest stereo demo, including Flutter Scene frame
production, Android `SurfaceTexture` transfer, native OpenXR submission, and
head-motion stability. The acceptance boundary is a full-resolution scene that
feels smooth in the headset; cast output and submission cadence alone do not
satisfy it.

## Measurement Contract

- **Target** - `dev.bdero.flutter_scene_openxr_example`, immersive native activity.
- **Build** - ARM64 profile APK, OpenGL ES Impeller, 1680x1760 per eye.
- **Device** - USB-connected Meta Quest 3 (`eureka`), OpenXR runtime `Oculus`.
- **Metrics** - OpenXR and Flutter cadence, unique/reused textures, Flutter frame
  timings, render-pass CPU encoding, native frame-loop timings, texture/render
  pose age, and pose-tag misses.
- **Workload** - four primitive objects, a lit floor/grid, shadows, and controller
  navigation.
- **Acceptance** - preserve full runtime-recommended resolution, FXAA, lighting,
  shadows, floor, grid, stereo tracking, and controls at a stable headset rate.

## Stage 0 - Original Symptom

Status: historical user observation, not a controlled benchmark.

- **Observed behavior** - the immersive demo felt extremely low-FPS and head
  movement made scene objects move unnaturally despite the small scene.
- **Control comparison** - flat mode rendered normally.
- **Interpretation boundary** - the symptom proved the headset path was broken;
  it did not identify Flutter GPU cost, OpenXR cadence, pose math, or compositor
  presentation as the owner.

## Stage 1 - Cadence-Only Instrumentation

Status: `fail`

- Profile windows reported 72 OpenXR submissions and up to 72 unique Flutter
  textures per second after sustained-high CPU/GPU performance was requested.
- Flutter build/raster measurements could fit within the 13.89 ms budget in
  those active windows.
- The user still observed severe low-FPS behavior in the headset.
- **Interpretation** - cadence did not prove spatially correct presentation.
  Native submitted every Flutter texture using the newest `xrLocateViews` pose,
  even though the asynchronous Flutter texture had been rendered from an older
  pose. That invalidated compositor reprojection and could present as judder or
  amplified head motion while all cadence counters remained healthy.

## Stage 2 - Pose-Tagged Texture Submission

Status: `fail`

**Code and runtime state**

- Dart reports the OpenXR view sequence used by `OpenXrSceneView` while it
  resolves the stereo cameras.
- Android tags each new `SurfaceTexture` buffer with that sequence.
- Native retains a bounded 32-sample pose ring and submits each texture with the
  exact original eye poses/FOV. Reused textures retain the same render pose so
  the compositor can time-warp them honestly.
- Native metrics now report tagged/untagged buffers, tag misses, texture pose
  age, and submitted pose age.
- Static Dart analysis passed and the ARM64 profile APK built and installed.

**Controlled idle-device sample**

| Metric | Result |
| --- | ---: |
| Pose-tag misses | 0 |
| Tagged buffers per 5-second window | 61-63 |
| Texture render-pose age | 1.68-1.81 OpenXR frames mean, 2 max |
| Native active work | 0.79-0.91 ms mean |
| Stereo copy/submit | 0.084-0.100 ms mean per eye |
| Flutter Scene pass encoding | about 0.19-0.24 ms mean |
| OpenXR cadence | 12.1-12.6 Hz |

The 12 Hz OpenXR cadence is an idle/not-worn runtime throttle: `xrWaitFrame`
blocked for about 79-82 ms while the physical display remained configured at
72 Hz. It is not accepted as an on-headset performance result. Flutter raster
backpressure in this state is likewise not comparable to an active-wear run,
because the OpenXR consumer drains the buffer queue only at the throttled rate.

**Interpretation**

- **Confirmed repair** - the texture-to-pose ownership defect is removed; the
  idle run had no missing pose tags.
- **User acceptance** - the user reported that active-wear head motion still felt
  extremely choppy after this build, so pose tagging did not close the defect.
- **Quality boundary** - no resolution, lighting, shadow, material, or geometry
  downgrade was used.

## Stage 3 - Stereo Live Performance HUD

Status: `diagnostic`

**Code and runtime state**

- Added a reusable native-to-Dart performance stream sampled once per second.
- Added a stereo-safe, head-locked demo HUD duplicated for both eyes. It reports
  OpenXR cadence, submitted-layer cadence, unique Flutter texture cadence, Dart
  scene cadence, texture pose age, native active time, and Flutter raster p95.
- Counter-mirrored the Flutter HUD before the existing native stereo-copy mirror
  so the text remains readable in the headset.
- The reusable package and Quest demo both pass focused static analysis. The
  ARM64 profile APK built, installed, and cold-launched successfully.

**Controlled idle-device sample**

| Metric | Result |
| --- | ---: |
| OpenXR cadence | 19.8-20.1 Hz |
| Unique Flutter texture cadence | 19.8-20.1 Hz |
| Dart scene cadence | 45.7-46.7 Hz |
| Flutter raster p95 | 20.4-21.1 ms |
| Native active work | 0.81-0.89 ms mean |
| Submitted texture pose age | 1.57-1.77 frames mean, 2 max |

This window was collected while the headset was connected but without a
confirmed active-wear journey. `xrWaitFrame` supplied the native app at about
20 Hz while native active work remained below 1 ms, so it must not be used as
the final performance verdict. The in-headset HUD is the next controlled source
of the exact active-wear cadence split.

## Stage 4 - Transport-Only Probe

Status: `pass`

A compile-time diagnostic replaced Flutter Scene with an animated, full-size
Flutter surface while retaining the same 3360x1760 `SurfaceTexture`, stereo
copy, and OpenXR submission path. It sustained 72/72 Hz with about 18% GPU
utilization and 1.2-1.6 ms combined CPU/GPU work. This isolated the failure to
scene fragment work rather than Flutter-to-OpenXR transport.

## Stage 5 - Render-Feature Isolation

Status: `diagnostic`

| Variant | Active-headset result | Interpretation |
| --- | ---: | --- |
| Original soft-shadow scene | 19-21 FPS, 21-24 ms raster p95 | Fails the 13.89 ms frame budget |
| FXAA disabled | 21-22 FPS | FXAA is not the bottleneck |
| Directional shadows disabled | 72/72 FPS, about 1.2 ms raster p95 | Directional shadow receiving owns the regression |

The soft-shadow receiver sampled the directional shadow map 16-17 times for
every shadow-receiving fragment. The floor covers most pixels in both eyes, so
the cost was dominated by shaded screen area rather than the four objects or
Flutter Scene command encoding.

## Stage 6 - Compile-Time Hard-Shadow Variant

Status: `pass`

Added a dedicated hard-shadow shader variant whose compiled receiver performs
one depth comparison. A runtime-only branch was insufficient because the
generic shader still retained the soft-shadow loops and their register
pressure. The demo selects the specialized shader while retaining full
runtime-recommended resolution, PBR materials, HDR, FXAA, a real 512px shadow
map, floor, grid, stereo tracking, and controller navigation.

The first hard-shadow deployment exposed front-face self-shadow acne. Solid
demo primitives now write back faces into the shadow map; the floor remains a
receiver and does not cast. This removed the triangular self-shadow artifacts
without removing cast shadows.

**Final active-headset sample after warm-up**

| Metric | Result |
| --- | ---: |
| OpenXR compositor | 72-73 / 72 FPS |
| Dart scene cadence | 72 FPS |
| Flutter raster p95 | 1.24-1.45 ms |
| Flutter total p95 | 3.95-4.60 ms |
| Native active work | about 1.15 ms mean |
| Texture render-pose age | 1.34-1.40 frames mean, 2 max |
| Stale compositor frames after warm-up | 0 |
| Unique Flutter textures | about 56-57 FPS |

The native loop continues to submit at 72 Hz and safely reuses pose-tagged
textures when Flutter has no fresh buffer, allowing OpenXR time-warp to keep
head tracking at display cadence. Raising unique Flutter texture delivery from
roughly 56-57 Hz remains useful follow-up work, but it no longer lowers XR or
scene cadence in the measured demo.

## Stage 7 - Fresh-Texture Cadence Instrumentation and Transport Repairs

Status: `diagnostic`; profile build and installation pass, active-wear
comparison pending.

**Hypothesis**

The remaining 56-57 Hz fresh-texture ceiling can come from two independent
transport costs that the previous HUD did not distinguish:

- `SurfaceTexture` frame callbacks shared Android's main looper with both
  directions of the Flutter method channel, so delayed or coalesced callbacks
  could make a produced texture appear stale to the 72 Hz OpenXR consumer.
- Every stale Flutter texture was copied into two newly acquired 1680x1760
  swapchain images even though `xrEndFrame` uses the most recently released
  image. Those redundant copies could consume GPU bandwidth needed by the
  Flutter producer.

**Changes**

- Moved the frame-available listener onto a dedicated `HandlerThread`. Its
  opt-in five-second aggregate reports callback Hz, mean/max callback interval,
  and overwritten pending notifications; it never logs per frame.
- Reuses each eye swapchain's most recently released image only when Flutter
  did not produce a new texture. Fresh textures retain the normal
  acquire/wait/copy/release path. Aggregate native logs now distinguish actual
  eye copies from reused swapchain submissions.
- Added a bounded 30-sample in-headset graph for XR, fresh texture, and real
  Flutter frame cadence. `FLUTTER` now reports completed Flutter frames while
  `TICK` reports the scene callback cadence that the old `SCENE` label showed.
- Moved the stereo HUD from 12% to 20% of eye height so the top edge remains in
  the comfortable field of view.

No scene geometry, PBR material, runtime eye resolution, FXAA, shadow-map
resolution, or shadow feature was reduced by this stage.

**Verification state**

- `flutter analyze` passes for `examples/openxr_quest`.
- The ARM64 profile APK compiles, installs, and cold-launches the native OpenXR
  host. The Oculus runtime initializes both 1680x1760 eye swapchains and the
  3360x1760 Flutter producer surface.
- The connected headset remained in OpenXR session state `IDLE`, so it produced
  no comparable active-wear frames. Treat candidate FPS as unavailable until a
  focused headset run captures at least 30 seconds of the new HUD and aggregate
  logs.
- Read-only display inspection confirms the active Quest display mode is
  72 Hz, ruling out a hidden 60 Hz Android display mode as the 56-57 Hz ceiling.

**Rollback**

- Return the frame listener to `mainHandler` and remove the dedicated callback
  thread/statistics.
- Remove `Swapchain.hasReleasedImage` and always execute the existing
  acquire/wait/copy/release loop for both eyes.
- Remove the two performance-panel files and restore the original compact HUD.

## Stage 8 - Shadow-Off Stereo-HUD Ablation

Status: `fail`; profile build and installation pass, active-wear result rejects
shadows as the primary cause.

**Code and runtime state**

- The demo's directional light now leaves `castsShadow` off by default.
  `QUEST_SHADOWS=1` is the explicit opt-in comparison; the legacy disable define
  still wins when both are supplied.
- With no shadow-casting directional or spot light, the render graph creates no
  shadow atlas/pass and PBR materials select their compile-time no-shadow
  shader variant. FXAA, PBR, geometry, runtime eye resolution, exposure,
  environment lighting, floor, grid, and object materials remain unchanged.
- The HUD reports `SHADOWS OFF — A/B`, sits at 25 percent of eye height, and
  applies inward eye disparity for finite-depth stereo fusion. The source
  offsets intentionally look reversed because the native SurfaceTexture copy
  mirrors each eye half.
- Static analysis passed. Commit `9c329a0c` plus the preserved working-tree
  changes produced a 41.1 MB ARM64 profile APK, installed at
  `2026-08-29 15:01:00 +0300` on Quest 3 `2G97C5ZJ0X030H`.

**Measurement boundary**

- The active headset sustained about 72 OpenXR submissions, 71 completed
  Flutter frames, and only 54-57 unique `SurfaceTexture` buffers per second.
- Native active work remained below 1 ms mean and Flutter raster CPU timing was
  about 1.3 ms p95, while Oculus reported roughly 83-85% GPU utilization.
- The user reported no material improvement in head-motion comfort with
  shadows fully absent. Shadows are therefore not the primary stutter owner.

**Interpretation**

- Flutter `FrameTiming.rasterDuration` measures raster-thread submission, not
  completion of the asynchronous GLES work that makes a producer buffer
  available. It therefore under-reported the GPU pressure visible to Oculus.
- The dedicated callback thread reported zero overwritten notifications. The
  missing texture cadence originates before `SurfaceTexture` notification,
  rather than in callback scheduling or native latching.

**Rollback**

- Set the light back to shadow-on by default and remove `QUEST_SHADOWS` plus the
  HUD status line. Restore zero HUD disparity only if a headset pass proves the
  finite-depth offsets are reversed or uncomfortable.

## Stage 9 - Timestamp-Correlated Camera Pose

Status: `candidate`; built, installed, and instrumented on Quest 3, subjective
active-wear acceptance pending.

**Defect**

The first pose-tag implementation kept only the latest Dart render sequence.
When Flutter began rendering frame N, then received frame N+1 before Android's
callback for N's buffer, that older buffer was mislabeled with N+1's camera.
OpenXR then reprojected from a pose that never produced the image, causing a
jump each time a fresh texture replaced a correctly reprojected reused image.

**Changes**

- Android now retains bounded `(view sequence, System.nanoTime)` render tags.
- Native first latches `SurfaceTexture`, reads its producer timestamp, then
  resolves the newest render tag at or before that exact timestamp.
- Frame availability and camera identity are separate signals, so a delayed
  callback cannot borrow a newer pose.
- The aggregate surface log reports resolved/missing tags, producer-to-tag
  delta, and pending tags without per-frame logging.
- The 30-second graph now has an explicit finite width inside the performance
  column; the previous height-only `CustomPaint` laid out at zero width.

**Post-deploy evidence**

| Metric | Result |
| --- | ---: |
| Resolved texture tags | 212 / 216 startup-window buffers |
| Missing tags | 4 startup buffers, then 0 steady-state |
| Buffer timestamp minus render-tag time | 3.39 ms mean |
| Maximum observed tag delta | 28.85 ms |
| Pose tag misses in native ring | 0 |
| OpenXR cadence after warm-up | 72-73 Hz |
| Native active work | about 0.7-1.0 ms mean |
| Quest GPU utilization | about 84-85% |

The timestamp relationship is live and uses the same monotonic timebase; it is
not a fixed assumed frame delay. A headset movement pass is still required to
decide whether correct rotational reprojection is sufficient while the Flutter
producer remains below 72 unique buffers per second.

## Chronological Audit

- Added bounded Flutter and native performance windows.
- Removed a redundant full-swapchain clear before the full-screen copy.
- Kept 1.0 render scale and FXAA.
- Requested sustained-high OpenXR CPU/GPU performance levels.
- Rejected cadence-only evidence after the user reported the issue remained.
- Added exact Flutter-buffer/OpenXR-pose correlation and redeployed the profile
  APK on 2026-08-28.
- Recorded that the pose-tagged build still failed subjective active-wear
  acceptance.
- Added and deployed the stereo live-performance HUD on 2026-08-28.
- Proved the full-resolution Flutter/OpenXR transport can sustain 72 Hz.
- Isolated the fragment bottleneck to directional soft-shadow receiving.
- Added the compile-time one-tap hard-shadow variant and back-face casting for
  the demo's solid primitives.
- Verified the final active-headset build at sustained 72/72 Hz with visible
  floor shadows and no self-shadow acne on 2026-08-28.
- Added a true Flutter-frame readout and bounded 30-second cadence graph.
- Built and installed the dedicated-callback and stale-swapchain-reuse profile
  candidates without reducing visual quality; active-wear comparison remains
  pending because the headset session stayed idle on 2026-08-29.
- Built and installed a clean shadow-off profile A/B without lowering any other
  scene-quality setting. Active-wear rejection proved shadows were not the
  primary stutter owner.
- Replaced latest-value pose tagging with SurfaceTexture-timestamp correlation,
  deployed the profile APK, verified live tag deltas, and repaired the
  zero-width 30-second graph on 2026-08-29.
