#version 330 core

// One instance of the UI kit: a rounded box or a glyph, in the order the
// kit's node array is drawn (KitPainter.zig).
layout(location = 0) in vec4 a_rect;   // x, y, width, height in pixels
layout(location = 1) in vec4 a_fill;   // box fill or glyph color, straight alpha
layout(location = 2) in vec4 a_border; // box border color
layout(location = 3) in vec2 a_params; // box: radius, border width; glyph: atlas x, y
layout(location = 4) in uint a_kind;   // 0 = box, 1 = glyph

uniform vec2 u_fb;    // framebuffer size in pixels
uniform vec2 u_atlas; // atlas texture size in pixels

out vec2 v_local;           // pixels from the box centre
out vec2 v_uv;              // glyph texture coordinate
flat out vec2 v_half;       // half the box size
flat out vec4 v_fill;
flat out vec4 v_border;
flat out vec2 v_params;
flat out uint v_kind;

void main() {
  // Corners from the vertex id: 0 top left, 1 top right, 2 bottom left, 3 bottom right.
  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
  // A box grows by one pixel so the antialiased edge is not cut off.
  float pad = a_kind == 0u ? 1.0 : 0.0;
  vec2 size = a_rect.zw + vec2(pad * 2.0);
  vec2 position = a_rect.xy - vec2(pad) + corner * size;

  v_local = (corner - 0.5) * size;
  v_uv = (a_params + corner * a_rect.zw) / u_atlas;
  v_half = a_rect.zw * 0.5;
  v_fill = a_fill;
  v_border = a_border;
  v_params = a_params;
  v_kind = a_kind;

  vec2 ndc = position / u_fb * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
