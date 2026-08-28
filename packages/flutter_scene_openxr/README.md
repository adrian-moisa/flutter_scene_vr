# Flutter Scene OpenXR

`flutter_scene_openxr` connects Flutter Scene to an immersive Android OpenXR
session. It lets an application render its Flutter Scene world into the left and
right eye images of a headset, receive tracked head and controller input, and
display ordinary Flutter controls on floating panels.

The current consumer is the [Quest example gallery](../../examples/openxr_quest/README.md).
Meta Quest 3, abbreviated MQ3, is the development target. This is an application
plugin bundled into an APK, not a headset driver or an operating-system component.

## Why this package exists

- **Immersive presentation** - A normal Flutter window can show a 3D scene, including inside the Quest home environment, but that does not give the application its own immersive stereo session. This package supplies the missing session, tracking, controller, and eye-image presentation boundary.
- **Keep the scene renderer** - Flutter Scene continues to render geometry, materials, lighting, shadows, and supported effects. Applications do not have to rewrite those scenes as a separate C++ world renderer merely to present them in the headset.
- **Keep platform work separate** - OpenXR sessions and Android GPU integration belong in the host layer. Keeping them in a companion plugin prevents every ordinary Flutter Scene application from needing an Android OpenXR activity and loader.
- **Reuse beyond one example** - The package exposes session, camera, input, rendering, and diagnostics APIs independently of the gallery's scene content. It also currently contains gallery convenience methods and the two-panel diagnostic presentation; it is not yet a completely gallery-independent abstraction.
- **Addition history** - The package was introduced in commit `4de7111b`, titled `Add OpenXR support`. The implementation now includes direct rendering into native-owned eye targets; the older intermediate world-surface path is historical context, described below.

## When it is used

- **Quest gallery in VR** - The immersive gallery starts this package's native activity and connects its selected Flutter Scene to the direct eye renderer. This is the active MQ3 path in this repository.
- **Quest gallery in flat mode** - The gallery uses ordinary Flutter presentation. The plugin may check availability or launch immersive mode, but its OpenXR eye-rendering loop is not running just because the app is visible as a flat Quest window.
- **Ordinary Flutter Scene applications** - Depending on `flutter_scene` alone does not enable this package. An application must include the plugin and explicitly launch/connect its immersive presentation.
- **Web and desktop** - The Android native host does not run there. Flutter Scene retains its ordinary view rendering. The package also contains a side-by-side stereo widget, but displaying that widget does not create a headset session.
- **Other Android headsets** - The code uses OpenXR, but that is not evidence of support on every headset. Runtime discovery, GLES integration, controller bindings, optional extensions, and actual rendering must be checked for each device.
- **Visual Space product** - As checked on 2026-08-31, the separate Visual Space application's `app-vs` does not depend on this plugin. Its MQ3 mode uses its own `VisualSpaceXrActivity` and native world renderer. The gallery and the product can both use OpenXR without using the same host implementation.

## Headset rendering terms

- **OpenXR and runtime** - OpenXR is the API used by this host to request headset services. The runtime is the headset-side implementation answering those requests. The plugin includes an OpenXR loader to connect to that implementation; it does not replace the runtime.
- **Pose and reference space** - A pose is a position and orientation. A reference space gives that pose a coordinate system, allowing tracked eyes, controllers, and placed panels to be related to one another.
- **Swapchain and eye target** - A swapchain supplies a rotating set of GPU images. The host acquires an image for each eye, waits until it may write to it, renders, and releases it for runtime use. An eye target is the image being rendered for that eye during this frame.
- **Projection and quad layers** - The projection layer contains the rendered stereo world. A quad layer places a rectangular texture, such as a Flutter panel, in space. The runtime composes the submitted layers into the headset output.
- **Atlas and surface** - The atlas is one texture containing multiple UI regions. An Android surface is where Flutter produces those UI pixels; native code samples them and maps crops onto the floating panels.

## What belongs to each layer

