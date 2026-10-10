// OWNER: CORE-31
//
// Audio lowering (ARCH §11.2 AudioSeg, §11.5, §11.6 "Audio", §11.7, D-15): one `<itemId>#a`
// segment per audible media clip on a video, overlay or audio lane.
//
// * **Same map as the picture.** A clip with a `<itemId>#v` media layer gets a segment with that
//   layer's asset, range and map exactly (after transition extensions), which is the A/V sync
//   contract (ARCH §11.5). Clips without one (audio lanes, hidden visual lanes) are lowered with
//   the same functions the picture uses: `clipPlayback` (reversed renditions, pending reverse) and
//   `clipExtentsOf` + `extendMap` (transition handles), so a hidden lane plays exactly what it
//   would play visible.
// * **What has no audio:** images, stills, LUTs, video without an audio stream (`hasAudio`),
//   clips with `detachedAudio` (their extracted partner plays instead), offline media (listed in
//   `req.offline`), and lanes of other kinds.
// * **Gain envelope** `g(t) = volume(t) × fadeIn(t) × fadeOut(t) × transition(t) × speedGate(t)`:
//   volume keyframes (item-local keys at absolute times, held outside, or the static volume
//   0–2); linear fades `clamp((t − start)/fadeIn)` and `clamp((end − t)/fadeOut)` from the clip's
//   own edges (ARCH native §audio gain); transition audio — fade and dips dip the same way as the
//   picture (outgoing 1→0 over [w0, c], incoming 0→1 over [c, w1]), overlap kinds an equal-power
//   crossfade over [w0, w1] (outgoing cos, incoming sin); speedGate is 0 on map segments faster
//   than `capabilities.maxAudioSpeed` (D-15: muted for that span; a 1 µs ramp at each change).
// * **Sampling** ([GainModel.envelope]): breakpoints at every factor's key; between them the
//   product is linear when at most one linear factor varies, otherwise samples every 20 ms plus
//   adaptive bisection until linear interpolation stays within 0.1 dB of the analytic product
//   (below −60 dBFS within 0.1 dB of −60 dBFS). A constant envelope is one key.
// * **Mute and solo.** A muted clip, a muted lane, or a lane silenced by another lane's solo
//   (solo counts video, overlay and audio lanes) keeps its segment with a zero gain in **preview**
//   plans, so toggling mute is a param-only patch (ARCH §11.2 classification), and has **no**
//   segment in export plans (nothing to decode).
// * `pitch` = `maintainPitch`; `stream` = the clip's audio stream (default 0).

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/media_probe.dart';
import '../model/track.dart';
import '../time/time.dart';
import 'asset_resolver.dart';
import 'compiler.dart';
import 'lowering_transitions.dart';
import 'lowering_visual.dart';
import 'render_plan.dart';

/// Default `capabilities.maxAudioSpeed` (D-15): audio is muted where the clip plays faster.
const double defaultMaxAudioSpeed = 4;

/// Spacing of the extra gain samples where the envelope is non-linear (ARCH §11.7).
const TimeUs gainSampleIntervalUs = 20000;

/// Largest allowed difference between the sampled envelope and the analytic gain, in dB.
const double gainToleranceDb = 0.1;

/// Gains below this (−60 dBFS) are compared in absolute terms against it.
const double gainFloor = 1e-3;

/// The model channel of clip volume keyframes.
const String volumeChannel = 'audio.volume';

/// Memo of lowered audio segments (CORE-32's `PlanMemo.audio` implements it): keyed by the clip
/// object's identity plus a key object compared with `==`.
abstract interface class AudioSegMemo {
  /// The segment stored for this very [clip] under a key equal to [key], or null.
  AudioSeg? lookup(MediaClip clip, Object key);

  /// Remembers [seg] for [clip] under [key].
  void store(MediaClip clip, Object key, AudioSeg seg);
}

// ---------------------------------------------------------------------------------------------
// Gain model.
// ---------------------------------------------------------------------------------------------

/// One factor of a gain envelope.
@immutable
sealed class GainFactor {
  const GainFactor();

  /// The factor at [t] (µs, fractional allowed).
  double at(double t);

  /// Times inside which the factor changes shape.
  Iterable<TimeUs> get breakpoints;

  /// Whether the factor is non-linear somewhere in `(a, b)` (no breakpoint inside).
  bool nonLinearOn(TimeUs a, TimeUs b);

  /// Whether the factor varies on `[a, b]` (no breakpoint inside).
  bool variesOn(TimeUs a, TimeUs b);
}

