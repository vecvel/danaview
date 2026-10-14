// OWNER: IOS-09
//
// Danaview Core Image kernels (ARCH §11.6 render math, D-08 stage order, ARCH §13.2), written in the
// Metal Shading Language for Core Image and PREBUILT with `-fcikernel` (IOS-01 §3, V-N9): Xcode 26
// ships no Metal toolchain, so the app build never compiles this file (podspec `preserve_paths`).
// Rebuild the metallibs with `build_kernels.sh` (next to this file) whenever this source changes and
// commit Prebuilt/ (dv_kernels.iphoneos.metallib, dv_kernels.iphonesimulator.metallib, BUILD_INFO.txt).
//
// Conventions (Kernels.swift is the only caller):
// * Core Image hands kernels PREMULTIPLIED colours; the pointwise maths of §11.6 runs on straight
//   alpha, so dv_look un-premultiplies, works and re-premultiplies. Colour management is off
//   (CIContext working/output colour space NSNull): values are gamma-encoded BT.709.
// * Core Image coordinates are y-up; the plan is y-down. Kernels that depend on position take the
//   rectangle/height they need to flip (`box`, `canvasH`).
// * Kernels that read neighbours (blur, sharpen) are applied by Kernels.swift on a clampedToExtent()
//   input with an INFINITE output extent and then cropped (IOS-01 §2.5 DOD rule).
// * smoothstep is GLSL's; a zero-width edge is `sd < 0 ? 1 : 0` (API-03 render_math.dart).

#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

namespace dvk {

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);
constant float kCbScale = 1.8556;
constant float kCrScale = 1.5748;

static inline float luma(float3 c) { return dot(c, kLuma); }

static inline float2 cbcr(float3 c) {
    float y = luma(c);
    return float2((c.b - y) / kCbScale, (c.r - y) / kCrScale);
}

static inline float sstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// 1 − smoothstep(−f, f, sd), or the hard edge `sd < 0` when f = 0.
static inline float edgeAlpha(float sd, float f) {
    if (f > 0.0f) return 1.0f - sstep(-f, f, sd);
    return sd < 0.0f ? 1.0f : 0.0f;
}

/// Signed distance to a box of half-size h with corner radius r (negative inside).
static inline float boxSdf(float2 p, float2 h, float r) {
    float2 q = abs(p) - h + r;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

/// (‖p/h‖ − 1)·min(h): exact zero contour, exact for circles; huge when degenerate.
static inline float ellipseSdf(float2 p, float2 h) {
    if (!(h.x > 0.0f && h.y > 0.0f)) return 1.0e9f;
    return (length(p / h) - 1.0f) * min(h.x, h.y);
}

/// Rotates d by −r (cs = (cos r, sin r)): into the frame of a shape rotated r clockwise, y down.
static inline float2 unrotate(float2 d, float2 cs) {
    return float2(cs.x * d.x + cs.y * d.y, -cs.y * d.x + cs.x * d.y);
}

/// Exposure of one component: pow(pow(v, 2.2)·k, 1/2.2), negative treated as 0.
static inline float expose(float v, float k) {
    return v > 0.0f ? pow(pow(v, 2.2f) * k, 1.0f / 2.2f) : 0.0f;
}

/// One blue slice of the tiled LUT: bilinear (hardware) sample of tile z at (x, y) grid units.
/// lutp = (n, cols, intensity, enabled); lutH = texture height (CI y-up flip).
static inline float3 lutSlice(coreimage::sampler lut, float x, float y, float z, float n, float cols, float lutH) {
    float row = floor(z / cols);
    float col = z - row * cols;
    float px = col * n + x + 0.5f;
    float pyDown = row * n + y + 0.5f;
    return lut.sample(lut.transform(float2(px, lutH - pyDown))).rgb;
}

static inline float3 lutLookup(coreimage::sampler lut, float3 c, float n, float cols, float lutH) {
    float n1 = n - 1.0f;
    float3 g = clamp(c, 0.0f, 1.0f) * n1;
    float z0 = min(floor(g.z), n1 - 1.0f);
    float fz = g.z - z0;
    float3 c0 = lutSlice(lut, g.x, g.y, z0, n, cols, lutH);
    float3 c1 = lutSlice(lut, g.x, g.y, z0 + 1.0f, n, cols, lutH);
    return mix(c0, c1, fz);
}

}  // namespace dvk

