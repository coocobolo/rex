#version 330 core

in vec2 v_uv;
out vec4 frag_color;

uniform sampler2D u_texture;
uniform vec2 u_half_pixel;
uniform float u_offset;
uniform int u_is_final;
uniform float u_dim_alpha;
uniform vec3 u_scrim_color;

// High-frequency interleaved gradient noise to eliminate dark color banding
float dither(vec2 coord) {
    return fract(52.9829189 * fract(dot(coord, vec2(0.06711056, 0.00583715))));
}

void main() {
    vec2 d = u_half_pixel * u_offset;

    // 9-tap 3x3 tent filter with bilinear hardware smoothing
    // Center tap anchors stability and eliminates cross-hatching
    vec4 sum = texture(u_texture, v_uv) * 4.0;

    // 4 Orthogonal taps with 2.0 weight
    sum += texture(u_texture, v_uv + vec2(-2.0 * d.x, 0.0)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(0.0, 2.0 * d.y)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(2.0 * d.x, 0.0)) * 2.0;
    sum += texture(u_texture, v_uv + vec2(0.0, -2.0 * d.y)) * 2.0;

    // 4 Diagonal taps with 1.0 weight
    sum += texture(u_texture, v_uv + vec2(-d.x, d.y));
    sum += texture(u_texture, v_uv + vec2(d.x, d.y));
    sum += texture(u_texture, v_uv + vec2(d.x, -d.y));
    sum += texture(u_texture, v_uv + vec2(-d.x, -d.y));

    // Normalize: 4.0 + 4*2.0 + 4*1.0 = 16.0
    vec3 blurred = (sum * 0.0625).rgb;

    if (u_is_final != 0) {
        // Vibrancy preservation: subtle 15% saturation retention
        float luma = dot(blurred, vec3(0.2126, 0.7152, 0.0722));
        vec3 vibrant = mix(vec3(luma), blurred, 1.15);

        // Blend blurred backdrop with dark scrim color according to dim_alpha
        vec3 tinted = mix(vibrant, u_scrim_color, clamp(u_dim_alpha, 0.0, 1.0));

        // Screen-space triangular dither in [-0.5/255, +0.5/255] range to dissolve quantization banding
        float noise = (dither(gl_FragCoord.xy) - 0.5) / 255.0;
        frag_color = vec4(clamp(tinted + vec3(noise), 0.0, 1.0), 1.0);
    } else {
        frag_color = vec4(blurred, 1.0);
    }
}
