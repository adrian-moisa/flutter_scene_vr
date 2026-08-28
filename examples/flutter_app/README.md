# Scene Examples App

This is a Flutter App that contains several Flutter Scene usage examples.

The app is just a simple harness with a dropdown that selects an example widget.

## Running

The platform stubs (`macos/`, `ios/`, `android/`, `linux/`, `windows/`) are gitignored — generate them once on a fresh clone:

```sh
flutter create . --platforms=macos,ios,android,linux,windows
```

Then run the app with Flutter GPU enabled:

```sh
flutter run --enable-flutter-gpu --enable-impeller
```

(Add `-d <device>` if multiple devices are connected.)


## Gallery controls

Click a scene to focus its camera. Drag to orbit, use WASD or arrow keys to
move, hold Shift to move faster, and press R to return to the authored camera.
Hold the middle mouse button (press the scroll wheel) and drag to orbit the camera
target, as in Visual Space. Keyboard movement carries the pivot with the camera;
wheel scrolling zooms toward/away from that pivot without crossing it. Orbit is
the default across the gallery, including VR. In split-screen examples this
controls the primary screen view.
Example overlays and settings retain their own input.

The FPS button beside Settings opens a compact panel with live scene-submission
and Flutter timing readouts, a bounded history graph, actual render/output sizes,
Flutter logical/backing sizes, DPR, and the reported display size.
Display/measurement details and the camera shortcut guide
expand on demand. The header close button dismisses the panel; sampling continues.
GPU completion and physical monitor pixels are not inferred from browser metrics.

Settings starts with a live resolution selector (50%, 67%, 75%, 100% of the current
physical viewport) and Low/Medium/High/Ultra graphics presets. Manual edits save
Custom for that example for the app session; selecting Custom restores the whole
settings instance, including nested effect controls. Custom survives example
switches but not a page reload. Selecting a different example starts its authored
settings; it does not erase that example's saved Custom slot.
