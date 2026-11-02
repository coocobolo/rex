#version 330 core  
  
layout(location = 0) in vec2  a_quad;  
layout(location = 1) in uvec2 a_cell;       // col, row  
layout(location = 2) in uvec2 a_atlas_pos;  // atlas_x, atlas_y  
layout(location = 3) in uvec2 a_glyph_size; // glyph_w, glyph_h  
layout(location = 4) in ivec2 a_bearing;    // bearing_x, bearing_y  
layout(location = 5) in vec4  a_fg;         // fg_r/g/b/a normalized (GL_UNSIGNED_BYTE + normalized)  
layout(location = 6) in uint  a_flags;  
  
uniform vec2  u_cell_size;
uniform vec2  u_screen_size;
uniform vec2  u_atlas_size;
uniform float u_ascender; // pixels from cell top to baseline
  
out vec2 v_uv;  
flat out vec4 v_fg;  
flat out uint v_flags;  
  
void main() {  
    vec2 cell_tl = vec2(a_cell) * u_cell_size;  
  
    // bearing_x: pixels right of pen to left edge of bitmap  
    // bearing_y: pixels above baseline to top of bitmap (FreeType convention)  
    // In screen space (Y-down): vertical offset = ascender - bearing_y  
    vec2 bearing_offset = vec2(float(a_bearing.x), u_ascender - float(a_bearing.y));
    vec2 pixel = cell_tl + bearing_offset + a_quad * vec2(a_glyph_size);  
  
    vec2 ndc = (pixel / u_screen_size) * 2.0 - 1.0;  
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);  
  
    vec2 uv_origin = vec2(a_atlas_pos)  / u_atlas_size;  
    vec2 uv_size   = vec2(a_glyph_size) / u_atlas_size;  
    v_uv    = uv_origin + a_quad * uv_size;  
  
    v_fg    = a_fg;  
    v_flags = a_flags;  
}