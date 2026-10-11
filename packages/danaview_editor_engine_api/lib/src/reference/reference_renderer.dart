// OWNER: API-03
//
// The Dart CPU reference renderer (ARCH §11.6): renders one RenderPlan frame at plan time t to RGBA
// at a small size, for goldens and for the parity checks of IOS-11, AND-10 and QA-03 (tolerance:
// mean absolute error ≤ 1.5/255 per channel, 99th percentile ≤ 6/255, SSIM ≥ 0.98, edge pixels
// excluded). Deterministic: pure functions of the plan, the time and the sources.
//
// Pipeline per active layer, bottom → top in (z, t0, id) order (D-08):
// 1. evaluate the layer's channels at t (`LayerParamSnapshot`);
// 2. build the layer raster in base-local orientation at render resolution
//    (`round(base·|s|·renderScale)` px): media and images sample the cropped, display-oriented
//    source (box-filtered by footprint supersampling, at most 8×8, bilinear taps); sprites sample
//    their premultiplied raster the same way, dropping texels hidden by `reveal`; solids are one
//    texel;
// 3. media and images only: chroma key + spill → grade → LUT (straight colour), blur → sharpen →
//    vignette → mask (premultiplied raster; blur σ in render px = σ_canvas·renderScale);
// 4. place: every output pixel centre is mapped to base-local px with M⁻¹ (core
//    `planPlacementMatrix`), sampled bilinearly from the raster inside `[0, base)`, multiplied by
//    `xf.op` and the canvas masks (evaluated at the pixel centre in canvas px) and composited
//    premultiplied source-over onto the opaque `bg`.
// Edges are not anti-aliased (parity excludes edge pixels).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/eval.dart' show Affine2;
import 'package:danaview_editor_core/model.dart' show FrameRate, TimeUs;
import 'package:danaview_editor_core/plan.dart';

import '../math/layer_params.dart';
import '../math/lut_table.dart';
import '../math/raster.dart';
import '../math/render_math.dart';
import 'reference_sources.dart';
import 'synthetic_sources.dart';

/// One rendered frame of the reference renderer (ARCH §11.6, API-03).
final class ReferenceFrame {
  /// Creates a frame.
  ReferenceFrame({required this.t, required this.renderScale, required this.raster, required List<String> drawnLayerIds})
      : drawnLayerIds = List.unmodifiable(drawnLayerIds);

  /// Plan time that was rendered.
  final TimeUs t;

  /// Render px per canvas px (horizontal; the vertical scale is `height / canvas.h`).
  final double renderScale;

  /// The opaque, premultiplied frame.
  final RenderRaster raster;

  /// Ids of the layers that drew at least one pixel, in draw order.
  final List<String> drawnLayerIds;

  /// Width in px.
  int get width => raster.width;

  /// Height in px.
  int get height => raster.height;

  /// RGBA8 (alpha always 255).
  Uint8List toRgba8() => raster.toStraightRgba8();
}

/// Renders one frame of a [RenderPlan] to RGBA on the CPU (ARCH §11.6, API-03).
class ReferenceRenderer {
  /// Creates a renderer. [longSide] is the output's long side in px (render scale
  /// `longSide / max(canvas.w, canvas.h)`); null renders at the canvas size.
  const ReferenceRenderer({
    this.sources = const SyntheticSources(),
    this.longSide,
    this.maxSupersample = 8,
    this.maxLayerRasterSide = 4096,
  });

  /// Decoded content for media, image, sprite and LUT assets.
  final ReferenceSources sources;

  /// Output long side in px, or null for the canvas size.
  final int? longSide;

  /// Per-axis cap of the footprint supersampling when a source is minified.
  final int maxSupersample;

  /// Cap of each side of a layer raster in px.
  final int maxLayerRasterSide;

  /// The output size for [canvas]: `round(canvas·scale)` per side (at least 1).
  (int, int) outputSizeOf(PlanCanvas canvas) {
    final ls = longSide;
    if (ls == null) return (canvas.w, canvas.h);
    final k = ls / math.max(canvas.w, canvas.h);
    return (math.max(1, (canvas.w * k).round()), math.max(1, (canvas.h * k).round()));
  }

  /// RGBA8 (straight alpha; opaque because the composite is onto the opaque `bg`) of the frame at
  /// plan time [t].
  Uint8List renderFrame(RenderPlan plan, TimeUs t) => render(plan, t).toRgba8();

