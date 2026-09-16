// Expands saved 3D line segments into screen-width strokes without CPU updates as the camera moves.
// The fragment shader shapes their rounded edges and markers inside these support rectangles.
// Scene depth stays attached to the stroke so nearer objects can hide it.
// Uses the camera matrix supplied for this draw, including the current eye when rendering in stereo.
uniform FrameInfo {
  mat4 camera_transform;
  vec3 camera_position;
  float depth_bias;
} frame_info;
uniform StrokeInfo {
  vec4 viewport; // logical width, height, half stroke width, glow
  vec4 style;    // taper, pass (0 solid core, 1 feather, 2 translucent), pattern (0 solid, 1 dashed, 2 dotted, 3 sketch), keep-alive zero
  vec4 tint;     // linear, straight RGBA
  vec4 marker_sizing; // overview start distance, shrink exponent, orthographic equivalent distance (0 for perspective), profile (0 tube, 1 flat ribbon)
  vec4 effects; // tail fade fraction, reserved
} stroke_info;
// Projected arc lengths are updated as uniforms; the mesh stays retained.
// This bounded batch size matches StageStrokePatternService.batchSize.
uniform StrokePattern {
  vec4 arcs[128];
} stroke_pattern;
// Reuses the standard mesh layout for stroke data, rather than surface normals or vertex colors.
// position/normal hold segment endpoints; color.xyz/tangent.xyz hold the neighboring endpoints.
// tangent.w indexes the projected arc range within the retained batch.
// texture_coords chooses the rectangle corner; texture_coords_1 holds fractions along the saved path.
// color.w matches StageStrokePieceKind: line, dot, circle, square, arrow, left companion, right companion.
// Keep this layout aligned with StageStrokeMeshService and the pointer shape calculations.
in vec3 position;
in vec3 normal;
in vec2 texture_coords;
in vec2 texture_coords_1;
in vec4 color;
in vec4 tangent;
in vec4 model_transform_0;
in vec4 model_transform_1;
in vec4 model_transform_2;
in vec4 model_transform_3;
in vec4 instance_color;

out vec3 v_pixel;
flat out vec4 v_ab;
flat out vec4 v_neighbors;
flat out vec4 v_shape; // kind, start/end arc fractions, enabled
flat out vec2 v_weights;
flat out vec2 v_arc;
flat out float v_marker_scale;

