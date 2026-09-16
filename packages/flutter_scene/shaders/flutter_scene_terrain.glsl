// Terrain elevations are IEEE754 float32 bytes in linear RGBA8 data textures.
// Integer texel lookup avoids filtering the encoded bytes or losing signed
// precision through a normalized grayscale height representation.
uniform sampler2D terrain_top;
uniform sampler2D terrain_bottom;

float TerrainHeight(ivec2 cell, bool lower) {
  vec4 packed = lower ? texelFetch(terrain_bottom, cell, 0)
                      : texelFetch(terrain_top, cell, 0);
  uvec4 bytes = uvec4(round(packed * 255.0));
  return uintBitsToFloat(bytes.x | (bytes.y << 8u) |
                         (bytes.z << 16u) | (bytes.w << 24u));
}

ivec2 TerrainCell(vec3 grid_position) {
  ivec2 last = textureSize(terrain_top, 0) - ivec2(1);
  return clamp(ivec2(round((grid_position.xz + vec2(0.5)) * vec2(last))),
               ivec2(0), last);
}

vec3 TerrainPosition(vec3 grid_position) {
  return vec3(grid_position.x,
              TerrainHeight(TerrainCell(grid_position), grid_position.y < 0.0),
              grid_position.z);
}

vec3 TerrainNormal(vec3 grid_position, vec3 grid_normal) {
  // Duplicated perimeter vertices retain their hard, horizontal cliff normal.
  if (grid_normal.y == 0.0) return grid_normal;
  ivec2 last = textureSize(terrain_top, 0) - ivec2(1);
  ivec2 cell = TerrainCell(grid_position);
  ivec2 lo = max(cell - ivec2(1), ivec2(0));
  ivec2 hi = min(cell + ivec2(1), last);
  bool lower = grid_position.y < 0.0;
  float dx = (TerrainHeight(ivec2(hi.x, cell.y), lower) -
              TerrainHeight(ivec2(lo.x, cell.y), lower)) *
             float(last.x) / float(hi.x - lo.x);
  float dz = (TerrainHeight(ivec2(cell.x, hi.y), lower) -
              TerrainHeight(ivec2(cell.x, lo.y), lower)) *
             float(last.y) / float(hi.y - lo.y);
  // Neighbor samples cross patch boundaries, keeping shared vertices smooth
  // even where the adaptive interiors use different triangle densities.
  return normalize(vec3(-dx, 1.0, -dz)) * (lower ? -1.0 : 1.0);
}
