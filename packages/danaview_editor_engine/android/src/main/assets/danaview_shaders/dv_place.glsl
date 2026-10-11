// OWNER: AND-09
// dv_place: LayerPlaceEffect (ARCH 13.3 "GL effects", 11.6 rows sharpen .. canvas mask), also
// the second pass of SpriteBandEffect. Every pixel of the canvas-render-size output is mapped to
// base-local px with the inverse of the placement matrix
// M = T(cx, cy) R(r) S(s (fx ? -1 : 1), s (fy ? -1 : 1)) T(-base / 2) (uInv already includes the
// render scale); inside the layer box the layer raster is sampled (bilinear, averaged over the
// pixel footprint when the raster is minified), then sharpen (at render resolution), vignette,
// item mask, opacity, canvas masks and a 1 px antialiased box edge. Output: STRAIGHT alpha,
// GL-oriented, transparent outside the layer (the Media3 compositor and LayerCompositorGl blend
// with glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)).
// The raster may fill only the top-left uRasterSize px of a larger texture (sprite rasters drawn
// into a reused target); samples are clamped to it, which equals clamp-to-edge.
uniform sampler2D uTex;        // layer raster (premultiplied)
uniform vec2 uTexSize;         // texture size in px
uniform vec2 uRasterSize;      // raster size in px (top-left part of the texture)
uniform vec2 uOutSize;         // render size in px
uniform vec4 uInv;             // local.x = x*X + z*Y + uInvT.x, local.y = y*X + w*Y + uInvT.y
uniform vec2 uInvT;
uniform vec2 uBase;            // layer box in base-local px
uniform vec4 uSample;          // raster px per local px (x, y), footprint taps, unused
uniform float uOpacity;
uniform vec2 uCanvasPerRender; // canvas px per render px
uniform vec4 uCm[8];           // canvas masks: centre (canvas px), half size
uniform vec4 uCmB[8];          // cos, sin (unrotate), feather (px), inverted
uniform float uCmCount;
uniform vec2 uAa;              // antialiased edge on, render px per local px
uniform float uSolidOn;
uniform vec4 uSolid;           // premultiplied solid colour
uniform float uSharpen;        // sharpen * 1.5
uniform vec2 uSharpStep;       // local px per reference raster px
uniform vec2 uVignette;        // amount, aspect = base.w / base.h
uniform vec4 uMaskA;           // centre, half size (base px)
uniform vec4 uMaskB;           // cos, sin (unrotate), corner radius, feather f
uniform vec4 uMaskC;           // shape (0 none, 1 rect, 2 ellipse), opacity, inverted, unused

vec4 dvTex(vec2 t) {
  vec2 c = clamp(t, vec2(0.5), uRasterSize - 0.5);
  return texture2D(uTex, vec2(c.x / uTexSize.x, 1.0 - c.y / uTexSize.y));
}

// The layer raster at local px L, averaged over the output pixel's footprint when minified.
vec4 dvSample(vec2 L) {
  vec2 t = L * uSample.xy;
  vec4 acc = vec4(0.0);
  if (uSample.z <= 1.0) {
    acc = dvTex(t);
  } else {
    vec2 dx = vec2(uInv.x, uInv.y) * uSample.xy;
    vec2 dy = vec2(uInv.z, uInv.w) * uSample.xy;
    for (int sy = 0; sy < 8; sy++) {
      if (float(sy) < uSample.z) {
        for (int sx = 0; sx < 8; sx++) {
          if (float(sx) < uSample.z) {
            vec2 o = (vec2(float(sx), float(sy)) + 0.5) / uSample.z - 0.5;
            acc += dvTex(t + dx * o.x + dy * o.y);
          }
        }
      }
    }
    acc /= uSample.z * uSample.z;
  }
  return acc;
}

float dvVignetteFactor(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(uVignette.y, 1.0);
  float d = length(p) / (0.5 * sqrt(uVignette.y * uVignette.y + 1.0));
  return 1.0 - uVignette.x * dvSmooth(0.35, 1.0, d);
}

float dvMaskAlpha(vec2 L) {
  vec2 p = dvUnrotate(L - uMaskA.xy, uMaskB.xy);
  float sd = uMaskC.x < 1.5 ? dvRoundedBoxSdf(p, uMaskA.zw, uMaskB.z) : dvEllipseSdf(p, uMaskA.zw);
  float a = dvEdgeAlpha(sd, uMaskB.w);
  if (uMaskC.z > 0.5) a = 1.0 - a;
  return mix(1.0, a, uMaskC.y);
}

float dvCanvasMask(vec2 P, vec4 m, vec4 n) {
  vec2 p = dvUnrotate(P - m.xy, n.xy);
  float a = dvEdgeAlpha(dvRoundedBoxSdf(p, m.zw, 0.0), n.z);
  return n.w > 0.5 ? 1.0 - a : a;
}

// No early return: the emulator's GLSL translator (SwiftShader, Pixel_9_Pro_XL_API_35) dropped
// pixels when an early return preceded the canvas-mask loop (measured 2026-10-11).
void main() {
  vec2 X = vec2(gl_FragCoord.x, uOutSize.y - gl_FragCoord.y);
  vec2 L = vec2(uInv.x * X.x + uInv.z * X.y, uInv.y * X.x + uInv.w * X.y) + uInvT;
  vec2 uv = L / uBase;
  float cov;
  if (uAa.x > 0.5) {
    float inside = min(min(L.x, uBase.x - L.x), min(L.y, uBase.y - L.y)) * uAa.y;
    cov = clamp(0.5 + inside, 0.0, 1.0);
  } else {
    cov = (uv.x >= 0.0 && uv.x < 1.0 && uv.y >= 0.0 && uv.y < 1.0) ? 1.0 : 0.0;
  }
  vec4 c = vec4(0.0);
  if (cov > 0.0) {
    if (uSolidOn > 0.5) {
      c = uSolid;
    } else {
      c = dvSample(L);
      if (uSharpen > 0.0) {
        vec4 box = vec4(0.0);
        for (int j = -1; j <= 1; j++) {
          for (int i = -1; i <= 1; i++) {
            box += dvSample(L + vec2(float(i), float(j)) * uSharpStep);
          }
        }
        c.rgb = clamp(c.rgb + uSharpen * (c.rgb - box.rgb / 9.0), vec3(0.0), vec3(c.a));
      }
      if (uVignette.x > 0.0) c.rgb *= dvVignetteFactor(uv);
      if (uMaskC.x > 0.5) c *= dvMaskAlpha(L);
    }
    float k = uOpacity * cov;
    vec2 P = X * uCanvasPerRender;
    for (int i = 0; i < 8; i++) {
      if (float(i) < uCmCount) k *= dvCanvasMask(P, uCm[i], uCmB[i]);
    }
    c *= k;
  }
  gl_FragColor = c.a > 0.0 ? vec4(clamp(c.rgb / c.a, 0.0, 1.0), c.a) : vec4(0.0);
}