/// A piecewise-linear factor: [keys] (sorted, unique times), linear between, held outside.
final class LinearGain extends GainFactor {
  /// Creates a linear factor.
  LinearGain(List<AnimKey> keys) : keys = List.unmodifiable(keys) {
    if (keys.isEmpty) throw ArgumentError.value(keys, 'keys', 'must not be empty');
  }

  /// A constant factor [v].
  factory LinearGain.constant(double v) => LinearGain([AnimKey(0, v)]);

  /// Keys.
  final List<AnimKey> keys;

  @override
  double at(double t) {
    if (t <= keys.first.tUs) return keys.first.v;
    if (t >= keys.last.tUs) return keys.last.v;
    var lo = 0;
    var hi = keys.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keys[mid].tUs <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = keys[lo];
    final b = keys[hi];
    return a.v + (b.v - a.v) * (t - a.tUs) / (b.tUs - a.tUs);
  }

  @override
  Iterable<TimeUs> get breakpoints => keys.map((k) => k.tUs);

  @override
  bool nonLinearOn(TimeUs a, TimeUs b) => false;

  @override
  bool variesOn(TimeUs a, TimeUs b) => at(a.toDouble()) != at(b.toDouble());

  @override
  bool operator ==(Object other) => other is LinearGain && const ListEquality<AnimKey>().equals(other.keys, keys);

  @override
  int get hashCode => Object.hashAll(keys);
}

/// The equal-power crossfade factor of an overlap window `[w0, w1]`: `sin(π/2·x)` when [rising]
/// (incoming), `cos(π/2·x)` otherwise (outgoing), `x` clamped to [0, 1].
final class EqualPowerGain extends GainFactor {
  /// Creates an equal-power factor.
  const EqualPowerGain(this.w0, this.w1, {required this.rising});

  /// Window start.
  final TimeUs w0;

  /// Window end.
  final TimeUs w1;

  /// Incoming (sin) or outgoing (cos).
  final bool rising;

  @override
  double at(double t) {
    final x = ((t - w0) / (w1 - w0)).clamp(0.0, 1.0);
    final a = math.pi / 2 * x;
    return rising ? math.sin(a) : math.cos(a);
  }

  @override
  Iterable<TimeUs> get breakpoints => [w0, w1];

  @override
  bool nonLinearOn(TimeUs a, TimeUs b) => w0 < b && w1 > a;

  @override
  bool variesOn(TimeUs a, TimeUs b) => nonLinearOn(a, b);

  @override
  bool operator ==(Object other) => other is EqualPowerGain && other.w0 == w0 && other.w1 == w1 && other.rising == rising;

  @override
  int get hashCode => Object.hash(w0, w1, rising);
}

/// The analytic gain of one segment over `[t0, t1]`: the product of [factors].
@immutable
final class GainModel {
  /// Creates a model.
  GainModel(this.t0, this.t1, List<GainFactor> factors) : factors = List.unmodifiable(factors);

  /// Segment start.
  final TimeUs t0;

  /// Segment end.
  final TimeUs t1;

  /// Factors.
  final List<GainFactor> factors;

  /// The analytic gain at [t].
  double at(num t) {
    var g = 1.0;
    final x = t.toDouble();
    for (final f in factors) {
      g *= f.at(x);
    }
    return g;
  }

  /// Linear tolerance factor of [gainToleranceDb] (internally half of it, so the probes of the
  /// bisection leave margin between them).
  static final double _tol = math.pow(10, gainToleranceDb / 2 / 20).toDouble() - 1;

  /// The sampled envelope (file header): linear keys within `[t0, t1]`, one key when constant.
  List<AnimKey> envelope() {
    final times = <TimeUs>{t0, t1};
    for (final f in factors) {
      for (final b in f.breakpoints) {
        if (b > t0 && b < t1) times.add(b);
      }
    }
    final bps = times.toList()..sort();
    final out = <TimeUs>[];
    for (var i = 0; i + 1 < bps.length; i++) {
      final a = bps[i];
      final b = bps[i + 1];
      out.add(a);
      var linearVarying = 0;
      var nonLinear = false;
      for (final f in factors) {
        if (f.nonLinearOn(a, b)) {
          nonLinear = true;
          break;
        }
        if (f.variesOn(a, b)) linearVarying++;
      }
      if (!nonLinear && linearVarying < 2) continue;
      var p = a;
      while (p < b) {
        var q = p + gainSampleIntervalUs;
        if (q > b) q = b;
        _refine(p, q, out);
        if (q < b) out.add(q);
        p = q;
      }
    }
    out.add(bps.last);
    final keys = [for (final t in out) AnimKey(t, at(t))];
    final first = keys.first.v;
    if (keys.every((k) => k.v == first)) return [AnimKey(t0, first)];
    return keys;
  }

