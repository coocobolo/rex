#version 330 core

in vec2 v_local;
in vec2 v_uv;
in vec2 v_pixel;
flat in vec4 v_clip;
flat in vec4 v_clip_round;
flat in float v_clip_radius;
flat in vec2 v_half;
flat in vec4 v_fill;
flat in vec4 v_border;
flat in vec2 v_params;
flat in vec2 v_arc;
flat in uint v_kind;

uniform sampler2D u_atlas_gray; // coverage in alpha (swizzled R8)

out vec4 frag_color;

// Signed distance to a box of half size b with corner radius r: negative inside.
float roundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Updates exact distance to a vertical coil leg `[a, b]` and its active prefix `[0, target]`.
void evalCoilLeg(vec2 p, vec2 a, vec2 b, float s0, float target, inout float d_track, inout float d_active) {
  vec2 ba = b - a;
  float len = length(ba);
  float h = clamp(dot(p - a, ba) / max(len * len, 1e-6), 0.0, 1.0);
  d_track = min(d_track, length(p - (a + ba * h)));
  if (target > s0) {
    float h_act = clamp((target - s0) / max(len, 1e-6), 0.0, 1.0);
    d_active = min(d_active, length(p - (a + ba * min(h, h_act))));
  }
}

// Updates exact distance to a 180-degree semicircular coil U-turn and its active prefix `[0, target]`.
void evalCoilTurn(vec2 p, vec2 c, float r, bool bottom, float s0, float target, inout float d_track, inout float d_active) {
  const float PI = 3.14159265359;
  vec2 d = p - c;
  float dist_c = max(length(d), 1e-6);
  bool on_arc_side = bottom ? (d.y >= 0.0) : (d.y <= 0.0);
  float phi = on_arc_side ? acos(clamp(-d.x / dist_c, -1.0, 1.0)) : (d.x < 0.0 ? 0.0 : PI);
  float sy = bottom ? 1.0 : -1.0;
  vec2 q_phi = c + vec2(-cos(phi), sy * sin(phi)) * r;
  float dist_phi = length(p - q_phi);
  d_track = min(d_track, dist_phi);
  if (target > s0) {
    float phi_act = clamp((target - s0) / max(r, 1e-6), 0.0, PI);
    if (phi <= phi_act) {
      d_active = min(d_active, dist_phi);
    } else {
      vec2 q_start = c + vec2(-r, 0.0);
      vec2 q_end = c + vec2(-cos(phi_act), sy * sin(phi_act)) * r;
      d_active = min(d_active, min(length(p - q_start), length(p - q_end)));
    }
  }
}

