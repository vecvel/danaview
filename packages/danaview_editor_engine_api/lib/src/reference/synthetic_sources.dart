// OWNER: API-03
//
// Deterministic synthetic content for any RenderPlan (ARCH §11.6 goldens): every video, image,
// sprite, LUT and audio asset gets procedurally generated, 8-bit-quantized content derived only
// from its `uri`, display size and frame index, so goldens need no media files. The golden tool
// (`tool/regen_goldens.dart`) writes the content a golden used to `test_fixtures/images/sources/`
// so the Swift and Kotlin parity tests feed the engines the same pixels (format in
// `test_fixtures/images/README.md`).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/formats.dart' show readVlut, writeVlut;
import 'package:danaview_editor_core/plan.dart';

import '../math/lut_table.dart';
import '../math/raster.dart';
import '../math/render_math.dart';
import 'reference_sources.dart';

/// Procedural [ReferenceSources] for goldens (ARCH §11.6, API-03):
///
/// * **video** (display-oriented, long side [videoLongSide] px, nominal fps from a `<n>p<fps>` or
///   `<n>k<fps>` token in the file name, else 30; `ceil(durUs·fps/10⁶)` frames): a colour ramp with
///   a moving blue term, a red orientation square at the top left, a key-green (`#00B140`) and a
///   key-blue (`#0000FF`) disc, a white bar sweeping once per second and a 12-bit frame-index
///   barcode along the bottom;
/// * **image** (long side [imageLongSide]): a shaded two-colour checkerboard with a white ring and
///   the red orientation square;
/// * **sprite** (`sw × sh`, premultiplied): box-letter glyphs in white with a 50 % black drop
///   shadow on transparent, glyph ids increasing left to right (0xFFFF outside the glyph cells);
/// * **lut** (`n`): a fixed warm/teal polynomial grade stored through `.vlut` float16;
/// * **audio**: one sine per channel (stereo: f and 1.5·f, f ∈ 220…605 Hz from the uri, peak 0.25).
final class SyntheticSources implements ReferenceSources {
  /// Creates the sources.
  const SyntheticSources({this.videoLongSide = 128, this.imageLongSide = 128});

  /// Long side of generated video frames in px.
  final int videoLongSide;

  /// Long side of generated images in px.
  final int imageLongSide;

  static final Map<String, Object> _cache = {};

  static T _memo<T extends Object>(String key, T Function() build) {
    final hit = _cache[key];
    if (hit is T) return hit;
    if (_cache.length > 256) _cache.clear();
    return _cache[key] = build();
  }