extern "C" { namespace coreimage {

/// Per-layer look (D-08: crop → chroma key + spill → grade → LUT).
///   src     the source image; the output pixel p samples src at p + crop.xy (crop sampling)
///   lut     tiled LUT texture (N tiles of N×N in a ⌈√N⌉-column grid), any 1×1 image when off
///   crop    (originX, originY, 0, 0) in src coordinates
///   key     (Cb_k, Cr_k, s0 = sim·0.25, s1 = max(0.001, smooth·0.25))
///   chroma  (enabled, spill, normalized key Cb, normalized key Cr)
///   g1      (exposure multiplier exp2(2·exposure) or 0 when exposure is 0, brightness, contrast, highlights)
///   g2      (shadows, saturation, temperature, tint)
///   lutp    (n, cols, intensity, enabled)
///   lutH    LUT texture height
float4 dv_look(sampler src, sampler lut, float4 crop, float4 key, float4 chroma, float4 g1, float4 g2,
               float4 lutp, float lutH, destination dest) {
    float4 s = src.sample(src.transform(dest.coord() + crop.xy));
    float a = s.a;
    float3 c = a > 0.0f ? s.rgb / a : float3(0.0f);

    if (chroma.x > 0.5f) {
        float2 cc = dvk::cbcr(c);
        float d = length(cc - key.xy);
        float ka = dvk::sstep(key.z, key.z + key.w, d);
        if (chroma.y > 0.0f) {
            float y = dvk::luma(c);
            float2 k = chroma.zw;
            float p = max(0.0f, dot(cc, k)) * chroma.y;
            cc -= k * p;
            float r = y + dvk::kCrScale * cc.y;
            float b = y + dvk::kCbScale * cc.x;
            float g = (y - 0.2126f * r - 0.0722f * b) / 0.7152f;
            c = clamp(float3(r, g, b), 0.0f, 1.0f);
        }
        a *= ka;
    }

    // Grade (exposure → brightness/contrast → highlights/shadows → saturation → temperature/tint).
    if (g1.x > 0.0f) {
        c = float3(dvk::expose(c.r, g1.x), dvk::expose(c.g, g1.x), dvk::expose(c.b, g1.x));
    }
    c = (c + g1.y / 4.0f - 0.5f) * (1.0f + g1.z) + 0.5f;
    float y = dvk::luma(c);
    c += g1.w / 4.0f * dvk::sstep(0.5f, 1.0f, y) + g2.x / 4.0f * (1.0f - dvk::sstep(0.0f, 0.5f, y));
    y = dvk::luma(c);
    c = mix(float3(y), c, 1.0f + g2.y);
    c *= float3(1.0f + g2.z / 10.0f, 1.0f - g2.w / 10.0f, 1.0f - g2.z / 10.0f);
    c = clamp(c, 0.0f, 1.0f);

    if (lutp.w > 0.5f) {
        float3 l = dvk::lutLookup(lut, c, lutp.x, lutp.y, lutH);
        c = mix(c, l, lutp.z);
    }
    return float4(c * a, a);
}

/// Horizontal pass of the separable Gaussian (weights exp(−i²/2σ²), i = −⌈3σ⌉…⌈3σ⌉, normalized), all
/// four premultiplied channels. Applied to a clamped input (clamp-to-edge).
float4 dv_blur_h(sampler src, float sigma, destination dest) {
    float2 dc = dest.coord();
    int r = int(ceil(3.0f * sigma));
    float4 acc = float4(0.0f);
    float wsum = 0.0f;
    for (int i = -r; i <= r; i++) {
        float w = exp(-float(i * i) / (2.0f * sigma * sigma));
        acc += w * src.sample(src.transform(dc + float2(float(i), 0.0f)));
        wsum += w;
    }
    return acc / wsum;
}

/// Vertical pass of dv_blur_h.
float4 dv_blur_v(sampler src, float sigma, destination dest) {
    float2 dc = dest.coord();
    int r = int(ceil(3.0f * sigma));
    float4 acc = float4(0.0f);
    float wsum = 0.0f;
    for (int i = -r; i <= r; i++) {
        float w = exp(-float(i * i) / (2.0f * sigma * sigma));
        acc += w * src.sample(src.transform(dc + float2(0.0f, float(i))));
        wsum += w;
    }
    return acc / wsum;
}

/// Sharpen on premultiplied RGB: c += gain·(c − box3×3(c)), gain = sharpen·1.5, clamped to [0, alpha];
/// alpha unchanged. Applied to a clamped input (clamp-to-edge box).
float4 dv_sharpen(sampler src, float gain, destination dest) {
    float2 dc = dest.coord();
    float4 c = src.sample(src.transform(dc));
    float3 box = float3(0.0f);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            box += src.sample(src.transform(dc + float2(float(dx), float(dy)))).rgb;
        }
    }
    float3 o = clamp(c.rgb + gain * (c.rgb - box / 9.0f), 0.0f, c.a);
    return float4(o, c.a);
}

