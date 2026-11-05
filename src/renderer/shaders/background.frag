#version 330 core

flat in vec4 v_bg;

uniform float u_bg_alpha;
uniform float u_grayscale;
uniform vec3 u_color_tint;

out vec4 frag_color;

void main() {
  vec3 rgb = v_bg.rgb * u_color_tint;
  float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  rgb = mix(rgb, vec3(luma), u_grayscale);
  frag_color = vec4(rgb, v_bg.a * u_bg_alpha);
}
