#version 330 core

in vec2 v_uv;
flat in vec4 v_fg;
flat in uint v_flags;

uniform sampler2D u_atlas_gray;  // texture unit 0, red channel coverage
uniform sampler2D u_atlas_color; // texture unit 1, RGBA premultiplied
uniform int u_is_color;          // 0 = gray pass, 1 = color emoji pass
uniform int u_blink_on;          // 0 = slow blink phase off
uniform int u_blink_rapid_on;    // 0 = rapid blink phase off
uniform int u_mask_mode;         // 1 = write glyph coverage for the ink mask
uniform float u_grayscale;
uniform vec3 u_color_tint;

out vec4 frag_color;

// Flag bits, must match the Flags packed struct (LSB first). Glyph
// instances only set the blink bits, decorations have their own pass.
const uint FLAG_BLINK = 2u;       // bit 1
const uint FLAG_BLINK_RAPID = 8u; // bit 3

void main() {
  // Blink: discard glyph when phase is off, bg color shows through
  if ((v_flags & FLAG_BLINK) != 0u && u_blink_on == 0)
    discard;
  if ((v_flags & FLAG_BLINK_RAPID) != 0u && u_blink_rapid_on == 0)
    discard;

  if (u_mask_mode == 1) {
    // Ink mask: coverage only, blended with MAX
    float coverage = u_is_color == 1 ? texture(u_atlas_color, v_uv).a
                                     : texture(u_atlas_gray, v_uv).a;
    frag_color = vec4(coverage);
    return;
  }

  if (u_is_color == 1) {
    // Color emoji: premultiplied RGBA, use ONE, ONE_MINUS_SRC_ALPHA blend
    frag_color = texture(u_atlas_color, v_uv);
    if (frag_color.a < 0.01) discard;
    vec3 rgb = frag_color.rgb * u_color_tint;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    frag_color.rgb = mix(rgb, vec3(luma), u_grayscale);
  } else {
    // Gray glyph: red channel = coverage, use SRC_ALPHA, ONE_MINUS_SRC_ALPHA
    float alpha = texture(u_atlas_gray, v_uv).a;
    if (alpha < 0.01) discard;
    vec3 rgb = v_fg.rgb * u_color_tint;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(rgb, vec3(luma), u_grayscale);
    frag_color = vec4(rgb, v_fg.a * alpha);
  }
}