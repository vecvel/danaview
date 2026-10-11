// OWNER: AND-09
// Full-screen quad of every Danaview GL pass (GLSL ES 1.00, ARCH §13.3 "GL effects"). The
// fragment shaders work on gl_FragCoord (pixel centres), so no varyings are needed.
attribute vec2 aPosition;

void main() {
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
