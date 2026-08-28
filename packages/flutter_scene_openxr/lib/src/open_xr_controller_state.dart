import 'package:vector_math/vector_math.dart' as vm;

/// Thumbstick input sampled with the matching OpenXR eye frame.
class OpenXrControllerState {
  OpenXrControllerState({
    required vm.Vector2 leftThumbstick,
    required vm.Vector2 rightThumbstick,
    this.aims = const [],
  }) : leftThumbstick = leftThumbstick.clone(),
       rightThumbstick = rightThumbstick.clone();

  factory OpenXrControllerState.idle() => OpenXrControllerState(
    leftThumbstick: vm.Vector2.zero(),
    rightThumbstick: vm.Vector2.zero(),
  );

  final List<OpenXrControllerAim> aims;
  final vm.Vector2 leftThumbstick;
  final vm.Vector2 rightThumbstick;
}

// A controller ray and trigger sampled with the eye poses in LOCAL space.
class OpenXrControllerAim {
  const OpenXrControllerAim({
    required this.position,
    required this.orientation,
    required this.tracked,
    required this.trigger,
  });
  final vm.Vector3 position;
  final vm.Quaternion orientation;
  final bool tracked;
  final double trigger;
}
