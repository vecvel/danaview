// OWNER: API-03
//
// The Dart reference audio mixer (ARCH §11.6 Audio row), the oracle of QA-11's PCM checks and of
// IOS-18's gain vectors: for every output sample `i` (timeline time `start + i·10⁶/48000` µs,
// exact, no ε) each active segment (`t0 ≤ t < t1`) reads its source at the mapped time
// `s = s0 + (t − t0)·rate` (varispeed: no pitch processing, so analytic sources stay exact under
// any speed map; `pitch: true` segments at rate ≠ 1 are therefore exact for RMS but not for pitch),
// is downmixed to stereo (mono duplicated, ITU coefficients above two channels), multiplied by the
// linearly interpolated gain, summed, and the sum is hard-clipped to [−1, 1].

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../math/audio_math.dart';
import 'reference_sources.dart';
import 'synthetic_sources.dart';

/// Level of one measurement window of a stereo mix (QA-11 compares per 20 ms window; ARCH §11.6,
/// API-03).
@immutable
final class AudioWindow {
  /// Creates a window.
  const AudioWindow({required this.index, required this.rmsL, required this.rmsR, required this.peakL, required this.peakR});

  /// Window index from the start of the mix.
  final int index;

  /// RMS of the left channel.
  final double rmsL;

  /// RMS of the right channel.
  final double rmsR;

  /// Largest |sample| of the left channel.
  final double peakL;

  /// Largest |sample| of the right channel.
  final double peakR;

  /// [rmsL] in dBFS (`20·log10`, floored at −120).
  double get rmsDbL => AudioMath.levelDb(rmsL);

  /// [rmsR] in dBFS (`20·log10`, floored at −120).
  double get rmsDbR => AudioMath.levelDb(rmsR);
}

/// Mixes the audio segments of a [RenderPlan] per sample (ARCH §11.6, API-03).
class ReferenceAudioMixer {
  /// Creates a mixer.
  const ReferenceAudioMixer({this.sources = const SyntheticSources(), this.sampleRate = AudioMath.sampleRate});

  /// Decoded audio per asset.
  final ReferenceSources sources;

  /// Output rate (48 kHz in v1).
  final int sampleRate;

  /// Interleaved float32 stereo at [sampleRate] for `[start, end)`.
  Float32List mix(RenderPlan plan, TimeUs start, TimeUs end) {
    final n = AudioMath.sampleCount(start, end, sampleRate);
    final acc = Float64List(n * 2);
    for (final seg in plan.audio) {
      final asset = plan.assets[seg.asset];
      if (asset == null) throw StateError('ReferenceAudioMixer: missing asset ${seg.asset}');
      final audio = sources.audio(seg.asset, asset, seg.stream);
      if (audio == null) throw StateError('ReferenceAudioMixer: no audio content for asset ${seg.asset}');
      final matrix = AudioMath.downmixMatrix(audio.channels);
      // Only samples with t0 ≤ t < t1.
      final first = math.max(0, AudioMath.sampleCount(start, seg.t0, sampleRate));
      final last = math.min(n, AudioMath.sampleCount(start, seg.t1, sampleRate));
      var m = 0;
      for (var i = first; i < last; i++) {
        final t = AudioMath.sampleTimeUs(start, i, sampleRate);
        if (t < seg.t0 || t >= seg.t1) continue;
        while (m < seg.map.length - 1 && t >= seg.map[m].t1) {
          m++;
        }
        final ms = seg.map[m];
        final s = ms.s0 + (t - ms.t0) * (ms.s1 - ms.s0) / (ms.t1 - ms.t0);
        final g = AudioMath.gainAt(seg.gain, t);
        if (g == 0) continue;
        var l = 0.0;
        var r = 0.0;
        for (var ch = 0; ch < audio.channels; ch++) {
          final x = audio.sampleAt(ch, s);
          if (x == 0) continue;
          l += matrix[0][ch] * x;
          r += matrix[1][ch] * x;
        }
        acc[2 * i] += l * g;
        acc[2 * i + 1] += r * g;
      }
    }
    final out = Float32List(n * 2);
    for (var i = 0; i < acc.length; i++) {
      out[i] = AudioMath.hardClip(acc[i]);
    }
    return out;
  }

  /// Splits an interleaved stereo [mix] into windows of [windowSamples] frames (the last, partial
  /// window is dropped) and measures each.
  static List<AudioWindow> windows(Float32List mix, {int windowSamples = AudioMath.windowSamples}) {
    final frames = mix.length ~/ 2;
    final out = <AudioWindow>[];
    for (var w = 0; (w + 1) * windowSamples <= frames; w++) {
      var sl = 0.0, sr = 0.0, pl = 0.0, pr = 0.0;
      for (var i = w * windowSamples; i < (w + 1) * windowSamples; i++) {
        final l = mix[2 * i].toDouble();
        final r = mix[2 * i + 1].toDouble();
        sl += l * l;
        sr += r * r;
        pl = math.max(pl, l.abs());
        pr = math.max(pr, r.abs());
      }
      out.add(AudioWindow(
        index: w,
        rmsL: math.sqrt(sl / windowSamples),
        rmsR: math.sqrt(sr / windowSamples),
        peakL: pl,
        peakR: pr,
      ));
    }
    return out;
  }
}
