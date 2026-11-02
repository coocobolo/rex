#version 330 core


layout(location = 0) in uvec2 a_cell; // (col, row), selection vertex

uniform vec2 u_cell_size;
uniform vec2 u_screen_size;

void main() {
  vec2 pixel = vec2(a_cell) + u_cell_size;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}