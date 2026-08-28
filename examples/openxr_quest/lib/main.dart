import 'package:flutter/widgets.dart';
import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

import 'open_xr_gallery.dart';
import 'open_xr_main.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureOpenXrEntrypointLinked();
  final selected = await OpenXrSession.instance.galleryInitialExample();
  runApp(OpenXrGallery(immersive: false, initialExample: selected));
}
