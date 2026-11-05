#version 330 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;
uniform vec2 u_half_pixel;

void main() {
    // 4 bilinear samples offset diagonally by half a texel to read 16 source texels
    vec4 sum = texture(u_texture, v_uv) * 4.0;
    sum += texture(u_texture, v_uv - u_half_pixel);
    sum += texture(u_texture, v_uv + u_half_pixel);
    sum += texture(u_texture, v_uv + vec2(u_half_pixel.x, -u_half_pixel.y));
    sum += texture(u_texture, v_uv + vec2(-u_half_pixel.x, u_half_pixel.y));
    frag_color = sum * 0.125;
}
