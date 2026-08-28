import 'package:flutter/widgets.dart';
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

import 'open_xr_gallery.dart';
import 'open_xr_ui_binding.dart';

// The flat launcher references this library so the native-selected entrypoint
// is included in the app; the pragma below retains the function for AOT lookup.
void ensureOpenXrEntrypointLinked() {}

@pragma('vm:entry-point')
Future<void> openXrMain() async {
  final binding = OpenXrUiBinding();
  OpenXrSession.instance.frames.addListener(() {
    binding.uiPaused = OpenXrSession.instance.latestFrame.uiPaused;
  });
  await OpenXrSession.instance.attachToNativeViewStream();
  final selected = await OpenXrSession.instance.galleryInitialExample();
  runApp(OpenXrGallery(immersive: true, initialExample: selected));
}
