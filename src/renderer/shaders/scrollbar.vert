#version 330 core

uniform vec4 u_rect; // x, y, w, h in pixels
uniform vec2 u_fb; // framebuffer width, height

out vec2 v_local; // local pixel coords within rect (for SDF)

void main() {
  // Reconstruct quad corners from vertex ID (0=TL, 1=TR, 2=BL, 3=BR)
  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
  vec2 px = u_rect.xy + corner * u_rect.zw;
  v_local = corner * u_rect.zw; // 0..w, 0..h;

  // Convert pixel coords to NDC, flip Y (pixels: Y down, NDC: Y up)
  vec2 ndc = (px / u_fb) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
}