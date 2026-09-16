// Draws smooth stroke contours from distances, so circles and rounded corners have no polygon facets.
// Uses the same shape sizes as StageStrokeHitService so empty ring centers remain unpickable.
// The host keeps depth testing enabled and separates the solid core from blended edges and glow.
uniform StrokeInfo {
  vec4 viewport;
  vec4 style;
  vec4 tint;
  vec4 marker_sizing;
  vec4 effects; // tail fade fraction, reserved
} stroke_info;
in vec3 v_pixel;
flat in vec4 v_ab;
flat in vec4 v_neighbors;
flat in vec4 v_shape;
flat in vec2 v_weights;
flat in vec2 v_arc;
flat in float v_marker_scale;
out vec4 frag_color;

float segmentDistance(vec2 p, vec2 a, vec2 b) {
  vec2 d = b - a;
  float t = clamp(dot(p - a, d) / max(dot(d, d), 1e-12), 0.0, 1.0);
  return length(p - a - d * t);
}
float radius(float t) {
  if (stroke_info.marker_sizing.w > 0.5) {
    return stroke_info.viewport.z * (1.0 - stroke_info.style.x * (1.0 - t) * (1.0 - t));
  }
  float x = 2.0 * t - 1.0;
  return stroke_info.viewport.z * (1.0 - stroke_info.style.x * 0.65 * x * x);
}
void main() {
  vec2 p = v_pixel.xy / v_pixel.z;
  vec2 a = v_ab.xy, b = v_ab.zw;
  vec2 delta = b - a;
  float kind = v_shape.x;
  // Arrow ink stays as thick as the line at every zoom. Only arm endpoints
  // use the bounded overview factor; scaling this width made heads skinny.
  float half_width = stroke_info.viewport.z;
  float distance;
  float path_fraction = v_shape.y;
  bool ribbon = stroke_info.marker_sizing.w > 0.5;
  bool owned = true;
  if (kind < 0.5 || kind > 4.5) {
    float t = clamp(dot(p - a, delta) / max(dot(delta, delta), 1e-12), 0.0, 1.0);
    float center_distance = segmentDistance(p, a, b);
    // Converts screen position back to a path fraction so taper stays attached to the 3D line in perspective.
    float lambda = t * v_weights.x / max((1.0 - t) * v_weights.y + t * v_weights.x, 1e-7);
    path_fraction = mix(v_shape.y, v_shape.z, lambda);
    float gap = 0.0;
    if (kind < 0.5 && stroke_info.style.z > 0.5 && stroke_info.style.z < 2.5) {
      // Match StageStrokePatternService: leave a real pixel gap after adding
      // the rounded caps, even when the world-space curve becomes tiny.
      float width = 2.0 * half_width;
      float dash = stroke_info.style.z > 1.5 ? 0.0 : max(12.0, 4.0 * width);
      float period = dash + width + max(4.0, 2.0 * width);
      float margin = (period - dash) * 0.5;
      float arc = mix(v_arc.x, v_arc.y, t);
      float local = mod(arc + margin, period) - margin;
      gap = max(0.0, max(-local, local - dash));
    }
    distance = length(vec2(center_distance, gap)) - radius(mix(v_shape.y, v_shape.z, lambda)) * (kind > 4.5 ? 0.42 : 1.0);
    // Flat ink has cut ends, while adjoining pieces still share smooth joins.
    // Clip only actual ends, not every retained centerline sample: otherwise
    // a curved ribbon would show cracks at the segment boundaries.
    if (ribbon && length(delta) > 1e-6) {
      vec2 direction = normalize(delta);
      if (length(v_neighbors.xy - a) <= 1e-5) distance = max(distance, -dot(p - a, direction));
      if (length(v_neighbors.zw - b) <= 1e-5) distance = max(distance, dot(p - b, direction));
    }
    // Lets the nearest adjoining segment own each pixel to avoid darker seams where rounded ends overlap.
    // Equal distances belong to the previous segment, so both segments cannot reject the same shared pixel.
    if (length(v_neighbors.xy - a) > 1e-5 && segmentDistance(p, v_neighbors.xy, a) <= center_distance) owned = false;
    if (length(v_neighbors.zw - b) > 1e-5 && segmentDistance(p, b, v_neighbors.zw) < center_distance) owned = false;
  } else {
    vec2 direction = length(delta) > 1e-6 ? normalize(delta) : vec2(0.0, 1.0);
    vec2 local = vec2(dot(p - a, vec2(-direction.y, direction.x)), dot(p - a, direction));
    if (kind < 1.5) {
      distance = length(local) - radius(v_shape.y);
    } else if (kind < 2.5) {
      distance = abs(length(local) - 5.0 * half_width) - half_width;
    } else if (kind < 3.5) {
      // A true rounded square ring; no polygon facets or miter spikes.
      vec2 q = abs(local) - vec2((3.535533906 - 1.25) * half_width);
      float box = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 1.25 * half_width;
      distance = abs(box) - half_width;
    } else {
      float extent_unit = half_width * v_marker_scale;
      vec2 left = vec2(-5.0, -8.75) * extent_unit;
      vec2 right = vec2(5.0, -8.75) * extent_unit;
      distance = min(segmentDistance(local, left, vec2(0.0)), segmentDistance(local, right, vec2(0.0)));
      if (ribbon) {
        // The sketchbook's broad flat arrow has filled ink between its arms.
        // Signed triangle coverage keeps this in the existing raster quad;
        // overview shortens the triangle while its rounded ink and halo keep
        // the shaft's thickness, matching open heads and pointer selection.
        distance = min(distance, segmentDistance(local, left, right));
        bool inside = local.y >= left.y && local.y <= 0.0 && abs(local.x) <= -local.y * (5.0 / 8.75);
        if (inside) distance = -distance;
      }
      distance -= half_width;
    }
  }
  // Measures edge softness before discarding pixels so neighboring fragments can still supply derivatives.
  float aa = max(fwidth(distance) * 0.75, 0.35);
  float coverage = 1.0 - smoothstep(-aa, aa, distance);
  if (!owned || v_shape.w < 0.5) discard;
  // The solid pass writes depth only inside fully covered stroke pixels, leaving marker holes empty.
  // The feather pass skips that core; a translucent stroke instead blends its entire contour in one pass.
  if (stroke_info.style.y < 0.5) {
    if (coverage < 0.999) discard;
    frag_color = vec4(stroke_info.tint.rgb, 1.0);
  } else {
    if (stroke_info.style.y < 1.5 && coverage >= 0.999) discard;
    float halo = stroke_info.viewport.w * 0.18
        * exp(-max(distance, 0.0) * 3.0 / max(half_width, 0.5));
    float fade = stroke_info.effects.x > 0.0 ? smoothstep(0.0, stroke_info.effects.x, path_fraction) : 1.0;
    float alpha = (coverage + (1.0 - coverage) * halo) * stroke_info.tint.a * fade;
    if (alpha < 0.002) discard;
    // Supplies linear color multiplied by alpha, as required by the scene's blending and display conversion.
    frag_color = vec4(stroke_info.tint.rgb * alpha, alpha);
  }
}
