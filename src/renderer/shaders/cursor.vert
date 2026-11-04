#version 330 core

layout(location = 0) in vec2 a_quad;

uniform uvec2 u_cell_pos;       // (col, row) in grid units
uniform vec2 u_cell_size;       // (cell_w, cell_h) in pixels
uniform vec2 u_screen_size;     // framebuffer (w, h) in pixels
uniform int u_shape;            // 0=block, 1=underline, 2=beam
uniform float u_underline_frac; // underline height, fraction of the cell height
uniform float u_bar_frac;       // bar width, fraction of the cell width
uniform float u_bar_offset_y;   // underline bottom, fraction of the cell height

out vec2 v_uv;
flat out vec2 v_size; // actual pixel size of this cursor quad

const int SHAPE_BLOCK = 0;
const int SHAPE_UNDERLINE = 1;
const int SHAPE_BEAM = 2;

void main() {
  vec2 cell_tl = vec2(u_cell_pos) * u_cell_size;

  // Adjust quad size and offset based on cursor shape
  vec2 size = u_cell_size;
  vec2 offset = vec2(0.0);

  if (u_shape == SHAPE_UNDERLINE) {
    size.y = u_cell_size.y * u_underline_frac;
    offset.y = u_cell_size.y * (u_bar_offset_y - u_underline_frac);
  } else if (u_shape == SHAPE_BEAM) {
    size.x = u_cell_size.x * u_bar_frac;
  }

  // u_shape == 0 (block): full cell, no adjustment
  vec2 pixel = cell_tl + offset + a_quad * size;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

  v_uv = a_quad;
  v_size = size;
}
