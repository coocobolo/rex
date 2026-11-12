#version 330 core

in vec2 v_local;
in vec2 v_uv;
flat in vec2 v_half;
flat in vec4 v_fill;
flat in vec4 v_border;
flat in vec2 v_params;
flat in uint v_kind;

uniform sampler2D u_atlas_gray; // coverage in alpha (swizzled R8)

out vec4 frag_color;

// Signed distance to a box of half size b with corner radius r: negative inside.
float roundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  if (v_kind == 1u) {
    float coverage = texture(u_atlas_gray, v_uv).a;
    if (coverage < 0.004) discard;
    frag_color = vec4(v_fill.rgb, v_fill.a * coverage);
    return;
  }

  float radius = min(v_params.x, min(v_half.x, v_half.y));
  float distance = roundedBox(v_local, v_half, radius);
  float shape = clamp(0.5 - distance, 0.0, 1.0);

  // The border is the band of v_params.y pixels inside the edge, drawn
  // over the fill (it may be translucent, such as white at 10%).
  float inside_border = v_params.y > 0.0 ? clamp(0.5 - (distance + v_params.y), 0.0, 1.0) : 1.0;
  float border = (1.0 - inside_border) * v_border.a;
  float alpha = border + v_fill.a * (1.0 - border);
  if (alpha * shape < 0.004) discard;
  vec3 color = (v_border.rgb * border + v_fill.rgb * v_fill.a * (1.0 - border)) / alpha;
  frag_color = vec4(color, alpha * shape);
}
