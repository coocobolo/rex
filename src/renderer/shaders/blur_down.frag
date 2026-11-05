#version 330 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;
uniform vec2 u_half_pixel;

void main() {
    // 5-tap downsampling filter: center tap plus 4 bilinear corner taps
    // Offset by 2x half-pixel so bilinear filtering reads a complete 6x6 texel neighborhood
    vec2 d = u_half_pixel * 2.0;

    vec4 sum = texture(u_texture, v_uv) * 4.0;
    sum += texture(u_texture, v_uv - d);
    sum += texture(u_texture, v_uv + d);
    sum += texture(u_texture, v_uv + vec2(d.x, -d.y));
    sum += texture(u_texture, v_uv + vec2(-d.x, d.y));

    frag_color = sum * 0.125;
}

