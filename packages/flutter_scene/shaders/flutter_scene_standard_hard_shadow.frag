// Standard PBR with one depth comparison per sampled directional cascade.
// Selected for DirectionalShadowFilter.hard: sharp edges replace penumbra
// filtering, while cascade blending, bias, and distance fade remain.
// A compile-time variant lets mobile drivers remove the soft-shadow loops
// and their register pressure instead of retaining both sides of a uniform branch.
#define FLUTTER_SCENE_HARD_SHADOWS
#include <flutter_scene_standard.frag>
