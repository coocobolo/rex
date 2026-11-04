#version 330 core

in vec2 v_pixel;
flat in vec4 v_underline;
flat in vec4 v_strikethrough;
flat in vec4 v_overline;
flat in uint v_flags;

uniform vec2 u_cell_size;
uniform float u_alpha;
uniform int u_blink_on;
uniform int u_blink_rapid_on;

// Decoration lines, in whole pixels down from the top of the cell
uniform float u_underline_y;
uniform float u_underline_thickness;
uniform float u_double_y; // top of the upper line of a double underline
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

float underlineCoverage(uint style, vec2 p) {
  float t = u_underline_thickness;
  float line = band(p.y, u_underline_y, t);
  switch (style) {
  case UL_SINGLE:
    return line;
  case UL_DOUBLE:
    return max(line, band(p.y, u_double_y, t));
  case UL_CURLY: {
    float amplitude = t + 0.5;
    float center = u_underline_y - amplitude;
    float wave = sin((p.x / u_cell_size.x) * 6.2831853) * amplitude;
    float dist = abs(p.y - center - wave);
    return 1.0 - smoothstep(t * 0.5, t * 0.75, dist);
  }
  case UL_DOTTED:
    return mod(p.x, t * 4.0) < t * 2.0 ? line : 0.0;
  case UL_DASHED:
    return mod(p.x, t * 8.0) < t * 4.0 ? line : 0.0;
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

  // Pixel centre inside the cell row, x along the run
  vec2 p = v_pixel;
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
