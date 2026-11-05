#version 330 core

in vec2 v_local;              // local pixel coordinates centered at (0, 0)
flat in vec2 v_half_size;     // half width, half height of card in pixels
flat in vec4 v_bg_color;      // rgba background fill color (0..1)
flat in vec4 v_border_color;  // rgba border color (0..1)
flat in vec2 v_params;        // x = corner radius, y = border thickness in pixels

out vec4 frag_color;

// Signed distance to a rounded rectangle centered at origin
float sdRoundRect(vec2 p, vec2 half_size, float r) {
  vec2 q = abs(p) - half_size + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  float u_radius = v_params.x;
  float u_border_width = v_params.y;

  // Clamp radius so it does not exceed half the card dimensions
  float r = min(u_radius, min(v_half_size.x, v_half_size.y));
  float d = sdRoundRect(v_local, v_half_size, r);

  // Compute adaptive anti-aliasing width across screen fragments
  float afwidth = fwidth(d);
  if (afwidth <= 0.0) afwidth = 1.0;
  float half_w = afwidth * 0.5;

  // Smooth anti-aliased outer coverage (0 outside, 1 inside)
  float outer = 1.0 - smoothstep(-half_w, half_w, d);
  if (outer <= 0.0) {
    discard;
  }

  // Inner border boundary inset by border thickness
  float inner_d = d + u_border_width;
  float inner = 1.0 - smoothstep(-half_w, half_w, inner_d);

  // If no visible border, output pure background fill
  if (u_border_width <= 0.0 || v_border_color.a <= 0.0) {
    frag_color = vec4(v_bg_color.rgb, v_bg_color.a * outer);
    return;
  }

  // Smooth seamless interpolation between border and interior fill
  vec3 rgb = mix(v_border_color.rgb, v_bg_color.rgb, inner);
  float alpha = outer * mix(v_border_color.a, v_bg_color.a, inner);

  frag_color = vec4(rgb, alpha);
}
