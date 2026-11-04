#version 330 core

in vec2 v_quad_uv;
flat in vec4 v_bg;
flat in vec4 v_fg;
flat in uint v_flags;

uniform vec2 u_cell_size;
uniform float u_bg_alpha;
uniform int u_blink_on;
uniform int u_blink_rapid_on;

// Decoration lines, in pixels down from the top of the cell
uniform float u_underline_y;
uniform float u_underline_thickness;
uniform float u_double_y; // top of the upper line of a double underline
uniform float u_strikethrough_y;
uniform float u_strikethrough_thickness;
uniform float u_overline_y;
uniform float u_overline_thickness;

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
  float x = pixel.x;
  float y = pixel.y;
  vec4 line_color = vec4(v_fg.rgb, 1.0);

  if ((v_flags & FLAG_OVERLINE) != 0u && y >= u_overline_y &&
      y < u_overline_y + u_overline_thickness) {
    frag_color = line_color;
    return;
  }

  if ((v_flags & FLAG_STRIKETHROUGH) != 0u && y >= u_strikethrough_y &&
      y < u_strikethrough_y + u_strikethrough_thickness) {
    frag_color = line_color;
    return;
  }

  uint ul_style = (v_flags & UNDERLINE_MASK) >> UNDERLINE_SHIFT;
  if (ul_style == UL_NONE)
    return;

  float t = u_underline_thickness;
  float ul_y = u_underline_y;
  bool on_line = y >= ul_y && y < ul_y + t;

  switch (ul_style) {
  case UL_SINGLE:
    if (on_line)
      frag_color = line_color;
    break;

  case UL_DOUBLE:
    if (on_line || (y >= u_double_y && y < u_double_y + t))
      frag_color = line_color;
    break;

  case UL_CURLY: {
    float amplitude = t + 0.5;
    float center = ul_y - amplitude;
    float wave = sin((x / cw) * 3.14159 * 2.0) * amplitude;
    float dist = abs(y - center - wave);
    float alpha = 1.0 - smoothstep(t * 0.5, t * 0.75, dist);
    frag_color = mix(frag_color, line_color, alpha);
    break;
  }

  case UL_DOTTED:
    if (on_line && mod(x, t * 4.0) < t * 2.0)
      frag_color = line_color;
    break;

  case UL_DASHED:
    if (on_line && mod(x, t * 8.0) < t * 4.0)
      frag_color = line_color;
    break;

  default:
    break;
  }
}