  /// RGBA8 of output frame [k]: plan time `timeOfFrame(k)` of `canvas.fps` (ARCH §11.5).
  Uint8List renderOutputFrame(RenderPlan plan, int k) => renderFrame(plan, FrameRate(plan.canvas.fps, 1).timeOfFrame(k));

  /// Renders the frame at plan time [t].
  ReferenceFrame render(RenderPlan plan, TimeUs t) {
    final c = plan.canvas;
    final (ow, oh) = outputSizeOf(c);
    final kx = ow / c.w;
    final ky = oh / c.h;
    final bg = RenderRgba.fromArgb(c.bg);
    final frame = RenderRaster.filled(ow, oh, RenderRgba(bg.r, bg.g, bg.b));
    final layers = [...plan.layers]..sort(_drawOrder);
    final drawn = <String>[];
    for (final l in layers) {
      if (!l.isActiveAt(t)) continue;
      if (_drawLayer(plan, l, t, frame, kx, ky)) drawn.add(l.id);
    }
    return ReferenceFrame(t: t, renderScale: kx, raster: frame, drawnLayerIds: drawn);
  }

  static int _drawOrder(PlanLayer a, PlanLayer b) {
    if (a.z != b.z) return a.z.compareTo(b.z);
    if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
    return a.id.compareTo(b.id);
  }

  int _rasterSide(double px) => math.max(1, math.min(maxLayerRasterSide, px.round()));

  bool _drawLayer(RenderPlan plan, PlanLayer layer, TimeUs t, RenderRaster frame, double kx, double ky) {
    final c = plan.canvas;
    final asset = layer.asset == null ? null : plan.assets[layer.asset];
    final p = LayerParamSnapshot.at(layer, c, t);
    if (!(p.xf.op > 0)) return false;
    final base = RenderMath.effectiveBase(layer, asset, c);
    final s = p.xf.s.abs();
    if (!(s > 0 && base.w > 0 && base.h > 0)) return false;
    final m = RenderMath.placement(p.xf, base, c);
    if (m.inverse() == null) return false;

    final RenderRaster raster;
    switch (layer.kind) {
      case PlanLayerKind.solid:
        raster = RenderRaster.filled(1, 1, RenderMath.premultiply(RenderRgba.fromArgb(layer.color ?? 0xFF000000)));
      case PlanLayerKind.sprite:
        raster = _spriteRaster(layer, asset!, p, _rasterSide(base.w * s * kx), _rasterSide(base.h * s * ky));
      case PlanLayerKind.media:
      case PlanLayerKind.image:
        raster = _pictureRaster(plan, layer, asset!, p, t, base, _rasterSide(base.w * s * kx), _rasterSide(base.h * s * ky), kx);
    }

    return placeOnto(frame, raster, m, base, p.xf.op, p.cmasks, kx, ky);
  }

  /// Places a premultiplied layer [raster] (covering the layer's `base` in base-local orientation)
  /// onto the premultiplied [frame]: every output pixel centre `((x + 0.5)/kx, (y + 0.5)/ky)` in
  /// canvas px is mapped to base-local px with `M⁻¹`; inside `[0, base.w) × [0, base.h)` the raster is
  /// sampled bilinearly at `(u·raster.width, v·raster.height)`, multiplied by [opacity] and every
  /// canvas mask (evaluated, at the pixel centre in canvas px) and composited source-over. Returns
  /// whether any pixel was touched.
  static bool placeOnto(
    RenderRaster frame,
    RenderRaster raster,
    Affine2 m,
    PlanSize base,
    double opacity,
    List<CanvasMask> cmasks,
    double kx,
    double ky,
  ) {
    final inv = m.inverse();
    if (inv == null || !(opacity > 0)) return false;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final (bx, by) in [(0.0, 0.0), (base.w, 0.0), (base.w, base.h), (0.0, base.h)]) {
      final x = m.a * bx + m.c * by + m.tx;
      final y = m.b * bx + m.d * by + m.ty;
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
    final x0 = math.max(0, (minX * kx).floor() - 1);
    final x1 = math.min(frame.width - 1, (maxX * kx).ceil() + 1);
    final y0 = math.max(0, (minY * ky).floor() - 1);
    final y1 = math.min(frame.height - 1, (maxY * ky).ceil() + 1);
    if (x0 > x1 || y0 > y1) return false;

    final rw = raster.width;
    final rh = raster.height;
    final sample = Float64List(4);
    final f = frame.data;
    var any = false;
    for (var y = y0; y <= y1; y++) {
      final cy = (y + 0.5) / ky;
      for (var x = x0; x <= x1; x++) {
        final cx = (x + 0.5) / kx;
        final lx = inv.a * cx + inv.c * cy + inv.tx;
        final ly = inv.b * cx + inv.d * cy + inv.ty;
        final u = lx / base.w;
        final v = ly / base.h;
        if (!(u >= 0 && u < 1 && v >= 0 && v < 1)) continue;
        raster.sampleInto(u * rw, v * rh, sample);
        var k = opacity;
        for (final cm in cmasks) {
          k *= RenderMath.canvasMaskAlpha(cm, cx, cy);
        }
        final sa = sample[3] * k;
        if (!(sa > 0)) continue;
        final o = (y * frame.width + x) * 4;
        final rest = 1 - sa;
        f[o] = sample[0] * k + f[o] * rest;
        f[o + 1] = sample[1] * k + f[o + 1] * rest;
        f[o + 2] = sample[2] * k + f[o + 2] * rest;
        f[o + 3] = sa + f[o + 3] * rest;
        any = true;
      }
    }
    return any;
  }

