// Depth-of-field postfilter, a 3x3 tent over the half-res gather output.
// Smooths the residual undersampling noise of the fixed gather kernel (the
// engine has no temporal pass to hide it), at the cost of slightly softer
// bokeh edges.

precision highp float;

uniform sampler2D dof_texture;

uniform PostFilterInfo {
  // xy: half-res texel size   zw: unused
  vec4 params0;
}
postfilter_info;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  // Each bilinear tap averages a 2x2 block. Four half-texel offsets overlap
  // into the same [1, 2, 1] x [1, 2, 1] tent, including clamped borders.
  // This relies on DofPass binding a linear, clamp-to-edge sampler.
  vec2 t = postfilter_info.params0.xy * 0.5;
  vec4 sum = vec4(0.0);
  sum += texture(dof_texture, v_uv + vec2(-t.x, -t.y));
  sum += texture(dof_texture, v_uv + vec2(t.x, -t.y));
  sum += texture(dof_texture, v_uv + vec2(-t.x, t.y));
  sum += texture(dof_texture, v_uv + vec2(t.x, t.y));
  frag_color = sum * 0.25;
}
