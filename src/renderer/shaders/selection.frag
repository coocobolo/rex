#version 330 core

in vec2 v_uv;
flat in vec2 v_size;
flat in uint v_flags;
flat in vec2 v_prev_overlap; // [x0, x1]
flat in vec2 v_next_overlap; // [x0, x1]

uniform vec4 u_color;
uniform float u_radius;
uniform float u_border_width;
uniform vec4 u_border_color;
uniform uint u_border_style;

out vec4 frag_color;

// Border style values (must match BorderStyle enum)
const uint BORDER_STYLE_PER_ROW = 0u;
const uint BORDER_STYLE_UNIFIED = 1u;

// Per-corner rounded rectangle SDF.
// radii = (TL, TR, BR, BL) | (top-left, top-right, bottom-right, bottom-left)
float roundedBoxCorners(vec2 pixel, vec2 size, vec4 radii) {
  vec2 half_size = size * 0.5;
  vec2 p = pixel - half_size;

  // pick radius for the quadrant we're in
  float r = p.x < 0.0
                ? (p.y < 0.0 ? radii.x : radii.w)  // left side  = TL or BL
                : (p.y < 0.0 ? radii.y : radii.z); // right side = TR or BR
  vec2 q = abs(p) - half_size + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  vec2 pixel = v_uv * v_size;
  bool is_first = (v_flags & 1u) != 0u;
  bool is_last = (v_flags & 2u) != 0u;

  bool step_TL = (v_flags & 8u) != 0u;
  bool step_TR = (v_flags & 16u) != 0u;
  bool step_BL = (v_flags & 32u) != 0u;
  bool step_BR = (v_flags & 64u) != 0u;

  float r_TL = (is_first || step_TL) ? u_radius : 0.0;
  float r_TR = (is_first || step_TR) ? u_radius : 0.0;
  float r_BL = (is_last || step_BL) ? u_radius : 0.0;
  float r_BR = (is_last || step_BR) ? u_radius : 0.0;

  // radii = (TL, TR, BR, BL)
  vec4 radii = vec4(r_TL, r_TR, r_BR, r_BL);
  float d = roundedBoxCorners(pixel, v_size, radii);

  // Outer shape.
  float outer = 1.0 - smoothstep(-0.5, 0.5, d);

  // Inner shape.
  float inner = 1.0 - smoothstep(-u_border_width - 0.5, -u_border_width + 0.5, d);

  float border = outer - inner;
  float border_orig = border;

  if (u_border_style == BORDER_STYLE_UNIFIED)  {
    bool in_top_zone = !is_first && pixel.y < u_border_width + 0.5;
    bool in_bot_zone = !is_last && pixel.y > v_size.y - u_border_width - 0.5;

    // Suppress only where this row overlaps with the adjacent row's span
    bool in_top_suppress = in_top_zone && pixel.x >= v_prev_overlap.x &&
                           pixel.x < v_prev_overlap.y;
    bool in_bot_suppress = in_bot_zone && pixel.x >= v_next_overlap.x &&
                           pixel.x < v_next_overlap.y;

    if (in_top_suppress || in_bot_suppress) {
      // Left/right border still drawn; fill in the suppressed zone
      float left =
          1.0 - smoothstep(u_border_width - 0.5, u_border_width + 0.5, pixel.x);
      float right = smoothstep(v_size.x - u_border_width - 0.5,
                               v_size.x - u_border_width + 0.5, pixel.x);
      float side_mask = max(left, right);
      float border_alpha = border_orig * side_mask;

      vec4 fill = vec4(u_color.rgb, u_color.a * (1.0 - side_mask));
      vec4 outline = vec4(u_border_color.rgb, u_border_color.a * border_alpha);
      frag_color = outline + fill * (1.0 - outline.a);
      if (frag_color.a < 0.01) discard;
      return;
    }

    // Pixels in the top/bottom border zone but OUTSIDE the overlap are step
    // edges hey fall through to the normal SDF path and keep their border
  }

  float border_alpha = border;
  vec4 fill = vec4(u_color.rgb, u_color.a * inner);
  vec4 outline = vec4(u_border_color.rgb, u_border_color.a * border_alpha);

  // Composite border over fill.
  frag_color = outline + fill * (1.0 - outline.a);
  if (frag_color.a < 0.01) discard;
}

