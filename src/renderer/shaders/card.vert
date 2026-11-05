#version 330 core

layout(location = 0) in uvec4 a_grid_rect;   // col, row, width, height in cells
layout(location = 1) in vec2 a_offset;       // sub-pixel offset (x, y) in pixels
layout(location = 2) in vec4 a_bg_color;     // rgba background fill color (0..1)
layout(location = 3) in vec4 a_border_color; // rgba border color (0..1)
layout(location = 4) in vec2 a_params;       // x = corner radius, y = border width in pixels

uniform vec2 u_fb;        // framebuffer width, height in pixels
uniform vec2 u_cell_size; // cell width, height in pixels

out vec2 v_local;              // local pixel coordinates centered at (0, 0)
flat out vec2 v_half_size;     // half width, half height of card in pixels
flat out vec4 v_bg_color;      // background fill color
flat out vec4 v_border_color;  // border stroke color
flat out vec2 v_params;        // radius, border_width

// Expand the quad by PAD pixels in all 4 directions so anti-aliasing around
// the outer border is never clipped by the triangle boundary.
const float PAD = 2.0;

void main() {
  vec2 pos_px = vec2(a_grid_rect.xy) * u_cell_size + a_offset;
  vec2 size_px = vec2(a_grid_rect.zw) * u_cell_size;

  // Reconstruct quad corners from vertex ID (0=TL, 1=TR, 2=BL, 3=BR)
  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
  vec2 expanded_pos = pos_px - vec2(PAD) + corner * (size_px + vec2(PAD * 2.0));

  v_half_size = size_px * 0.5;
  v_local = (corner - 0.5) * (size_px + vec2(PAD * 2.0));
  v_bg_color = a_bg_color;
  v_border_color = a_border_color;
  v_params = a_params;

  // Convert pixel coords to NDC (-1 to 1) and flip Y (OpenGL Y up, pixel Y down)
  vec2 ndc = (expanded_pos / u_fb) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
}