- **Application** - Owns the selected scene, assets, simulation, Flutter widgets, and application state. The gallery decides which example to load and which controls to expose.
- **Flutter Scene** - Owns the scene graph and scene rendering. It produces two eye views of the same scene through its render-target API.
- **This plugin** - Owns the Android immersive host and the bridge between OpenXR's eye targets/input and Flutter Scene's rendering/input data.
- **Flutter GPU and engine** - Execute the GPU work and expose the custom external-surface facility used to render into borrowed native targets. The necessary engine changes are not implemented by this plugin alone.
- **Headset runtime** - Supplies OpenXR session services, tracked views, frame timing, and swapchain images, then consumes the submitted composition layers for display.

**Flow: World rendering**

```text
Application scene and simulation
-> Flutter Scene renders tracked left/right views through Flutter GPU
-> plugin coordinates borrowed OpenXR eye targets and GPU completion
-> headset runtime composes the submitted views for display
```

The native host controls when a headset frame is requested; Flutter Scene controls
how the scene is drawn. C++ in this package is therefore not a replacement for
Flutter Scene's material, lighting, or scene-graph implementation.

## Entering and leaving VR

- **Availability check** - `OpenXrSession.isAvailable()` asks Android whether a runtime service or recognized VR/head-tracking feature is advertised. It returns false when the platform channel is unavailable. This is a launch eligibility check, not proof that session creation or rendering will succeed.
- **Explicit entry** - `enterImmersive()` takes a Dart entrypoint and library URI, plus optional panel configuration. The Kotlin plugin launches `FlutterSceneOpenXrActivity`; registering the plugin alone does not launch VR.
- **Separate process** - The manifest declares the immersive activity in `:openxr`. It creates its own Flutter engine and Dart state, separate from the flat launcher process. That gives the immersive host its own lifecycle, but in-memory application state does not automatically cross the boundary.
- **Native initialization** - The activity and C++ host coordinate Flutter engine startup, a shared GLES context, OpenXR instance/session creation, reference spaces, controller actions, and stereo swapchains. The immersive Dart entrypoint subscribes to native updates and attaches a ready scene renderer.
- **Gallery transitions** - The gallery removes the old flat example before entering VR and preserves the selected example name. Entering VR or returning to flat mode restarts the example's authored baseline; tuned sliders and simulation state are not transferred between processes.
- **Explicit exit** - `exitImmersive()` requests the immersive activity's exit. Normal shutdown drains borrowed GPU resources before destroying their owning contexts and engine. Applications that need document continuity must supply their own state handoff or retained-owner design.

## How each stereo frame works

**Flow: Direct eye submission**

```text
OpenXR waits for the next frame and supplies predicted display timing
-> native host locates both eye views and samples controller input
-> native host acquires and waits for both swapchain images
-> Android exposes those images as borrowed Flutter GPU surface frames
-> Dart updates the simulation once and renders both tracked eye views
-> the engine confirms completion of both final GPU writes
-> native host releases both images and submits the projection layer
```

- **Two tracked cameras** - Each eye uses its own position, orientation, and field of view. These are not two copies of a flat camera image. `OpenXrCamera` translates the tracked view into the camera matrices Flutter Scene needs.
- **One simulation update** - `OpenXrDirectEyeRenderer` invokes the scene update once and calls `Scene.renderViewsToTargets` with both eye targets. Objects must not advance to different simulation states between the left and right eye render.
- **Matched frame identity** - The request carries a sequence number that must match the tracked view sample. Rendering with unrelated newer poses would associate the pixels with the wrong view at submission time.
- **Navigation around tracking** - Optional controller navigation changes a scene-to-reference-space transform. Physical head tracking remains active; the authored example camera supplies the initial placement rather than replacing tracked head movement every frame.
- **Native frame cadence** - Direct world rendering is requested through the platform bridge. It is not driven by the ordinary Flutter widget build/paint cycle, which is why the gallery can suspend widget frames without stopping the world renderer.

## Why direct eye targets matter

The earlier world path rendered stereo images into an ordinary Flutter surface
before copying them into OpenXR's eye images. The current immersive path removes
that intermediate world presentation and copy.

**Flow: Historical world path**

```text
Flutter Scene eye textures
-> Flutter image/Canvas presentation into one side-by-side Android surface
-> native SurfaceTexture sampling and eye crop/copy
-> OpenXR eye images
```

**Flow: Current world path**

