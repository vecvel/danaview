// OWNER: AND-09
// dv_blur: one direction of the SeparableBlurEffect (ARCH 11.6 "Blur"): normalized Gaussian
// weights exp(-x^2 / 2 sigma^2) at x = i * step for |x| <= radius (radius = ceil(3 sigma); step > 1
// only for very large radii) on all four premultiplied channels. The raster fills the top-left
// uRasterSize px of its texture (a Media3 effect texture sized for the layer's largest footprint,
// or exactly the raster); reads are clamped to it, which equals clamp-to-edge, and the output goes
// to the top-left uRasterSize px of the bound target of height uOutHeight.
uniform sampler2D uTex;
uniform vec2 uTexSize;         // texture size in px
uniform vec2 uRasterSize;      // raster size in px (top-left part of the texture)
uniform float uOutHeight;      // height of the bound target in px
uniform vec2 uDir;             // (1, 0) horizontal, (0, 1) vertical
uniform vec3 uKernel;          // sigma, radius, step (texels)

// Bilinear read at top-down raster position p (px), clamped to the raster's texel centres.
vec4 dvTap(vec2 p) {
  vec2 c = clamp(p, vec2(0.5), uRasterSize - 0.5);
  return texture2D(uTex, vec2(c.x / uTexSize.x, 1.0 - c.y / uTexSize.y));
}

void main() {
  vec2 p = vec2(gl_FragCoord.x, uOutHeight - gl_FragCoord.y);
  vec2 d = vec2(uDir.x, uDir.y);
  vec4 acc = dvTap(p);
  float wsum = 1.0;
  if (uKernel.y > 0.0) {
    float s2 = 2.0 * uKernel.x * uKernel.x;
    for (int i = 1; i <= 64; i++) {
      float x = float(i) * uKernel.z;
      if (x <= uKernel.y) {
        float w = exp(-x * x / s2);
        acc += w * (dvTap(p + d * x) + dvTap(p - d * x));
        wsum += 2.0 * w;
      }
    }
  }
  gl_FragColor = acc / wsum;
}
