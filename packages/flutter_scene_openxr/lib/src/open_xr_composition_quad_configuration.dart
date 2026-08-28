/// Describes one Flutter-painted texture crop submitted as an OpenXR quad.
///
// The direct-eye host renders Flutter into a UI-only atlas, separate from eyes.
// OpenXR presents each crop to both eyes and updates its pose independently,
// so moving a panel does not require another Flutter paint.
class OpenXrCompositionQuadConfiguration {
  const OpenXrCompositionQuadConfiguration({
    required this.textureWidthPixels,
    required this.textureHeightPixels,
    required this.widthMeters,
    required this.heightMeters,
    required this.positionX,
    required this.positionY,
    required this.positionZ,
    this.orientationX = 0,
    this.orientationY = 0,
    this.orientationZ = 0,
    this.orientationW = 1,
    this.headLocked = false,
    this.panelSplitPixels = 0,
  }) : assert(textureWidthPixels > 0),
       assert(textureHeightPixels > 0),
       assert(widthMeters > 0),
       assert(heightMeters > 0);

  final int textureWidthPixels;
  final int textureHeightPixels;
  final double widthMeters;
  final double heightMeters;
  final double positionX;
  final double positionY;
  final double positionZ;
  final double orientationX;
  final double orientationY;
  final double orientationZ;
  final double orientationW;

  /// Anchors the quad to the headset when true, otherwise to LOCAL space.
  final bool headLocked;

  /// Optional vertical atlas split for two movable panels and a native FPS/UI
  /// toggle. Zero retains the ordinary single quad. The host must install its
  /// UI scheduler gate before enabling this diagnostic presentation.
  final int panelSplitPixels;

  Map<String, Object> toPlatformArguments() => {
    'textureWidthPixels': textureWidthPixels,
    'textureHeightPixels': textureHeightPixels,
    'widthMeters': widthMeters,
    'heightMeters': heightMeters,
    'positionX': positionX,
    'positionY': positionY,
    'positionZ': positionZ,
    'orientationX': orientationX,
    'orientationY': orientationY,
    'orientationZ': orientationZ,
    'orientationW': orientationW,
    'headLocked': headLocked,
    'panelSplitPixels': panelSplitPixels,
  };
}
