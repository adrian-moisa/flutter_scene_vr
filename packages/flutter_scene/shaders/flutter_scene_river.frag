// Stage-owned coverage and direction fields. The engine owns transforms,
// depth, transparent composition and final display encoding.
#include <material_varyings.glsl>
uniform RiverInfo {
  vec4 tint;       // linear RGB, combined opacity
  vec4 effect;     // elapsed seconds * speed, scale, strength, kind
  vec4 appearance; // wire/solid/material, table, selected, pastel/realistic
  vec4 extent;     // world width/depth, world height, bank fade in world meters
} river_info;
uniform sampler2D river_mask;
uniform sampler2D river_direction;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
  vec2 cell = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(cell), hash(cell + vec2(1, 0)), f.x),
             mix(hash(cell + vec2(0, 1)), hash(cell + vec2(1, 1)), f.x), f.y);
}
// World-space pigment remains still while currents move. Fade frequencies
// that a pixel cannot resolve instead of turning paper grain into shimmer.
float filteredNoise(vec2 p) {
  float footprint = max(length(dFdx(p)), length(dFdy(p)));
  return mix(noise(p), .5, smoothstep(.35, 1.0, footprint));
}
float bankTexture(vec2 uv) {
  vec2 p = uv * max(river_info.extent.xy, vec2(.01));
  return filteredNoise(p * 1.7) * .65 + filteredNoise(p * 5.3 + 21.7) * .35;
}
vec2 directionAt(vec2 uv) {
  vec2 direction = (texture(river_direction, clamp(uv, 0.0, 1.0)).rg * 255.0 - 128.0) / 127.0;
  if (length(direction) <= .03) return vec2(1.0, .0);
  // Authored tangents live in the unit footprint. Normalize in world meters
  // before placing world-sized highlights, preserving bends after resizing.
  direction *= max(river_info.extent.xy, vec2(.01));
  return normalize(direction);
}
// Each curve owns a fixed anchor and direction. Projecting absolute position
// onto a per-fragment direction would rotate stripe phase around the patch
// origin, bunching lines at bends. Two anchored scales mix long currents with
// short strokes; fine companion wisps reuse their direction samples.
vec3 riverPattern(vec2 uv, float time) {
  vec2 extent = max(river_info.extent.xy, vec2(.01));
  float scale = max(river_info.effect.y, .1);
  vec2 p = uv * extent;
  float line = 0.0, ripple = 0.0;
  // Derivatives come from continuous position, never the discontinuous cell
  // index: a pixel quad crossing a cell boundary must keep the same AA width.
  vec2 dx = dFdx(p), dy = dFdy(p);
  for (int layer = 0; layer < 2; layer++) {
    bool mainCurrent = layer == 0;
    float cellSize = (mainCurrent ? 3.3 : .78) * scale;
    vec2 cell = floor(p / cellSize);
    for (int row = -1; row <= 1; row++) {
      for (int column = -1; column <= 1; column++) {
        vec2 seed = cell + vec2(float(column), float(row));
        vec2 identity = seed + float(layer) * 43.71;
        float random = hash(identity + 7.31), variation = hash(identity + 31.13);
        vec2 jitter = vec2(random, hash(identity + 19.47)) * .46 - .23;
        vec2 center = (seed + .5 + jitter) * cellSize;
        vec2 tangent = directionAt(center / extent), side = vec2(-tangent.y, tangent.x);
        vec2 relative = p - center;
        float along = dot(relative, tangent), across = dot(relative, side);
        float halfLength = cellSize * (mainCurrent ? .22 + variation * .24 : .12 + variation * .22);
        float curvePhase = random * 6.2831853;
        float curvature = cellSize * (mainCurrent ? .016 + variation * .040 : .009 + variation * .025);
        float bend = curvature * (sin(along / halfLength * 1.8 + curvePhase) - sin(curvePhase));
        float curveSlope = curvature * cos(along / halfLength * 1.8 + curvePhase) * 1.8 / halfLength;
        float ridge = abs(across - bend);
        vec2 ridgeGradient = side - tangent * curveSlope;
        float aa = max(abs(dot(dx, ridgeGradient)) + abs(dot(dy, ridgeGradient)), .0001);
        float lengthFraction = along / halfLength;
        float taper = max(.08, 1.0 - lengthFraction * lengthFraction);
        float width = cellSize * (mainCurrent ? .004 : .010) * (.75 + random * .65) * taper;
        float resolved = 1.0 - smoothstep(cellSize * .035, cellSize * .13, aa);
        float stroke = (1.0 - smoothstep(width, width * 1.6 + aa, ridge)) * resolved;
        float ends = 1.0 - smoothstep(halfLength * .68, halfLength, abs(along));
        // The travelling envelope is entirely outside the segment at both
        // ends of its cycle, so wrapping phase does not cause a visible jump.
        float travel = (fract(time * .13 + random) * 3.2 - 1.6) * halfLength;
        float pulse = 1.0 - smoothstep(halfLength * .18, halfLength * .55, abs(along - travel));
        float enabled = mainCurrent ? 1.0 : smoothstep(.28, .50, hash(identity + 63.27));
        float intensity = (.70 + variation * .30) * (.78 + pulse * .22) * enabled;
        line = max(line, stroke * ends * intensity);
        if (!mainCurrent) {
          // Offset, shorter companion marks vary the drawing vocabulary
          // without another field lookup or regularly repeated parallel pairs.
          float offset = cellSize * (.028 + variation * .034);
          float wispDistance = abs(across - bend - offset * (random < .5 ? -1.0 : 1.0));
          float wispEnds = 1.0 - smoothstep(halfLength * .30, halfLength * .66, abs(along + halfLength * .20));
          float wisp = (1.0 - smoothstep(width * .35, width * .70 + aa, wispDistance)) * resolved;
          float wispPresence = smoothstep(.68, .84, hash(identity + 84.61));
          line = max(line, wisp * wispEnds * intensity * wispPresence * .70);
        } else {
          float rippleBand = 1.0 - smoothstep(cellSize * .06, cellSize * .18, ridge);
          ripple += sin((across - bend) / cellSize * 24.0) * rippleBand * ends * resolved;
        }
      }
    }
  }
  float wash = noise(p / scale * .13);
  return vec3(line, wash, ripple);
}
float surfaceAlpha(vec2 uv, bool realistic) {
  if (river_info.appearance.y < .5) {
    // This is the derived blurred field, not binary authored coverage. Keep
    // its full transition and widen subpixel edges with screen derivatives.
    float value = texture(river_mask, clamp(uv, 0.0, 1.0)).r;
    // Vary only the existing fade: dry holes stay empty and the painted
    // interior stays solid. This breaks the uniform airbrush silhouette
    // without translating UVs or introducing a second coverage source.
    float bank = realistic ? .5 : bankTexture(uv);
    value += (bank - .5) * .72 * (value * (1.0 - value));
    float aa = max(fwidth(value) * .5, .001);
    float mask = smoothstep(.05 - aa, .82 + aa, value);
    vec2 border = min(uv, 1.0 - uv) * 512.0;
    float edge = min(border.x, border.y);
    float screenWidth = max(fwidth(edge), .001);
    return mask * smoothstep(0.0, (realistic ? 1.5 : 1.4 + bank * 2.0) + screenWidth, edge);
  }
  // Terrain clipping supplies each vertex's submerged depth in local Y.
  // Both the actual bank and the finite patch border receive a soft fade.
  float width = max(river_info.extent.w, .001) * (realistic ? .65 : .5 + bankTexture(uv) * .5);
  float depth = max(v_color.r, 0.0) * max(river_info.extent.z, .001);
  vec2 border = min(uv, 1.0 - uv) * max(river_info.extent.xy, vec2(.01));
  float proximity = min(depth, min(border.x, border.y)) / width;
  float aa = max(fwidth(proximity) * .5, .001);
  return smoothstep(-aa, 1.0 + aa, proximity);
}
void main() {
  vec2 uv = v_texture_coords;
  bool realistic = river_info.appearance.w > .5;
  float shape = surfaceAlpha(uv, realistic);
  float contour = 4.0 * shape * (1.0 - shape);
  vec3 color = river_info.tint.rgb;
  float alpha = river_info.tint.a * shape;
  if (river_info.appearance.x < .5) {
    alpha *= contour;
    if (alpha < .002) discard;
    color = river_info.appearance.z > .5 ? vec3(.01, .22, 1.0) : vec3(.06, .12, .18);
    frag_color = vec4(color * alpha, alpha);
    return;
  }
  if (river_info.appearance.x < 1.5) {
    if (alpha < .002) discard;
    color = mix(vec3(.42, .46, .5), vec3(.03, .38, .8), contour * river_info.appearance.z * .65);
    frag_color = vec4(color * alpha, alpha);
    return;
  }
  float time = river_info.effect.x;
  vec3 pattern = riverPattern(uv, time);
  float ribbon = pattern.x;
  float wash = pattern.y;
  float strength = river_info.effect.z;
  float kind = river_info.effect.w;
  if (!realistic) {
    // Pigment has broad pools and smaller washed variations, while fine grain
    // disappears below pixel resolution. Existing authored tints stay primary.
    vec3 paperTint = kind < .5 ? vec3(.76, .87, .93)
        : kind < 1.5 ? vec3(.96, .69, .40)
        : kind < 2.5 ? vec3(.70, .65, .91) : vec3(.39, .43, .49);
    vec2 pigmentPosition = uv * max(river_info.extent.xy, vec2(.01)) / max(river_info.effect.y, .1);
    float broadPigment = filteredNoise(pigmentPosition * .23 + 4.7);
    float middlePigment = filteredNoise(pigmentPosition * .87 + vec2(broadPigment * .7, 13.4));
    float grain = filteredNoise(pigmentPosition * 26.0 + 71.9) - .5;
    // Transparency already lifts the wash against paper. Keep the linear
    // water base cooler/darker instead of whitening it a second time.
    if (kind < .5) color *= vec3(.56, .74, .98);
    color = mix(color, paperTint, kind < .5 ? .02 : kind > 2.5 ? .42 : .20);
    color *= .82 + broadPigment * .27 + (middlePigment - .5) * .17 + grain * .028;
    color = mix(color, paperTint, smoothstep(.60, .82, middlePigment) * .12);
    vec3 highlight = kind < .5 ? vec3(1.0, .98, .90)
        : kind < 1.5 ? vec3(1.0, .85, .58)
        : kind < 2.5 ? vec3(.9, .86, 1.0) : vec3(.62, .67, .72);
    float ink = clamp(ribbon * strength * (kind < .5 ? 1.8 : 1.45), 0.0, .94);
    if (kind < .5) {
      float flecks = smoothstep(.56, .73, bankTexture(uv))
          * smoothstep(.48, .68, filteredNoise(pigmentPosition * vec2(3.7, 7.1) + 17.3));
      ink = max(ink, contour * flecks * strength * .65);
    }
    color = mix(color, highlight, ink);
  } else {
    // View-dependent surface response remains a shader effect, without
    // refraction, scene captures or a fluid simulation dependency.
    vec3 normal = normalize(v_normal), view = normalize(v_viewvector);
    if (dot(normal, view) < 0.0) normal = -normal;
    // Small derivative-based ripples perturb the actual world tangent plane,
    // so a rotated/resized surface keeps the same view-dependent sheen.
    vec3 dx = dFdx(v_position), dy = dFdy(v_position);
    vec3 acrossX = cross(dy, normal), acrossY = cross(normal, dx);
    float determinant = dot(dx, acrossX);
    float height = pattern.z * max(river_info.effect.y, .1) * .006;
    vec3 gradient = (dFdx(height) * acrossX + dFdy(height) * acrossY)
        * sign(determinant) / max(abs(determinant), 1e-8);
    normal = normalize(normal - gradient * strength);
    float fresnel = pow(1.0 - clamp(dot(normal, view), 0.0, 1.0), 4.0);
    vec3 halfVector = normalize(view + normalize(vec3(-.35, .85, -.3)));
    float gloss = pow(max(dot(normal, halfVector), 0.0), 64.0);
    float reflection = strength * (fresnel * .24 + gloss * (.04 + ribbon * .55));
    if (kind < .5) {
      color *= .78 + wash * .22;
      color = mix(color, vec3(.65, .81, .9), fresnel * .35);
      color += vec3(.72, .88, 1.0) * (ribbon * strength * .28 + reflection);
    } else if (kind < 1.5) {
      // Broad warm crust and molten seams, with no black threshold bands.
      color *= .55 + wash * .30;
      color += vec3(1.5, .55, .08) * ribbon * strength;
      color += vec3(.4, .11, .025) * strength * (.4 + wash * .3);
    } else if (kind < 2.5) {
      float pulse = .85 + .15 * sin(time * 1.3 + wash * 3.0);
      color *= .72 + wash * .20;
      color += mix(color * 1.8, vec3(1.0), .3) * ribbon * strength * pulse;
      color += color * reflection;
    } else {
      vec3 sheen = .5 + .5 * cos(vec3(0, 2.1, 4.2) + wash * 5.0 + fresnel * 2.0);
      color *= .65 + wash * .2;
      color += sheen * strength * (.018 + fresnel * .14) + vec3(reflection * .45 + ribbon * .025);
    }
  }
  color = mix(color, vec3(.03, .42, 1.0), contour * river_info.appearance.z * .55);
  // Keep helper fragments alive through the Realistic surface derivatives.
  if (alpha < .002) discard;
  frag_color = vec4(color * alpha, alpha);
}
