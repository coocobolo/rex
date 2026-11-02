#version 330 core

in vec2 v_uv;
flat in vec2 v_size;

uniform vec4 u_cursor_color;
uniform float u_radius; // corner radius in pixels, e.g. 3.0
uniform float u_hollow;

out vec4 frag_color;

// Standard rounded-rectangle SDF.
// Returns < 0 inside, 0 on edge, > 0 outside.
float roundedBox(vec2 uv, vec2 size, float r) {
  vec2 pixel = uv * size;
  vec2 half = size * 0.5;
  vec2 q = abs(pixel - half) - (half - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  // Only round the block cursor; underline/bar are too thin to benefit.
  // float r = (u_shape == 0) ? u_radius : 0.0;

  // Clamp radius to half the smallest dimension — works for all shapes.
  // Block: min(cell_w, cell_h)/2 — large enough for u_radius = 4.6
  // Underline: min(cell_w, cell_h*0.12)/2 — small but non-zero, rounds the ends
  // Bar: min(cell_w*0.12, cell_h)/2 — same
  float r = min(u_radius, min(v_size.x, v_size.y) * 0.5);
  float d = roundedBox(v_uv, v_size, r);

  // Anti-aliased shape boundary: 1 inside, 0 outside
  float edge = 1.0 - smoothstep(-0.5, 0.5, d);

  // Hollow suppression: 0 deep inside, 1 near edge
  float safe_hollow = min(u_hollow, min(v_size.x, v_size.y) * 0.4);
  float fill = (safe_hollow > 0.0)
                   ? smoothstep(safe_hollow, safe_hollow - 1.0, -d)
                   : 1.0; // filled: keep all interior

  float alpha = edge * fill * u_cursor_color.a;

  if (alpha < 0.01) discard;
  frag_color = vec4(u_cursor_color.rgb, alpha);
}