```text
OpenXR eye images borrowed through Flutter GPU
-> Flutter Scene final color output into those targets
-> GPU completion and OpenXR submission
```

- **Less presentation work** - The direct path removes the large world `SurfaceTexture`, its image-presentation step, and the native eye crop/copy. This addresses extra full-resolution presentation work and fresh-buffer delivery overhead.
- **Rendering still costs work** - Stereo rendering, scene simulation, shading, shadows, and effects remain. Removing an intermediate surface is not a guarantee of a particular frame rate or comfortable head motion.
- **Intermediate render targets remain** - Flutter Scene still owns depth, stencil, MSAA, HDR, shadows, and post-processing attachments when needed. Direct output means its final display color reaches the borrowed eye target without the former Android world-surface detour; it does not mean every effect renders without intermediate GPU textures.
- **No hidden world fallback** - The current Quest gallery uses the direct renderer. `OpenXrSceneView` remains an image-based side-by-side widget, but the current native host has removed the world eye-copy path. Mounting that widget is not a fallback for a broken direct-rendering setup.
- **Historical comments** - Some retained image-path APIs and comments refer to a side-by-side surface or a quad appended beside it. They describe the earlier presentation layout, not the current direct-eye gallery contract.

See [Direct OpenXR swapchain rendering](../../examples/openxr_quest/DIRECT_SWAPCHAIN_RENDERING.md)
for the detailed migration rationale and engine boundary.

## Why GPU ownership is strict

- **Borrowed images** - OpenXR owns the swapchain images. Flutter receives a temporary opportunity to render into them, not permission to retain or reuse them after the native host releases them.
- **Shared textures, local framebuffers** - The host uses Flutter's GLES share-context information so the eye textures are visible to the renderer. A framebuffer object is context-local, so the engine creates the framebuffer attachment in its raster context instead of treating a native framebuffer integer as portable.
- **Completion is not submission** - Returning from Dart rendering or calling `present()` does not prove the GPU has finished. The engine reports terminal callbacks only after the relevant final GPU work completes; the Android bridge then retires its local framebuffer resources.
- **Both eyes form a unit** - The native host waits for both token-matched terminal callbacks before releasing either image. This prevents the runtime from reusing a texture while Flutter may still be writing into it.
- **Safe cancellation** - Example switches suspend new renderer requests and drain or discard outstanding frames before disposing the scene. Render scale changes recreate swapchains only between completed stereo frames.
- **Unresolved ownership** - If a frame cannot be safely resolved, the host ends the session instead of reusing an image with uncertain ownership. An unresolved shutdown can quarantine engine/GPU resources until process cleanup; recovery then requires restarting the process.

These rules explain much of the Kotlin/C++ coordination. Simplifying away a wait
or callback can introduce image corruption or resource-lifetime failures even
when a static frame initially looks correct.

## Floating Flutter panels

- **Separate UI surface** - Ordinary Flutter widgets still render into an Android surface. Native code consumes that texture and copies it into a compositor swapchain for floating UI. Removing the world surface did not remove the UI texture path.
- **Physical panel placement** - `OpenXrCompositionQuadConfiguration` describes texture dimensions separately from physical width, height, pose, and head-relative or world-relative placement. Changing texture resolution affects pixel density; changing physical size affects how large the panel appears in the world.
- **One or two panels** - The ordinary configuration supplies one quad. A positive `panelSplitPixels` enables the gallery's two movable crops and native FPS/UI control from a shared texture atlas.
- **Controller input** - Native ray intersections determine the panel-local pixel coordinates delivered to Flutter. Panel movement, hit testing, and compositor placement use the same native geometry so a moved panel remains clickable where it is drawn.
- **Panel manipulation** - In the gallery, a controller grip grabs the aimed panel and that hand's stick pushes or pulls it. Panels remain where released. The reset action restores their starting layout.
- **Input arbitration** - A stick aimed at UI is reserved for panel interaction/scrolling; navigation uses the remaining unclaimed input. Away from panels, the gallery's left stick orbits and the right stick translates the navigation rig.
- **Controller rays** - Optional rays are Flutter Scene meshes driven by tracked aim poses. The gallery rays are direction hints, not general-purpose scene picking or object manipulation. Their tips do not claim to mark scene-surface intersections.
- **Application responsibility** - The gallery supplies widgets, routing, and its scheduler gate. The plugin does not automatically turn arbitrary application pages into panels or provide document editing, authentication, persistence, collaboration, or hand-manipulation tools.

