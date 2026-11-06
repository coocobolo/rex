#version 330 core

in vec2 v_local;
flat in vec2 v_half_size;
flat in vec4 v_bg_color;
flat in vec4 v_border_color;
flat in vec2 v_params;
flat in float v_progress;
flat in uint v_kind;
flat in vec2 v_arc_sc;

out vec4 frag_color;

float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

vec4 blendOver(vec4 bottom, float bottom_mask, vec4 top, float top_mask) {
  float a_top = top.a * top_mask;
  float a_bot = bottom.a * bottom_mask;
  float out_a = a_top + a_bot * (1.0 - a_top);
  if (out_a <= 0.0001) return vec4(0.0);
  vec3 out_rgb = (top.rgb * a_top + bottom.rgb * a_bot * (1.0 - a_top)) / out_a;
  return vec4(out_rgb, out_a);
}

void main() {
  if (v_kind == 1u) {
    // .bar_h: Sub-pixel horizontal pill progress bar
    vec2 track_half = vec2(v_half_size.x, max(1.0, v_half_size.y - v_params.y));
    float r = min(v_params.x, min(track_half.x, track_half.y));
    float d_track = sdRoundedBox(v_local, track_half, r);
    float aa = max(fwidth(d_track), 0.75);
    float track_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_track);
    if (track_mask <= 0.001) discard;

    float fill_mask = 0.0;
    if (v_progress > 0.001) {
      float fill_half_x = track_half.x * v_progress;
      float fill_center_x = -track_half.x + fill_half_x;
      float r_fill = min(r, fill_half_x);
      float d_fill = sdRoundedBox(
          v_local - vec2(fill_center_x, 0.0),
          vec2(fill_half_x, track_half.y),
          r_fill
      );
      fill_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, max(d_fill, d_track));
    }

    frag_color = blendOver(v_bg_color, track_mask, v_border_color, fill_mask);
    if (frag_color.a <= 0.001) discard;
    return;
  }

  if (v_kind == 2u) {
    // .bar_v: Sub-pixel vertical column bar anchored at bottom
    vec2 col_half = vec2(max(1.0, v_half_size.x - v_params.y), v_half_size.y);
    float r = min(v_params.x, min(col_half.x, col_half.y));
    float d_track = sdRoundedBox(v_local, col_half, r);
    float aa = max(fwidth(d_track), 0.75);
    float track_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_track);
    if (track_mask <= 0.001) discard;

    float fill_mask = 0.0;
    if (v_progress > 0.001) {
      float fill_half_y = col_half.y * v_progress;
      float fill_center_y = col_half.y - fill_half_y;
      float r_fill = min(r, min(col_half.x, fill_half_y));
      float d_fill = sdRoundedBox(
          v_local - vec2(0.0, fill_center_y),
          vec2(col_half.x, fill_half_y),
          r_fill
      );
      fill_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, max(d_fill, d_track));
    }

    frag_color = blendOver(v_bg_color, track_mask, v_border_color, fill_mask);
    if (frag_color.a <= 0.001) discard;
    return;
  }

  if (v_kind == 3u) {
    // .ring: Analytic SDF circular countdown ring / arc gauge
    float outer_r = min(v_half_size.x, v_half_size.y) - 1.5;
    float th = max(1.0, v_params.y * 0.5);
    float r_mid = max(th, outer_r - th);
    float dist = length(v_local);
    float d_ring = abs(dist - r_mid) - th;
    float aa = max(fwidth(dist), 0.75);
    float ring_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_ring);
    if (ring_mask <= 0.001) discard;

    float arc_mask = 0.0;
    if (v_progress >= 0.999) {
      arc_mask = ring_mask;
    } else if (v_progress > 0.001) {
      // Clockwise sweep starting from 12 o'clock (0, -1)
      vec2 p = vec2(v_local.x, -v_local.y);
      vec2 q = vec2(
          v_arc_sc.y * p.x - v_arc_sc.x * p.y,
          v_arc_sc.x * p.x + v_arc_sc.y * p.y
      );
      q.x = abs(q.x);
      float d_arc = ((v_arc_sc.y * q.x > v_arc_sc.x * q.y)
          ? length(q - v_arc_sc * r_mid)
          : abs(length(q) - r_mid)) - th;
      arc_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_arc);
    }

    frag_color = blendOver(v_bg_color, ring_mask, v_border_color, arc_mask);
    if (frag_color.a <= 0.001) discard;
    return;
  }

  if (v_kind == 4u) {
    // .pip: Analytic SDF circular dot / step indicator pip
    float outer_r = min(v_half_size.x, v_half_size.y) - 1.0;
    float dist = length(v_local);
    float d_outer = dist - outer_r;
    float aa = max(fwidth(dist), 0.75);
    float outer_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_outer);
    if (outer_mask <= 0.001) discard;

    float border_w = v_params.y;
    float d_ring = abs(dist - (outer_r - border_w * 0.5)) - border_w * 0.5;
    float ring_mask = (border_w > 0.0) ? (1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_ring)) : 0.0;

    float inner_mask = 0.0;
    if (v_progress > 0.001) {
      float inner_r = max(0.5, (outer_r - border_w) * v_progress);
      float d_inner = dist - inner_r;
      inner_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_inner);
    }

    frag_color = blendOver(v_bg_color, inner_mask, v_border_color, ring_mask);
    if (frag_color.a <= 0.001) discard;
    return;
  }

  // Default .box (0u): Standard SDF rounded rectangle
  float radius = min(v_params.x, min(v_half_size.x, v_half_size.y));
  float border_w = v_params.y;

  float d_outer = sdRoundedBox(v_local, v_half_size, radius);
  float aa = max(fwidth(d_outer), 0.75);

  float outer_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_outer);
  if (outer_mask <= 0.001) {
    discard;
  }

  vec4 color = v_bg_color;
  if (border_w > 0.0) {
    float d_inner = d_outer + border_w;
    float inner_mask = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d_inner);
    float border_factor = clamp(outer_mask - inner_mask, 0.0, 1.0) / max(outer_mask, 0.0001);
    color = mix(v_bg_color, v_border_color, border_factor);
  }

  frag_color = vec4(color.rgb, color.a * outer_mask);
}
