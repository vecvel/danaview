// OWNER: API-03
//
// Render math of ARCH §11.6 (restated normatively in danaview_editor_core
// `schema/effects_reference.md`): every per-layer stage on straight-alpha, gamma-encoded BT.709
// values in [0, 1] with colour management off. The Metal Core Image kernels (IOS-09/IOS-10), the
// GLSL ES shaders (AND-09/AND-17) and the Dart reference renderer (`../reference/`) implement the
// same formulas; `test_fixtures/vectors/render_math.json` pins them for all three.
//
// Interpretations fixed here where the §11.6 table is silent (also in test_fixtures/vectors/README.md):
// * smoothstep is GLSL's; a zero-width edge is `1 − step(0, sd)`, i.e. inside iff sd < 0;
// * the chroma stage clamps the spill-rebuilt RGB to [0, 1] (the rebuild can leave the gamut);
// * blur and sharpen filter **premultiplied** RGBA: blur all four channels, sharpen RGB only,
//   clamped to [0, alpha]; vignette scales RGB; mask, opacity and canvas masks scale alpha;
// * the item mask SDF is evaluated in base px (aspect-correct): the point is
//   `((u − cx)·base.w, (v − cy)·base.h)` rotated by −r, the box half-size `(w·base.w/2, h·base.h/2)`,
//   the corner radius `corner·min(w·base.w, h·base.h)` and `f = feather·0.25·min(w·base.w, h·base.h)`;
// * the ellipse distance is `(‖(px/hx, py/hy)‖ − 1)·min(hx, hy)` (exact zero contour, exact for circles);
// * canvas masks are rectangles without corners; their `feather` is `f` in canvas px;
// * a missing `base` is the canvas size (solids, images, media) or `sw/sscale × sh/sscale` (sprites);
// * the canvas `bg` is drawn opaque (its alpha is ignored).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/eval.dart' show Affine2, Size2, cosSinDeg, planPlacementMatrix;
import 'package:danaview_editor_core/plan.dart';

import 'lut_table.dart';
import 'raster.dart';

/// A colour of the render pipeline (ARCH §11.6): gamma-encoded BT.709 components in [0, 1] (they
/// may leave the range between grade steps) plus alpha. Whether the colour is straight or
/// premultiplied is stated by the function that takes or returns it.
@immutable
final class RenderRgba {
  /// Creates a colour.
  const RenderRgba(this.r, this.g, this.b, [this.a = 1.0]);

  /// The colour of a plan ARGB int (`0xAARRGGBB`, ARCH §11.2 colours), straight alpha.
  factory RenderRgba.fromArgb(int argb) =>
      RenderRgba(((argb >> 16) & 0xFF) / 255, ((argb >> 8) & 0xFF) / 255, (argb & 0xFF) / 255, ((argb >> 24) & 0xFF) / 255);

  /// The opaque colour of a `0xRRGGBB` int (chroma `key`).
  factory RenderRgba.fromRgb(int rgb) => RenderRgba(((rgb >> 16) & 0xFF) / 255, ((rgb >> 8) & 0xFF) / 255, (rgb & 0xFF) / 255);

  /// The colour of `[r, g, b]` or `[r, g, b, a]`.
  factory RenderRgba.fromList(List<num> v) =>
      RenderRgba(v[0].toDouble(), v[1].toDouble(), v[2].toDouble(), v.length > 3 ? v[3].toDouble() : 1.0);

  /// Opaque black.
  static const RenderRgba black = RenderRgba(0, 0, 0);

  /// Fully transparent (premultiplied zero).
  static const RenderRgba transparent = RenderRgba(0, 0, 0, 0);

  /// Red.
  final double r;

  /// Green.
  final double g;

  /// Blue.
  final double b;

  /// Alpha.
  final double a;

  /// `Y = dot(c, (0.2126, 0.7152, 0.0722))`.
  double get luma => RenderMath.luma(r, g, b);

  /// This colour with alpha [alpha].
  RenderRgba withAlpha(double alpha) => RenderRgba(r, g, b, alpha);

  /// `[r, g, b, a]`.
  List<double> toList() => [r, g, b, a];