  /// Adds interior sample times of `(p, q)` until linear interpolation is within tolerance.
  void _refine(TimeUs p, TimeUs q, List<TimeUs> out) {
    if (q - p <= 2) return;
    final gp = at(p);
    final gq = at(q);
    var ok = true;
    for (final f in const [0.25, 0.5, 0.75]) {
      final t = p + (q - p) * f;
      final exact = at(t);
      final lin = gp + (gq - gp) * f;
      if ((lin - exact).abs() > _tol * math.max(exact, gainFloor)) {
        ok = false;
        break;
      }
    }
    if (ok) return;
    final m = p + (q - p) ~/ 2;
    _refine(p, m, out);
    out.add(m);
    _refine(m, q, out);
  }

  @override
  bool operator ==(Object other) =>
      other is GainModel && other.t0 == t0 && other.t1 == t1 && const ListEquality<GainFactor>().equals(other.factors, factors);

  @override
  int get hashCode => Object.hash(t0, t1, Object.hashAll(factors));
}

/// The gain factors of a clip (file header), for a segment whose map is [map].
List<GainFactor> clipGainFactors(
  MediaClip clip, {
  required List<MapSegment> map,
  List<TransitionWindow> windows = const [],
  double maxAudioSpeed = defaultMaxAudioSpeed,
}) {
  final out = <GainFactor>[];
  // Volume: in-range keys at absolute time, else the static volume.
  final track = clip.keyframes[volumeChannel];
  final keys = <AnimKey>[];
  if (track != null) {
    for (final k in track.keys) {
      if (k.t >= 0 && k.t < clip.duration) keys.add(AnimKey(clip.start + k.t, k.v.clamp(0.0, 2.0).toDouble()));
    }
  }
  if (keys.isNotEmpty) {
    out.add(LinearGain(keys));
  } else if (clip.audio.volume != 1) {
    out.add(LinearGain.constant(clip.audio.volume.clamp(0.0, 2.0).toDouble()));
  }
  final a = clip.audio;
  if (a.fadeIn > 0) out.add(LinearGain([AnimKey(clip.start, 0), AnimKey(clip.start + a.fadeIn, 1)]));
  if (a.fadeOut > 0) out.add(LinearGain([AnimKey(clip.end - a.fadeOut, 1), AnimKey(clip.end, 0)]));
  for (final w in windows) {
    final outgoing = identical(w.left, clip) || w.left.id == clip.id;
    final incoming = identical(w.right, clip) || w.right.id == clip.id;
    if (!outgoing && !incoming) continue;
    if (w.overlaps) {
      out.add(EqualPowerGain(w.w0, w.w1, rising: incoming));
    } else if (outgoing) {
      if (w.w0 < w.cut) out.add(LinearGain([AnimKey(w.w0, 1), AnimKey(w.cut, 0)]));
    } else {
      out.add(LinearGain([AnimKey(w.cut, 0), AnimKey(w.w1, 1)]));
    }
  }
  final gate = speedGate(map, maxAudioSpeed);
  if (gate != null) out.add(gate);
  return out;
}

/// The factor muting the spans of [map] faster than [maxAudioSpeed] (D-15), or null when none
/// is: 1 / 0 per segment with a 1 µs linear step at each change.
LinearGain? speedGate(List<MapSegment> map, double maxAudioSpeed) {
  const eps = 1e-9;
  if (map.every((s) => s.rate <= maxAudioSpeed + eps)) return null;
  final keys = <AnimKey>[];
  double? prev;
  for (final s in map) {
    final v = s.rate > maxAudioSpeed + eps ? 0.0 : 1.0;
    if (prev == null) {
      keys.add(AnimKey(s.t0, v));
    } else if (v != prev) {
      if (s.t0 - 1 > keys.last.tUs) keys.add(AnimKey(s.t0 - 1, prev));
      keys.add(AnimKey(s.t0, v));
    }
    prev = v;
  }
  final end = map.last.t1;
  if (end > keys.last.tUs) keys.add(AnimKey(end, prev!));
  return LinearGain(keys);
}

// ---------------------------------------------------------------------------------------------
// The stage.
// ---------------------------------------------------------------------------------------------

/// Lowers the audio of every media clip (file header). Runs after the transition stage.
final class AudioLoweringStage implements PlanLoweringStage {
  /// Creates the stage.
  const AudioLoweringStage({this.maxAudioSpeed = defaultMaxAudioSpeed, this.memo});

  /// `capabilities.maxAudioSpeed` (D-15).
  final double maxAudioSpeed;

