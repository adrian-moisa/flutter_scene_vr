import 'package:vector_math/vector_math.dart' as vm;

/// The four OpenXR view angles that define one asymmetric eye frustum.
class OpenXrFieldOfView {
  const OpenXrFieldOfView({
    required this.angleLeft,
    required this.angleRight,
    required this.angleUp,
    required this.angleDown,
  });

  final double angleLeft;
  final double angleRight;
  final double angleUp;
  final double angleDown;
}

/// One eye pose and lens sampled by the native OpenXR frame loop.
class OpenXrEyeView {
  OpenXrEyeView({
    required vm.Vector3 position,
    required vm.Quaternion orientation,
    required this.fieldOfView,
  }) : position = position.clone(),
       orientation = orientation.normalized();

  final vm.Vector3 position;
  final vm.Quaternion orientation;
  final OpenXrFieldOfView fieldOfView;
}
