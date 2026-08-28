// Cubemap-radiance counterpart of the hard-shadow standard PBR variant.
// Register both in base.shaderbundle.json so selecting hard shadows preserves
// the environment sampler type required by the backend.
#define FLUTTER_SCENE_HARD_SHADOWS
#define FLUTTER_SCENE_RADIANCE_CUBE
#include <flutter_scene_standard.frag>
