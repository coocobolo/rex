#version 330 core

flat in vec4 v_fg;
flat in vec4 v_bg;
flat in uint v_flags;
in vec2 v_quad_uv;

uniform vec2 u_cell_size;
uniform vec3 u_cursor_color;
uniform int u_cursor_style;
uniform int u_cursor_blink_on;
uniform float u_bg_alpha;

out vec4 frag_color;

const uint FLAG_UNDERLINE = 1u;
const uint FLAG_BOLD = 2u;
const uint FLAG_ITALIC = 4u;
const uint FLAG_STRIKETHROUGH = 8u;
const uint FLAG_CURSOR = 16u;
const uint FLAG_REVERSE = 32u;
const uint FLAG_BLINK = 64u;

const int CURSOR_BLINKING_BLOCK = 0;
const int CURSOR_STEADY_BLOCK = 1;
const int CURSOR_BLINKING_UNDERLINE = 2;
const int CURSOR_STEADY_UNDERLINE = 3;
const int CURSOR_BLINKING_BAR = 4;
const int CURSOR_STEADY_BAR = 5;

float roundedBox(vec2 uv, vec2 cell_size, float radius_px) {
   vec2 pixel = uv * cell_size; // [0,1] → pixel coords within cell  
   vec2 half = cell_size * 0.5;
   vec2 q = abs(pixel - half) - (half - radius_px);
   return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius_px;
}

void main() {
   vec4 fg = v_fg;
   vec4 bg = v_bg;

   // Reverse video (SGR 7 / DECSCNM mode 5)
   if ((v_flags & FLAG_REVERSE) != 0u) {
      fg = v_bg;
      bg = v_fg;
   }

   // Cursor
   if ((v_flags & FLAG_CURSOR) != 0u) {
      bool is_block = (u_cursor_style == CURSOR_BLINKING_BLOCK || u_cursor_style == CURSOR_STEADY_BLOCK);

      bool blink_off = (u_cursor_blink_on == 0) &&
         (u_cursor_style == CURSOR_BLINKING_BLOCK ||
          u_cursor_style == CURSOR_BLINKING_BAR ||
          u_cursor_style == CURSOR_BLINKING_UNDERLINE);

      if (blink_off) {

         // Cursor is in blink-off phase, skip cursor rendering,
         // fall through to normal cell
      }else {
         if (u_cursor_style == CURSOR_BLINKING_BLOCK || u_cursor_style == CURSOR_STEADY_BLOCK) {
            float radius = 4.6; // pixels - tune this for the cursor shape block redius value
            float dist = roundedBox(v_quad_uv, u_cell_size, radius);
            float alpha = 1.0 - smoothstep(-0.5, 0.5, dist);

            if (alpha < 0.05) discard;

            vec4 cursor_col = vec4(u_cursor_color, 1.0);
            frag_color = mix(bg, cursor_col, alpha);
            return;
         } else if (u_cursor_style == CURSOR_BLINKING_UNDERLINE || u_cursor_style == CURSOR_STEADY_UNDERLINE) {
            // frag_color = (!blink_off && v_quad_uv.y > 0.88) ?
            // vec4(u_cursor_color, 1.0) : bg;
            frag_color = (v_quad_uv.y > 0.88) ? vec4(u_cursor_color, 1.0) : bg;
            return;
         } else {
            // frag_color = (!blink_off && v_quad_uv.x < 0.12) ?
            // vec4(u_cursor_color, 1.0) : bg;
            frag_color = (v_quad_uv.x < 0.12) ? vec4(u_cursor_color, 1.0) : bg;
            return;
         }
      }
   }

   // Non-cursor: base background
   frag_color = vec4(bg.rgb, bg.a * u_bg_alpha);

   // Underline decoration (SGR 4): solid line at bottom 12% of cell
   if ((v_flags & FLAG_UNDERLINE) != 0u && v_quad_uv.y > 0.88) {
      frag_color = fg;
   }

   // Strikethrough decoration (SGR 9): solid line at 44–56% of cell height  
   if ((v_flags & FLAG_STRIKETHROUGH) != 0u && v_quad_uv.y > 0.44 && v_quad_uv.y < 0.56) {
      frag_color = fg;
   }
}