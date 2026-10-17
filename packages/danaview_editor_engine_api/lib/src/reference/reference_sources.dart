// OWNER: API-03
//
// Pixel and sample sources of the Dart reference renderer and mixer (ARCH §11.6). A real engine
// decodes files; the reference gets decoded content from a [ReferenceSources]: explicit rasters,
// tones and PCM for tests ([MapReferenceSources]) or deterministic synthetic content for goldens
// (`SyntheticSources`). Frame selection follows ARCH §11.5: the displayed frame is the one with the
// greatest PTS ≤ s + 500 µs.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/plan.dart';

import '../math/lut_table.dart';
import '../math/raster.dart';

/// Offset added to the mapped source time before picking a video frame (ARCH §11.5, D-04).
const int sourceFrameBiasUs = 500;

/// Decoded content for the reference renderer and mixer, keyed by plan asset id (ARCH §11.6,
/// API-03). Returning null means "no content": the renderer and mixer then throw, because an
/// oracle must not silently skip a layer.
abstract interface class ReferenceSources {
  /// The decoded video of a `video` asset.
  ReferenceVideo? video(String assetId, PlanAsset asset);

  /// The decoded, display-oriented picture of an `image` asset (premultiplied).
  RenderRaster? image(String assetId, PlanAsset asset);

  /// The decoded raster of a `sprite` asset.
  ReferenceSprite? sprite(String assetId, PlanAsset asset);

  /// The table of a `lut` asset.
  RenderLut? lut(String assetId, PlanAsset asset);

  /// Stream [stream] of an `audio` or `video` asset.
  ReferenceAudio? audio(String assetId, PlanAsset asset, int stream);
}

/// A decoded video: display-oriented frames (rotation applied) with presentation timestamps
/// (ARCH §11.5, API-03).
final class ReferenceVideo {
  /// A constant-rate video: frame `j` has PTS `j·10⁶/fps` (rational) for `j < frameCount`.
  ReferenceVideo.constantRate({required this.fps, required this.frameCount, required RenderRaster Function(int j) frame})
      : assert(fps > 0 && frameCount > 0),
        pts = null,
        _frame = frame;

  /// A video with explicit, strictly increasing PTS (µs) per frame.
  ReferenceVideo.withPts(List<int> pts, {required RenderRaster Function(int j) frame})
      : assert(pts.isNotEmpty),
        pts = List.unmodifiable(pts),
        fps = 0,
        frameCount = pts.length,
        _frame = frame;

  /// Frames per second of a constant-rate video (0 when [pts] is given).
  final int fps;

  /// Number of frames.
  final int frameCount;

  /// Explicit PTS per frame, or null for a constant-rate video.
  final List<int>? pts;

  final RenderRaster Function(int j) _frame;