/// Vignette and item mask over the layer box (premultiplied in and out).
///   box    (x0, y0, w, h): the layer box in CI coordinates; u = (x − x0)/w, v = 1 − (y − y0)/h (y down)
///   vig    (amount, aspect = base.w/base.h, 0, 0): RGB *= 1 − amount·smoothstep(0.35, 1, d)
///   mgeom  (cx, cy, base.w, base.h): mask centre (layer-normalized) and base size (px)
///   msize  (half w, half h, corner radius, feather f) in base px
///   mrot   (cos r, sin r, 0, 0)
///   mopt   (enabled, shape 0 rect / 1 ellipse, inv, op): all channels *= mix(1, a, op)
float4 dv_vignette_mask(sample_t s, float4 box, float4 vig, float4 mgeom, float4 msize, float4 mrot, float4 mopt,
                        destination dest) {
    float2 dc = dest.coord();
    float u = (dc.x - box.x) / box.z;
    float v = 1.0f - (dc.y - box.y) / box.w;
    float4 o = s;
    if (vig.x > 0.0f) {
        float2 q = float2((u - 0.5f) * vig.y, v - 0.5f);
        float d = length(q) / (0.5f * sqrt(vig.y * vig.y + 1.0f));
        o.rgb *= 1.0f - vig.x * dvk::sstep(0.35f, 1.0f, d);
    }
    if (mopt.x > 0.5f) {
        float2 p = dvk::unrotate(float2((u - mgeom.x) * mgeom.z, (v - mgeom.y) * mgeom.w), mrot.xy);
        float sd = mopt.y > 0.5f ? dvk::ellipseSdf(p, msize.xy) : dvk::boxSdf(p, msize.xy, msize.z);
        float a = dvk::edgeAlpha(sd, msize.w);
        if (mopt.z > 0.5f) a = 1.0f - a;
        o *= mix(1.0f, a, mopt.w);
    }
    return o;
}

/// Canvas mask (after placement): rect SDF without corner in canvas render px, y down.
///   rect   (cx, cy, half w, half h) in render px (y down)
///   p      (cos r, sin r, feather f in render px, inv)
///   canvasH  render canvas height (flip)
float4 dv_cmask(sample_t s, float4 rect, float4 p, float canvasH, destination dest) {
    float2 dc = dest.coord();
    float2 pt = float2(dc.x, canvasH - dc.y);
    float2 q = dvk::unrotate(pt - rect.xy, p.xy);
    float a = dvk::edgeAlpha(dvk::boxSdf(q, rect.zw, 0.0f), p.z);
    if (p.w > 0.5f) a = 1.0f - a;
    return s * a;
}

/// Sprite reveal: a texel is drawn iff glyph < shown (shown = floor(reveal(t))). The glyph map is an
/// RGBA8 image aligned with the sprite: glyph = R·255 + 256·G·255 (0xFFFF = background).
float4 dv_reveal(sample_t s, sample_t g, float shown) {
    float glyph = round(g.r * 255.0f) + 256.0f * round(g.g * 255.0f);
    return glyph < shown ? s : float4(0.0f);
}

/// Chroma matte preview: the layer's alpha as opaque grey.
float4 dv_matte(sample_t s) {
    return float4(s.a, s.a, s.a, 1.0f);
}

}}
