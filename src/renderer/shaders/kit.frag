#version 330 core

in vec2 v_local;
in vec2 v_uv;
in vec2 v_pixel;
flat in vec4 v_clip;
flat in vec2 v_half;
flat in vec4 v_fill;
flat in vec4 v_border;
flat in vec2 v_params;
flat in vec2 v_arc;
flat in uint v_kind;

uniform sampler2D u_atlas_gray; // coverage in alpha (swizzled R8)

out vec4 frag_color;

// Signed distance to a box of half size b with corner radius r: negative inside.
float roundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  // Outside the clipping box this instance sits in.
  if (v_pixel.x < v_clip.x || v_pixel.y < v_clip.y || v_pixel.x >= v_clip.z || v_pixel.y >= v_clip.w) discard;

  if (v_kind == 1u) {
    float coverage = texture(u_atlas_gray, v_uv).a;
    if (coverage < 0.004) discard;
    frag_color = vec4(v_fill.rgb, v_fill.a * coverage);
    return;
  }

  // A ring segment. 0 is the top and the sweep runs clockwise, which is
  // atan’s direction in this y-down pixel space after a quarter turn.
  if (v_kind == 2u) {
    const float TAU = 6.28318530718;
    float outer = max(v_params.x, 0.0);
    float thick = abs(v_params.y);
    float inner = max(outer - thick, 0.0);
    float d = length(v_local);
    float ring = max(inner - d, d - outer);
    // Coverage is zero past half a pixel, and a round cap stays inside
    // the outer radius, so this pixel cannot be ink.
    if (ring > 0.5) discard;

    float ang = mod(atan(v_local.y, v_local.x) + 1.57079632679, TAU);
    float start = mod(v_arc.x, TAU);
    float sweep = clamp(v_arc.y, 0.0, TAU);
    float cw = mod(ang - start, TAU);
    float ccw = mod(start - ang, TAU);
    float wedge = cw <= sweep ? -min(cw, sweep - cw) : min(cw - sweep, ccw);
    float dist = max(ring, wedge * max(d, 1.0));

    // Round caps are discs on the centerline at each end. A full turn
    // already covers them.
    if (v_params.y < 0.0 && sweep < TAU) {
      float cl = max(outer - thick * 0.5, 0.0);
      float half_t = thick * 0.5;
      vec2 cap_a = vec2(sin(start), -cos(start)) * cl;
      vec2 cap_b = vec2(sin(start + sweep), -cos(start + sweep)) * cl;
      dist = min(dist, min(length(v_local - cap_a), length(v_local - cap_b)) - half_t);
    }

    float shape = clamp(0.5 - dist, 0.0, 1.0);
    if (v_fill.a * shape < 0.004) discard;
    frag_color = vec4(v_fill.rgb, v_fill.a * shape);
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