vec4 sampleShape() {
  if (v_kind == 1u) {
    float coverage = texture(u_atlas_gray, v_uv).a;
    if (coverage < 0.004) return vec4(0.0);
    return vec4(v_fill.rgb, v_fill.a * coverage);
  }

  // A ring segment. 0 is the top and the sweep runs clockwise, which is
  // atan’s direction in this y-down pixel space after a quarter turn.
  if (v_kind == 2u) {
    const float TAU = 6.28318530718;
    float outer = max(v_params.x, 0.0);
    float thick = abs(v_params.y);
    float inner = max(outer - thick, 0.0);
    float d = length(v_local);
    float ring = max(inner - d, d - outer);
    // Coverage is zero past half a pixel, and a round cap stays inside
    // the outer radius, so this pixel cannot be ink.
    if (ring > 0.5) return vec4(0.0);

    float ang = mod(atan(v_local.y, v_local.x) + 1.57079632679, TAU);
    float start = mod(v_arc.x, TAU);
    float sweep = clamp(v_arc.y, 0.0, TAU);
    float cw = mod(ang - start, TAU);
    float ccw = mod(start - ang, TAU);
    float wedge = cw <= sweep ? -min(cw, sweep - cw) : min(cw - sweep, ccw);
    float dist = max(ring, wedge * max(d, 1.0));

    // Round caps are discs on the centerline at each end. A full turn
    // already covers them.
    if (v_params.y < 0.0 && sweep < TAU) {
      float cl = max(outer - thick * 0.5, 0.0);
      float half_t = thick * 0.5;
      vec2 cap_a = vec2(sin(start), -cos(start)) * cl;
      vec2 cap_b = vec2(sin(start + sweep), -cos(start + sweep)) * cl;
      dist = min(dist, min(length(v_local - cap_a), length(v_local - cap_b)) - half_t);
    }

    float shape = clamp(0.5 - dist, 0.0, 1.0);
    if (v_fill.a * shape < 0.004) return vec4(0.0);
    return vec4(v_fill.rgb, v_fill.a * shape);
  }

  if (v_kind == 3u) {
    if (abs(v_local.x) >= v_half.x || abs(v_local.y) >= v_half.y) return vec4(0.0);
    float x = v_local.x + v_half.x;
    float period = v_params.x + v_params.y;
    if (period > 0.0 && mod(x, period) >= v_params.x) return vec4(0.0);
    if (v_fill.a < 0.004) return vec4(0.0);
    return v_fill;
  }

  // A serpentine progress ribbon: `N` vertical legs joined by alternating
  // bottom/top 180-degree U-turns, evaluated in O(1) over the local neighborhood.
  if (v_kind == 4u) {
    const float PI = 3.14159265359;
    float w = v_half.x * 2.0;
    float h = v_half.y * 2.0;
    float n = max(floor(v_params.y + 0.5), 2.0);
    float t = clamp(v_params.x, 1.0, min(w / (n * 1.35), h * 0.4));
    float ht = t * 0.5;
    float span_x = max(w - t, 1.0);
    float pitch = span_x / (n - 1.0);
    float r = pitch * 0.5;
    float y_turn = max(v_half.y - r - ht, 0.0);

    float l_seg = 2.0 * y_turn;
    float l_arc = PI * r;
    float l_step = l_seg + l_arc;
    float s_total = (n - 1.0) * l_step + l_seg + 2.0 * r;
    float frac = clamp(v_arc.x, 0.0, 1.0);
    float target = frac * s_total;

    float u = (v_local.x + span_x * 0.5) / pitch;
    float k0 = clamp(floor(u), 0.0, n - 2.0);
    float d_track = 1e9;
    float d_active = 1e9;

    // Two nearest vertical legs (`k0` and `k0 + 1`).
    for (int di = 0; di <= 1; ++di) {
      float idx = k0 + float(di);
      float x_col = -span_x * 0.5 + idx * pitch;
      bool down = mod(idx, 2.0) < 0.5;
      float top_y = (idx < 0.5 || (idx > n - 1.5 && !down)) ? -(y_turn + r) : -y_turn;
      float bot_y = (idx > n - 1.5 && down) ? (y_turn + r) : y_turn;
      vec2 a = vec2(x_col, down ? top_y : bot_y);
      vec2 b = vec2(x_col, down ? bot_y : top_y);
      float s0 = (idx < 0.5) ? 0.0 : (r + idx * l_step);
      evalCoilLeg(v_local, a, b, s0, target, d_track, d_active);
    }

    // Up to three nearest U-turns (`k0 - 1`, `k0`, `k0 + 1`).
    for (int dk = -1; dk <= 1; ++dk) {
      float k = k0 + float(dk);
      if (k < 0.0 || k > n - 2.0) continue;
      float x_turn = -span_x * 0.5 + (k + 0.5) * pitch;
      bool bottom = mod(k, 2.0) < 0.5;
      vec2 c = vec2(x_turn, bottom ? y_turn : -y_turn);
      float s0 = r + k * l_step + l_seg;
      evalCoilTurn(v_local, c, r, bottom, s0, target, d_track, d_active);
    }

    float track_cov = clamp(0.5 - (d_track - ht), 0.0, 1.0);
    float active_cov = (frac > 0.0) ? clamp(0.5 - (d_active - ht), 0.0, 1.0) : 0.0;
    float a_act = v_fill.a * active_cov;
    float a_trk = v_border.a * track_cov;
    float out_a = a_act + a_trk * (1.0 - a_act);
    if (out_a < 0.004) return vec4(0.0);
    vec3 out_rgb = (v_fill.rgb * a_act + v_border.rgb * a_trk * (1.0 - a_act)) / out_a;
    return vec4(out_rgb, out_a);
  }

  float radius = min(v_params.x, min(v_half.x, v_half.y));
  float distance = roundedBox(v_local, v_half, radius);
  float shape = clamp(0.5 - distance, 0.0, 1.0);

  // The border is the band of v_params.y pixels inside the edge, drawn
  // over the fill (it may be translucent, such as white at 10%).
  float inside_border = v_params.y > 0.0 ? clamp(0.5 - (distance + v_params.y), 0.0, 1.0) : 1.0;
  float border_seg = 1.0;
  if (v_arc.x > 0.0 && v_arc.x < 0.9999 && v_params.y > 0.0 && inside_border < 1.0) {
    float sx = max(v_half.x - radius, 0.0);
    float sy = max(v_half.y - radius, 0.0);
    float r_mid = max(radius - v_params.y * 0.5, 0.5);
    float q_arc = 1.57079632679 * r_mid;
    float perim = 4.0 * sx + 4.0 * sy + 4.0 * q_arc;
    if (perim > 0.0) {
      vec2 p = v_local;
      float s = 0.0;
      if (p.x >= 0.0 && p.x <= sx && p.y <= 0.0) {
        s = p.x;
      } else if (p.x > sx && p.y < -sy) {
        s = sx + r_mid * atan(p.x - sx, max(-sy - p.y, 1e-4));
      } else if (p.x >= 0.0 && p.y >= -sy && p.y <= sy) {
        s = sx + q_arc + (p.y + sy);
      } else if (p.x > sx && p.y > sy) {
        s = sx + q_arc + 2.0 * sy + r_mid * atan(p.y - sy, max(p.x - sx, 1e-4));
      } else if (p.y > 0.0 && p.x >= -sx && p.x <= sx) {
        s = sx + 2.0 * q_arc + 2.0 * sy + (sx - p.x);
      } else if (p.x < -sx && p.y > sy) {
        s = 3.0 * sx + 2.0 * q_arc + 2.0 * sy + r_mid * atan(-sx - p.x, max(p.y - sy, 1e-4));
      } else if (p.x < 0.0 && p.y >= -sy && p.y <= sy) {
        s = 3.0 * sx + 3.0 * q_arc + 2.0 * sy + (sy - p.y);
      } else if (p.x < -sx && p.y < -sy) {
        s = 3.0 * sx + 3.0 * q_arc + 4.0 * sy + r_mid * atan(-sy - p.y, max(-sx - p.x, 1e-4));
      } else {
        s = 3.0 * sx + 4.0 * q_arc + 4.0 * sy + (sx + p.x);
      }
      float target = clamp(v_arc.x, 0.0, 1.0) * perim;
      float ccw = perim - s;
      float along = s <= target ? -min(s, target - s) : min(s - target, ccw);
      border_seg = clamp(0.5 - along, 0.0, 1.0);
    }
  }
  float border = (1.0 - inside_border) * v_border.a * border_seg;
  float alpha = border + v_fill.a * (1.0 - border);
  if (alpha * shape < 0.004) return vec4(0.0);
  vec3 color = (v_border.rgb * border + v_fill.rgb * v_fill.a * (1.0 - border)) / alpha;
  return vec4(color, alpha * shape);
}

void main() {
  // Outside the clipping box this instance sits in.
  if (v_pixel.x < v_clip.x || v_pixel.y < v_clip.y || v_pixel.x >= v_clip.z || v_pixel.y >= v_clip.w) discard;

  float clip_alpha = 1.0;
  if (v_clip_radius > 0.0) {
    vec2 half_clip = max((v_clip_round.zw - v_clip_round.xy) * 0.5, 0.0);
    if (half_clip.x == 0.0 || half_clip.y == 0.0) discard;
    vec2 center_clip = (v_clip_round.xy + v_clip_round.zw) * 0.5;
    float r_clip = min(v_clip_radius, min(half_clip.x, half_clip.y));
    clip_alpha = clamp(0.5 - roundedBox(v_pixel - center_clip, half_clip, r_clip), 0.0, 1.0);
    if (clip_alpha < 0.004) discard;
  }

  vec4 sampled = sampleShape();
  float final_alpha = sampled.a * clip_alpha;
  if (final_alpha < 0.004) discard;
  frag_color = vec4(sampled.rgb, final_alpha);
}