vec2 pixel(vec4 clip) {
  return clip.xy / max(clip.w, 1e-7) * stroke_info.viewport.xy * 0.5;
}
float radius(float t) {
  // A flat brush gathers weight toward its destination (DS-LINE-019).
  // This is raster width, never a camera-dependent ribbon mesh.
  if (stroke_info.marker_sizing.w > 0.5) {
    return stroke_info.viewport.z * (1.0 - stroke_info.style.x * (1.0 - t) * (1.0 - t));
  }
  float x = 2.0 * t - 1.0;
  return stroke_info.viewport.z * (1.0 - stroke_info.style.x * 0.65 * x * x);
}
void main() {
  mat4 model = mat4(model_transform_0, model_transform_1,
                    model_transform_2, model_transform_3);
  mat4 vp = frame_info.camera_transform * model;
  vec4 a = vp * vec4(position, 1.0);
  vec4 b = vp * vec4(normal, 1.0);
  vec4 previous = vp * vec4(color.xyz, 1.0);
  vec4 next = vp * vec4(tangent.xyz, 1.0);
  float kind = color.w;
  bool line = kind < 0.5 || kind > 4.5;
  float start = texture_coords_1.x;
  float end = texture_coords_1.y;
  // Clips the centerline before calculating its on-screen direction.
  // Hardware clipping alone cannot repair a direction calculated from a point behind the eye.
  // This clips at the camera's near plane; ordinary depth testing handles occlusion by scene objects.
  float near_a = min(a.z, a.w - 1e-6);
  float near_b = min(b.z, b.w - 1e-6);
  float enabled = line ? ((near_a >= 0.0 || near_b >= 0.0) ? 1.0 : 0.0)
                      : (near_a >= 0.0 ? 1.0 : 0.0);
  if (line && enabled > 0.0) {
    if (near_a < 0.0) {
      float t = (-near_a + 1e-7) / (near_b - near_a + 1e-7);
      a = mix(a, b, t);
      start = mix(start, end, t);
      previous = a;
    }
    if (near_b < 0.0) {
      float t = (-near_b + 1e-7) / (near_a - near_b + 1e-7);
      b = mix(b, a, t);
      end = mix(end, start, t);
      next = b;
    }
  }
  vec2 pa = pixel(a), pb = pixel(b);
  vec2 delta = pb - pa;
  // Keeps the marker's direction stable even when its auxiliary tangent endpoint is behind the near plane.
  // Calculates the projected direction before dividing by depth to avoid a flip at that crossing.
  if (!line) delta = (b.xy * a.w - a.xy * b.w) * stroke_info.viewport.xy;
  vec2 direction = length(delta) > 1e-6 ? normalize(delta) : vec2(0.0, 1.0);
  vec2 side = vec2(-direction.y, direction.x);
  float base = stroke_info.viewport.z;
  // Intentional Stage behavior: only arm length/spread follows Post-it's
  // half-rate falloff. Keep full stroke thickness and stop at 50% extent:
  // wings then still project 2.5 half-widths sideways from the shaft. Shrinking
  // the ink too made skinny heads; unbounded shrinkage erased the arrow shape.
  // Preserve this distinction and floor, including in StageStrokeHitService.
  // Use this draw's clip depth, including the current eye, without mesh uploads.
  float distance = stroke_info.marker_sizing.z > 0.0 ? stroke_info.marker_sizing.z : max(a.w, 0.03);
  v_marker_scale = kind > 3.5 && kind < 4.5
      ? max(0.5, pow(min(1.0, stroke_info.marker_sizing.x / distance), stroke_info.marker_sizing.y)) : 1.0;
  float r0 = line || kind < 1.5 ? radius(start) : base;
  float r1 = line || kind < 1.5 ? radius(end) : base;
  vec2 sample_pixel;
  vec4 clip;
  float feather = 1.5 + base * 1.8 * stroke_info.viewport.w;
  if (line) {
    float offset = kind > 4.5 ? (kind < 5.5 ? 3.4 : -3.4) * base : 0.0;
    pa += side * offset;
    pb += side * offset;
    if (kind > 4.5) { r0 *= 0.42; r1 *= 0.42; }
    // Taper can be widest between the endpoints (a straight line needs only
    // one capsule), so bound its full width rather than just its end radii.
    float pad = base * (kind > 4.5 ? 0.42 : 1.0) + feather;
    float t = texture_coords.x;
    sample_pixel = mix(pa, pb, t) + direction * mix(-pad, pad, t)
                   + side * texture_coords.y * pad;
    clip = mix(a, b, t);
    vec2 pp = previous.z > 0.0 && previous.w > 1e-6 ? pixel(previous) + side * offset : pa;
    vec2 pn = next.z > 0.0 && next.w > 1e-6 ? pixel(next) + side * offset : pb;
    v_neighbors = vec4(pp, pn);
  } else {
    float extent = kind < 1.5 ? r0 : (kind < 2.5 ? 6.0 * base : 5.0 * base);
    vec2 lo = vec2(-extent - feather), hi = vec2(extent + feather);
    if (kind > 3.5) {
      float extent_unit = base * v_marker_scale;
      // Only the arm endpoints shrink; retain full ink/halo padding.
      lo = vec2(-5.0 * extent_unit - base - feather, -8.75 * extent_unit - base - feather);
      hi = vec2(5.0 * extent_unit + base + feather, base + feather);
    }
    vec2 local = mix(lo, hi, vec2(texture_coords.x, texture_coords.y * 0.5 + 0.5));
    sample_pixel = pa + side * local.x + direction * local.y;
    clip = a;
    pb = pa + direction;
    v_neighbors = vec4(pa, pa);
  }
  gl_Position = vec4(sample_pixel * 2.0 / stroke_info.viewport.xy * clip.w, clip.z, clip.w);
  if (enabled < 0.5) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
  // Ratio cancels perspective interpolation, giving logical pixel coordinates
  // on native and web without relying on framebuffer origin or device ratio.
  v_pixel = vec3(sample_pixel * gl_Position.w, gl_Position.w);
  v_ab = vec4(pa, pb);
  v_shape = vec4(kind, start, end, enabled);
  v_weights = vec2(a.w, b.w);
  v_arc = stroke_pattern.arcs[int(tangent.w)].xy;
  // Keeps the compiler from dropping standard mesh inputs that the renderer still binds.
  // The host supplies zero here, so preserving those inputs does not move the stroke.
  gl_Position.x += stroke_info.style.w * (tangent.w + instance_color.x + instance_color.y
      + instance_color.z + instance_color.w + frame_info.camera_position.x + frame_info.depth_bias);
}
