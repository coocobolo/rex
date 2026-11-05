#version 330 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;
uniform vec2 u_half_pixel;
uniform float u_offset;

void main() {
    vec2 d = u_half_pixel * u_offset;

    // Dual Kawase 5-tap downsampling filter: center tap + 4 bilinear corner taps
    // At u_offset = 1.0, corner taps sample at the junction of 4 source texels,
    // gathering a full 4x4 texel area with hardware bilinear filtering.
    vec4 sum = texture(u_texture, v_uv) * 4.0;
    sum += texture(u_texture, v_uv - d);
    sum += texture(u_texture, v_uv + d);
    sum += texture(u_texture, v_uv + vec2(d.x, -d.y));
    sum += texture(u_texture, v_uv + vec2(-d.x, d.y));

    frag_color = sum * 0.125;
}
