// OWNER: AND-09
// dv_place: LayerPlaceEffect (ARCH 13.3 "GL effects", 11.6 rows sharpen .. canvas mask) and, with
// DV_SPRITE, the SpriteBandEffect pass (11.6 "Sprite"). Every pixel of the canvas-render-size
// output is mapped to base-local px with the inverse of the placement matrix
// M = T(cx, cy) R(r) S(s (fx ? -1 : 1), s (fy ? -1 : 1)) T(-base / 2) (uInv already includes the
// render scale); inside the layer box the layer texture is sampled (bilinear, averaged over the
// pixel footprint when the texture is minified), then sharpen (at render resolution), vignette,
// item mask, opacity, canvas masks and a 1 px antialiased box edge. Output: STRAIGHT alpha,
// GL-oriented, transparent outside the layer (the Media3 compositor and LayerCompositorGl blend
// with glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)).
uniform sampler2D uTex;        // layer raster (premultiplied) or sprite (premultiplied)
uniform vec2 uTexSize;
uniform vec2 uOutSize;         // render size in px
uniform vec4 uInv;             // local.x = x*X + z*Y + uInvT.x, local.y = y*X + w*Y + uInvT.y
uniform vec2 uInvT;
uniform vec2 uBase;            // layer box in base-local px
uniform vec4 uSample;          // texture px per local px (x, y), taps (x, y)
uniform float uOpacity;
uniform vec2 uCanvasPerRender; // canvas px per render px
uniform vec4 uCm[8];           // canvas masks: centre (canvas px), half size
uniform vec4 uCmB[8];          // cos, sin (unrotate), feather (px), inverted
uniform float uCmCount;
uniform vec2 uAa;              // antialiased edge on, render px per local px
#ifdef DV_SPRITE
uniform sampler2D uGlyphs;     // glyph order per texel: luminance = high byte, alpha = low byte
uniform vec2 uTapStep;         // sprite px covered by the taps (the reference raster texel footprint)
uniform vec2 uReveal;          // animated reveal on, glyphs shown = floor(reveal)
#else
uniform float uSolidOn;
uniform vec4 uSolid;           // premultiplied solid colour
uniform float uSharpen;        // sharpen * 1.5
uniform vec2 uSharpStep;       // local px per reference raster px
uniform vec2 uVignette;        // amount, aspect = base.w / base.h
uniform vec4 uMaskA;           // centre, half size (base px)
uniform vec4 uMaskB;           // cos, sin (unrotate), corner radius, feather f
uniform vec4 uMaskC;           // shape (0 none, 1 rect, 2 ellipse), opacity, inverted, unused
#endif

vec4 dvTex(vec2 t) {
  return texture2D(uTex, vec2(t.x / uTexSize.x, 1.0 - t.y / uTexSize.y));
}

#ifdef DV_SPRITE
float dvGlyph(vec2 t) {
  vec2 g = clamp(floor(t), vec2(0.0), uTexSize - 1.0);
  vec4 v = texture2D(uGlyphs, vec2((g.x + 0.5) / uTexSize.x, 1.0 - (g.y + 0.5) / uTexSize.y));
  return floor(v.r * 255.0 + 0.5) * 256.0 + floor(v.a * 255.0 + 0.5);
}

// The sprite at local px L: taps over the footprint of one reference raster texel; with an
// animated reveal a tap is kept iff its glyph < floor(reveal) (dropped taps count as transparent).
vec4 dvSample(vec2 L) {
  vec2 q = L * uSample.xy;
  vec4 acc = vec4(0.0);
  for (int sy = 0; sy < 8; sy++) {
    if (float(sy) < uSample.w) {
      for (int sx = 0; sx < 8; sx++) {
        if (float(sx) < uSample.z) {
          vec2 p = q + ((vec2(float(sx), float(sy)) + 0.5) / uSample.zw - 0.5) * uTapStep;
          vec4 c = dvTex(p);
          if (uReveal.x > 0.5 && !(dvGlyph(p) < uReveal.y)) c = vec4(0.0);
          acc += c;
        }
      }
    }
  }
  return acc / (uSample.z * uSample.w);
}
#else
// The layer raster at local px L, averaged over the output pixel's footprint when minified.
vec4 dvSample(vec2 L) {
  vec2 t = L * uSample.xy;
  if (uSample.z <= 1.0) return dvTex(t);
  vec2 dx = vec2(uInv.x, uInv.y) * uSample.xy;
  vec2 dy = vec2(uInv.z, uInv.w) * uSample.xy;
  vec4 acc = vec4(0.0);
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
  return acc / (uSample.z * uSample.z);
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
#endif

float dvCanvasMask(vec2 P, vec4 m, vec4 n) {
  vec2 p = dvUnrotate(P - m.xy, n.xy);
  float a = dvEdgeAlpha(dvRoundedBoxSdf(p, m.zw, 0.0), n.z);
  return n.w > 0.5 ? 1.0 - a : a;
}

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
  if (!(cov > 0.0)) {
    gl_FragColor = vec4(0.0);
    return;
  }
  vec4 c;
#ifdef DV_SPRITE
  c = dvSample(L);
#else
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
#endif
  float k = uOpacity * cov;
  vec2 P = X * uCanvasPerRender;
  for (int i = 0; i < 8; i++) {
    if (float(i) < uCmCount) k *= dvCanvasMask(P, uCm[i], uCmB[i]);
  }
  c *= k;
  gl_FragColor = c.a > 0.0 ? vec4(clamp(c.rgb / c.a, 0.0, 1.0), c.a) : vec4(0.0);
}