  /// Whether every component is within [eps] of [o]'s.
  bool closeTo(RenderRgba o, double eps) =>
      (r - o.r).abs() <= eps && (g - o.g).abs() <= eps && (b - o.b).abs() <= eps && (a - o.a).abs() <= eps;

  @override
  bool operator ==(Object other) => other is RenderRgba && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => 'RenderRgba($r, $g, $b, $a)';
}

/// The per-layer stages of ARCH §11.6 in D-08 order (chroma key + spill → grade → LUT → blur →
/// sharpen → vignette → mask → place → canvas masks → composite), plus sprite reveal. Pointwise
/// stages take and return **straight** colours; spatial stages work on premultiplied
/// [RenderRaster]s. Audio gain math lives in `AudioMath` (ARCH §11.6 Audio row).
abstract final class RenderMath {
  /// BT.709 luma weight of red.
  static const double lumaR = 0.2126;

  /// BT.709 luma weight of green.
  static const double lumaG = 0.7152;

  /// BT.709 luma weight of blue.
  static const double lumaB = 0.0722;

  /// `Cb = (B − Y) / 1.8556`.
  static const double cbScale = 1.8556;

  /// `Cr = (R − Y) / 1.5748`.
  static const double crScale = 1.5748;

  /// Blur σ in plan-canvas px per unit of `detail.blur` and px of `min(W, H)`.
  static const double blurSigmaPerUnit = 0.03;

  /// Blur is skipped below this σ (in the px of the image being blurred).
  static const double blurMinSigma = 0.5;

  /// Sharpen gain per unit of `detail.sharpen`.
  static const double sharpenGain = 1.5;

  /// Glyph id of sprite pixels outside every glyph (ARCH §10.3).
  static const int spriteBackgroundGlyph = 0xFFFF;

  /// `Y(c) = dot(c, (0.2126, 0.7152, 0.0722))`.
  static double luma(double r, double g, double b) => r * lumaR + g * lumaG + b * lumaB;

  /// Clamps [v] to [0, 1].
  static double clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

  /// GLSL `mix(x, y, a) = x·(1 − a) + y·a`.
  static double mix(double x, double y, double a) => x * (1 - a) + y * a;

  /// GLSL `smoothstep(e0, e1, x)` (requires `e0 < e1`).
  static double smoothstep(double e0, double e1, double x) {
    final t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
  }

  // ---------------------------------------------------------------------------------------------
  // Chroma key + spill (keyed on source colours, D-08).
  // ---------------------------------------------------------------------------------------------

  /// `(Cb, Cr)` of a colour.
  static (double cb, double cr) chromaOf(double r, double g, double b) {
    final y = luma(r, g, b);
    return ((b - y) / cbScale, (r - y) / crScale);
  }

  /// The key alpha `a = smoothstep(s0, s0 + s1, d)` with `s0 = sim·0.25`,
  /// `s1 = max(0.001, smooth·0.25)` and `d` the CbCr distance to the key.
  static double chromaKeyAlpha(RenderRgba c, PlanChroma chroma) {
    final key = RenderRgba.fromRgb(chroma.key);
    final (cb, cr) = chromaOf(c.r, c.g, c.b);
    final (kb, kr) = chromaOf(key.r, key.g, key.b);
    final db = cb - kb;
    final dr = cr - kr;
    final d = math.sqrt(db * db + dr * dr);
    final s0 = chroma.sim * 0.25;
    final s1 = math.max(0.001, chroma.smooth * 0.25);
    return smoothstep(s0, s0 + s1, d);
  }