## FPS diagnostics and UI suspension

- **Independent native HUD** - `openxr_fps_hud.h` draws the small FPS/UI button without Flutter widgets, image uploads, or a Dart paint callback. It remains available to turn the panels back on after their rendering is suspended.
- **UI OFF meaning** - In the gallery integration, UI OFF hides the two large panels, skips future Flutter framework frame callbacks, and bypasses panel texture latching/copying. The mounted UI and selected example are retained. One already-started widget frame may finish during the transition.
- **Flutter remains active** - The Dart isolate, Flutter engine, Flutter GPU/Scene rendering, scene simulation, platform messages, and stats collection continue. UI OFF measures the widget/panel workload; it does not measure an application with Flutter removed.
- **Host scheduler gate** - The gallery installs `OpenXrUiBinding` before starting its widgets and follows native pause state. Another host using the split-panel diagnostic mode must implement that contract; the native toggle alone cannot suspend Flutter's framework scheduler.
- **Separate measurements** - Completed stereo frames, OpenXR submission cadence, Flutter UI frame/raster timing, native bridge waits, and runtime CPU/GPU measurements answer different questions. A fast compositor or UI stream does not prove equally fast fresh world rendering.
- **Optional runtime counters** - `openxr_runtime_metrics.h` reads available Meta performance counters for application CPU/GPU time, compositor GPU time, and GPU utilization. Unsupported or invalid samples remain unavailable rather than appearing as zero cost. These counters are diagnostics, not rendering-policy inputs.
- **Bounded comparisons** - The gallery retains a bounded 30-second history and marks UI OFF intervals. Compare the same scene, eye dimensions, quality settings, head motion, and thermal conditions before making a performance claim.

## Resolution and scene changes

- **Eye render scale** - `OpenXrSession.setRenderScale()` accepts scales from 0.5 through 1.5 relative to the runtime-recommended eye dimensions. The gallery exposes a smaller set of choices. Native allocation applies device limits and acknowledges the result asynchronously.
- **Safe replacement** - Resolution changes keep the old eye pair until both replacement swapchains are ready. Allocation failure retains the previous resolution. The UI atlas, scene, navigation rig, and OpenXR session do not need to be rebuilt.
- **Interpret sizes correctly** - Runtime-recommended eye dimensions are rendering recommendations, not physical headset panel resolution. Increasing both dimensions increases pixel work by area; frame-rate impact still depends on the workload.
- **Scene switching** - The gallery temporarily pauses renderer requests while replacing an example. It preserves the immersive activity and selector, but disposes the old scene only after its outstanding target use is resolved.
- **Supported adaptations** - Not every flat example maps directly to stereo. The direct renderer requires a perspective reference camera when adapting an authored camera; custom rendering and split-screen examples can need specific handling. The [gallery report](../../examples/openxr_quest/GALLERY_VR_REPORT.md) records those boundaries.

## Why Dart, Kotlin, and C++ coexist

- **Dart scene integration** - `lib/` exposes the Flutter API and uses Flutter Scene's existing scene graph, cameras, simulation callbacks, and renderer. Moving that logic into C++ would duplicate the engine-facing application layer.
- **Kotlin Android bridge** - Android activity lifecycle, Flutter engines, platform channels, surfaces, pointer delivery, and engine callbacks meet here. Kotlin connects Android's embedding APIs to the native host and Dart renderer.
- **C++ OpenXR host** - OpenXR lifecycle, actions, reference spaces, frame timing, swapchains, and GLES submission are handled together in the native frame loop. The native panel/HUD helpers also operate here.
- **Build and manifest glue** - Gradle builds the Android library and supplies the OpenXR loader; CMake links C++ with the loader, Android native activity glue, EGL, and GLES. The manifest declares the immersive activity, runtime visibility, permissions, and GPU requirements.
- **Optional immersive entry** - Head tracking is marked optional in the plugin manifest so importing applications can retain flat mode. The build still has Android/GLES requirements; optional head tracking does not mean unrestricted device compatibility.

