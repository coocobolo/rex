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

// Ink skipping: glyph coverage of the frame, see InkMask.zig
uniform sampler2D u_ink_mask;
uniform uint u_skip_ink_styles; // bit n: UnderlineStyle n skips ink, 0 = off
uniform int u_ink_gap;          // whole pixels of clearance around ink
uniform int u_ink_min_segment;  // shortest piece of line kept, in pixels
uniform float u_ink_threshold;  // coverage counted as ink
uniform float u_strikethrough_y;
uniform float u_strikethrough_thickness;
uniform float u_overline_y;
uniform float u_overline_thickness;
uniform float u_baseline; // first pixel row below the glyph bodies

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

// Must match Decoration.Metrics.max_ink_scan
const int MAX_INK_SCAN = 64;

// True when the mask column `dx` pixels from `base` has ink within
// u_ink_gap pixels above or below it. For a line pixel at cell row
// `row` below the baseline, ink above the baseline is the glyph body
// resting on it, not a descender, and is ignored.
bool inkColumn(ivec2 base, int dx, ivec2 size, int row) {
  int baseline = int(u_baseline);
  int x = base.x + dx;
  if (x < 0 || x >= size.x)
    return false;
  for (int dy = -MAX_INK_SCAN; dy <= MAX_INK_SCAN; dy++) {
    if (dy < -u_ink_gap)
      continue;
    if (dy > u_ink_gap)
      break;
    int y = base.y + dy;
    if (y < 0 || y >= size.y)
      continue;
    // The mask grows upwards, the cell row downwards.
    if (row >= baseline && row - dy < baseline)
      continue;
    if (texelFetch(u_ink_mask, ivec2(x, y), 0).r >= u_ink_threshold)
      return true;
  }
  return false;
}

// 0.0 where the underline gives way to ink: within u_ink_gap pixels of
// it, or on a piece shorter than u_ink_min_segment between two inks.
float inkSkip(int row) {
  ivec2 base = ivec2(gl_FragCoord.xy);
  ivec2 size = textureSize(u_ink_mask, 0);
  int reach = min(u_ink_gap + u_ink_min_segment + 1, MAX_INK_SCAN);

  int left = reach + 1;
  for (int k = 0; k <= MAX_INK_SCAN; k++) {
    if (k > reach)
      break;
    if (inkColumn(base, -k, size, row)) {
      left = k;
      break;
    }
  }
  if (left <= u_ink_gap)
    return 0.0;

  int right = reach + 1;
  for (int k = 1; k <= MAX_INK_SCAN; k++) {
    if (k > reach)
      break;
    if (inkColumn(base, k, size, row)) {
      right = k;
      break;
    }
  }
  if (right <= u_ink_gap)
    return 0.0;

  // The piece runs from left - gap - 1 pixels left of here to
  // right - gap - 1 pixels right of here.
  if (left <= reach && right <= reach &&
      left + right - 2 * u_ink_gap - 1 < u_ink_min_segment)
    return 0.0;
  return 1.0;
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
  if (ul_style != UL_NONE) {
    float coverage = underlineCoverage(ul_style, p);
    if (coverage > 0.0 && (u_skip_ink_styles & (1u << ul_style)) != 0u)
      coverage *= inkSkip(int(floor(p.y)));
    color = over(color, v_underline, coverage);
  }
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