  /// Chroma key and spill on a straight colour: `alpha *= a` ([chromaKeyAlpha]); then
  /// `(Cb, Cr) −= k·max(0, dot((Cb, Cr), k))·spill` with `k = normalize(Cbk, Crk)`, RGB rebuilt
  /// keeping Y and clamped to [0, 1].
  static RenderRgba chromaKey(RenderRgba c, PlanChroma chroma) {
    final a = chromaKeyAlpha(c, chroma);
    final key = RenderRgba.fromRgb(chroma.key);
    final (kb, kr) = chromaOf(key.r, key.g, key.b);
    final len = math.sqrt(kb * kb + kr * kr);
    var r = c.r;
    var g = c.g;
    var b = c.b;
    if (len > 0 && chroma.spill > 0) {
      final y = luma(r, g, b);
      var (cb, cr) = chromaOf(r, g, b);
      final nx = kb / len;
      final ny = kr / len;
      final p = math.max(0.0, cb * nx + cr * ny) * chroma.spill;
      cb -= nx * p;
      cr -= ny * p;
      r = y + crScale * cr;
      b = y + cbScale * cb;
      g = (y - lumaR * r - lumaB * b) / lumaG;
      r = clamp01(r);
      g = clamp01(g);
      b = clamp01(b);
    }
    return RenderRgba(r, g, b, c.a * a);
  }

  // ---------------------------------------------------------------------------------------------
  // Grade (exposure → brightness/contrast → highlights/shadows → saturation → temperature/tint).
  // ---------------------------------------------------------------------------------------------

  /// `c = pow(pow(c, 2.2)·exp2(2·exposure), 1/2.2)` (±2 EV). Negative components are treated as 0.
  static RenderRgba exposure(RenderRgba c, double exposure) {
    if (exposure == 0) return c;
    final k = math.pow(2.0, 2 * exposure).toDouble();
    double f(double v) => v <= 0 ? 0.0 : math.pow(math.pow(v, 2.2) * k, 1 / 2.2).toDouble();
    return RenderRgba(f(c.r), f(c.g), f(c.b), c.a);
  }

  /// `c += brightness/4`; `c = (c − 0.5)·(1 + contrast) + 0.5`.
  static RenderRgba brightnessContrast(RenderRgba c, double brightness, double contrast) {
    final k = 1 + contrast;
    final add = brightness / 4;
    double f(double v) => (v + add - 0.5) * k + 0.5;
    return RenderRgba(f(c.r), f(c.g), f(c.b), c.a);
  }

  /// `c += highlights/4 · smoothstep(0.5, 1, Y)`; `c += shadows/4 · (1 − smoothstep(0, 0.5, Y))`
  /// (Y of the input colour for both terms).
  static RenderRgba highlightsShadows(RenderRgba c, double highlights, double shadows) {
    final y = c.luma;
    final add = highlights / 4 * smoothstep(0.5, 1, y) + shadows / 4 * (1 - smoothstep(0, 0.5, y));
    return RenderRgba(c.r + add, c.g + add, c.b + add, c.a);
  }

  /// `c = mix(vec3(Y), c, 1 + saturation)`.
  static RenderRgba saturation(RenderRgba c, double saturation) {
    final y = c.luma;
    final k = 1 + saturation;
    return RenderRgba(mix(y, c.r, k), mix(y, c.g, k), mix(y, c.b, k), c.a);
  }

  /// `c.r *= 1 + temperature/10`; `c.b *= 1 − temperature/10`; `c.g *= 1 − tint/10`; then
  /// `clamp(c, 0, 1)`.
  static RenderRgba temperatureTint(RenderRgba c, double temperature, double tint) => RenderRgba(
        clamp01(c.r * (1 + temperature / 10)),
        clamp01(c.g * (1 - tint / 10)),
        clamp01(c.b * (1 - temperature / 10)),
        c.a,
      );

  /// The whole grade in order; the result is clamped to [0, 1] by [temperatureTint].
  static RenderRgba grade(RenderRgba c, PlanAdjust adj) {
    var o = exposure(c, adj.exposure);
    o = brightnessContrast(o, adj.brightness, adj.contrast);
    o = highlightsShadows(o, adj.highlights, adj.shadows);
    o = saturation(o, adj.saturation);
    return temperatureTint(o, adj.temperature, adj.tint);
  }

  // ---------------------------------------------------------------------------------------------
  // LUT.
  // ---------------------------------------------------------------------------------------------

  /// `c = mix(c, lut(c), i)` with a trilinear lookup in [lut] (input clamped to [0, 1]).
  static RenderRgba lut(RenderRgba c, RenderLut lut, double intensity) {
    if (intensity == 0) return c;
    final (lr, lg, lb) = lut.lookup(c.r, c.g, c.b);
    return RenderRgba(mix(c.r, lr, intensity), mix(c.g, lg, intensity), mix(c.b, lb, intensity), c.a);
  }

