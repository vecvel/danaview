// OWNER: AND-09
// dv_blur: one direction of the SeparableBlurEffect (ARCH 11.6 "Blur"): normalized Gaussian
// weights exp(-x^2 / 2 sigma^2) at x = i * step for |x| <= radius (radius = ceil(3 sigma); step > 1
// only for very large radii), clamp-to-edge through the texture wrap mode, on all four
// premultiplied channels. Input and output have the same size; taps land on texel centres.
uniform sampler2D uTex;
uniform vec2 uTexSize;
uniform vec2 uDir;             // (1, 0) horizontal, (0, 1) vertical
uniform vec3 uKernel;          // sigma, radius, step (texels)

void main() {
  vec2 tc = gl_FragCoord.xy / uTexSize;
  vec2 d = uDir / uTexSize;
  vec4 acc = texture2D(uTex, tc);
  float wsum = 1.0;
  if (uKernel.y > 0.0) {
    float s2 = 2.0 * uKernel.x * uKernel.x;
    for (int i = 1; i <= 64; i++) {
      float x = float(i) * uKernel.z;
      if (x <= uKernel.y) {
        float w = exp(-x * x / s2);
        acc += w * (texture2D(uTex, tc + d * x) + texture2D(uTex, tc - d * x));
        wsum += 2.0 * w;
      }
    }
  }
  gl_FragColor = acc / wsum;
}
