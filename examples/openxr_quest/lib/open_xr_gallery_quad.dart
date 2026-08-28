import 'package:flutter_scene_openxr/flutter_scene_openxr.dart';

// Keep this surface, the deployment extras and ray-to-pixel mapping together.
// The selector is an in-bounds scrolling list, never an off-quad popup.
const openXrGalleryQuad = OpenXrCompositionQuadConfiguration(
  textureWidthPixels: 1200,
  textureHeightPixels: 900,
  widthMeters: 1.2,
  heightMeters: 0.9,
  positionX: 0,
  positionY: -0.25,
  positionZ: -1.4,
  panelSplitPixels: 560,
);
