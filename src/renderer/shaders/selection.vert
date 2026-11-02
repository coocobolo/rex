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

out vec2 v_uv;
flat out vec2 v_size;
flat out uint v_flags;
flat out vec2 v_prev_overlap; // (left, right) in local pixel space
flat out vec2 v_next_overlap; // (left, right) in local pixel space

void main() {
  vec2 size = vec2(float(a_span) * u_cell_size.x, u_cell_size.y);
  vec2 cell_tl = vec2(a_cell) * u_cell_size;
  vec2 pixel = cell_tl + a_quad * size;
  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
  v_uv = a_quad;
  v_size = size;
  v_flags = a_flags;

  // // Overlap with previous row in local x-space (relative to this quad's left edge)
  // float col_f = float(a_cell.x);
  // float prev_left = (float(a_prev.x) - col_f) * u_cell_size.x;
  // float prev_right = (float(a_prev.x + a_prev.y) - col_f) * u_cell_size.x;
  // v_prev_overlap = vec2(clamp(prev_left, 0.0, size.x), clamp(prev_right, 0.0, size.x));

  // Overlap with next row
  // float next_left = (float(a_next.x) - col_f) * u_cell_size.x;
  // float next_right = (float(a_next.x + a_next.y) - col_f) * u_cell_size.x;
  // v_next_overlap = vec2(clamp(next_left, 0.0, size.x), clamp(next_right, 0.0, size.x));

  float col_f = float(a_cell.x);
  float u = u_cell_size.x;

  float prev_left  = (float(a_prev.x) - col_f) * u;
  float prev_right = (float(a_prev.x + a_prev.y) - col_f) * u;

  float l = min(prev_left, prev_right);
  float r = max(prev_left, prev_right);
  v_prev_overlap = vec2(clamp(l, 0.0, size.x), clamp(r, 0.0, size.x));

  float next_left  = (float(a_next.x) - col_f) * u;
  float next_right = (float(a_next.x + a_next.y) - col_f) * u;

  l = min(next_left, next_right);
  r = max(next_left, next_right);
  v_next_overlap = vec2(clamp(l, 0.0, size.x), clamp(r, 0.0, size.x));
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