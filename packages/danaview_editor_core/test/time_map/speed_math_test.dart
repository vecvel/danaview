// OWNER: CORE-06
//
// Closed forms of speed ramps against numerical integration (≤ 1 µs over 10,000 seeded random
// ramps), the numeric helpers, ramp validation and cropping.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

/// Adaptive Simpson integral of [f] over [a, b] to a tight tolerance (independent of the closed
/// forms under test).
double integrate(double Function(double) f, double a, double b, {double eps = 1e-14}) {
  double simpson(double fa, double fm, double fb, double a, double b) => (b - a) / 6 * (fa + 4 * fm + fb);
  double rec(double a, double b, double fa, double fm, double fb, double whole, double eps, int depth) {
    final m = (a + b) / 2;
    final lm = (a + m) / 2;
    final rm = (m + b) / 2;
    final flm = f(lm);
    final frm = f(rm);
    final left = simpson(fa, flm, fm, a, m);
    final right = simpson(fm, frm, fb, m, b);
    final delta = left + right - whole;
    if (depth <= 0 || delta.abs() <= 15 * eps) return left + right + delta / 15;
    return rec(a, m, fa, flm, fm, left, eps / 2, depth - 1) + rec(m, b, fm, frm, fb, right, eps / 2, depth - 1);
  }

  final fa = f(a);
  final fb = f(b);
  final fm = f((a + b) / 2);
  return rec(a, b, fa, fm, fb, simpson(fa, fm, fb, a, b), eps, 40);
}

SpeedRamp randomRamp(math.Random rnd) {
  final n = 2 + rnd.nextInt(15); // 2..16 points
  final xs = <double>{0, 1};
  while (xs.length < n) {
    xs.add(0.02 + rnd.nextDouble() * 0.96);
  }
  final sorted = xs.toList()..sort();
  double speed() => math.pow(10, rnd.nextDouble() * 2 - 1).toDouble(); // log-uniform in [0.1, 10]
  return SpeedRamp([for (final x in sorted) SpeedPoint(x, speed())]);
}

/// Reference speed v(x) of [ramp] by plain linear interpolation.
double speedOf(SpeedRamp r, double x) {
  final p = r.points;
  for (var i = 0; i + 1 < p.length; i++) {
    if (x <= p[i + 1].x) return p[i].y + (p[i + 1].y - p[i].y) * ((x - p[i].x) / (p[i + 1].x - p[i].x));
  }
  return p.last.y;
}

