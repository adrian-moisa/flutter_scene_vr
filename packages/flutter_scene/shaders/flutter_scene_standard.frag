#include <material_varyings.glsl>
#include <normals.glsl>
#include <pbr.glsl>
#include <texture.glsl>
#include <material_engine_lighting.glsl>
#include <material_inputs.glsl>
#include <material_lighting.glsl>
#include <lod_fade.glsl>

uniform sampler2D base_color_texture;
uniform sampler2D cliff_color_texture;
uniform sampler2D emissive_texture;
uniform sampler2D metallic_roughness_texture;
uniform sampler2D normal_texture;
uniform sampler2D occlusion_texture;

uniform TextureTransforms {
  // Rotation.w padding carries built-in white-placeholder flags. The base
  // flag rides in normal_rotation.w because base_color_rotation.w already
  // gates UV transforms. The other flags use their own rotation.w. Zero
  // preserves texture sampling for callers that do not provide these flags.
  // A known white sample needs no UV work, texture read, or sRGB decoding;
  // material and vertex factors still apply, including their alpha.
  vec4 base_color_transform;
  vec4 base_color_rotation;
  vec4 metallic_roughness_transform;
  vec4 metallic_roughness_rotation;
  vec4 normal_transform;
  vec4 normal_rotation;
  vec4 emissive_transform;
  vec4 emissive_rotation;
  vec4 occlusion_transform;
  vec4 occlusion_rotation;
  vec4 base_color_world; // tile size, texture weight, reserved, reserved
  vec4 cliff_color_world; // tile size (zero disables), weight, fade start/end radians
}
texture_transforms;

// Decode before mixing both projections and material layers. Explicit gradients
// keep mip selection stable when neighboring fragments skip a slope layer.
vec3 WorldColor(sampler2D image, vec3 position, vec3 weights, vec3 dx, vec3 dy) {
  return SRGBToLinear(textureGrad(image, position.zy, dx.zy, dy.zy).rgb) * weights.x +
         SRGBToLinear(textureGrad(image, position.xz, dx.xz, dy.xz).rgb) * weights.y +
         SRGBToLinear(textureGrad(image, position.xy, dx.xy, dy.xy).rgb) * weights.z;
}

