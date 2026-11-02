#version 330 core

layout(location = 0) in vec2 a_quad;
layout(location = 1) in uvec2 a_cell; // col, row
layout(location = 2) in uvec4 a_atlas; // atlas_x, atlas_y, atlas_w, atlas_h
layout(location = 3) in ivec2 a_bearing; // bearing_x, bearing_y (FreeType pixels)
layout(location = 4) in uint a_fg;
layout(location = 5) in uint a_bg;
layout(location = 6) in uint a_flags;
layout(location = 7) in uint a_cell_span;

uniform mat4 u_proj;  
uniform vec2 u_cell_size;
uniform vec2 u_screen_size;
uniform vec2 u_atlas_size;
uniform float u_ascender;  // pixels from cell top to baseline

out vec2 v_uv;
flat out vec4 v_fg;
flat out vec4 v_bg;
flat out uint v_flags;

vec4 unpackColor(uint c) {
  return vec4(float((c >> 24) & 0xFFu) / 255.0,
              float((c >> 16) & 0xFFu) / 255.0, float((c >> 8) & 0xFFu) / 255.0,
              float((c) & 0xFFu) / 255.0);
}

void main() {
  vec2 cell_tl = vec2(a_cell) * u_cell_size;
  // bearing_x: pixels right of pen to left edge of bitmap  
  // bearing_y: pixels above baseline to top of bitmap (FreeType convention)  
  // In screen space (Y down): vertical offset = ascender - bearing_y  
  vec2 bearing_offset = vec2(float(a_bearing.x), u_ascender - float(a_bearing.y));
  vec2 pixel = cell_tl + bearing_offset + a_quad * vec2(a_atlas.zw);

  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

  vec2 uv_origin = vec2(a_atlas.xy) / u_atlas_size;
  vec2 uv_size = vec2(a_atlas.zw) / u_atlas_size;
  v_uv = uv_origin + a_quad * uv_size;

  v_fg = unpackColor(a_fg);
  v_bg = unpackColor(a_bg);
  v_flags = a_flags;
}