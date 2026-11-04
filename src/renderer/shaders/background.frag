#version 330 core

flat in vec4 v_bg;

uniform float u_bg_alpha;

out vec4 frag_color;

void main() {
  frag_color = vec4(v_bg.rgb, v_bg.a * u_bg_alpha);
}
