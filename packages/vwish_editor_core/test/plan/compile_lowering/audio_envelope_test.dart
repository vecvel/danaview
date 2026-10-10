// OWNER: CORE-31
//
// Gain envelopes (ARCH §11.7): products of volume keys, fades, transition dips and equal-power
// crossfades are sampled every 20 ms where non-linear and stay within 0.1 dB of the analytic gain
// (absolute below −60 dBFS); volume 200% is 2.0 (+6.02 dB); speeds above maxAudioSpeed mute
// their span (D-15).

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import 'lowering_support.dart';

double db(double x) => 20 * math.log(x) / math.ln10;

/// The worst error of [model]'s envelope against the analytic gain, sampled every [step] µs.
double worstErrorDb(GainModel model, {int step = 137}) {
  final env = model.envelope();
  var worst = 0.0;
  for (var t = model.t0; t <= model.t1; t += step) {
    final exact = model.at(t);
    final lin = evaluateAnimKeys(env, t);
    final double e;
    if (exact >= gainFloor) {
      e = db(lin / exact).abs();
    } else {
      e = (lin - exact).abs() <= gainFloor * (math.pow(10, gainToleranceDb / 20) - 1) ? 0 : double.infinity;
    }
    if (e > worst) worst = e;
  }
  return worst;
}

void main() {
  test('volume 200% is a 2.0 gain (+6.02 dB) and stays one key', () {
    final env = GainModel(0, 1000000, [LinearGain.constant(2)]).envelope();
    expect(env, [const AnimKey(0, 2)]);
    expect(db(env.single.v), closeTo(6.0206, 1e-4));
  });

  test('volume 200% × fade in × fade out: exact linear pieces', () {
    final model = GainModel(0, 3000000, [
      LinearGain.constant(2),
      LinearGain([const AnimKey(0, 0), const AnimKey(500000, 1)]),
      LinearGain([const AnimKey(2000000, 1), const AnimKey(3000000, 0)]),
    ]);
    expect(model.envelope(), [const AnimKey(0, 0), const AnimKey(500000, 2), const AnimKey(2000000, 2), const AnimKey(3000000, 0)]);
    expect(worstErrorDb(model), 0);
  });

  test('equal-power crossfade × volume ramp: ≤ 0.1 dB, samples every 20 ms', () {
    final model = GainModel(0, 1000000, [
      const EqualPowerGain(200000, 800000, rising: false),
      LinearGain([const AnimKey(0, 2), const AnimKey(1000000, 0.5)]),
    ]);
    final env = model.envelope();
    final inWindow = env.where((k) => k.tUs > 200000 && k.tUs < 800000).length;
    expect(inWindow, greaterThanOrEqualTo(29), reason: '600 ms / 20 ms');
    expect(worstErrorDb(model), lessThanOrEqualTo(gainToleranceDb));
  });

  test('random products of every factor kind stay within 0.1 dB of the analytic gain', () {
    final rnd = math.Random(31);
    for (var i = 0; i < 300; i++) {
      final t1 = 200000 + rnd.nextInt(4000000);
      // One volume factor (0–2); every other factor is ≤ 1, as in real clips.
      final factors = <GainFactor>[LinearGain.constant(rnd.nextDouble() * 2)];
      final n = 1 + rnd.nextInt(4);
      for (var j = 0; j < n; j++) {
        switch (rnd.nextInt(4)) {
          case 0:
            final ks = <AnimKey>[];
            var t = rnd.nextInt(t1 ~/ 4);
            for (var k = 0; k < 2 + rnd.nextInt(4); k++) {
              ks.add(AnimKey(t, rnd.nextDouble()));
              t += 1 + rnd.nextInt(t1 ~/ 3);
            }
            factors.add(LinearGain(ks));
          case 1:
            factors.add(LinearGain([const AnimKey(0, 0), AnimKey(1 + rnd.nextInt(t1 ~/ 2), 1)]));
          case 2:
            final a = rnd.nextInt(t1 ~/ 2);
            factors.add(EqualPowerGain(a, a + 1 + rnd.nextInt(t1 ~/ 2), rising: rnd.nextBool()));
          default:
            factors.add(LinearGain([AnimKey(t1 - 1 - rnd.nextInt(t1 ~/ 2), 1), AnimKey(t1, 0)]));
        }
      }
      final model = GainModel(0, t1, factors);
      expect(worstErrorDb(model, step: 211), lessThanOrEqualTo(gainToleranceDb), reason: 'case $i');
      final env = model.envelope();
      for (var k = 1; k < env.length; k++) {
        expect(env[k].tUs, greaterThan(env[k - 1].tUs));
      }
      expect(env.every((k) => k.v >= 0 && k.v <= 2), isTrue);
    }
  });

  test('speed gate mutes segments faster than maxAudioSpeed with a 1 µs step', () {
    final map = [
      const MapSegment(0, 1000000, 0, 2000000), // 2×
      const MapSegment(1000000, 1500000, 2000000, 5000000), // 6×
      const MapSegment(1500000, 2000000, 5000000, 6000000), // 2×
    ];
    final gate = speedGate(map, 4)!;
    expect(gate.keys, [
      const AnimKey(0, 1),
      const AnimKey(999999, 1),
      const AnimKey(1000000, 0),
      const AnimKey(1499999, 0),
      const AnimKey(1500000, 1),
      const AnimKey(2000000, 1),
    ]);
    expect(speedGate(map, 6), isNull);
  });

  test('a ramp crossing maxAudioSpeed mutes only the fast part of the compiled segment', () {
    final music = asset('md_music000001', MediaKind.audio, w: null, h: null, duration: 120000000);
    final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 8), const SpeedPoint(1, 1)]);
    final p = project([
      mainLane(const []),
      lane('tr_music', TrackKind.audio, [audioClip('it_ramp00000001', 0, 150, 'md_music000001', speed: ramp)]),
    ], assets: [music]);
    final c = compileStd(p, PlanTarget.preview);
    expect(c.violations(), isEmpty);
    final a = c.plan.audio.single;
    for (final s in a.map) {
      final mid = (s.t0 + s.t1) ~/ 2;
      expect(evaluateAnimKeys(a.gain, mid), s.rate > 4 ? 0 : 1, reason: 'segment rate ${s.rate}');
    }
  });
}