// Fills the surface description for the standard glTF metallic-roughness
// material from the FragInfo parameters and the material textures. The shared
// lighting framework (material_lighting.glsl) consumes it.
void Surface(inout MaterialInputs material) {
  vec4 vertex_color = mix(vec4(1), v_color, frag_info.vertex_color_weight);
  // base_color_rotation.w (padding in each record) carries a single flag set
  // when any of the five records transforms its UVs or selects UV set 1.
  // Every record is identity for a default glTF material, and the identity
  // transform reproduces the raw UV bit-exactly, so the uniform branch only
  // skips work.
  bool transformed_uvs = texture_transforms.base_color_rotation.w > 0.5;
  vec4 base_color_srgb = vec4(1.0);
  vec3 base_color_linear = vec3(1.0);
  bool world_texture = texture_transforms.base_color_world.x > 0.0;
  bool cliff_texture = texture_transforms.cliff_color_world.x > 0.0;
  vec3 position = GetWorldPosition();
  vec3 position_dx = dFdx(position), position_dy = dFdy(position);
  vec3 world_normal = GetWorldNormal();
  vec3 weights = vec3(0.0);
  if (world_texture || cliff_texture) {
    weights = pow(abs(world_normal), vec3(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.00001);
  }
  if (world_texture) {
    float scale = texture_transforms.base_color_world.x;
    base_color_linear = WorldColor(base_color_texture, position / scale, weights,
                                   position_dx / scale, position_dy / scale);
  } else if (texture_transforms.normal_rotation.w < 0.5) {
    vec2 base_color_uv = transformed_uvs
        ? MaterialTextureUv(
              texture_transforms.base_color_transform,
              texture_transforms.base_color_rotation)
        : GetUV0();
    base_color_srgb = texture(base_color_texture, base_color_uv);
    base_color_linear = SRGBToLinear(base_color_srgb.rgb);
  }
  vec3 albedo = base_color_linear * vertex_color.rgb * frag_info.color.rgb;
  if (world_texture) {
    albedo = mix(frag_info.color.rgb * vertex_color.rgb, base_color_linear,
                 clamp(texture_transforms.base_color_world.y, 0.0, 1.0));
  }
  if (cliff_texture) {
    // Absolute Y makes horizontal undersides gentle too and prevents
    // double-sided normal reversal from changing the selected layer.
    float angle = acos(clamp(abs(world_normal.y), 0.0, 1.0));
    float blend = smoothstep(texture_transforms.cliff_color_world.z,
                             texture_transforms.cliff_color_world.w, angle);
    if (blend > 0.0) {
      float scale = texture_transforms.cliff_color_world.x;
      vec3 cliff = WorldColor(cliff_color_texture, position / scale, weights,
                              position_dx / scale, position_dy / scale);
      cliff = mix(frag_info.color.rgb * vertex_color.rgb, cliff,
                   clamp(texture_transforms.cliff_color_world.y, 0.0, 1.0));
      albedo = mix(albedo, cliff, blend);
    }
  }
  float alpha = base_color_srgb.a * vertex_color.a * frag_info.color.a;
  // MASK alpha mode: discard fragments below the cutoff, render the
  // rest fully opaque (glTF treats MASK output as binary). Done here, before
  // the normal-map derivatives, so the discard's effect on screen-space
  // derivatives matches the original monolithic shader.
  if (frag_info.alpha_mode == 1.0) {
    if (alpha < frag_info.alpha_cutoff) {
      discard;
    }
    alpha = 1.0;
  }
  material.base_color = vec4(albedo, alpha);

  // Note: PerturbNormal needs the non-normalized view vector
  //       (camera_position - vertex_position).
  vec3 normal = GetWorldNormal();
  if (frag_info.has_normal_map > 0.5) {
    vec2 normal_uv = transformed_uvs
        ? MaterialTextureUv(
              texture_transforms.normal_transform,
              texture_transforms.normal_rotation)
        : GetUV0();
    normal = PerturbNormal(normal_texture, normal, v_viewvector,
                           normal_uv, frag_info.normal_scale);
  }
  material.normal = normal;

  vec4 metallic_roughness = vec4(1.0);
  if (texture_transforms.metallic_roughness_rotation.w < 0.5) {
    vec2 metallic_roughness_uv = transformed_uvs
        ? MaterialTextureUv(
              texture_transforms.metallic_roughness_transform,
              texture_transforms.metallic_roughness_rotation)
        : GetUV0();
    metallic_roughness =
        texture(metallic_roughness_texture, metallic_roughness_uv);
  }
  material.metallic = clamp(metallic_roughness.b * frag_info.metallic_factor,
                            0.0, 1.0);
  material.roughness =
      clamp(metallic_roughness.g * frag_info.roughness_factor, kMinRoughness,
            1.0);

  float occlusion = 1.0;
  if (texture_transforms.occlusion_rotation.w < 0.5) {
    vec2 occlusion_uv = transformed_uvs
        ? MaterialTextureUv(
              texture_transforms.occlusion_transform,
              texture_transforms.occlusion_rotation)
        : GetUV0();
    occlusion = texture(occlusion_texture, occlusion_uv).r;
  }
  material.occlusion = 1.0 - (1.0 - occlusion) * frag_info.occlusion_strength;

  vec3 emissive_linear = vec3(1.0);
  if (texture_transforms.emissive_rotation.w < 0.5) {
    vec2 emissive_uv = transformed_uvs
        ? MaterialTextureUv(
              texture_transforms.emissive_transform,
              texture_transforms.emissive_rotation)
        : GetUV0();
    emissive_linear = SRGBToLinear(texture(emissive_texture, emissive_uv).rgb);
  }
  material.emissive = emissive_linear * frag_info.emissive_factor.rgb *
                      frag_info.emissive_factor.a;

  PrepareMaterial(material);
}

void main() {
  ApplyLodFade(frag_info.fade);
  MaterialInputs material = InitMaterialInputs();
  Surface(material);
  frag_color = EvaluateLighting(material);
}
