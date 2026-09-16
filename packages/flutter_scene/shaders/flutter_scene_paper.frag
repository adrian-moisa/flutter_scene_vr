uniform PaperInfo {
  vec4 viewport;
  vec4 style;
  vec4 appearance;
  vec4 shadow;
  vec4 geometry;
} paper_info;
uniform sampler2D paper_texture;
uniform sampler2D paper_shadow_texture;
in vec2 v_paper_uv;
in float v_paper_lift;
in vec3 v_paper_normal;
out vec4 frag_color;
vec3 linearColor(vec3 c) { return mix(c / 12.92, pow((c + .055) / 1.055, vec3(2.4)), step(.04045,c)); }
void main() {
  if (paper_info.appearance.y > 2.5) {
    if(paper_info.shadow.z < .5) discard;
    float raised=smoothstep(0.0,4.0,v_paper_lift);
    float angle=paper_info.shadow.y-paper_info.style.y;
    vec2 pixel=1.0/(paper_info.viewport.zw*280.0);
    vec2 offset=vec2(cos(angle),-sin(angle))*(.65+v_paper_lift*.85)*pixel;
    vec2 coverage=texture(paper_shadow_texture,v_paper_uv-offset).rg;
    float alpha=mix(coverage.r,coverage.g,raised)*paper_info.shadow.x*paper_info.appearance.x;
    // Clear coverage directly beneath the attached contact even when distant
    // depth precision cannot resolve the tiny sheet/receiver separation.
    float contact=1.0-smoothstep(0.0,.15,v_paper_lift);
    alpha*=1.0-texture(paper_texture,v_paper_uv).a*contact;
    if(alpha<.003)discard;
    frag_color=vec4(linearColor(vec3(.15,.19,.23))*alpha,alpha);
    return;
  }
  vec4 paper = texture(paper_texture, v_paper_uv);
  float alpha = paper.a * paper_info.appearance.x;
  if (paper_info.appearance.z > .0) {
    vec2 d = 2.0 / (paper_info.viewport.zw * 280.0);
    float around = max(max(texture(paper_texture,v_paper_uv+vec2(d.x,0)).a,texture(paper_texture,v_paper_uv-vec2(d.x,0)).a),max(texture(paper_texture,v_paper_uv+vec2(0,d.y)).a,texture(paper_texture,v_paper_uv-vec2(0,d.y)).a));
    float line = smoothstep(.55,.95,around) * (1.0 - smoothstep(.3,.95,paper.a));
    paper.rgb = mix(paper.rgb, vec3(.05,.5,1.0), line * paper_info.appearance.z);
    alpha = max(alpha,line * paper_info.appearance.x);
  }
  if (alpha < .003) discard;
  if (paper_info.appearance.y < .5 && alpha < .995) discard;
  if (paper_info.appearance.y > .5 && paper_info.appearance.y < 1.5 && alpha >= .995) discard;
  // Subtle normal shading makes the actual lifted edge legible without turning
  // a white piece of paper into a strongly lit, glossy 3D prop.
  vec3 n=normalize(v_paper_normal);
  float shade=clamp(1.0+n.y*.35-n.x*.2,.965,1.015);
  frag_color = vec4(linearColor(paper.rgb)*shade*alpha, alpha);
}
