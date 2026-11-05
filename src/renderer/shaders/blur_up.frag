#version 330 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;
uniform vec2 u_half_pixel;
uniform float u_offset;
uniform float u_dim_alpha;
uniform vec3 u_scrim_color;

void main() {
    vec2 d = u_half_pixel * u_offset;

    // 8-tap Kawase reconstruction filter with bilinear hardware smoothing
    vec4 sum = vec4(0.0);
    sum += texture(u_texture, v_uv + vec2(-2.0 * d.x, 0.0)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(0.0, 2.0 * d.y)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(2.0 * d.x, 0.0)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(0.0, -2.0 * d.y)) * 2.0;

    sum += texture(u_texture, v_uv + vec2(-d.x, d.y));
    sum += texture(u_texture, v_uv + vec2(d.x, d.y));
    sum += texture(u_texture, v_uv + vec2(d.x, -d.y));
    sum += texture(u_texture, v_uv + vec2(-d.x, -d.y));

    vec3 blurred = (sum / 12.0).rgb;

    // Blend blurred backdrop with dark scrim color according to dim_alpha
    vec3 tinted = mix(blurred, u_scrim_color, clamp(u_dim_alpha, 0.0, 1.0));
    frag_color = vec4(tinted, 1.0);
}
