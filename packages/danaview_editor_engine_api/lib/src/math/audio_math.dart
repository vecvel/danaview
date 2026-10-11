// OWNER: API-03
//
// Audio row of ARCH §11.6: `out = Σ seg(t)·gain(t)`, the gain envelope linearly interpolated
// (0–2, up to +6.02 dB) and applied per sample (iOS `MTAudioProcessingTap`, D-37; Android
// `GainProcessor`), 48 kHz stereo, mono duplicated, more than two channels downmixed with ITU
// coefficients, hard clip to [−1, 1]. The reference mixer (`../reference/audio_mix.dart`) and the
// vectors in `test_fixtures/vectors/gain.json` use these functions.

import 'dart:math' as math;

import 'package:danaview_editor_core/model.dart' show TimeUs;
import 'package:danaview_editor_core/plan.dart' show AnimKey, MapSegment;

/// Gain, timing, downmix and level math of the ARCH §11.6 Audio row (D-37).
abstract final class AudioMath {
  /// Output sample rate of every mix and export (48 kHz).
  static const int sampleRate = 48000;

  /// Samples per 20 ms measurement window at [sampleRate] (QA-11).
  static const int windowSamples = 960;

  /// ITU-R BS.775 downmix coefficient for centre and surround channels (−3 dB).
  static const double ituMinus3dB = 0.7071067811865476;

  /// Level floor reported for silence, in dBFS.
  static const double silenceDb = -120;

  /// Timeline time in µs of output sample [i] of a mix starting at [start]: `start + i·10⁶/rate`
  /// (exact rational, evaluated in double; no ε, ARCH §11.5).
  static double sampleTimeUs(TimeUs start, int i, [int rate = sampleRate]) => start + i * 1e6 / rate;

  /// Samples in `[start, end)` at [rate]: `ceil((end − start)·rate / 10⁶)`.
  static int sampleCount(TimeUs start, TimeUs end, [int rate = sampleRate]) {
    final num = (end - start) * rate;
    if (num <= 0) return 0;
    return (num + 999999) ~/ 1000000;
  }

  /// The gain envelope at fractional timeline time [tUs]: linear between keys, held outside
  /// (agrees exactly with core's `evaluateAnimKeys` at integer times).
  static double gainAt(List<AnimKey> gain, double tUs) {
    if (gain.isEmpty) return 1;
    if (tUs <= gain.first.tUs) return gain.first.v;
    if (tUs >= gain.last.tUs) return gain.last.v;
    var lo = 0;
    var hi = gain.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (gain[mid].tUs <= tUs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = gain[lo];
    final b = gain[hi];
    return a.v + (b.v - a.v) * (tUs - a.tUs) / (b.tUs - a.tUs);
  }

  /// The source time of timeline time [tUs] on [map] (the segment with `t0 ≤ t < t1`; the last
  /// segment's end maps to its `s1`), or null outside the map.
  static double? sourceTimeAt(List<MapSegment> map, double tUs) {
    for (final s in map) {
      if (tUs >= s.t0 && tUs < s.t1) return s.s0 + (tUs - s.t0) * (s.s1 - s.s0) / (s.t1 - s.t0);
    }
    return null;
  }

  /// `20·log10(g)`; −∞ for g ≤ 0.
  static double gainToDb(double g) => g > 0 ? 20 * math.log(g) / math.ln10 : double.negativeInfinity;

  /// `10^(db/20)`.
  static double dbToGain(double db) => math.pow(10, db / 20).toDouble();

  /// `20·log10(rms)` floored at [silenceDb] (no +3.01 dB sine correction).
  static double levelDb(double rms) => rms > 0 ? math.max(silenceDb, gainToDb(rms)) : silenceDb;

  /// Equal-power crossfade gain of the outgoing side at progress [x] ∈ [0, 1]: `cos(πx/2)`.
  static double equalPowerOut(double x) => math.cos(math.pi * x / 2);

  /// Equal-power crossfade gain of the incoming side at progress [x] ∈ [0, 1]: `sin(πx/2)`.
  static double equalPowerIn(double x) => math.sin(math.pi * x / 2);

  /// Hard clip to [−1, 1].
  static double hardClip(double v) => v < -1 ? -1.0 : (v > 1 ? 1.0 : v);

  /// The 2 × [channels] downmix matrix `[[L coefficients], [R coefficients]]`: mono duplicated,
  /// stereo as is, and ITU-R BS.775 for the SMPTE layouts (3 = L R C, 4 = L R Ls Rs,
  /// 5 = L R C Ls Rs, 6 = L R C LFE Ls Rs, 7 = L R C LFE Cs Ls Rs, 8 = L R C LFE Ls Rs Lb Rb):
  /// centre and surrounds at −3 dB, LFE dropped. Other counts keep the first two channels.
  static List<List<double>> downmixMatrix(int channels) {
    const k = ituMinus3dB;
    switch (channels) {
      case 1:
        return const [
          [1.0],
          [1.0],
        ];
      case 3:
        return const [
          [1.0, 0.0, k],
          [0.0, 1.0, k],
        ];
      case 4:
        return const [
          [1.0, 0.0, k, 0.0],
          [0.0, 1.0, 0.0, k],
        ];
      case 5:
        return const [
          [1.0, 0.0, k, k, 0.0],
          [0.0, 1.0, k, 0.0, k],
        ];
      case 6:
        return const [
          [1.0, 0.0, k, 0.0, k, 0.0],
          [0.0, 1.0, k, 0.0, 0.0, k],
        ];
      case 7:
        return const [
          [1.0, 0.0, k, 0.0, 0.5, k, 0.0],
          [0.0, 1.0, k, 0.0, 0.5, 0.0, k],
        ];
      case 8:
        return const [
          [1.0, 0.0, k, 0.0, k, 0.0, k, 0.0],
          [0.0, 1.0, k, 0.0, 0.0, k, 0.0, k],
        ];
      default:
        return [
          [for (var c = 0; c < channels; c++) c == 0 ? 1.0 : 0.0],
          [for (var c = 0; c < channels; c++) c == 1 ? 1.0 : 0.0],
        ];
    }
  }
}