## Source map

- **Public library** - [flutter_scene_openxr.dart](lib/flutter_scene_openxr.dart) exports the supported Dart-facing types.
- **Session bridge** - [open_xr_session.dart](lib/src/open_xr_session.dart) handles launch/exit, tracked updates, renderer attachment, resolution changes, and performance controls.
- **Stereo renderer** - [open_xr_scene_view.dart](lib/src/open_xr_scene_view.dart) contains `OpenXrDirectEyeRenderer` and the retained image-based `OpenXrSceneView`.
- **Camera and frame data** - [open_xr_camera.dart](lib/src/open_xr_camera.dart), [open_xr_eye_view.dart](lib/src/open_xr_eye_view.dart), [open_xr_frame.dart](lib/src/open_xr_frame.dart), and [open_xr_controller_state.dart](lib/src/open_xr_controller_state.dart) describe tracked views and input.
- **Navigation and rays** - [open_xr_navigation.dart](lib/src/open_xr_navigation.dart) and [open_xr_controller_rays.dart](lib/src/open_xr_controller_rays.dart) adapt tracked input to optional scene navigation and visible aim hints.
- **Panel contract** - [open_xr_composition_quad_configuration.dart](lib/src/open_xr_composition_quad_configuration.dart) defines texture and world-placement configuration.
- **Performance models** - [open_xr_performance_monitor.dart](lib/src/open_xr_performance_monitor.dart) and [open_xr_native_performance_sample.dart](lib/src/open_xr_native_performance_sample.dart) collect and expose distinct timing/cadence measurements.
- **Android launch plugin** - [FlutterSceneOpenXrPlugin.kt](android/src/main/kotlin/dev/bdero/flutter_scene_openxr/FlutterSceneOpenXrPlugin.kt) connects the flat activity to immersive entry.
- **Immersive activity** - [FlutterSceneOpenXrActivity.kt](android/src/main/kotlin/dev/bdero/flutter_scene_openxr/FlutterSceneOpenXrActivity.kt) owns Android/Flutter coordination, surface delivery, input, and teardown.
- **Native frame loop** - [flutter_scene_openxr.cpp](android/src/main/cpp/flutter_scene_openxr.cpp) owns OpenXR initialization, tracking, rendering coordination, and layer submission.
- **Native helpers** - [openxr_panel_controls.h](android/src/main/cpp/openxr_panel_controls.h), [openxr_fps_hud.h](android/src/main/cpp/openxr_fps_hud.h), and [openxr_runtime_metrics.h](android/src/main/cpp/openxr_runtime_metrics.h) separate panel interaction and diagnostics from the host implementation.
- **Build declarations** - [pubspec.yaml](pubspec.yaml), [build.gradle.kts](android/build.gradle.kts), [CMakeLists.txt](android/src/main/cpp/CMakeLists.txt), and [AndroidManifest.xml](android/src/main/AndroidManifest.xml) define package registration and platform integration.

## Requirements and integration

- **Local workspace package** - The package is version `0.1.0`, uses workspace resolution, and has `publish_to: none`. Treat this checkout and its example host as the integration source, not as instructions to install a published pub.dev package.
- **Declared platform baseline** - The package declares Dart `^3.10.0` and Flutter `>=3.47.0`. Its Android build currently targets ARM64, requires API 29 or later, uses Java 17, and links the Khronos Android OpenXR loader. Consult the build declarations for exact SDK, NDK, CMake, and dependency versions.
- **Matching custom engine** - Those minimum versions are not sufficient for the direct path. The selected Flutter SDK must contain the matching Dart GPU external-surface API, Android embedding bridge, and native engine implementation. A stock SDK without those changes cannot supply the required direct eye targets.
- **Matching scene renderer** - The selected Flutter Scene revision must provide `Scene.renderViewsToTargets` and external surface color targets. Matching package version text alone does not establish that a checkout contains the required changes.
- **GLES backend** - The current external-target integration is OpenGL ES. Vulkan, Metal, and other backends are not interchangeable substitutes for this host's shared-context contract.
- **Existing host example** - Start with [open_xr_main.dart](../../examples/openxr_quest/lib/open_xr_main.dart), [open_xr_gallery_scene.dart](../../examples/openxr_quest/lib/open_xr_gallery_scene.dart), and [open_xr_ui_binding.dart](../../examples/openxr_quest/lib/open_xr_ui_binding.dart). They demonstrate entrypoint retention, native update subscription, scene readiness, renderer attachment/disposal, and optional UI suspension together.
- **Application-owned integration** - A new host must provide a retained Dart entrypoint, initialize Flutter Scene resources, attach a ready renderer, define state transfer and exit behavior, and dispose resources in the required order. Calling `enterImmersive()` alone does not supply a scene or a complete application lifecycle.