  // ---------------------------------------------------------------------------------------------
  // Blur, sharpen, vignette.
  // ---------------------------------------------------------------------------------------------

  /// `σ = blur·0.03·min(W, H)` in plan-canvas px ([canvasW] × [canvasH] is the plan canvas, the
  /// output size for export plans).
  static double blurSigmaCanvasPx(double blur, int canvasW, int canvasH) => blur * blurSigmaPerUnit * math.min(canvasW, canvasH);

  /// [sigmaCanvasPx] converted to source px by the layer's current scale: [canvasPxPerSourcePx]
  /// is `base.w·|xf.s| / (crop width in source px)`.
  static double blurSigmaSourcePx(double sigmaCanvasPx, double canvasPxPerSourcePx) => sigmaCanvasPx / canvasPxPerSourcePx;

  /// [sigmaCanvasPx] converted to render px ([renderScale] render px per canvas px).
  static double blurSigmaRenderPx(double sigmaCanvasPx, double renderScale) => sigmaCanvasPx * renderScale;

  /// Kernel radius `ceil(3σ)`.
  static int blurRadius(double sigma) => (3 * sigma).ceil();

  /// Whether a blur of [sigma] is skipped (`σ < 0.5`).
  static bool blurSkipped(double sigma) => !(sigma >= blurMinSigma);

  /// The normalized 1-D Gaussian weights `exp(−i²/(2σ²))` for `i = −r…r`, `r = ceil(3σ)`.
  static Float64List gaussianKernel(double sigma) {
    final r = blurRadius(sigma);
    final w = Float64List(2 * r + 1);
    var sum = 0.0;
    for (var i = -r; i <= r; i++) {
      final v = math.exp(-(i * i) / (2 * sigma * sigma));
      w[i + r] = v;
      sum += v;
    }
    for (var i = 0; i < w.length; i++) {
      w[i] /= sum;
    }
    return w;
  }