void main() {
  group('numeric helpers', () {
    test('log1p and expm1 are accurate for tiny and ordinary arguments', () {
      expect(log1p(1e-20), closeTo(1e-20, 1e-35));
      expect(log1p(0), 0);
      expect(log1p(1), closeTo(math.ln2, 1e-15));
      expect(log1p(-0.5), closeTo(-math.ln2, 1e-15));
      expect(log1p(-1), double.negativeInfinity);
      expect(log1p(-2).isNaN, isTrue);
      expect(expm1(1e-20), closeTo(1e-20, 1e-35));
      expect(expm1(0), 0);
      expect(expm1(1), closeTo(math.e - 1, 1e-15));
      expect(expm1(-1), closeTo(1 / math.e - 1, 1e-15));
      expect(expm1(-800), -1);
      expect(expm1(1000), double.infinity);
    });

    test('log1pOverR and expm1OverZ are continuous through zero', () {
      expect(log1pOverR(0), 1);
      expect(expm1OverZ(0), 1);
      for (final x in [1e-12, -1e-12, 1e-9, -1e-9, 2e-9, -2e-9]) {
        expect(log1pOverR(x), closeTo(1 - x / 2, 1e-9), reason: '$x');
        expect(expm1OverZ(x), closeTo(1 + x / 2, 1e-9), reason: '$x');
      }
      for (final x in [1e-4, -1e-4, 0.3, -0.3, 5.0]) {
        expect(log1pOverR(x), closeTo(math.log(1 + x) / x, 1e-9), reason: '$x');
        expect(expm1OverZ(x), closeTo((math.exp(x) - 1) / x, 1e-9), reason: '$x');
      }
      expect(log1pOverR(1e-9 * 0.999), closeTo(log1pOverR(1e-9 * 1.001), 1e-9));
    });
  });

  group('segment closed forms', () {
    test('rampTime: constant speed is dx/v, and matches (1/b)·ln(v1/v0) otherwise', () {
      expect(rampTime(0.5, 2, 2), 0.25);
      expect(rampTime(1, 1, math.e), closeTo(1 / (math.e - 1), 1e-15));
      expect(rampTime(0, 1, 2), 0);
      const dx = 0.4, v0 = 0.5, v1 = 4.0;
      const b = (v1 - v0) / dx;
      expect(rampTime(dx, v0, v1), closeTo(math.log(v1 / v0) / b, 1e-14));
      expect(rampTime(dx, v1, v0), closeTo(math.log(v0 / v1) / -b, 1e-14), reason: 'decelerating segment');
    });

    test('rampOffsetAtTime inverts rampTime', () {
      final rnd = math.Random(1);
      for (var i = 0; i < 2000; i++) {
        final dx = 0.01 + rnd.nextDouble();
        final v0 = math.pow(10, rnd.nextDouble() * 2 - 1).toDouble();
        final v1 = rnd.nextInt(5) == 0 ? v0 : math.pow(10, rnd.nextDouble() * 2 - 1).toDouble();
        final part = rnd.nextDouble() * dx;
        final v = v0 + (v1 - v0) * part / dx;
        final u = rampTime(part, v0, v);
        expect(rampOffsetAtTime(u, dx, v0, v1), closeTo(part, 1e-12), reason: 'dx=$dx v0=$v0 v1=$v1');
      }
      expect(rampOffsetAtTime(0, 1, 1, 2), 0);
      expect(rampOffsetAtTime(-1, 1, 1, 2), 0);
    });
  });

  group('RampProfile vs numerical integration', () {
    test('total time K and the inverse match adaptive Simpson within 1 µs over 10,000 random ramps', () {
      final rnd = math.Random(2026);
      var worstTotal = 0.0;
      var worstInverse = 0.0;
      for (var trial = 0; trial < 10000; trial++) {
        final ramp = randomRamp(rnd);
        final profile = RampProfile(ramp);
        final lengthUs = 1e5 + rnd.nextDouble() * 3.6e9; // 0.1 s .. 1 h of source
        // Total: numeric integral of 1/v over the whole ramp, summed per segment (v is linear).
        var numeric = 0.0;
        final p = ramp.points;
        for (var i = 0; i + 1 < p.length; i++) {
          numeric += integrate((x) => 1 / speedOf(ramp, x), p[i].x, p[i + 1].x);
        }
        final errTotal = (lengthUs * profile.total - lengthUs * numeric).abs();
        worstTotal = math.max(worstTotal, errTotal);
        expect(errTotal, lessThan(1.0), reason: 'trial $trial total: closed ${lengthUs * profile.total} numeric ${lengthUs * numeric}');

        // Inverse: pick a random time, find x(τ), integrate 1/v back up to x and compare.
        final u = rnd.nextDouble() * profile.total;
        final x = profile.positionAtTime(u);
        var back = 0.0;
        for (var i = 0; i + 1 < p.length && p[i].x < x; i++) {
          back += integrate((t) => 1 / speedOf(ramp, t), p[i].x, math.min(x, p[i + 1].x));
        }
        final errInverse = (lengthUs * back - lengthUs * u).abs();
        worstInverse = math.max(worstInverse, errInverse);
        expect(errInverse, lessThan(1.0), reason: 'trial $trial inverse at u=$u x=$x');
      }
      // Reported for the record: both are far below the 1 µs budget.
      expect(worstTotal, lessThan(1.0));
      expect(worstInverse, lessThan(1.0));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('timeAtPosition and positionAtTime are inverse functions', () {
      final rnd = math.Random(7);
      for (var trial = 0; trial < 3000; trial++) {
        final profile = RampProfile(randomRamp(rnd));
        final x = rnd.nextDouble();
        expect(profile.positionAtTime(profile.timeAtPosition(x)), closeTo(x, 1e-10), reason: 'x=$x');
        final u = rnd.nextDouble() * profile.total;
        expect(profile.timeAtPosition(profile.positionAtTime(u)), closeTo(u, 1e-10 * math.max(1, profile.total)));
      }
    });

    test('boundaries and clamping', () {
      final profile = RampProfile(SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 4), const SpeedPoint(1, 0.5)]));
      expect(profile.timeAtPosition(0), 0);
      expect(profile.timeAtPosition(1), closeTo(profile.total, 1e-15));
      expect(profile.positionAtTime(0), 0);
      expect(profile.positionAtTime(-3), 0);
      expect(profile.positionAtTime(profile.total), 1);
      expect(profile.positionAtTime(profile.total + 3), 1);
      expect(profile.timeAtPosition(-1), 0);
      expect(profile.timeAtPosition(2), closeTo(profile.total, 1e-15));
      expect(profile.speedAtPosition(0), 1);
      expect(profile.speedAtPosition(0.25), closeTo(2.5, 1e-15));
      expect(profile.speedAtPosition(0.5), 4);
      expect(profile.speedAtPosition(0.75), closeTo(2.25, 1e-15));
      expect(profile.speedAtPosition(1), 0.5);
      expect(profile.length, 3);
      expect(profile.seamTimes.length, 3);
    });

    test('a flat ramp behaves like a constant speed', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 2), const SpeedPoint(0.3, 2), const SpeedPoint(1, 2)]);
      final profile = RampProfile(ramp);
      expect(profile.total, closeTo(0.5, 1e-15));
      expect(SpeedRamps.isFlat(ramp), isTrue);
      expect(SpeedRamps.isFlat(SpeedRamp([const SpeedPoint(0, 2), const SpeedPoint(1, 2.5)])), isFalse);
      expect(profile.positionAtTime(0.25), closeTo(0.5, 1e-15));
      expect(speedTimeFactor(const ConstantSpeed(4)), 0.25);
      expect(speedTimeFactor(ramp), closeTo(0.5, 1e-15));
      expect(SpeedRamps.timeFactor(ramp), closeTo(0.5, 1e-15));
      expect(SpeedRamps.speedAt(ramp, 0.9), 2);
    });

    test('speed climbing ten-fold over the whole clip takes ln(10)/9 of the source length', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.1), const SpeedPoint(1, 1)]);
      // ∫0^1 dx / (0.1 + 0.9x) = ln(10) / 0.9
      expect(RampProfile(ramp).total, closeTo(math.log(10) / 0.9, 1e-14));
    });
  });

  group('validation', () {
    SpeedRamp ramp(List<(double, double)> pts) => SpeedRamp([for (final (x, y) in pts) SpeedPoint(x, y)]);

    test('a valid ramp has no issues', () {
      expect(speedRampIssues(ramp([(0, 1), (1, 2)])), isEmpty);
      expect(speedRampIssues(ramp([(0, 0.1), (0.2, 10), (0.9, 5), (1, 1)])), isEmpty);
      expect(speedRampIssues(ramp([for (var i = 0; i < 16; i++) (i / 15, 1.0 + i / 10)])), isEmpty);
    });

    test('every rule reports', () {
      expect(speedRampIssues(ramp([(0, 1)])), isNotEmpty, reason: 'too few');
      expect(speedRampIssues(ramp([for (var i = 0; i < 17; i++) (i / 16, 1.0)])), isNotEmpty, reason: 'too many');
      expect(speedRampIssues(ramp([(0.1, 1), (1, 1)])), isNotEmpty, reason: 'x0 != 0');
      expect(speedRampIssues(ramp([(0, 1), (0.9, 1)])), isNotEmpty, reason: 'xn != 1');
      expect(speedRampIssues(ramp([(0, 1), (0.5, 1), (0.5, 2), (1, 1)])), isNotEmpty, reason: 'not strictly increasing');
      expect(speedRampIssues(ramp([(0, 1), (0.6, 1), (0.4, 2), (1, 1)])), isNotEmpty, reason: 'decreasing x');
      expect(speedRampIssues(ramp([(0, 0.05), (1, 1)])), isNotEmpty, reason: 'too slow');
      expect(speedRampIssues(ramp([(0, 1), (1, 10.5)])), isNotEmpty, reason: 'too fast');
      expect(speedRampIssues(ramp([(0, double.nan), (1, 1)])), isNotEmpty, reason: 'nan');
      expect(speedRampIssues(ramp([(0, 1), (1, double.infinity)])), isNotEmpty, reason: 'infinite');
      expect(speedRampIssues(SpeedRamp(const [])), isNotEmpty);
    });

    test('RampProfile rejects an invalid ramp', () {
      expect(() => RampProfile(ramp([(0, 1)])), throwsArgumentError);
      expect(() => RampProfile(ramp([(0, 1), (1, 20)])), throwsArgumentError);
    });
  });

  group('crop keeps content speeds', () {
    final ramp = SpeedRamp([
      const SpeedPoint(0, 1),
      const SpeedPoint(0.2, 4),
      const SpeedPoint(0.5, 0.5),
      const SpeedPoint(0.8, 8),
      const SpeedPoint(1, 2),
    ], presetId: 'montage');

    test('speeds at the same content are equal before and after', () {
      final cropped = SpeedRamps.crop(ramp, 0.3, 0.9);
      expect(speedRampIssues(cropped), isEmpty);
      expect(cropped.presetId, isNull);
      expect(cropped.points.first.x, 0);
      expect(cropped.points.last.x, 1);
      for (var i = 0; i <= 20; i++) {
        final xc = i / 20; // position in the cropped clip
        final xo = 0.3 + xc * 0.6; // same content in the original
        expect(SpeedRamps.speedAt(cropped, xc), closeTo(SpeedRamps.speedAt(ramp, xo), 1e-12), reason: 'xc=$xc');
      }
    });

    test('time of the cropped window equals the original time between the same positions', () {
      final profile = RampProfile(ramp);
      for (final (a, b) in [(0.0, 0.5), (0.3, 0.9), (0.25, 0.26), (0.5, 1.0), (0.0, 1.0)]) {
        final cropped = RampProfile(SpeedRamps.crop(ramp, a, b));
        // L' = L·(b−a): the window's time L'·K' must equal L·(u(b) − u(a)).
        expect(cropped.total * (b - a), closeTo(profile.timeAtPosition(b) - profile.timeAtPosition(a), 1e-12), reason: '[$a, $b]');
      }
    });

    test('the full window is the identity (without the preset id)', () {
      final c = SpeedRamps.crop(ramp, 0, 1);
      expect(c.points, ramp.points);
    });

    test('bad windows throw', () {
      expect(() => SpeedRamps.crop(ramp, 0.5, 0.5), throwsRangeError);
      expect(() => SpeedRamps.crop(ramp, -0.1, 0.5), throwsRangeError);
      expect(() => SpeedRamps.crop(ramp, 0.2, 1.1), throwsRangeError);
      expect(() => SpeedRamps.crop(ramp, 0.7, 0.3), throwsRangeError);
    });
  });
}
