#version 330 core

layout(location = 0) in vec2 a_quad;
layout(location = 1) in uvec2 a_cell;
layout(location = 2) in uvec4 a_atlas;   // padding only, unused here, keeps stride correct
layout(location = 3) in ivec2 a_bearing; // padding only, unused here, keeps stride correct
layout(location = 4) in uint a_fg;
layout(location = 5) in uint a_bg;
layout(location = 6) in uint a_flags;
layout(location = 7) in uint a_cell_span;

uniform vec2 u_cell_size;
uniform vec2 u_screen_size;

out vec2 v_quad_uv;
flat out vec4 v_fg;
flat out vec4 v_bg;
flat out uint v_flags;

vec4 unpackColor(uint c) {
   return vec4(float((c >> 24) & 0xFFu) / 255.0, 
         float((c >> 16) & 0xFFu) / 255.0,
         float((c >> 8) & 0xFFu) / 255.0,
         float((c) & 0xFFu) / 255.0     
         );
}

void main() {
  // Always full-cell quad — bg pass covers the entire cell.
  vec2 cell_tl = vec2(a_cell) * u_cell_size;  
  // Scale only the X dimension by cell_span:
  vec2 span_size = vec2(float(a_cell_span) * u_cell_size.x, u_cell_size.y);  
  vec2 pixel = cell_tl + a_quad * span_size;  
  // vec2 pixel = cell_tl + a_quad * u_cell_size;  

  vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;  
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);  

  v_quad_uv = a_quad;
  v_fg = unpackColor(a_fg);
  v_bg = unpackColor(a_bg);
  v_flags = a_flags;
}