  /// Averages `n × n` bilinear taps of [src] over the footprint of each raster texel of the source
  /// rectangle `[sx0, sx1) × [sy0, sy1)` (source texel units). [keep] filters taps (sprite reveal).
  RenderRaster _resample(RenderRaster src, double sx0, double sy0, double sx1, double sy1, int rw, int rh,
      {bool Function(double x, double y)? keep}) {
    final out = RenderRaster(rw, rh);
    final fx = (sx1 - sx0) / rw;
    final fy = (sy1 - sy0) / rh;
    final nx = math.max(1, math.min(maxSupersample, (fx - 1e-9).ceil()));
    final ny = math.max(1, math.min(maxSupersample, (fy - 1e-9).ceil()));
    final tap = Float64List(4);
    final d = out.data;
    final inv = 1 / (nx * ny);
    for (var j = 0; j < rh; j++) {
      for (var i = 0; i < rw; i++) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        for (var sy = 0; sy < ny; sy++) {
          final ys = sy0 + (j + (sy + 0.5) / ny) * fy;
          for (var sx = 0; sx < nx; sx++) {
            final xs = sx0 + (i + (sx + 0.5) / nx) * fx;
            if (keep != null && !keep(xs, ys)) continue;
            src.sampleInto(xs, ys, tap);
            r += tap[0];
            g += tap[1];
            b += tap[2];
            a += tap[3];
          }
        }
        final o = (j * rw + i) * 4;
        d[o] = r * inv;
        d[o + 1] = g * inv;
        d[o + 2] = b * inv;
        d[o + 3] = a * inv;
      }
    }
    return out;
  }

  RenderRaster _spriteRaster(PlanLayer layer, PlanAsset asset, LayerParamSnapshot p, int rw, int rh) {
    final sprite = sources.sprite(layer.asset!, asset);
    if (sprite == null) throw StateError('ReferenceRenderer: no sprite content for asset ${layer.asset}');
    final reveal = asset.reveal == true && sprite.glyphs != null ? p.reveal : null;
    return _resample(
      sprite.raster,
      0,
      0,
      sprite.width.toDouble(),
      sprite.height.toDouble(),
      rw,
      rh,
      keep: reveal == null ? null : (x, y) => RenderMath.spriteTexelDrawn(sprite.glyphAt(x, y), reveal),
    );
  }

  RenderRaster _pictureRaster(
    RenderPlan plan,
    PlanLayer layer,
    PlanAsset asset,
    LayerParamSnapshot p,
    TimeUs t,
    PlanSize base,
    int rw,
    int rh,
    double renderScale,
  ) {
    final RenderRaster src;
    if (layer.kind == PlanLayerKind.media) {
      final video = sources.video(layer.asset!, asset);
      if (video == null) throw StateError('ReferenceRenderer: no video content for asset ${layer.asset}');
      final double s;
      if (layer.hold) {
        s = layer.map.first.s0.toDouble();
      } else {
        final seg = layer.map.firstWhere((m) => m.contains(t), orElse: () => layer.map.last);
        s = seg.sourceAt(t);
      }
      src = video.frame(video.displayedFrameIndex(s));
    } else {
      final img = sources.image(layer.asset!, asset);
      if (img == null) throw StateError('ReferenceRenderer: no image content for asset ${layer.asset}');
      src = img;
    }
    final crop = layer.crop;
    final raster = _resample(src, crop.l * src.width, crop.t * src.height, crop.r * src.width, crop.b * src.height, rw, rh);
    final fx = layer.fx;
    final lutRef = fx.lut;
    final lutAsset = lutRef == null ? null : plan.assets[lutRef.asset];
    final lut = lutRef == null || lutRef.i == 0 || lutAsset == null ? null : sources.lut(lutRef.asset, lutAsset);
    if (lutRef != null && lutRef.i != 0 && lut == null) throw StateError('ReferenceRenderer: no LUT content for asset ${lutRef.asset}');
    final detail = p.detail;
    return applyEffects(
      raster,
      base: base,
      chroma: fx.chroma,
      adj: p.adj,
      lut: lut,
      lutIntensity: lutRef?.i ?? 0,
      blurSigmaRenderPx: detail == null || detail.blur == 0
          ? 0
          : RenderMath.blurSigmaRenderPx(RenderMath.blurSigmaCanvasPx(detail.blur, plan.canvas.w, plan.canvas.h), renderScale),
      sharpen: detail?.sharpen ?? 0,
      vignette: detail?.vignette ?? 0,
      mask: p.mask,
    );
  }

  /// Runs the effect stages of a media or image layer in D-08 order on its premultiplied layer
  /// [raster] (texels covering the layer box over [base]): chroma key + spill → grade → LUT on the
  /// straight colour of every texel with alpha > 0, then Gaussian blur ([blurSigmaRenderPx] in
  /// raster px) → sharpen → vignette (aspect `base.w / base.h`) → item mask (layer-normalized
  /// texel centres). Returns a new raster or [raster] itself when nothing applies.
  static RenderRaster applyEffects(
    RenderRaster raster, {
    required PlanSize base,
    PlanChroma? chroma,
    PlanAdjust? adj,
    RenderLut? lut,
    double lutIntensity = 0,
    double blurSigmaRenderPx = 0,
    double sharpen = 0,
    double vignette = 0,
    PlanMask? mask,
  }) {
    var out = raster;
    final useLut = lut != null && lutIntensity != 0;
    if (chroma != null || adj != null || useLut) {
      out = raster.copy();
      final d = out.data;
      for (var o = 0; o < d.length; o += 4) {
        final a = d[o + 3];
        if (!(a > 0)) continue;
        var c = RenderRgba(d[o] / a, d[o + 1] / a, d[o + 2] / a, a);
        if (chroma != null) c = RenderMath.chromaKey(c, chroma);
        if (adj != null) c = RenderMath.grade(c, adj);
        if (useLut) c = RenderMath.lut(c, lut, lutIntensity);
        d[o] = c.r * c.a;
        d[o + 1] = c.g * c.a;
        d[o + 2] = c.b * c.a;
        d[o + 3] = c.a;
      }
    }
    if (blurSigmaRenderPx > 0) out = RenderMath.gaussianBlur(out, blurSigmaRenderPx);
    if (sharpen > 0) out = RenderMath.sharpen(out, sharpen);
    if (vignette > 0 || mask != null) {
      if (identical(out, raster)) out = raster.copy();
      final d = out.data;
      final rw = out.width;
      final rh = out.height;
      final aspect = base.w / base.h;
      for (var j = 0; j < rh; j++) {
        final v = (j + 0.5) / rh;
        for (var i = 0; i < rw; i++) {
          final u = (i + 0.5) / rw;
          final o = (j * rw + i) * 4;
          if (vignette > 0) {
            final k = RenderMath.vignetteFactor(u, v, aspect, vignette);
            d[o] *= k;
            d[o + 1] *= k;
            d[o + 2] *= k;
          }
          if (mask != null) {
            final k = RenderMath.maskAlpha(mask, u, v, base.w, base.h);
            d[o] *= k;
            d[o + 1] *= k;
            d[o + 2] *= k;
            d[o + 3] *= k;
          }
        }
      }
    }
    return out;
  }
}
