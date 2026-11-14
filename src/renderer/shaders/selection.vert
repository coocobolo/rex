#version 330 core

layout(location = 0) in vec2 a_quad;
layout(location = 1) in uvec2 a_cell; // (col, row), per instance
layout(location = 2) in uint a_span;  // width in columns, per instance
layout(location = 3) in uint a_flags;
layout(location = 4) in uvec2 a_prev; // (prev_col, prev_span)
layout(location = 5) in uvec2 a_next; // (next_col, next_span)

uniform vec2 u_cell_size;
uniform vec2 u_screen_size;
uniform float u_border_width;
uniform float u_radius;
uniform uint u_border_style;

out vec2 v_pixel;
flat out vec2 v_size;
flat out uint v_flags;
flat out vec2 v_prev_span; // (left, right) in local pixel space
flat out vec2 v_next_span; // (left, right) in local pixel space

const uint BORDER_STYLE_UNIFIED = 1u;

void main() {
  vec2 size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y);
  vec2 cell_tl = vec2(a_cell) * u_cell_size;

  float col_f = float(a_cell.x);
  float u = u_cell_size.x;

  float prev_left = (float(a_prev.x) - col_f) * u;
  float prev_right = (float(a_prev.x + a_prev.y) - col_f) * u;
  vec2 prev_span = vec2(min(prev_left, prev_right), max(prev_left, prev_right));

  float next_left = (float(a_next.x) - col_f) * u;
  float next_right = (float(a_next.x + a_next.y) - col_f) * u;
  vec2 next_span = vec2(min(next_left, next_right), max(next_left, next_right));

  bool is_first = (a_flags & 1u) != 0u;
  bool is_last = (a_flags & 2u) != 0u;

  float pad_left = 0.0;
  float pad_right = 0.0;
  if (u_border_style == BORDER_STYLE_UNIFIED && u_radius > 0.0) {
    float max_pad = min(u_radius * 0.5, size.y * 0.5);
    bool conc_left = (!is_first && prev_span.x < 0.0 && prev_span.y > 0.0) ||
                     (!is_last && next_span.x < 0.0 && next_span.y > 0.0);
    bool conc_right =
        (!is_first && prev_span.y > size.x && prev_span.x < size.x) ||
        (!is_last && next_span.y > size.x && next_span.x < size.x);
    if (conc_left) pad_left = max_pad;
    if (conc_right) pad_right = max_pad;
  }

  vec2 local_pixel =
      vec2(mix(-pad_left, size.x + pad_right, a_quad.x), a_quad.y * size.y);
  vec2 pixel = cell_tl + local_pixel;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
  v_pixel = local_pixel;
  v_size = size;
  v_flags = a_flags;
  v_prev_span = prev_span;
  v_next_span = next_span;
}

// void main() {
//   bool is_first = (a_flags & 1u) != 0u;
//   bool is_last = (a_flags & 2u) != 0u;
//
//   float ext = (u_connected != 0) ? u_border_width : 0.0;
//   float y_offset = is_first ? 0.0 : -ext; // extend top for non-first rows
//   // top extension
//   // bottom extension
//   float h_extra = (is_first ? 0.0 : ext) + (is_last ? 0.0 : ext);
//
//   // vec2 size = vec2(u_cell_size.x, u_cell_size.y + h_extra);
//   // vec2 size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y +
//   h_extra);
//   // vec2 cell_tl = vec2(a_cell) * u_cell_size + vec2(0.0, y_offset);
//   vec2 size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y + h_extra);
//   vec2 cell_tl = vec2(a_cell) * u_cell_size + vec2(0.0, y_offset);
//   vec2 pixel = cell_tl + a_quad * size;
//   vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
//   gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
//   v_uv = a_quad;
//   v_size = size;
//   v_flags = a_flags;
// }