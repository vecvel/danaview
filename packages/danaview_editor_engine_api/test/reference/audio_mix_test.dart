// OWNER: API-03
//
// The Dart reference audio mixer and gain math (ARCH §11.6 Audio row, D-37), the oracle of QA-11
// and IOS-18: per-sample gain up to 2.0 (+6.02 dB), half-open segments, varispeed maps, mono
// duplication, ITU downmix, hard clip, 20 ms window levels; and replays of gain.json and
// audio_mix.json from the JSON alone.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/fixtures.dart';

const PlanCanvas canvas = PlanCanvas(w: 64, h: 36, fps: 30);
const PlanAsset audioAsset = PlanAsset(kind: PlanAssetKind.audio, uri: 'file:///a.wav', durUs: 60000000);

RenderPlan single({List<AnimKey> gain = const [AnimKey(0, 1)], int t0 = 0, int t1 = 1000000, int s0 = 0, int? s1, bool pitch = true}) =>
    RenderPlan(
      rev: 1,
      target: PlanTarget.export,
      canvas: canvas,
      durUs: 2000000,
      assets: const {'md_a': audioAsset},
      audio: [
        AudioSeg(
            id: 'it_a#a', asset: 'md_a', t0: t0, t1: t1, map: [MapSegment(t0, t1, s0, s1 ?? s0 + (t1 - t0))], gain: gain, pitch: pitch),
      ],
    );

ReferenceAudioMixer mixerFor(ReferenceAudio audio) => ReferenceAudioMixer(sources: MapReferenceSources(audios: {'md_a': audio}));

double rms(Float32List pcm, int channel, [int from = 0, int? to]) {
  final end = to ?? pcm.length ~/ 2;
  var s = 0.0;
  for (var i = from; i < end; i++) {
    s += pcm[2 * i + channel] * pcm[2 * i + channel];
  }
  return math.sqrt(s / (end - from));
}

int zeroCrossings(Float32List pcm, int channel) {
  var n = 0;
  for (var i = 1; i < pcm.length ~/ 2; i++) {
    if ((pcm[2 * (i - 1) + channel] < 0) != (pcm[2 * i + channel] < 0)) n++;
  }
  return n;
}

ToneAudio tonesOf(Map<String, Object?> j) => ToneAudio(
      [
        for (final c in list(j['channels']))
          c == null ? null : Tone(asDouble(obj(c)['freqHz']), asDouble(obj(c)['amplitude']), asDouble(obj(c)['phase'])),
      ],
      durUs: j['durUs'] as int?,
    );

