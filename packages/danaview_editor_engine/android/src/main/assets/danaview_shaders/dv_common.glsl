// OWNER: AND-09
// Shared GLSL ES 1.00 helpers of ARCH 11.6, prepended to every fragment shader by ShaderSources
// (after the program's extension and define lines). Colours are gamma-encoded BT.709 with colour
// management off; smoothstep is spelled out because GLSL leaves it undefined for e0 >= e1.
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

const vec3 DV_LUMA = vec3(0.2126, 0.7152, 0.0722);

// GLSL smoothstep for e0 < e1.
float dvSmooth(float e0, float e1, float x) {
  float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// Signed distance to a box of half size h with corner radius r (negative inside).
float dvRoundedBoxSdf(vec2 p, vec2 h, float r) {
  vec2 q = abs(p) - h + vec2(r);
  return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Ellipse distance (|p/h| - 1) * min(h); far outside when degenerate.
float dvEllipseSdf(vec2 p, vec2 h) {
  if (!(h.x > 0.0 && h.y > 0.0)) return 1.0e6;
  return (length(p / h) - 1.0) * min(h.x, h.y);
}

// 1 - smoothstep(-f, f, sd), or inside iff sd < 0 when f = 0.
float dvEdgeAlpha(float sd, float f) {
  if (!(f > 0.0)) return sd < 0.0 ? 1.0 : 0.0;
  return 1.0 - dvSmooth(-f, f, sd);
}

// Rotates d by -deg into the frame of a shape rotated deg clockwise (y down); cs = (cos, sin).
vec2 dvUnrotate(vec2 d, vec2 cs) {
  return vec2(cs.x * d.x + cs.y * d.y, -cs.y * d.x + cs.x * d.y);
}
