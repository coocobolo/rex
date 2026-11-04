#version 330 core

in vec2 v_pixel;
flat in float v_run_x;
flat in vec4 v_underline;
flat in vec4 v_strikethrough;
flat in vec4 v_overline;
flat in uint v_flags;

uniform vec2 u_cell_size;
uniform float u_alpha;
uniform int u_blink_on;
uniform int u_blink_rapid_on;
uniform int u_phase_grid; // 1: patterns start at the window edge, 0: at the run

// Decoration lines, in whole pixels down from the top of the cell
uniform float u_underline_y;
uniform float u_underline_thickness;
uniform float u_double_y; // top of the upper line of a double underline
uniform float u_curly_y;  // centre line of the curly wave
uniform float u_curly_amplitude;
uniform float u_curly_wavelength;
uniform float u_dot_length;
uniform float u_dot_gap;
uniform float u_dash_length;
uniform float u_dash_gap;
uniform float u_strikethrough_y;
uniform float u_strikethrough_thickness;
uniform float u_overline_y;
uniform float u_overline_thickness;

out vec4 frag_color;

// Flag bits, same layout as Frame.Flags (LSB first)
const uint FLAG_STRIKETHROUGH = 1u;
const uint FLAG_BLINK = 2u;
const uint FLAG_OVERLINE = 4u;
const uint FLAG_BLINK_RAPID = 8u;

const uint UNDERLINE_MASK = 0x70u; // bits 4-6
const uint UNDERLINE_SHIFT = 4u;

// UnderlineStyle values (must match UnderlineStyle enum)
const uint UL_NONE = 0u;
const uint UL_SINGLE = 1u;
const uint UL_DOUBLE = 2u;
const uint UL_CURLY = 3u;
const uint UL_DOTTED = 4u;
const uint UL_DASHED = 5u;

// 1.0 inside the band [top, top + thickness), else 0.0
float band(float y, float top, float thickness) {
  return (y >= top && y < top + thickness) ? 1.0 : 0.0;
}

// 1.0 on the dots or dashes of a pattern, centred in each period
float pattern(float x, float on, float off) {
  return mod(x - off * 0.5, on + off) < on ? 1.0 : 0.0;
}

// Antialiased coverage of a sine wave `t` pixels thick, from the
// vertical distance to the curve divided by its slope.
float curly(vec2 p, float t) {
  float k = 6.2831853 / u_curly_wavelength;
  float phase = k * p.x;
  float wave = u_curly_y + u_curly_amplitude * sin(phase);
  float slope = u_curly_amplitude * k * cos(phase);
  float dist = abs(p.y - wave) / sqrt(1.0 + slope * slope);
  return clamp(t * 0.5 + 0.5 - dist, 0.0, 1.0);
}

float underlineCoverage(uint style, vec2 p) {
  float t = u_underline_thickness;
  float line = band(p.y, u_underline_y, t);
  switch (style) {
  case UL_SINGLE:
    return line;
  case UL_DOUBLE:
    return max(line, band(p.y, u_double_y, t));
  case UL_CURLY:
    return curly(p, t);
  case UL_DOTTED:
    return line * pattern(p.x, u_dot_length, u_dot_gap);
  case UL_DASHED:
    return line * pattern(p.x, u_dash_length, u_dash_gap);
  default:
    return 0.0;
  }
}

// Paints `color` with `coverage` over the premultiplied `dst`
vec4 over(vec4 dst, vec4 color, float coverage) {
  float a = color.a * coverage;
  return vec4(color.rgb * a, a) + dst * (1.0 - a);
}

void main() {
  bool blink_off = ((v_flags & FLAG_BLINK) != 0u && u_blink_on == 0) ||
                   ((v_flags & FLAG_BLINK_RAPID) != 0u && u_blink_rapid_on == 0);
  if (blink_off)
    discard;

  // Pixel centre inside the cell row, x along the run or the window
  vec2 p = v_pixel;
  if (u_phase_grid != 0)
    p.x += v_run_x;
  vec4 color = vec4(0.0);

  uint ul_style = (v_flags & UNDERLINE_MASK) >> UNDERLINE_SHIFT;
  if (ul_style != UL_NONE)
    color = over(color, v_underline, underlineCoverage(ul_style, p));
  if ((v_flags & FLAG_OVERLINE) != 0u)
    color = over(color, v_overline, band(p.y, u_overline_y, u_overline_thickness));
  if ((v_flags & FLAG_STRIKETHROUGH) != 0u)
    color = over(color, v_strikethrough,
                 band(p.y, u_strikethrough_y, u_strikethrough_thickness));

  float alpha = color.a * u_alpha;
  if (alpha <= 0.0)
    discard;
  frag_color = vec4(color.rgb / color.a, alpha);
}
