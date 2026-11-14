#version 330 core

in vec2 v_pixel;
flat in vec2 v_size;
flat in uint v_flags;
flat in vec2 v_prev_span; // [x0, x1]
flat in vec2 v_next_span; // [x0, x1]

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

// Returns [0, 1] suppression weight along an overlapping row seam: 1 inside
// [overlap.x + w, overlap.y - w] so flush side edges and interior step L-joints
// keep a continuous border around adjacent vertical strokes.
float seamSuppress(float x, vec2 overlap, float border_w) {
  float lo = overlap.x + border_w;
  float hi = overlap.y - border_w;
  if (hi <= lo) return 0.0;
  return smoothstep(lo - 0.5, lo + 0.5, x) *
         (1.0 - smoothstep(hi - 0.5, hi + 0.5, x));
}

// Returns SDF union with a quarter-circle concave fillet along one side of a
// shared row seam. out_x is -1 (left) or +1 (right); in_y is +1 (top seam) or
// -1 (bottom seam).
float concaveSide(float d, vec2 pixel, vec2 size, float seam_y, float in_y,
                  float edge_x, float out_x, float neighbor_edge,
                  float mid_x, float overlap_w, float r_max) {
  float delta = out_x * (neighbor_edge - edge_x);
  if (delta == 0.0 || overlap_w <= 0.0) return d;

  float r = min(r_max, min(abs(delta) / 3.0, min(overlap_w, size.y) * 0.5));
  if (r <= 0.0) return d;

  // Wider side (delta < 0): circle center sits outside this row across the seam.
  // Narrower side (delta > 0): circle center sits inside this row's horizontal overhang pocket.
  bool is_wider = delta < 0.0;
  float corner_x = is_wider ? neighbor_edge : edge_x;
  float y_max = is_wider ? size.y * 0.5 : r;
  float center_y = is_wider ? seam_y - in_y * r : seam_y + in_y * r;

  float y_rel = in_y * (pixel.y - seam_y);
  if (y_rel < 0.0 || y_rel > y_max) return d;
  if (out_x * (pixel.x - corner_x) > r) return d;
  if (out_x * (pixel.x - mid_x) < 0.0) return d;

  vec2 center = vec2(corner_x + out_x * r, center_y);
  return min(d, r - length(pixel - center));
}

void main() {
  vec2 pixel = v_pixel;
  bool is_first = (v_flags & 1u) != 0u;
  bool is_last = (v_flags & 2u) != 0u;

  bool step_TL = (v_flags & 8u) != 0u;
  bool step_TR = (v_flags & 16u) != 0u;
  bool step_BL = (v_flags & 32u) != 0u;
  bool step_BR = (v_flags & 64u) != 0u;

  vec2 prev_overlap = clamp(v_prev_span, 0.0, v_size.x);
  vec2 next_overlap = clamp(v_next_span, 0.0, v_size.x);
  float prev_overlap_w = prev_overlap.y - prev_overlap.x;
  float next_overlap_w = next_overlap.y - next_overlap.x;

  float r_base = (u_border_style == BORDER_STYLE_UNIFIED)
                     ? min(u_radius, min(v_size.x, v_size.y) * 0.5)
                     : u_radius;

  float r_TL = (is_first || step_TL) ? r_base : 0.0;
  float r_TR = (is_first || step_TR) ? r_base : 0.0;
  float r_BL = (is_last || step_BL) ? r_base : 0.0;
  float r_BR = (is_last || step_BR) ? r_base : 0.0;

  if (u_border_style == BORDER_STYLE_UNIFIED && r_base > 0.0) {
    if (!is_first && prev_overlap_w > 0.0) {
      if (step_TL && v_prev_span.x > 0.0) {
        r_TL = min(r_TL, v_prev_span.x * (2.0 / 3.0));
      }
      if (step_TR && v_prev_span.y < v_size.x) {
        r_TR = min(r_TR, (v_size.x - v_prev_span.y) * (2.0 / 3.0));
      }
    }
    if (!is_last && next_overlap_w > 0.0) {
      if (step_BL && v_next_span.x > 0.0) {
        r_BL = min(r_BL, v_next_span.x * (2.0 / 3.0));
      }
      if (step_BR && v_next_span.y < v_size.x) {
        r_BR = min(r_BR, (v_size.x - v_next_span.y) * (2.0 / 3.0));
      }
    }
  }

  // radii = (TL, TR, BR, BL)
  vec4 radii = vec4(r_TL, r_TR, r_BR, r_BL);
  float d = roundedBoxCorners(pixel, v_size, radii);

  if (u_border_style == BORDER_STYLE_UNIFIED && r_base > 0.0) {
    float r_conc_max = r_base * 0.5;
    if (!is_first && prev_overlap_w > 0.0) {
      float prev_mid = 0.5 * (prev_overlap.x + prev_overlap.y);
      d = concaveSide(d, pixel, v_size, 0.0, 1.0, 0.0, -1.0,
                      v_prev_span.x, prev_mid, prev_overlap_w, r_conc_max);
      d = concaveSide(d, pixel, v_size, 0.0, 1.0, v_size.x, 1.0,
                      v_prev_span.y, prev_mid, prev_overlap_w, r_conc_max);
    }
    if (!is_last && next_overlap_w > 0.0) {
      float next_mid = 0.5 * (next_overlap.x + next_overlap.y);
      d = concaveSide(d, pixel, v_size, v_size.y, -1.0, 0.0, -1.0,
                      v_next_span.x, next_mid, next_overlap_w, r_conc_max);
      d = concaveSide(d, pixel, v_size, v_size.y, -1.0, v_size.x, 1.0,
                      v_next_span.y, next_mid, next_overlap_w, r_conc_max);
    }
  }

  // Outer shape.
  float outer = 1.0 - smoothstep(-0.5, 0.5, d);

  // Inner shape.
  float inner = 1.0 - smoothstep(-u_border_width - 0.5, -u_border_width + 0.5, d);

  float border = outer - inner;
  float suppress = 0.0;

  if (u_border_style == BORDER_STYLE_UNIFIED) {
    bool in_top_zone = !is_first && pixel.y < u_border_width + 0.5;
    bool in_bot_zone = !is_last && pixel.y > v_size.y - u_border_width - 0.5;

    if (in_top_zone) {
      suppress = max(suppress, seamSuppress(pixel.x, prev_overlap, u_border_width));
    }
    if (in_bot_zone) {
      suppress = max(suppress, seamSuppress(pixel.x, next_overlap, u_border_width));
    }
  }

  float border_alpha = border * (1.0 - suppress);
  float fill_alpha = mix(inner, 1.0, suppress);
  vec4 fill = vec4(u_color.rgb, u_color.a * fill_alpha);
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