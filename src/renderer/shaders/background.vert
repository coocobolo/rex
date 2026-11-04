#version 330 core

layout(location = 0) in vec2 a_quad;
layout(location = 1) in uvec2 a_cell; // col, row (u16)
layout(location = 2) in uint a_span;  // span (u16)
layout(location = 3) in vec4 a_bg;    // r,g,b,a normalized (GL_UNSIGNED_BYTE + normalized)

uniform vec2 u_cell_size;
uniform vec2 u_screen_size;

flat out vec4 v_bg;

void main() {
  vec2 cell_tl = vec2(a_cell) * u_cell_size;
  vec2 span_size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y);
  vec2 pixel = cell_tl + a_quad * span_size;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

  v_bg = a_bg;
}