// void main() {
//   vec2 pixel = v_uv * v_size;
//   bool is_first = (v_flags & 1u) != 0u;
//   bool is_last = (v_flags & 2u) != 0u;
//   bool is_rect = (v_flags & 4u) != 0u;
//
//   // Only the outer corners are rounded.
//   float r_top = is_first ? u_radius : 0.0;
//   float r_bot = is_last ? u_radius : 0.0;
//   vec4 radii = vec4(r_top, r_top, r_bot, r_bot);
//
//   float d = roundedBoxCorners(pixel, v_size, radii);
//
//   // Outer shape.
//   float outer = 1.0 - smoothstep(-0.5, 0.5, d);
//
//   // Inner shape.
//   float inner =
//       1.0 - smoothstep(-u_border_width - 0.5, -u_border_width + 0.5, d);
//
//   float border = outer - inner;
//   float border_orig = border;  // ← save here
//
//   // if (u_border_style != 0) {
//   //    if (!is_first && pixel.y < u_border_width + 0.5) {
//   //       inner = 1.0;
//   //       border = 0.0;
//   //    }
//   //    if (!is_last && pixel.y > v_size.y - u_border_width - 0.5) {
//   //       inner = 1.0;
//   //       border = 0.0;
//   //    }
//   // }
//
//   if (u_border_style != 0) {
//      bool in_suppress = (!is_first && pixel.y < u_border_width + 0.5) ||
//      (!is_last  && pixel.y > v_size.y - u_border_width - 0.5); if
//      (in_suppress) {
//          float left = 1.0 - smoothstep(
//                  u_border_width - 0.5,
//                  u_border_width + 0.5,
//                  pixel.x);
//
//          float right = smoothstep(
//                  v_size.x - u_border_width - 0.5,
//                  v_size.x - u_border_width + 0.5,
//                  pixel.x);
//
//          float side_mask = max (left, right);
//
//          // float fill_alpha = inner * u_fill_opacity;
//          float fill_alpha   = u_fill_opacity * (1.0 - side_mask);  // ← was:
//          inner * u_fill_opacity
//          // Use the original border mask.
//
//          float border_alpha = border_orig * side_mask;
//          vec4 fill = vec4(u_color.rgb, u_color.a * fill_alpha);
//          vec4 outline = vec4(u_border_color.rgb, u_border_color.a *
//          border_alpha); frag_color = outline + fill * (1.0 - outline.a); if
//          (frag_color.a < 0.01) discard;
//
//          return;
//      }
//   }
//
//   float fill_alpha = inner * u_fill_opacity;
//   float border_alpha = border;
//
//   vec4 fill = vec4(u_color.rgb, u_color.a * fill_alpha);
//   vec4 outline = vec4(u_border_color.rgb, u_border_color.a * border_alpha);
//
//   // Composite border over fill.
//   frag_color = outline + fill * (1.0 - outline.a);
//   if (frag_color.a < 0.01) {
//     discard;
//   }
// }

// void main() {
//   vec2 pixel = v_uv * v_size;
//
//   bool is_first = (v_flags & 1u) != 0u;
//   bool is_last = (v_flags & 2u) != 0u;
//
//   float r_top = is_first ? u_radius : 0.0;
//   float r_bot = is_last ? u_radius : 0.0;
//
//   // (TL, TR, BR, BL)
//   vec4 radii = vec4(r_top, r_top, r_bot, r_bot);
//
//   float d = roundedBoxCorners(pixel, v_size, radii);
//   // outer edge: 1 inside shape, 0 outside
//   float outer = 1.0 - smoothstep(-0.5, 0.5, d);
//   // inner edge: 1 inside the inner boundary, 0 outside
//   float inner =
//       1.0 - smoothstep(-u_border_width - 0.5, -u_border_width + 0.5, d);
//   float border = outer - inner;        // ring only
//   float fill = inner * u_fill_opacity; // semi-tansparent interior
//   float alpha = max(border, fill);
//
//   if (alpha < 0.01) {
//     discard;
//   }
//
//   frag_color = vec4(u_color.rgb, u_color.a * alpha);
// }