void main() {
  group('AudioMath', () {
    test('200 % is +6.02 dB, 50 % is −6.02 dB', () {
      expect(AudioMath.gainToDb(2), closeTo(6.0206, 1e-4));
      expect(AudioMath.gainToDb(0.5), closeTo(-6.0206, 1e-4));
      expect(AudioMath.dbToGain(AudioMath.gainToDb(0.4)), closeTo(0.4, 1e-12));
      expect(AudioMath.gainToDb(0), double.negativeInfinity);
      expect(AudioMath.levelDb(0), AudioMath.silenceDb);
    });

    test('gain envelopes are linear between keys, held outside, and agree with evaluateAnimKeys', () {
      const keys = [AnimKey(1000, 0), AnimKey(3000, 2), AnimKey(5000, 0.5)];
      expect(AudioMath.gainAt(keys, 0), 0);
      expect(AudioMath.gainAt(keys, 2000), 1);
      expect(AudioMath.gainAt(keys, 2500.5), closeTo(1.5005, 1e-12));
      expect(AudioMath.gainAt(keys, 9e9), 0.5);
      for (var t = 0; t <= 6000; t += 37) {
        expect(AudioMath.gainAt(keys, t.toDouble()), evaluateAnimKeys(keys, t));
      }
    });

    test('sample times are exact rationals and counts are ceil((end − start)·rate/10⁶)', () {
      expect(AudioMath.sampleTimeUs(0, 48000), 1e6);
      expect(AudioMath.sampleTimeUs(0, 1), closeTo(20.8333333, 1e-6));
      expect(AudioMath.sampleCount(0, 1000000), 48000);
      expect(AudioMath.sampleCount(0, 1), 1);
      expect(AudioMath.sampleCount(0, 21), 2);
      expect(AudioMath.sampleCount(5, 5), 0);
    });

    test('downmix matrices: mono duplicated, stereo as is, ITU −3 dB for centre and surrounds, LFE dropped', () {
      expect(AudioMath.downmixMatrix(1), [
        [1.0],
        [1.0],
      ]);
      expect(AudioMath.downmixMatrix(2), [
        [1.0, 0.0],
        [0.0, 1.0],
      ]);
      final m6 = AudioMath.downmixMatrix(6);
      expect(m6[0][2], closeTo(math.sqrt1_2, 1e-15));
      expect(m6[0][3], 0);
      expect(m6[1][5], closeTo(math.sqrt1_2, 1e-15));
      for (final n in [3, 4, 5, 7, 8]) {
        expect(AudioMath.downmixMatrix(n)[0], hasLength(n));
      }
    });

    test('equal-power crossfade keeps power constant', () {
      for (var x = 0.0; x <= 1; x += 0.05) {
        final o = AudioMath.equalPowerOut(x);
        final i = AudioMath.equalPowerIn(x);
        expect(o * o + i * i, closeTo(1, 1e-12));
      }
    });
  });

  group('ReferenceAudioMixer', () {
    test('a mono tone is duplicated to both channels sample-exactly', () {
      const tone = Tone(1000, 0.25);
      final pcm = mixerFor(const ToneAudio([tone])).mix(single(), 0, 100000);
      expect(pcm.length, 2 * 4800);
      for (final i in [0, 1, 7, 100, 4799]) {
        final expected = tone.at(i * 1e6 / 48000);
        expect(pcm[2 * i], closeTo(expected, 1e-7));
        expect(pcm[2 * i + 1], pcm[2 * i]);
      }
    });

    test('gain 2.0 is +6.02 dB over gain 1.0 (V-N21)', () {
      const audio = ToneAudio([Tone(1000, 0.25)]);
      final unity = mixerFor(audio).mix(single(), 0, 500000);
      final boosted = mixerFor(audio).mix(single(gain: const [AnimKey(0, 2)]), 0, 500000);
      expect(AudioMath.gainToDb(rms(boosted, 0) / rms(unity, 0)), closeTo(6.0206, 1e-6));
    });

    test('segments are half-open on the sample grid', () {
      final pcm = mixerFor(const ToneAudio([Tone(1000, 0.5, math.pi / 2)])).mix(single(t0: 1000000, t1: 1500000), 0, 2000000);
      expect(pcm[2 * 47999], 0); // t < t0
      expect(pcm[2 * 48000], closeTo(0.5, 1e-7)); // t = t0, source time 0, phase π/2
      expect(pcm[2 * 71999], isNot(0));
      expect(pcm[2 * 72000], 0); // t = t1
    });

    test('a 2× map without pitch keeping doubles the frequency', () {
      final normal = mixerFor(const ToneAudio([Tone(500, 0.5)])).mix(single(), 0, 1000000);
      final fast = mixerFor(const ToneAudio([Tone(500, 0.5)])).mix(single(s1: 2000000, pitch: false), 0, 1000000);
      expect(zeroCrossings(normal, 0), closeTo(1000, 2));
      expect(zeroCrossings(fast, 0), closeTo(2000, 2));
    });

    test('5.1 downmix and hard clip', () {
      final surround = mixerFor(const ToneAudio([null, null, Tone(1000, 0.5), Tone(100, 0.9), null, null])).mix(single(), 0, 100000);
      expect(rms(surround, 0), closeTo(0.5 * math.sqrt1_2 * math.sqrt1_2, 1e-6));
      expect(rms(surround, 1), closeTo(rms(surround, 0), 1e-9));
      final loud = mixerFor(const ToneAudio([Tone(1000, 0.75)])).mix(single(gain: const [AnimKey(0, 2)]), 0, 100000);
      expect(loud.reduce(math.max), 1);
      expect(loud.reduce(math.min), -1);
    });

    test('PCM sources interpolate linearly between samples', () {
      final pcm = PcmAudio(sampleRate: 1000, channels: 2, interleaved: Float32List.fromList([0, 1, 1, 0, 0.5, 0.5]));
      expect(pcm.frames, 3);
      expect(pcm.sampleAt(0, 500), closeTo(0.5, 1e-7));
      expect(pcm.sampleAt(1, 1500), closeTo(0.25, 1e-7));
      expect(pcm.sampleAt(0, 5000), 0);
    });

    test('20 ms windows: a sine of peak A has RMS A/√2', () {
      final pcm = mixerFor(const ToneAudio([Tone(1000, 0.5), Tone(500, 0.25)])).mix(single(), 0, 200000);
      final w = ReferenceAudioMixer.windows(pcm);
      expect(w, hasLength(10));
      for (final x in w) {
        expect(x.rmsL, closeTo(0.5 * math.sqrt1_2, 1e-6));
        expect(x.rmsR, closeTo(0.25 * math.sqrt1_2, 1e-6));
        expect(x.peakL, closeTo(0.5, 1e-3));
        expect(x.rmsDbL, closeTo(AudioMath.gainToDb(0.5 * math.sqrt1_2), 1e-5));
      }
    });

    test('silence measures at the −120 dBFS floor and missing content throws', () {
      final pcm = mixerFor(const ToneAudio([null])).mix(single(), 0, 40000);
      expect(ReferenceAudioMixer.windows(pcm).first.rmsDbL, -120);
      expect(() => const ReferenceAudioMixer(sources: MapReferenceSources()).mix(single(), 0, 1000), throwsStateError);
    });
  });

  group('gain.json replays from the JSON alone', () {
    final doc = vectorFile('gain.json');
    for (final raw in list(doc['envelopes'])) {
      final e = obj(raw);
      test('${e['name']}', () {
        final keys = [for (final k in list(e['keys'])) AnimKey((list(k)[0]! as num).toInt(), asDouble(list(k)[1]))];
        for (final rawS in list(e['samples'])) {
          final s = obj(rawS);
          final t = AudioMath.sampleTimeUs(0, s['i']! as int);
          expect(t, closeTo(asDouble(s['tUs']), 1e-8));
          final g = AudioMath.gainAt(keys, t);
          expect(g, closeTo(asDouble(s['g']), 1e-9));
          if (s['errDb'] != null) expect(asDouble(s['errDb']).abs(), lessThanOrEqualTo(0.1));
        }
      });
    }

    test('dB table includes +6.02 dB for 200 %', () {
      final two = list(doc['db']).map(obj).firstWhere((j) => j['g'] == 2.0);
      expect(asDouble(two['db']), closeTo(6.0206, 1e-4));
    });
  });

  group('audio_mix.json replays from the JSON alone', () {
    final doc = vectorFile('audio_mix.json');
    for (final raw in list(doc['cases'])) {
      final c = obj(raw);
      test('${c['name']}', () {
        final plan = PlanJson.decodePlan(obj(c['plan']));
        expect(PlanValidator.validate(plan), isEmpty);
        final sources = {for (final e in obj(c['sources']).entries) e.key: tonesOf(obj(e.value))};
        final pcm = ReferenceAudioMixer(sources: MapReferenceSources(audios: sources)).mix(plan, c['startUs']! as int, c['endUs']! as int);
        expect(pcm.length ~/ 2, c['frames']);
        final windows = ReferenceAudioMixer.windows(pcm, windowSamples: c['windowSamples']! as int);
        final expected = list(c['windows']);
        expect(windows, hasLength(expected.length));
        for (var i = 0; i < windows.length; i++) {
          final e = doubles(expected[i]);
          expect(windows[i].rmsDbL, closeTo(e[0], 1e-6), reason: 'window $i L');
          expect(windows[i].rmsDbR, closeTo(e[1], 1e-6), reason: 'window $i R');
          expect(windows[i].peakL, closeTo(e[2], 1e-6));
          expect(windows[i].peakR, closeTo(e[3], 1e-6));
        }
        for (final rawS in list(c['samples'])) {
          final s = obj(rawS);
          final i = s['i']! as int;
          expect(pcm[2 * i], closeTo(asDouble(s['l']), 1e-7));
          expect(pcm[2 * i + 1], closeTo(asDouble(s['r']), 1e-7));
        }
      });
    }

    test('the three-lane reference project covers the QA-11 ingredients', () {
      final c = list(doc['cases']).map(obj).firstWhere((c) => c['name'] == 'three_lane_reference');
      final plan = PlanJson.decodePlan(obj(c['plan']));
      expect(plan.audio.length, 4);
      expect(plan.audio.expand((a) => a.gain).map((k) => k.v), contains(2.0));
      expect(list(c['omitted']).map((o) => obj(o)['flag']), containsAll(<String>['muted', 'soloedOut']));
      // No window clips and the mix is never silent while a lane plays.
      for (final w in list(c['windows'])) {
        final v = doubles(w);
        expect(v[2], lessThan(1));
        expect(v[0], greaterThan(-60));
      }
    });
  });
}
