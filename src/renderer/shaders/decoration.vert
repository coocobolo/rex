#version 330 core

layout(location = 0) in vec2 a_quad;
layout(location = 1) in uvec2 a_cell;         // col, row of the first cell of the run
layout(location = 2) in uint a_span;          // columns the run covers
layout(location = 3) in vec4 a_underline;     // rgba, alpha already dimmed
layout(location = 4) in vec4 a_strikethrough; // rgba
layout(location = 5) in vec4 a_overline;      // rgba
layout(location = 6) in uint a_flags;         // Flags packed byte

uniform vec2 u_cell_size;
uniform vec2 u_screen_size;

// Pixel inside the run, from its top left corner
out vec2 v_pixel;
// Left edge of the run, in pixels from the left of the window
flat out float v_run_x;
flat out vec4 v_underline;
flat out vec4 v_strikethrough;
flat out vec4 v_overline;
flat out uint v_flags;

void main() {
  vec2 cell_tl = vec2(a_cell) * u_cell_size;
  vec2 span_size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y);
  vec2 pixel = cell_tl + a_quad * span_size;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

  v_pixel = a_quad * span_size;
  v_run_x = cell_tl.x;
  v_underline = a_underline;
  v_strikethrough = a_strikethrough;
  v_overline = a_overline;
  v_flags = a_flags;
}
