// The display chain stores premultiplied, display-encoded sRGB in plain
// textures. Only this final handoff knows whether the destination also
// performs hardware sRGB encoding (for example, a Quest eye swapchain).
uniform DisplayOutputInfo {
  vec4 background_color;
  float decode_srgb;
  float _pad0;
  float _pad1;
  float _pad2;
} output_info;

uniform sampler2D display_color;
in vec2 v_uv;
out vec4 frag_color;

vec3 SRGBToLinear(vec3 color) {
  return mix(color / 12.92,
             pow(max((color + 0.055) / 1.055, vec3(0.0)), vec3(2.4)),
             step(0.04045, color));
}

void main() {
  vec4 color = texture(display_color, v_uv);
  // Match Flutter's display-space source-over composition. Opaque skybox
  // pixels remain untouched; transparent pixels reveal the shared backdrop.
  color += output_info.background_color * (1.0 - color.a);
  if (output_info.decode_srgb > 0.5) {
    // Decode the stored premultiplied RGB, without dividing by alpha: the
    // attachment's hardware encode must restore those exact RGB values.
    color.rgb = SRGBToLinear(color.rgb);
  }
  frag_color = color;
}