  /// Memo of unchanged segments, or null.
  final AudioSegMemo? memo;

  @override
  void lower(PlanCompilation c) {
    final rate = c.project.settings.frameRate;
    final tracks = c.project.tracks;
    var anySolo = false;
    for (final t in tracks) {
      if (t.solo && _hasAudio(t.kind)) anySolo = true;
    }
    final preview = c.target == PlanTarget.preview;
    for (final track in tracks) {
      if (!_hasAudio(track.kind)) continue;
      final laneAudible = !track.muted && (!anySolo || track.solo);
      if (!laneAudible && !preview) continue;
      final windows = transitionWindowsOf(track, rate);
      final windowsOf = <ItemId, List<TransitionWindow>>{};
      for (final w in windows) {
        (windowsOf[w.left.id] ??= []).add(w);
        (windowsOf[w.right.id] ??= []).add(w);
      }
      Map<ItemId, TimeRange>? extents;
      Map<ItemId, TimeRange> extentsOf() => extents ??= clipExtentsOf(track, rate);
      for (final item in track.items) {
        if (item is! MediaClip || item.detachedAudio) continue;
        final zero = !laneAudible || item.audio.muted;
        if (zero && !preview) continue;
        final clipWindows = windowsOf[item.id] ?? const <TransitionWindow>[];
        // Fast path for clips without a picture layer (audio lanes, hidden lanes): the memo key is
        // known before the time map is lowered.
        Object? plainKey;
        if (memo != null && !item.reversed && !c.clips.containsKey(item.id)) {
          final entry = _plainEntry(c, item);
          if (entry != null) {
            final ext = clipWindows.isEmpty ? null : extentsOf()[item.id];
            plainKey = _PlainKey(entry, rate, ext, clipWindows, zero, maxAudioSpeed);
            final hit = memo!.lookup(item, plainKey);
            if (hit != null) {
              c.audio[hit.id] = hit;
              c.assets.putIfAbsent(hit.asset, () => entry);
              continue;
            }
          }
        }
        final source = _sourceOf(c, item, track, rate, extentsOf);
        if (source == null) continue;
        final key = plainKey ??
            _SegKey(source.asset, source.entry, source.t0, source.t1, source.map, clipWindows, zero, maxAudioSpeed,
                item.maintainPitch, item.audioStream ?? 0);
        var seg = plainKey == null ? memo?.lookup(item, key) : null;
        if (seg == null) {
          seg = lowerClipAudio(item,
              asset: source.asset,
              t0: source.t0,
              t1: source.t1,
              map: source.map,
              windows: clipWindows,
              zero: zero,
              maxAudioSpeed: maxAudioSpeed);
          memo?.store(item, key, seg);
        }
        c.audio[seg.id] = seg;
        c.assets.putIfAbsent(source.asset, () => source.entry);
      }
    }
  }

  /// The plan asset entry a forward clip without a picture layer plays, when it has audio.
  static PlanAsset? _plainEntry(PlanCompilation c, MediaClip clip) {
    final asset = c.project.pool[clip.media];
    if (asset == null || !asset.probe.hasAudio) return null;
    final kind = switch (asset.kind) {
      MediaKind.video => PlanAssetKind.video,
      MediaKind.audio || MediaKind.recording => PlanAssetKind.audio,
      _ => null,
    };
    if (kind == null) return null;
    final entry = c.assetFactory.media(clip.media, kind);
    return entry != null && entry.hasAudio == true ? entry : null;
  }

  static bool _hasAudio(TrackKind k) => k == TrackKind.video || k == TrackKind.overlay || k == TrackKind.audio;

