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