  /// 32-bit FNV-1a of the UTF-16 code units of [s].
  static int fnv1a(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// A seed in [0, 1) derived from [key].
  static double seedOf(String key) => fnv1a(key) / 4294967296.0;

  /// File-name-safe identity of an asset's content: the uri's base name without extension,
  /// lower-cased to `[a-z0-9_]`, plus `_<w>x<h>` (display size, `na` when unknown).
  static String sourceKey(PlanAsset asset) {
    var name = asset.uri.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.toLowerCase().replaceAll(RegExp('[^a-z0-9_]'), '_');
    if (name.isEmpty) name = 'asset';
    final size = asset.w != null && asset.h != null ? '${asset.w}x${asset.h}' : 'na';
    return '${name}_$size';
  }

  /// The nominal frame rate of a synthetic video: the last `<n>p<fps>` / `<n>k<fps>` token of the
  /// file name when it is a v1 rate, else 30.
  static int nominalFps(PlanAsset asset) {
    final name = asset.uri.split('/').last.toLowerCase();
    final m = RegExp(r'(\d+)[pk](\d+)').allMatches(name).toList();
    if (m.isNotEmpty) {
      final fps = int.parse(m.last.group(2)!);
      if (const {24, 25, 30, 48, 50, 60}.contains(fps)) return fps;
    }
    return 30;
  }

  /// Frames of a synthetic video: `ceil(durUs·fps/10⁶)` (at least 1), or 2³⁰ without a duration.
  static int frameCountOf(PlanAsset asset) {
    final d = asset.durUs;
    if (d == null || d <= 0) return 1 << 30;
    final fps = nominalFps(asset);
    return math.max(1, (d * fps + 999999) ~/ 1000000);
  }

  /// Raster size for an asset of display size `w × h` (16 × 9 when unknown) scaled to [longSide].
  static (int, int) rasterSize(PlanAsset asset, int longSide) {
    final w = (asset.w ?? 16).toDouble();
    final h = (asset.h ?? 9).toDouble();
    final k = longSide / math.max(w, h);
    return (math.max(1, (w * k).round()), math.max(1, (h * k).round()));
  }

  static double _tri(double x) => 1 - 2 * (x - x.floor() - 0.5).abs();

  static void _put(Uint8List out, int o, double r, double g, double b, [double a = 1]) {
    out[o] = RenderMath.toByte(r);
    out[o + 1] = RenderMath.toByte(g);
    out[o + 2] = RenderMath.toByte(b);
    out[o + 3] = RenderMath.toByte(a);
  }

  /// Straight RGBA8 of frame [j] of the synthetic video of [asset] (size [rasterSize]).
  Uint8List videoFrameRgba8(PlanAsset asset, int j) => _memo('v8|${sourceKey(asset)}|$videoLongSide|$j', () {
        final (w, h) = rasterSize(asset, videoLongSide);
        final seed = seedOf(sourceKey(asset));
        final fps = nominalFps(asset);
        final aspect = w / h;
        final out = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final u = (x + 0.5) / w;
            final v = (y + 0.5) / h;
            final o = (y * w + x) * 4;
            if (v >= 0.78) {
              final bit = (j >> math.min(11, (u * 12).floor())) & 1;
              final c = bit == 1 ? 0.95 : 0.05;
              _put(out, o, c, c, c);
              continue;
            }
            if (v >= 0.62 && v < 0.74) {
              final pos = ((j % fps) + 0.5) / fps;
              final c = (u - pos).abs() < 0.03 ? 0.97 : 0.2;
              _put(out, o, c, c, c);
              continue;
            }
            if (u < 0.1 && v < 0.1 * aspect) {
              _put(out, o, 1, 0.1, 0.1);
              continue;
            }
            final gx = (u - 0.68) * aspect;
            final gy = v - 0.34;
            if (gx * gx + gy * gy < 0.15 * 0.15) {
              _put(out, o, 0, 0xB1 / 255, 0x40 / 255);
              continue;
            }
            final bx = (u - 0.30) * aspect;
            final by = v - 0.34;
            if (bx * bx + by * by < 0.11 * 0.11) {
              _put(out, o, 0, 0, 1);
              continue;
            }
            _put(out, o, 0.1 + 0.8 * u, 0.1 + 0.8 * v, 0.1 + 0.8 * _tri(seed + 0.5 * u + 0.25 * v + j / (2 * fps)));
          }
        }
        return out;
      });

  /// Straight RGBA8 of the synthetic picture of [asset] (size [rasterSize]).
  Uint8List imageRgba8(PlanAsset asset) => _memo('i8|${sourceKey(asset)}|$imageLongSide', () {
        final (w, h) = rasterSize(asset, imageLongSide);
        final seed = seedOf(sourceKey(asset));
        final aspect = w / h;
        final out = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final u = (x + 0.5) / w;
            final v = (y + 0.5) / h;
            final o = (y * w + x) * 4;
            if (u < 0.1 && v < 0.1 * aspect) {
              _put(out, o, 1, 0.1, 0.1);
              continue;
            }
            final dx = (u - 0.5) * aspect;
            final dy = v - 0.5;
            if ((math.sqrt(dx * dx + dy * dy) - 0.3).abs() < 0.035) {
              _put(out, o, 0.97, 0.97, 0.97);
              continue;
            }
            final cx = (u * 8).floor();
            final cy = (v * 8 / aspect).floor();
            final shade = 0.7 + 0.3 * (1 - v);
            if ((cx + cy).isEven) {
              _put(out, o, 0.85 * shade, (0.55 + 0.3 * seed) * shade, 0.30 * shade);
            } else {
              _put(out, o, 0.20 * shade, 0.35 * shade, (0.75 - 0.3 * seed) * shade);
            }
          }
        }
        return out;
      });

  /// Premultiplied RGBA8 and glyph ids of the synthetic sprite of [asset] (`sw × sh`).
  (Uint8List rgba, Uint16List glyphs) spriteRgba8(PlanAsset asset) => _memo('s8|${asset.sw}x${asset.sh}', () {
        final w = asset.sw ?? 16;
        final h = asset.sh ?? 16;
        final margin = math.max(1, (h * 0.15).round());
        final cell = math.max(1, (h * 0.5).round());
        final gap = math.max(1, (h * 0.12).round());
        final stroke = math.max(1, (h * 0.1).round());
        final shadow = math.max(1, (h * 0.03).round());
        final ch = math.max(1, h - 2 * margin);
        final count = math.max(1, (w - 2 * margin + gap) ~/ (cell + gap));
        int glyphOf(int x, int y) {
          if (y < margin || y >= margin + ch || x < margin) return 0xFFFF;
          final g = (x - margin) ~/ (cell + gap);
          if (g >= count || (x - margin) - g * (cell + gap) >= cell) return 0xFFFF;
          return g;
        }

        bool isStroke(int x, int y) {
          if (x < 0 || y < 0 || x >= w || y >= h) return false;
          final g = glyphOf(x, y);
          if (g == 0xFFFF) return false;
          final lx = (x - margin) - g * (cell + gap);
          final ly = y - margin;
          final left = lx < stroke;
          final right = lx >= cell - stroke && g % 3 != 2;
          final topBottom = ly < stroke || ly >= ch - stroke;
          final middle = g.isOdd && (2 * ly - ch).abs() < stroke;
          return left || right || topBottom || middle;
        }

        final rgba = Uint8List(w * h * 4);
        final glyphs = Uint16List(w * h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = y * w + x;
            var g = glyphOf(x, y);
            if (isStroke(x, y)) {
              rgba.fillRange(i * 4, i * 4 + 4, 255);
            } else if (isStroke(x - shadow, y - shadow)) {
              rgba[i * 4 + 3] = 128;
              g = glyphOf(x - shadow, y - shadow);
            }
            glyphs[i] = g;
          }
        }
        return (rgba, glyphs);
      });

  /// The warm/teal grade of the synthetic LUTs at one grid point (before float16 storage).
  static (double, double, double) lutFunction(double r, double g, double b) {
    final y = RenderMath.luma(r, g, b);
    return (
      RenderMath.clamp01(r + 0.18 * r * (1 - r) + 0.06 * (y - 0.5)),
      RenderMath.clamp01(g + 0.05 * g * (1 - g)),
      RenderMath.clamp01(b - 0.12 * b * (1 - b) + 0.10 * (1 - y) * (1 - b)),
    );
  }

  /// The `.vlut` bytes of the synthetic LUT of edge [n].
  static Uint8List vlutBytes(int n) => _memo('vlut|$n', () => writeVlut(n, RenderLut.generate(n, lutFunction).rgb));

  @override
  ReferenceVideo? video(String assetId, PlanAsset asset) {
    final (w, h) = rasterSize(asset, videoLongSide);
    return ReferenceVideo.constantRate(
      fps: nominalFps(asset),
      frameCount: frameCountOf(asset),
      frame: (j) => _memo('v|${sourceKey(asset)}|$videoLongSide|$j', () => RenderRaster.fromStraightRgba8(videoFrameRgba8(asset, j), w, h)),
    );
  }

  @override
  RenderRaster? image(String assetId, PlanAsset asset) {
    final (w, h) = rasterSize(asset, imageLongSide);
    return _memo('i|${sourceKey(asset)}|$imageLongSide', () => RenderRaster.fromStraightRgba8(imageRgba8(asset), w, h));
  }

  @override
  ReferenceSprite? sprite(String assetId, PlanAsset asset) => _memo('s|${asset.sw}x${asset.sh}|${asset.reveal}', () {
        final (rgba, glyphs) = spriteRgba8(asset);
        final w = asset.sw ?? 16;
        final h = asset.sh ?? 16;
        return ReferenceSprite(RenderRaster.fromPremultipliedRgba8(rgba, w, h), glyphs: asset.reveal == true ? glyphs : null);
      });

  @override
  RenderLut? lut(String assetId, PlanAsset asset) =>
      _memo('lut|${asset.n ?? 33}', () => RenderLut.fromVlut(readVlut(vlutBytes(asset.n ?? 33))));

  @override
  ReferenceAudio? audio(String assetId, PlanAsset asset, int stream) {
    final f = 220 * (1 + (fnv1a(sourceKey(asset)) % 8) / 4);
    return ToneAudio([Tone(f, 0.25), Tone(1.5 * f, 0.25)], durUs: asset.durUs);
  }
}
