#version 330 core

in vec2 v_uv; // atlas UV (interpolated)
flat in vec4 v_fg;
flat in vec4 v_bg;
flat in uint v_flags;

// Uniforms
uniform sampler2D u_atlas;
uniform int u_cursor_style; // CursorStyle enum value (0–5)  
uniform vec3 u_cursor_color; // (default white)
uniform int u_cursor_blink_on;
uniform float u_bg_alpha;

out vec4 frag_color;

// Flag bits (must match Instance.Flags packed struct bit order)
const uint FLAG_UNDERLINE = 1u;     // bit 0
const uint FLAG_BOLD = 2u;          // bit 1
const uint FLAG_ITALIC = 4u;        // bit 2
const uint FLAG_STRIKETHROUGH = 8u; // bit 3
const uint FLAG_CURSOR = 16u;       // bit 4
const uint FLAG_REVERSE = 32u;      // bit 5
const uint FLAG_BLINK = 64u;        // bit 6

// Cursor style constants (must match CursorStyle enum order)
const int CURSOR_BLINKING_BLOCK = 0;
const int CURSOR_STEADY_BLOCK = 1;
const int CURSOR_BLINKING_UNDERLINE = 2;
const int CURSOR_STEADY_UNDERLINE = 3;
const int CURSOR_BLINKING_BAR = 4;
const int CURSOR_STEADY_BAR = 5;

void main() {
   float alpha = texture(u_atlas, v_uv).r;

   // Discard fully transparent pixels — bg pass color shows through.  
   if (alpha < 0.05) discard;

   vec4 fg = v_fg;
   vec4 bg = v_bg;

   // Reverse video (SGR 7)
   if ((v_flags & FLAG_REVERSE) != 0u) {
      fg = v_bg;
      bg = v_fg;
   }

   if ((v_flags & FLAG_CURSOR) != 0u) {
      bool is_block = (u_cursor_style == CURSOR_BLINKING_BLOCK || u_cursor_style == CURSOR_STEADY_BLOCK);  
      bool blink_off = (u_cursor_blink_on == 0) && (  
            u_cursor_style == CURSOR_BLINKING_BLOCK ||  
            u_cursor_style == CURSOR_BLINKING_BAR   ||  
            u_cursor_style == CURSOR_BLINKING_UNDERLINE  
            );  

      // Debug: paint cursor cell red when blink on, green when blink-off
      // frag_color = blink_off ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);  
      // return;

      if (!blink_off) {  
         if (is_block) {  
            // Cursor on: glyph drawn in bg color so it's visible inside cursor block  
            frag_color = mix(vec4(u_cursor_color, 1.0), bg, alpha);  
         } else {  
            // Bar/underline cursor on: glyph drawn normally  
            frag_color = mix(bg, fg, alpha);  
         }  
         return;  
      }  

      // blink_off: fall through to normal glyph rendering below  
   }


   // Normal glyph rendering (also used for blink-off cursor cells)
   frag_color = vec4(  
         mix(bg.rgb, fg.rgb, alpha),  
         mix(u_bg_alpha, 1.0, alpha)
   );
}