  /// Separable Gaussian blur of a premultiplied raster (horizontal then vertical pass,
  /// clamp-to-edge, all four channels). Returns [src] itself when [blurSkipped].
  static RenderRaster gaussianBlur(RenderRaster src, double sigma) {
    if (blurSkipped(sigma)) return src;
    final k = gaussianKernel(sigma);
    final r = (k.length - 1) ~/ 2;
    final w = src.width;
    final h = src.height;
    final tmp = RenderRaster(w, h);
    final s = src.data;
    final t = tmp.data;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
        for (var i = -r; i <= r; i++) {
          var xx = x + i;
          if (xx < 0) xx = 0;
          if (xx >= w) xx = w - 1;
          final o = (y * w + xx) * 4;
          final wt = k[i + r];
          a0 += s[o] * wt;
          a1 += s[o + 1] * wt;
          a2 += s[o + 2] * wt;
          a3 += s[o + 3] * wt;
        }
        final o = (y * w + x) * 4;
        t[o] = a0;
        t[o + 1] = a1;
        t[o + 2] = a2;
        t[o + 3] = a3;
      }
    }
    final out = RenderRaster(w, h);
    final d = out.data;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
        for (var i = -r; i <= r; i++) {
          var yy = y + i;
          if (yy < 0) yy = 0;
          if (yy >= h) yy = h - 1;
          final o = (yy * w + x) * 4;
          final wt = k[i + r];
          a0 += t[o] * wt;
          a1 += t[o + 1] * wt;
          a2 += t[o + 2] * wt;
          a3 += t[o + 3] * wt;
        }
        final o = (y * w + x) * 4;
        d[o] = a0;
        d[o + 1] = a1;
        d[o + 2] = a2;
        d[o + 3] = a3;
      }
    }
    return out;
  }

  /// `c += sharpen·1.5·(c − box3x3(c))` on the premultiplied RGB of [src] (clamp-to-edge box,
  /// alpha unchanged, RGB clamped to [0, alpha]). Returns [src] itself when [amount] is 0.
  static RenderRaster sharpen(RenderRaster src, double amount) {
    if (amount == 0) return src;
    final w = src.width;
    final h = src.height;
    final s = src.data;
    final out = RenderRaster(w, h);
    final d = out.data;
    final gain = amount * sharpenGain;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          var yy = y + dy;
          if (yy < 0) yy = 0;
          if (yy >= h) yy = h - 1;
          for (var dx = -1; dx <= 1; dx++) {
            var xx = x + dx;
            if (xx < 0) xx = 0;
            if (xx >= w) xx = w - 1;
            final o = (yy * w + xx) * 4;
            b0 += s[o];
            b1 += s[o + 1];
            b2 += s[o + 2];
          }
        }
        final o = (y * w + x) * 4;
        final a = s[o + 3];
        double f(double c, double box) {
          final v = c + gain * (c - box / 9);
          return v < 0 ? 0.0 : (v > a ? a : v);
        }

        d[o] = f(s[o], b0);
        d[o + 1] = f(s[o + 1], b1);
        d[o + 2] = f(s[o + 2], b2);
        d[o + 3] = a;
      }
    }
    return out;
  }

  /// The vignette multiplier `1 − vignette·smoothstep(0.35, 1, d)` with
  /// `d = ‖(uv − 0.5)·(aspect, 1)‖ / ‖(aspect, 1)·0.5‖` over the layer box ([aspect] =
  /// `base.w / base.h`, [u], [v] in [0, 1]).
  static double vignetteFactor(double u, double v, double aspect, double amount) {
    if (amount == 0) return 1;
    final x = (u - 0.5) * aspect;
    final y = v - 0.5;
    final d = math.sqrt(x * x + y * y) / (0.5 * math.sqrt(aspect * aspect + 1));
    return 1 - amount * smoothstep(0.35, 1, d);
  }

  // ---------------------------------------------------------------------------------------------
  // Masks.
  // ---------------------------------------------------------------------------------------------

  /// Signed distance of `(px, py)` to a box of half-size `(hx, hy)` with corner [radius]
  /// (centred at the origin, axis-aligned; negative inside).
  static double roundedBoxSdf(double px, double py, double hx, double hy, double radius) {
    final qx = px.abs() - hx + radius;
    final qy = py.abs() - hy + radius;
    final ox = qx > 0 ? qx : 0.0;
    final oy = qy > 0 ? qy : 0.0;
    final inside = math.min(math.max(qx, qy), 0.0);
    return math.sqrt(ox * ox + oy * oy) + inside - radius;
  }

  /// Ellipse distance `(‖(px/hx, py/hy)‖ − 1)·min(hx, hy)` (exact zero contour); +∞ when the ellipse
  /// is degenerate.
  static double ellipseSdf(double px, double py, double hx, double hy) {
    if (!(hx > 0 && hy > 0)) return double.infinity;
    final nx = px / hx;
    final ny = py / hy;
    return (math.sqrt(nx * nx + ny * ny) - 1) * math.min(hx, hy);
  }

  /// `1 − smoothstep(−f, f, sd)`, or `1 − step(0, sd)` when `f = 0`.
  static double edgeAlpha(double sd, double f) {
    if (!(f > 0)) return sd < 0 ? 1.0 : 0.0;
    return 1 - smoothstep(-f, f, sd);
  }

  /// Rotates `(dx, dy)` by `−deg` (into the frame of a shape rotated `deg` clockwise, y down).
  static (double, double) unrotate(double dx, double dy, double deg) {
    if (deg == 0) return (dx, dy);
    final (cos, sin) = cosSinDeg(deg);
    return (cos * dx + sin * dy, -sin * dx + cos * dy);
  }

  /// The alpha multiplier `mix(1, a, op)` of the item [mask] (values already evaluated at the frame
  /// time) at layer-normalized `(u, v)` of a layer whose `base` is [baseW] × [baseH].
  static double maskAlpha(PlanMask mask, double u, double v, double baseW, double baseH) {
    final (px, py) = unrotate((u - mask.cx) * baseW, (v - mask.cy) * baseH, mask.r);
    final w = mask.w * baseW;
    final h = mask.h * baseH;
    final m = math.min(w, h);
    final sd = switch (mask.shape) {
      PlanMaskShape.rect => roundedBoxSdf(px, py, w / 2, h / 2, mask.corner * m),
      PlanMaskShape.ellipse => ellipseSdf(px, py, w / 2, h / 2),
    };
    var a = edgeAlpha(sd, mask.feather * 0.25 * m);
    if (mask.inv) a = 1 - a;
    return mix(1, a, mask.op);
  }

  /// The alpha multiplier of a canvas mask (values already evaluated, `anim` ignored) at canvas px
  /// `(x, y)`: the rectangle SDF with `f = feather` px, inverted when `inv`.
  static double canvasMaskAlpha(CanvasMask m, double x, double y) {
    final (px, py) = unrotate(x - m.cx, y - m.cy, m.r);
    final sd = roundedBoxSdf(px, py, m.w / 2, m.h / 2, 0);
    final a = edgeAlpha(sd, m.feather);
    return m.inv ? 1 - a : a;
  }

  // ---------------------------------------------------------------------------------------------
  // Place and composite.
  // ---------------------------------------------------------------------------------------------

  /// The placement matrix `M = T(cx, cy)·R(r)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base/2)` from
  /// base-local px to canvas px. Delegates to core geometry (`planPlacementMatrix`, CORE-07), the
  /// same M as `boxAt`.
  static Affine2 placement(PlanTransform xf, PlanSize base, PlanCanvas canvas) =>
      planPlacementMatrix(xf, base, Size2(canvas.w.toDouble(), canvas.h.toDouble()));

  /// The `base` a layer is drawn with: its own, `sw/sscale × sh/sscale` for a sprite without one,
  /// else the canvas size.
  static PlanSize effectiveBase(PlanLayer layer, PlanAsset? asset, PlanCanvas canvas) {
    final own = layer.base;
    if (own != null) return own;
    if (layer.kind == PlanLayerKind.sprite && asset != null && asset.sw != null && asset.sh != null && (asset.sscale ?? 0) > 0) {
      return PlanSize(asset.sw! / asset.sscale!, asset.sh! / asset.sscale!);
    }
    return PlanSize(canvas.w.toDouble(), canvas.h.toDouble());
  }

  /// Premultiplies a straight colour.
  static RenderRgba premultiply(RenderRgba c) => RenderRgba(c.r * c.a, c.g * c.a, c.b * c.a, c.a);

  /// Un-premultiplies a premultiplied colour (transparent stays zero).
  static RenderRgba unpremultiply(RenderRgba c) => c.a > 0 ? RenderRgba(c.r / c.a, c.g / c.a, c.b / c.a, c.a) : RenderRgba.transparent;

  /// Premultiplied source-over: `out = src + dst·(1 − src.a)`.
  static RenderRgba sourceOver(RenderRgba src, RenderRgba dst) {
    final k = 1 - src.a;
    return RenderRgba(src.r + dst.r * k, src.g + dst.g * k, src.b + dst.b * k, src.a + dst.a * k);
  }

  // ---------------------------------------------------------------------------------------------
  // Sprites and quantization.
  // ---------------------------------------------------------------------------------------------

  /// Glyphs shown at a `reveal` channel value: `floor(reveal)`.
  static int revealCount(double reveal) => reveal.floor();

  /// Whether a sprite texel of [glyph] is drawn: always when [reveal] is null (not animated),
  /// otherwise iff `glyph < floor(reveal)` (so background texels, glyph 0xFFFF, are never drawn
  /// while `reveal` is animated).
  static bool spriteTexelDrawn(int glyph, double? reveal) => reveal == null || glyph < revealCount(reveal);

  /// An 8-bit channel value: `round(clamp(v, 0, 1)·255)`.
  static int toByte(double v) => (clamp01(v) * 255).round();

  /// Transitional: the D-33 placeholder getter, kept only so API-01's placeholder test
  /// (`test/contract/fake_engine_behavior_test.dart`) still compiles until its owner drops the
  /// RenderMath / ReferenceRenderer / ReferenceAudioMixer lines. Always throws.
  static Never get notImplemented => throw UnimplementedError('RenderMath is implemented (API-03); remove this placeholder check');
}