The maintained local-forks helper builds, installs, and launches the gallery on a
connected Quest. Run it deliberately: it changes the installed application and
starts an immersive session. From this repository's root:

```sh
./examples/openxr_quest/tool/quest-build-and-deploy-local-forks.sh
```

Read the [gallery README](../../examples/openxr_quest/README.md) for controls and
the [direct rendering guide](../../examples/openxr_quest/DIRECT_SWAPCHAIN_RENDERING.md)
for custom-engine prerequisites. The helper checks matching device/host engine
artifacts and accepts `QUEST_*` overrides for local paths and build targets.

## Relationship to Visual Space

- **Different current world paths** - This gallery renders the world through Flutter Scene into borrowed OpenXR targets. Visual Space's current Quest host renders native world geometry derived from its authoritative portable feature state and uses a retained Flutter atlas for product UI.
- **No automatic replacement** - Adding this package to the Flutter Scene repository does not replace Visual Space's native world renderer or its activity. Pinning a Flutter Scene version also does not automatically wire up this host.
- **Possible shared renderer boundary** - A future product integration can use the direct-target technique while preserving the existing product host. The important seam is between acquiring the eye images and releasing them, not a wholesale replacement of routes, authentication, panels, or editing sessions.
- **Product state must survive** - The gallery's separate-process, restart-baseline behavior is intentional for examples. It is not an appropriate implicit state contract for a live editor with documents, autosave, presence, collaboration, and undo history.
- **UI remains independent** - Replacing native world drawing with Flutter Scene does not require deleting the product's Flutter UI atlas. World rendering and panel composition are separate responsibilities.

The [integration boundary notes](../../examples/openxr_quest/DIRECT_SWAPCHAIN_RENDERING.md#visual-space-integration-boundary)
describe this distinction and the migration constraints. They are a design guide,
not evidence that the separate product has already migrated.

## Failure interpretation and limits

- **Availability but no session** - Device feature discovery can succeed before real OpenXR initialization fails. Inspect runtime/loader/session errors rather than treating `isAvailable()` as a rendering guarantee.
- **Missing engine APIs** - Missing external-surface Dart methods or Android embedding types indicate an SDK/engine integration mismatch. Do not restore a hidden image-copy fallback to conceal it.
- **UI without a world** - The panel and world paths are separate. Visible Flutter controls do not prove the direct renderer is attached, tracked views are valid, or eye writes completed successfully.
- **Tracking not valid** - The host skips projection rendering when the necessary view position/orientation is invalid. A skipped world frame is not permission to invent a camera pose or render mismatched stereo views.
- **Correct panels, wrong stereo** - Eye basis, asymmetric projection, image origin, color transfer, and pose association must agree at the direct-output boundary. A working widget atlas does not validate those properties.
- **No complete XR product promise** - The package is not a universal headset adapter, a spatial application shell, a generic scene editor, or an automatic state synchronizer. Advanced hands, passthrough, product-specific picking, and editing interactions require separate implementation and verification.
- **Verification scope** - Source implementation and successful compilation are distinct from on-headset behavior. Comfort, image correctness, controller interaction, pause/resume, and sustained performance need physical headset checks. This README adds no new runtime verification claim; dated build evidence and remaining checks belong in the [gallery report](../../examples/openxr_quest/GALLERY_VR_REPORT.md) and [performance notes](../../examples/openxr_quest/PERFORMANCE.md).

