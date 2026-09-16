// A retained low-face-count sheet. Its receiver pass uses the same footprint
// at z=0, while the actual paper lifts away from its attached upper region.
uniform FrameInfo { mat4 camera_transform; vec3 camera_position; float depth_bias; } frame_info;
uniform PaperInfo {
  vec4 viewport;
  vec4 style;
  vec4 appearance;
  vec4 shadow;
  vec4 geometry; // logical viewer pixels per world-size unit
} paper_info;
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
out vec2 v_paper_uv;
out float v_paper_lift;
out vec3 v_paper_normal;
void main() {
  mat4 model = mat4(model_transform_0, model_transform_1, model_transform_2, model_transform_3);
  float c = cos(paper_info.style.y), s = sin(paper_info.style.y);
  vec2 local = mat2(c,s,-s,c) * (position.xy * paper_info.viewport.zw);
  vec3 toward_eye = normalize(frame_info.camera_position - model_transform_3.xyz);
  vec3 depth_offset = toward_eye * paper_info.style.z;
  bool receiver = paper_info.appearance.y > 2.5;
  // The receiver must stay behind its zero-lift contact under lessEqual depth.
  if (receiver) depth_offset -= toward_eye * .0002;
  float lift = receiver ? 0.0 : position.z;
  float width = length(model_transform_0.xyz);
  if (paper_info.style.x > .5) {
    vec4 anchor = frame_info.camera_transform * model_transform_3;
    vec3 row_x = vec3(frame_info.camera_transform[0].x,frame_info.camera_transform[1].x,frame_info.camera_transform[2].x);
    vec3 row_y = vec3(frame_info.camera_transform[0].y,frame_info.camera_transform[1].y,frame_info.camera_transform[2].y);
    vec3 facing = normalize(cross(row_x,row_y));
    float units = 2.0 * anchor.w / (paper_info.viewport.y * length(row_y));
    vec3 lifted_center = model_transform_3.xyz + depth_offset + facing * lift * width * paper_info.geometry.x * units;
    vec2 dimensions = vec2(width, length(model_transform_1.xyz));
    vec2 extent = local * dimensions * paper_info.geometry.x * units;
    // Project the complete curved world point once, matching the CPU's
    // camera-basis matrix and ray/triangle intersections at lifted edges.
    vec3 world = lifted_center + normalize(row_x) * extent.x
                              + normalize(row_y) * extent.y;
    gl_Position = frame_info.camera_transform * vec4(world,1.0);
  } else {
    vec4 world = model * vec4(local, 0.0, 1.0);
    world.xyz += normalize(model_transform_2.xyz) * lift * width + depth_offset;
    gl_Position = frame_info.camera_transform * world;
  }
  v_paper_uv = texture_coords;
  v_paper_lift = position.z * 280.0;
  v_paper_normal = normal;
  gl_Position.x += paper_info.style.w * (texture_coords_1.x + color.x + tangent.x + instance_color.x + frame_info.depth_bias + paper_info.appearance.w);
}
