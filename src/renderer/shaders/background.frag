#version 330 core

in vec2 v_quad_uv;
flat in vec4 v_bg;
flat in vec4 v_fg;
flat in uint v_flags;

uniform vec2 u_cell_size;
uniform float u_bg_alpha;
uniform int u_blink_on;
uniform int u_blink_rapid_on;
// uniform float u_line_thickness; // pixels, from font metrics (typically 1–2px)

out vec4 frag_color;

// Flag bits same layout as cell.frag
const uint FLAG_STRIKETHROUGH = 1u;
const uint FLAG_BLINK         = 2u;
const uint FLAG_OVERLINE      = 4u;
const uint FLAG_BLINK_RAPID   = 8u;

const uint UNDERLINE_MASK  = 0x70u; // bits 4-6
const uint UNDERLINE_SHIFT = 4u;

// UnderlineStyle values (must match UnderlineStyle enum)
const uint UL_NONE   = 0u;
const uint UL_SINGLE = 1u;
const uint UL_DOUBLE = 2u;
const uint UL_CURLY  = 3u;
const uint UL_DOTTED = 4u;
const uint UL_DASHED = 5u;

void main() {
  frag_color = vec4(v_bg.rgb, v_bg.a * u_bg_alpha);

  // Decorations are hidden when the cell is blink-off
  bool blink_off =
      ((v_flags & FLAG_BLINK) != 0u && u_blink_on == 0) ||
      ((v_flags & FLAG_BLINK_RAPID) != 0u && u_blink_rapid_on == 0);

  if (blink_off) return;

  vec2 pixel = v_quad_uv * u_cell_size;
  float cw = u_cell_size.x;
  float ch = u_cell_size.y;

  float strike_center = ch * 0.5;
  float t = max(1.0, round(u_cell_size.y / 16.0));
  // float t = u_line_thickness;

  // line thickness stays at 1px regardless of cell size, curly wave
  // amplitude/period are in pixels, and dotted/dashed periods are pixel-based
  // for consistent visual spacing.

  // Overline: 1px band at the top of the cell
  if ((v_flags & FLAG_OVERLINE) != 0u && pixel.y < t) {
    frag_color = vec4(v_fg.rgb, 1.0);
    return;
  }

  // Strikethrough: 1px band at 50% cell height
  float half_t = t * 0.5;
  if ((v_flags & FLAG_STRIKETHROUGH) != 0u && pixel.y >= strike_center - half_t &&
      pixel.y < strike_center + half_t) {
    frag_color = vec4(v_fg.rgb, 1.0);
    return;
  }

  // Underline styles
  uint ul_style = (v_flags & UNDERLINE_MASK) >> UNDERLINE_SHIFT;
  if (ul_style == UL_NONE)
    return;

  float x = pixel.x;
  float y = pixel.y;

  // Underline baseline: 2px from the bottom of the cell
  float ul_y = ch - 2.0;

  switch (ul_style) {
  case UL_SINGLE:
    // 1px line at ul_y
    if (y >= ul_y && y < ul_y + t) {
      frag_color = vec4(v_fg.rgb, 1.0);
    }
    break;

  case UL_DOUBLE:
    // Two 1px lines separated by 1px gap
    if ((y >= ul_y - t * 2.0 && y < ul_y - t) || (y >= ul_y && y < ul_y + t)) {
      frag_color = vec4(v_fg.rgb, 1.0);
    }
    break;

  case UL_CURLY: {  
    float amplitude = t + 0.5;  
    float center = ul_y - amplitude; // shift center up so bottom peak = ul_y  
    float wave = sin((x / cw) * 3.14159 * 2.0) * amplitude;  
    float dist = abs(y - center - wave);  
    float alpha = 1.0 - smoothstep(t * 0.5, t * 0.75, dist);  
    frag_color = mix(frag_color, vec4(v_fg.rgb, 1.0), alpha);  
    break;  
  }

  // case UL_CURLY: {
  //   // Sine wave centered at ul_y, amplitude ±1.5px, 2 full cycles across cell width
  //   float wave = sin((x / cw) * 3.14159 * 4.0) * (t + 0.5);
  //   if (abs(y - ul_y - wave) < t * 0.75) {
  //     frag_color = vec4(v_fg.rgb, 1.0);
  //   }
  //   break;
  // }

  case UL_DOTTED:
    // 1px dots: 2px on, 2px off (4px period)
    if (y >= ul_y && y < ul_y + t && mod(x, t * 4.0) < t * 2.0) {  
       frag_color = vec4(v_fg.rgb, 1.0);  
    }  
    break;

  case UL_DASHED:
    // 1px dashes: 50% on per 8px segment
    if (y >= ul_y && y < ul_y + t && mod(x, t * 8.0) < t * 4.0) {
      frag_color = vec4(v_fg.rgb, 1.0);
    }
    break;

  default:
    break;
  }
}