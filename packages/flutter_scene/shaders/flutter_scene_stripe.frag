// The silhouette is a retained world-space triangle mesh, not a stroke mask.
// No texture is needed: UV.x only carries distance from the authored tail.
uniform StripeInfo {
  vec4 tint;
  vec4 effects; // tail fade fraction, reserved
} stripe_info;
in vec2 v_texture_coords;
out vec4 frag_color;
void main() {
  float fade = stripe_info.effects.x > 0.0 ? smoothstep(0.0, stripe_info.effects.x, v_texture_coords.x) : 1.0;
  float alpha = stripe_info.tint.a * fade;
  if (alpha < 0.002) discard;
  frag_color = vec4(stripe_info.tint.rgb * alpha, alpha);
}