  /// Index of the frame with the greatest PTS ≤ [targetUs], clamped to the first and last frame.
  int frameIndexAt(double targetUs) {
    final p = pts;
    if (p == null) {
      final j = (targetUs * fps / 1e6).floor();
      return math.max(0, math.min(frameCount - 1, j));
    }
    var lo = 0;
    var hi = p.length - 1;
    if (targetUs < p.first) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (p[mid] <= targetUs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The frame displayed for exact source time [sourceUs]: [frameIndexAt]`(s + 500)`.
  int displayedFrameIndex(double sourceUs) => frameIndexAt(sourceUs + sourceFrameBiasUs);

  /// Frame [j] (premultiplied).
  RenderRaster frame(int j) => _frame(j);
}

/// A decoded text sprite (ARCH §10.3): premultiplied RGBA at sprite resolution and, when the asset
/// has `reveal`, a glyph-order id per pixel (0xFFFF = background) (D-06, API-03).
final class ReferenceSprite {
  /// Creates a sprite. [glyphs] has `width × height` entries when present.
  ReferenceSprite(this.raster, {this.glyphs}) : assert(glyphs == null || glyphs.length == raster.width * raster.height);

  /// Premultiplied colour.
  final RenderRaster raster;

  /// Glyph order per pixel (row-major), or null without a reveal map.
  final Uint16List? glyphs;

  /// Width in sprite px.
  int get width => raster.width;

  /// Height in sprite px.
  int get height => raster.height;

  /// The glyph id of the texel nearest to continuous sprite coordinates (`x`, `y`), or 0xFFFF
  /// without a map.
  int glyphAt(double x, double y) {
    final g = glyphs;
    if (g == null) return 0xFFFF;
    var ix = x.floor();
    var iy = y.floor();
    if (ix < 0) ix = 0;
    if (iy < 0) iy = 0;
    if (ix >= width) ix = width - 1;
    if (iy >= height) iy = height - 1;
    return g[iy * width + ix];
  }
}

/// Decoded audio sampled at fractional source times (ARCH §11.6 Audio row, API-03).
abstract interface class ReferenceAudio {
  /// Channel count (1 = mono, 2 = stereo, 6 = 5.1 …).
  int get channels;

  /// The value of [channel] at source time [sourceUs] (0 outside the stream).
  double sampleAt(int channel, double sourceUs);
}

/// One sine partial `amplitude·sin(2π·freqHz·s/10⁶ + phase)` of a [ToneAudio] (ARCH §11.6, API-03).
final class Tone {
  /// Creates a partial.
  const Tone(this.freqHz, this.amplitude, [this.phase = 0]);

  /// Frequency in Hz.
  final double freqHz;

  /// Peak amplitude (0.25 ≈ −12 dBFS peak).
  final double amplitude;

  /// Phase in radians at source time 0.
  final double phase;

  /// The value at source time [sourceUs].
  double at(double sourceUs) => amplitude * math.sin(2 * math.pi * freqHz * sourceUs / 1e6 + phase);
}

/// Analytic audio: one [Tone] (or silence when null) per channel, zero outside `[0, durUs)`
/// (ARCH §11.6, API-03). Exact under any speed map, which makes varispeed cases analytic.
final class ToneAudio implements ReferenceAudio {
  /// Creates tones, one per channel.
  const ToneAudio(this.tones, {this.durUs});

  /// Partial per channel (null = silent channel).
  final List<Tone?> tones;

  /// Stream length, or null for unbounded.
  final int? durUs;

  @override
  int get channels => tones.length;

  @override
  double sampleAt(int channel, double sourceUs) {
    if (sourceUs < 0 || (durUs != null && sourceUs >= durUs!)) return 0;
    return tones[channel]?.at(sourceUs) ?? 0;
  }
}

/// Interleaved PCM read with linear interpolation between samples (sample `n` at `n·10⁶/rate` µs),
/// zero outside the buffer (ARCH §11.6, API-03).
final class PcmAudio implements ReferenceAudio {
  /// Creates PCM audio.
  PcmAudio({required this.sampleRate, required this.channels, required this.interleaved})
      : assert(sampleRate > 0 && channels > 0 && interleaved.length % channels == 0);

  /// Samples per second.
  final int sampleRate;

  @override
  final int channels;

  /// Interleaved samples.
  final Float32List interleaved;

  /// Frames (samples per channel).
  int get frames => interleaved.length ~/ channels;

  @override
  double sampleAt(int channel, double sourceUs) {
    final x = sourceUs * sampleRate / 1e6;
    final i = x.floor();
    final f = x - i;
    double s(int n) => n < 0 || n >= frames ? 0.0 : interleaved[n * channels + channel];
    return f == 0 ? s(i) : s(i) * (1 - f) + s(i + 1) * f;
  }
}

/// [ReferenceSources] from explicit maps keyed by asset id, falling back to [fallback] (ARCH §11.6,
/// API-03).
final class MapReferenceSources implements ReferenceSources {
  /// Creates sources.
  const MapReferenceSources({
    this.videos = const {},
    this.images = const {},
    this.sprites = const {},
    this.luts = const {},
    this.audios = const {},
    this.fallback,
  });

  /// Videos by asset id.
  final Map<String, ReferenceVideo> videos;

  /// Images by asset id.
  final Map<String, RenderRaster> images;

  /// Sprites by asset id.
  final Map<String, ReferenceSprite> sprites;

  /// LUTs by asset id.
  final Map<String, RenderLut> luts;

  /// Audio by asset id (stream 0 only).
  final Map<String, ReferenceAudio> audios;

  /// Sources consulted for ids missing from the maps.
  final ReferenceSources? fallback;

  @override
  ReferenceVideo? video(String assetId, PlanAsset asset) => videos[assetId] ?? fallback?.video(assetId, asset);

  @override
  RenderRaster? image(String assetId, PlanAsset asset) => images[assetId] ?? fallback?.image(assetId, asset);

  @override
  ReferenceSprite? sprite(String assetId, PlanAsset asset) => sprites[assetId] ?? fallback?.sprite(assetId, asset);

  @override
  RenderLut? lut(String assetId, PlanAsset asset) => luts[assetId] ?? fallback?.lut(assetId, asset);

  @override
  ReferenceAudio? audio(String assetId, PlanAsset asset, int stream) =>
      (stream == 0 ? audios[assetId] : null) ?? fallback?.audio(assetId, asset, stream);
}

/// Wraps [ReferenceSources] and records which assets and video frames a render used (the golden
/// tool writes exactly those sources for the native parity tests; ARCH §11.6, API-03).
final class RecordingReferenceSources implements ReferenceSources {
  /// Wraps [inner].
  RecordingReferenceSources(this.inner);

  /// The wrapped sources.
  final ReferenceSources inner;

  /// Asset id → asset of every asset requested.
  final Map<String, PlanAsset> assets = {};

  /// Asset id → video frame indices requested.
  final Map<String, Set<int>> videoFrames = {};

  /// Forgets everything recorded.
  void clear() {
    assets.clear();
    videoFrames.clear();
  }

  @override
  ReferenceVideo? video(String assetId, PlanAsset asset) {
    final v = inner.video(assetId, asset);
    if (v == null) return null;
    assets[assetId] = asset;
    final frames = videoFrames.putIfAbsent(assetId, () => <int>{});
    RenderRaster frame(int j) {
      frames.add(j);
      return v.frame(j);
    }

    final pts = v.pts;
    return pts == null
        ? ReferenceVideo.constantRate(fps: v.fps, frameCount: v.frameCount, frame: frame)
        : ReferenceVideo.withPts(pts, frame: frame);
  }

  @override
  RenderRaster? image(String assetId, PlanAsset asset) {
    assets[assetId] = asset;
    return inner.image(assetId, asset);
  }

  @override
  ReferenceSprite? sprite(String assetId, PlanAsset asset) {
    assets[assetId] = asset;
    return inner.sprite(assetId, asset);
  }

  @override
  RenderLut? lut(String assetId, PlanAsset asset) {
    assets[assetId] = asset;
    return inner.lut(assetId, asset);
  }

  @override
  ReferenceAudio? audio(String assetId, PlanAsset asset, int stream) {
    assets[assetId] = asset;
    return inner.audio(assetId, asset, stream);
  }
}