  _AudioSource? _sourceOf(
    PlanCompilation c,
    MediaClip clip,
    Track track,
    FrameRate rate,
    Map<ItemId, TimeRange> Function() extents,
  ) {
    final lowered = c.clips[clip.id];
    if (lowered != null) {
      // Visible visual lane: the picture's media layer is the source of truth (A/V sync).
      final layer = c.layers[PlanIds.visual(clip.id)];
      if (layer == null || layer.kind != PlanLayerKind.media || layer.hold || layer.asset == null) return null;
      final entry = c.assets[layer.asset!];
      if (entry == null || entry.hasAudio != true) return null;
      return _AudioSource(layer.asset!, entry, layer.t0, layer.t1, layer.map);
    }
    final asset = c.project.pool[clip.media];
    if (asset == null) {
      c.requirements.offline(clip.media);
      return null;
    }
    final PlanAssetKind kind;
    switch (asset.kind) {
      case MediaKind.video:
        kind = PlanAssetKind.video;
      case MediaKind.audio:
      case MediaKind.recording:
        kind = PlanAssetKind.audio;
      case MediaKind.image:
      case MediaKind.still:
      case MediaKind.lut:
        return null;
    }
    if (!asset.probe.hasAudio) return null;
    final ClipPlayback playback;
    try {
      playback = clipPlayback(clip, rate, c.visual.renditions, available: c.assetFactory.isAvailable);
    } on ArgumentError {
      return null;
    }
    final entry = c.assetFactory.media(playback.media, kind);
    if (entry == null) {
      c.requirements.offline(clip.media);
      return null;
    }
    if (entry.hasAudio != true) return null;
    if (playback.pendingReverse) c.requirements.pendingReverse(clip.id);
    var t0 = clip.start;
    var t1 = clip.end;
    var map = playback.map;
    final ext = extents()[clip.id];
    if (ext != null) {
      map = extendMap(map, t0: ext.start < t0 ? ext.start : null, t1: ext.end > t1 ? ext.end : null);
      t0 = ext.start;
      t1 = ext.end;
    }
    return _AudioSource(PlanAssetIds.media(playback.media), entry, t0, t1, map);
  }
}

/// The audio segment of [clip] playing [asset] over `[t0, t1)` with [map] (file header). [zero]
/// silences it (muted clip or lane in a preview plan).
AudioSeg lowerClipAudio(
  MediaClip clip, {
  required String asset,
  required TimeUs t0,
  required TimeUs t1,
  required List<MapSegment> map,
  List<TransitionWindow> windows = const [],
  bool zero = false,
  double maxAudioSpeed = defaultMaxAudioSpeed,
}) {
  final gain = zero
      ? [AnimKey(t0, 0)]
      : GainModel(t0, t1, clipGainFactors(clip, map: map, windows: windows, maxAudioSpeed: maxAudioSpeed)).envelope();
  return AudioSeg(
    id: PlanIds.audio(clip.id),
    asset: asset,
    stream: clip.audioStream ?? 0,
    t0: t0,
    t1: t1,
    map: map,
    gain: gain,
    pitch: clip.maintainPitch,
  );
}

final class _AudioSource {
  _AudioSource(this.asset, this.entry, this.t0, this.t1, this.map);
  final String asset;
  final PlanAsset entry;
  final TimeUs t0;
  final TimeUs t1;
  final List<MapSegment> map;
}

/// Memo key of one segment: everything [lowerClipAudio] reads besides the clip itself.
@immutable
final class _SegKey {
  const _SegKey(this.asset, this.entry, this.t0, this.t1, this.map, this.windows, this.zero, this.maxAudioSpeed,
      this.pitch, this.stream);
  final String asset;
  final PlanAsset entry;
  final TimeUs t0;
  final TimeUs t1;
  final List<MapSegment> map;
  final List<TransitionWindow> windows;
  final bool zero;
  final double maxAudioSpeed;
  final bool pitch;
  final int stream;

  @override
  bool operator ==(Object other) =>
      other is _SegKey &&
      other.asset == asset &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      other.zero == zero &&
      other.maxAudioSpeed == maxAudioSpeed &&
      other.pitch == pitch &&
      other.stream == stream &&
      other.entry == entry &&
      (identical(other.map, map) || const ListEquality<MapSegment>().equals(other.map, map)) &&
      _windowsEqual(other.windows, windows);

  static bool _windowsEqual(List<TransitionWindow> a, List<TransitionWindow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.transition != y.transition || x.w0 != y.w0 || x.w1 != y.w1 || x.cut != y.cut) return false;
      if (x.left.id != y.left.id || x.right.id != y.right.id) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(asset, t0, t1, zero, maxAudioSpeed, pitch, stream, map.length, windows.length);
}

/// Memo key of a forward clip without a picture layer: its segment depends only on the clip
/// object (the memo's identity key) and these.
@immutable
final class _PlainKey {
  const _PlainKey(this.entry, this.rate, this.extent, this.windows, this.zero, this.maxAudioSpeed);
  final PlanAsset entry;
  final FrameRate rate;
  final TimeRange? extent;
  final List<TransitionWindow> windows;
  final bool zero;
  final double maxAudioSpeed;

  @override
  bool operator ==(Object other) =>
      other is _PlainKey &&
      other.rate == rate &&
      other.extent == extent &&
      other.zero == zero &&
      other.maxAudioSpeed == maxAudioSpeed &&
      other.entry == entry &&
      _SegKey._windowsEqual(other.windows, windows);

  @override
  int get hashCode => Object.hash(rate, extent, zero, maxAudioSpeed, windows.length);
}
