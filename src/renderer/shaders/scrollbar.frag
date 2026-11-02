#version 330 core

uniform vec4 u_color;
uniform vec2 u_size;    // rect width, height (for SDF)
uniform float u_radius; // corner radius

in vec2 v_local;
out vec4 frag_color;

// Signed distance to a rounded rectangle centered at origin
float sdRoundRect(vec2 p, vec2 half_size, float r) {
  vec2 q = abs(p) - half_size + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  vec2 half_size = u_size * 0.5;
  vec2 p = v_local - half_size;
  float d = sdRoundRect(p, half_size, u_radius);
  float alpha = 1.0 - smoothstep(-0.5, 0.5, d);
  frag_color = vec4(u_color.rgb, u_color.a * alpha);
}