#version 330 core

in vec2 v_uv;
flat in vec2 v_size;
flat in uint v_flags;

uniform vec4 u_color;         // rgba: rgb = tint, a = base opacity
uniform float u_border_width; // e.g. 1.5
uniform vec4 u_border_color;
uniform float u_radius;
uniform float u_fill_opacity; // 0.0 = border only, 1.0 solid fill
uniform int u_connected;

out vec4 frag_color;

// Per-corner rounded rectangle SDF.
// radii = (TL, TR, BR, BL) | (top-left, top-right, bottom-right, bottom-left)
float roundedBoxCorners(vec2 pixel, vec2 size, vec4 radii) {
  vec2 half = size * 0.5;
  vec2 p = pixel - half;
  // pick radius for the quadrant we're in
  float r = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w)  // left side: TL or BL
                      : (p.y < 0.0 ? radii.y : radii.z); // right side: TR or BR
  vec2 q = abs(p) - half + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}


void main() {
  vec2 pixel = v_uv * v_size;
  bool is_first = (v_flags & 1u) != 0u;
  bool is_last = (v_flags & 2u) != 0u;

  // Only the outer corners are rounded.
  float r_top = is_first ? u_radius : 0.0;
  float r_bot = is_last ? u_radius : 0.0;
  vec4 radii = vec4(r_top, r_top, r_bot, r_bot);

  float d = roundedBoxCorners(pixel, v_size, radii);

  // Outer shape.
  float outer = 1.0 - smoothstep(-0.5, 0.5, d);

  // Inner shape.
  float inner =
      1.0 - smoothstep(-u_border_width - 0.5, -u_border_width + 0.5, d);

  float border = outer - inner;
  float border_orig = border;  // ← save here  


  if (u_connected != 0) {  
     if (!is_first && pixel.y < u_border_width + 0.5) {  
        inner = 1.0;  
        border = 0.0;  
     }  
     if (!is_last && pixel.y > v_size.y - u_border_width - 0.5) {  
        inner = 1.0;  
        border = 0.0;  
     }  
  }

  if (u_connected != 0) {  
     bool in_suppress = (!is_first && pixel.y < u_border_width + 0.5) ||  (!is_last  && pixel.y > v_size.y - u_border_width - 0.5);  
     // if (in_suppress) {  
     //    // Only draw left/right border in the suppressed zone  
     //    float left  = 1.0 - smoothstep(u_border_width - 0.5, u_border_width + 0.5, pixel.x);  
     //    float right = smoothstep(v_size.x - u_border_width - 0.5, v_size.x - u_border_width + 0.5, pixel.x);  
     //    float lr = max(left, right);  
     //    float fill_a = u_color.a * u_fill_opacity;  
     //    frag_color = vec4(u_border_color.rgb, u_border_color.a * lr) + vec4(u_color.rgb, fill_a) * (1.0 - u_border_color.a * lr);  
     //    if (frag_color.a < 0.01) discard;  
     //    return;  
     // }  

     if (in_suppress) {
         float left = 1.0 - smoothstep(
                 u_border_width - 0.5,
                 u_border_width + 0.5,
                 pixel.x);

         float right = smoothstep(
                 v_size.x - u_border_width - 0.5,
                 v_size.x - u_border_width + 0.5,
                 pixel.x);

         float side_mask = max (left, right);

         // float fill_alpha = inner * u_fill_opacity;
         float fill_alpha   = u_fill_opacity * (1.0 - side_mask);  // ← was: inner * u_fill_opacity  
         // Use the original border mask.

         float border_alpha = border_orig * side_mask;
         vec4 fill = vec4(u_color.rgb, u_color.a * fill_alpha);
         vec4 outline = vec4(u_border_color.rgb, u_border_color.a * border_alpha);
         frag_color = outline + fill * (1.0 - outline.a);
         if (frag_color.a < 0.01) discard;  

         return;
     }
  }

  float fill_alpha = inner * u_fill_opacity;
  float border_alpha = border;

  vec4 fill = vec4(u_color.rgb, u_color.a * fill_alpha);
  vec4 outline = vec4(u_border_color.rgb, u_border_color.a * border_alpha);

  // Composite border over fill.
  frag_color = outline + fill * (1.0 - outline.a);
  if (frag_color.a < 0.01) {
    discard;
  }
}


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