// OWNER: AND-09
// dv_look: the LayerLookEffect pass (ARCH 13.3 "GL effects", 11.6 rows chroma key .. LUT, D-08).
// Renders the layer raster: the cropped, display-oriented source is box-filtered onto an
// outW x outH raster (uTaps.x x uTaps.y bilinear taps per texel, the API-03 reference renderer's
// footprint supersampling), then chroma key + spill, grade and LUT run on the straight colour.
// Output: premultiplied RGBA, GL-oriented (framebuffer row 0 = bottom of the image).
// DV_EXTERNAL selects a samplerExternalOES source (HardwareBuffer / SurfaceTexture frames).
#ifdef DV_EXTERNAL
uniform samplerExternalOES uTex;
#else
uniform sampler2D uTex;
#endif
uniform mat3 uSrcXform;        // normalized top-down source position -> texture coordinate
uniform vec2 uSrcSize;         // source size in px (display oriented)
uniform float uSrcPremultiplied;
uniform vec4 uCrop;            // crop origin (source px, top-down), source px per raster px
uniform vec2 uOutSize;         // raster size in px
uniform vec2 uTaps;            // taps per raster texel (x, y), 1..8
uniform float uChromaOn;
uniform vec4 uChroma;          // key Cb, key Cr, edge0 = sim/4, edge1 = edge0 + max(0.001, smooth/4)
uniform vec4 uSpill;           // normalized key direction, spill amount, enabled
uniform float uGradeOn;
uniform vec4 uAdjA;            // exposure, brightness, contrast, highlights
uniform vec4 uAdjB;            // shadows, saturation, temperature, tint
uniform sampler2D uLut;        // N tiles of N x N (red across, green down) in a grid of uLutInfo.y columns
uniform vec4 uLutInfo;         // N, tiles per row, texture width, texture height
uniform float uLutI;           // intensity; 0 = no LUT
uniform float uMatte;          // 1 = show the keyed alpha as opaque grey (matte editing mode)

vec4 dvSource(vec2 sourcePx) {
  vec2 tc = (uSrcXform * vec3(sourcePx / uSrcSize, 1.0)).xy;
  vec4 c = texture2D(uTex, tc);
  if (uSrcPremultiplied < 0.5) c.rgb *= c.a;
  return c;
}

vec4 dvChroma(vec3 c, float a) {
  float y = dot(c, DV_LUMA);
  vec2 cc = vec2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
  float k = dvSmooth(uChroma.z, uChroma.w, length(cc - uChroma.xy));
  if (uSpill.w > 0.5) {
    float p = max(0.0, dot(cc, uSpill.xy)) * uSpill.z;
    cc -= uSpill.xy * p;
    float r = y + 1.5748 * cc.y;
    float b = y + 1.8556 * cc.x;
    float g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
    c = clamp(vec3(r, g, b), 0.0, 1.0);
  }
  return vec4(c, a * k);
}

vec3 dvGrade(vec3 c) {
  // Exposure: pow(pow(c, 2.2) * 2^(2e), 1/2.2) = c * 2^(2e/2.2) for c > 0, 0 otherwise.
  if (uAdjA.x != 0.0) c = max(c, vec3(0.0)) * exp2(2.0 * uAdjA.x / 2.2);
  c = (c + uAdjA.y / 4.0 - 0.5) * (1.0 + uAdjA.z) + 0.5;
  float y = dot(c, DV_LUMA);
  c += uAdjA.w / 4.0 * dvSmooth(0.5, 1.0, y) + uAdjB.x / 4.0 * (1.0 - dvSmooth(0.0, 0.5, y));
  float ys = dot(c, DV_LUMA);
  c = mix(vec3(ys), c, 1.0 + uAdjB.y);
  c *= vec3(1.0 + uAdjB.z / 10.0, 1.0 - uAdjB.w / 10.0, 1.0 - uAdjB.z / 10.0);
  return clamp(c, 0.0, 1.0);
}

// Bilinear lookup inside blue slice `slice` at grid position rg (0 .. N-1).
vec3 dvLutSlice(float slice, vec2 rg) {
  float ty = floor((slice + 0.5) / uLutInfo.y);
  float tx = slice - ty * uLutInfo.y;
  vec2 px = vec2(tx, ty) * uLutInfo.x + rg + 0.5;
  return texture2D(uLut, px / uLutInfo.zw).rgb;
}

// Trilinear lookup: bilinear in the two nearest blue slices, then linear between them.
vec3 dvLut(vec3 c) {
  float n1 = uLutInfo.x - 1.0;
  vec3 g = clamp(c, 0.0, 1.0) * n1;
  float z0 = min(floor(g.z), n1 - 1.0);
  return mix(dvLutSlice(z0, g.xy), dvLutSlice(z0 + 1.0, g.xy), g.z - z0);
}

void main() {
  vec2 ij = vec2(gl_FragCoord.x - 0.5, uOutSize.y - gl_FragCoord.y - 0.5);
  vec4 acc = vec4(0.0);
  for (int sy = 0; sy < 8; sy++) {
    if (float(sy) < uTaps.y) {
      for (int sx = 0; sx < 8; sx++) {
        if (float(sx) < uTaps.x) {
          vec2 o = (vec2(float(sx), float(sy)) + 0.5) / uTaps;
          acc += dvSource(uCrop.xy + (ij + o) * uCrop.zw);
        }
      }
    }
  }
  acc /= uTaps.x * uTaps.y;
  if (!(acc.a > 0.0)) {
    gl_FragColor = uMatte > 0.5 ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(0.0);
    return;
  }
  vec3 c = acc.rgb / acc.a;
  float a = acc.a;
  if (uChromaOn > 0.5) {
    vec4 keyed = dvChroma(c, a);
    c = keyed.rgb;
    a = keyed.a;
  }
  if (uGradeOn > 0.5) c = dvGrade(c);
  if (uLutI > 0.0) c = mix(c, dvLut(c), uLutI);
  if (uMatte > 0.5) {
    gl_FragColor = vec4(vec3(a), 1.0);
    return;
  }
  gl_FragColor = vec4(c * a, a);
}
