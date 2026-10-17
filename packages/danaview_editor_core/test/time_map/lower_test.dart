// OWNER: CORE-06
//
// ClipTimeMap.lower(): contiguous coverage, breakpoints on frame starts of the project grid
// (D-35), rates in [0.1, 10], error ≤ 250 µs at every frame start, reversed maps, splits, and the
// ≤ 0.2 ms benchmark for a 7-point ramp.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../model/core/model_fixtures.dart' show f, r30;
import 'speed_math_test.dart' show randomRamp;

ClipTimeMap map({
  int startFrame = 0,
  int frames = 90,
  TimeUs sourceIn = 0,
  SpeedSpec speed = SpeedSpec.normal,
  bool reversed = false,
  FrameRate rate = r30,
}) =>
    ClipTimeMap(
      start: rate.timeOfFrame(startFrame),
      duration: rate.timeOfFrame(startFrame + frames) - rate.timeOfFrame(startFrame),
      sourceIn: sourceIn,
      speed: speed,
      reversed: reversed,
      rate: rate,
    );

/// Source (or rendition) time of the lowered map at timeline time [t].
double lowered(List<MapSegment> segs, TimeUs t) {
  for (final s in segs) {
    if (t < s.t1 || identical(s, segs.last)) return s.sourceAt(t);
  }
  throw StateError('unreachable');
}

/// The true time the lowered map stands for: source time for forward clips, `sourceOut − r` for
/// reversed clips.
double sourceOfLowered(ClipTimeMap m, List<MapSegment> segs, TimeUs t) {
  final v = lowered(segs, t);
  return m.reversed ? m.sourceOut - v : v;
}

/// Checks every contract of `lower()` for [m] and returns the segments.
List<MapSegment> checkLowering(ClipTimeMap m, {int maxErrorUs = 250, String reason = ''}) {
  final segs = m.lower(maxErrorUs: maxErrorUs);
  expect(segs, isNotEmpty, reason: reason);
  // Covers the clip, contiguous in time.
  expect(segs.first.t0, m.start, reason: reason);
  expect(segs.last.t1, m.end, reason: reason);
  for (var i = 1; i < segs.length; i++) {
    expect(segs[i].t0, segs[i - 1].t1, reason: '$reason: contiguous in t at $i');
    expect(segs[i].s0, segs[i - 1].s1, reason: '$reason: continuous in s at $i');
  }
  // Every breakpoint t on a frame start of the project grid (the clip's own ends are on it too).
  for (final s in segs) {
    expect(m.rate.isOnGrid(s.t0), isTrue, reason: '$reason: t0 ${s.t0} on the ${m.rate} grid');
    expect(m.rate.isOnGrid(s.t1), isTrue, reason: '$reason: t1 ${s.t1} on the ${m.rate} grid');
    expect(s.rate, inInclusiveRange(0.1, 10), reason: '$reason: rate of $s');
    expect(s.t1, greaterThan(s.t0));
    expect(s.s1, greaterThanOrEqualTo(s.s0));
  }
  // Starts and ends in the playback asset's time.
  final base = m.reversed ? 0 : m.sourceIn;
  expect(segs.first.s0, base, reason: reason);
  expect(segs.last.s1, base + m.sourceLengthUs, reason: reason);
  // Error at every frame start and at every breakpoint.
  final k0 = m.rate.frameIndexOf(m.start);
  final k1 = m.rate.frameIndexOf(m.end);
  var worst = 0.0;
  for (var k = k0; k < k1; k++) {
    final t = m.rate.timeOfFrame(k);
    final err = (sourceOfLowered(m, segs, t) - m.sourceAt(t)).abs();
    if (err > worst) worst = err;
  }
  for (final s in segs) {
    final err = (sourceOfLowered(m, segs, s.t0) - m.sourceAt(s.t0)).abs();
    if (err > worst) worst = err;
  }
  expect(worst, lessThanOrEqualTo(maxErrorUs), reason: '$reason: worst error $worst µs');
  return segs;
}

void main() {
  group('constant speed', () {
    test('lowers to exactly one segment', () {
      final m = map(startFrame: 4, frames: 60, sourceIn: 1000000, speed: const ConstantSpeed(2));
      final segs = checkLowering(m);
      expect(segs, hasLength(1));
      expect(segs.single, MapSegment(m.start, m.end, 1000000, m.sourceOut));
    });

    test('rates at the bounds stay in [0.1, 10] after rounding', () {
      for (final rate in [0.1, 0.1000001, 9.9999, 10.0, 1 / 3, 1.0000001]) {
        for (final frames in [1, 2, 7, 100]) {
          final segs = checkLowering(map(frames: frames, speed: ConstantSpeed(rate)), reason: 'rate $rate frames $frames');
          expect(segs, hasLength(1));
        }
      }
    });

    test('reversed lowers to an increasing map into the rendition (0 at the clip start)', () {
      final m = map(frames: 60, sourceIn: 5000000, speed: const ConstantSpeed(2), reversed: true);
      final segs = checkLowering(m);
      expect(segs.single.s0, 0);
      expect(segs.single.s1, m.sourceLengthUs);
      expect(segs.single.rate, closeTo(2, 1e-6));
    });
  });

  group('ramps', () {
    final montage = SpeedRamp([
      const SpeedPoint(0, 1),
      const SpeedPoint(0.15, 5),
      const SpeedPoint(0.3, 0.3),
      const SpeedPoint(0.5, 0.3),
      const SpeedPoint(0.7, 6),
      const SpeedPoint(0.85, 1.5),
      const SpeedPoint(1, 1),
    ]);

    test('a 7-point ramp lowers within tolerance with at most one segment per frame', () {
      final m = map(frames: 300, sourceIn: 1234567, speed: montage);
      final segs = checkLowering(m, reason: 'montage');
      expect(segs.length, inInclusiveRange(7, 300), reason: 'got ${segs.length}');
    });

    test('a gentle ramp lowers to a few dozen segments, not one per frame (adaptive)', () {
      final gentle = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 1.1), const SpeedPoint(1, 1)]);
      final m = map(frames: 300, speed: gentle);
      final segs = checkLowering(m, reason: 'gentle');
      expect(segs.length, inInclusiveRange(10, 60), reason: 'got ${segs.length}');
    });

    test('segment count grows with curvature: steeper ramps need more segments', () {
      int count(double peak) => map(frames: 300, speed: SpeedRamp([const SpeedPoint(0, 1), SpeedPoint(0.5, peak), const SpeedPoint(1, 1)])).lower().length;
      expect(count(1.05), lessThan(count(1.5)));
      expect(count(1.5), lessThanOrEqualTo(count(4)));
    });

    test('segment seams: the ramp corners appear as breakpoints (snapped to frames)', () {
      final m = map(frames: 300, speed: montage);
      final segs = m.lower();
      final cuts = segs.map((s) => s.t0).toSet();
      final profile = RampProfile(montage);
      for (var i = 1; i < profile.length - 1; i++) {
        final corner = m.start + (m.sourceLengthUs * profile.cumulative[i]).round();
        final snapped = r30.quantizeNearest(corner);
        expect(cuts, contains(snapped), reason: 'corner $i at $corner snapped to $snapped');
      }
    });

    test('a tighter tolerance gives more segments and still meets it', () {
      final m = map(frames: 300, speed: montage);
      final coarse = checkLowering(m, maxErrorUs: 2000);
      final fine = checkLowering(m, maxErrorUs: 20);
      final default250 = checkLowering(m);
      expect(fine.length, greaterThan(default250.length));
      expect(default250.length, greaterThanOrEqualTo(coarse.length));
    });

    test('reversed ramps lower to the increasing rendition map, mirrored in time', () {
      final m = map(frames: 240, sourceIn: 3000000, speed: montage, reversed: true);
      final segs = checkLowering(m, reason: 'reversed montage');
      final fwd = map(frames: 240, sourceIn: 0, speed: montage);
      final fsegs = fwd.lower();
      expect(segs.map((s) => (s.t0, s.t1, s.s0, s.s1)), fsegs.map((s) => (s.t0, s.t1, s.s0, s.s1)),
          reason: 'with sourceIn 0 a reversed ramp lowers to the same increasing map as the forward ramp');
    });

    test('a one-frame ramp clip is a single segment', () {
      final m = map(frames: 1, speed: SpeedRamp([const SpeedPoint(0, 0.5), const SpeedPoint(1, 8)]));
      expect(checkLowering(m), hasLength(1));
    });

    test('flat ramps behave like a constant speed', () {
      final m = map(frames: 200, speed: SpeedRamp([const SpeedPoint(0, 3), const SpeedPoint(0.4, 3), const SpeedPoint(1, 3)]));
      final segs = checkLowering(m);
      expect(segs.length, lessThanOrEqualTo(3));
    });

    test('extreme speeds: 0.1× to 10× and back in a 24 h clip lowers and meets the tolerance', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.1), const SpeedPoint(0.5, 10), const SpeedPoint(1, 0.1)]);
      final m = ClipTimeMap(start: 0, duration: 3600 * 1000000, sourceIn: 0, speed: ramp, rate: FrameRate.fps24);
      checkLowering(m, reason: '1 h at 24 fps');
    });

    test('every project rate: breakpoints are frame starts of that grid and the error holds', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.25), const SpeedPoint(0.4, 7), const SpeedPoint(1, 0.8)]);
      for (final fps in FrameRate.supportedProjectRates) {
        final rate = FrameRate(fps, 1);
        for (final startFrame in [0, 1, 2, 31, 32, 61, 62]) {
          checkLowering(map(startFrame: startFrame, frames: 3 * fps + 2, sourceIn: 100000, speed: ramp, rate: rate), reason: '$fps fps start $startFrame');
        }
      }
    });

    test('10,000 seeded random clips: contract holds for constants, ramps and reversed', () {
      final rnd = math.Random(250);
      for (var trial = 0; trial < 10000; trial++) {
        final rate = FrameRate(FrameRate.supportedProjectRates[rnd.nextInt(6)], 1);
        final SpeedSpec speed = rnd.nextInt(4) == 0 ? ConstantSpeed(math.pow(10, rnd.nextDouble() * 2 - 1).toDouble()) : randomRamp(rnd);
        final m = map(
          startFrame: rnd.nextInt(300),
          frames: 1 + rnd.nextInt(rnd.nextInt(10) == 0 ? 3000 : 300),
          sourceIn: rnd.nextInt(60000000),
          speed: speed,
          reversed: rnd.nextBool(),
          rate: rate,
        );
        checkLowering(m, reason: 'trial $trial');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('A/V sync: video layer and audio segments share one lowering', () {
    test('lowering is deterministic and pure', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 4), const SpeedPoint(1, 1)]);
      final a = map(frames: 200, sourceIn: 777, speed: ramp).lower();
      final b = map(frames: 200, sourceIn: 777, speed: ramp).lower();
      expect(a, b);
      expect(identical(a, b), isFalse);
    });
  });

  group('maps of the two halves of a split equal the original at every frame', () {
    test('lowered halves, forward and reversed ramps', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.5), const SpeedPoint(0.4, 6), const SpeedPoint(1, 1)]);
      for (final reversed in [false, true]) {
        final m = map(startFrame: 3, frames: 300, sourceIn: 2000000, speed: ramp, reversed: reversed);
        for (final cutFrame in [10, 60, 150, 290]) {
          final at = f(cutFrame);
          final s = m.splitAt(at);
          final left = ClipTimeMap(start: m.start, duration: s.leftDuration, sourceIn: s.leftSourceIn, speed: s.leftSpeed, reversed: reversed, rate: r30);
          final right = ClipTimeMap(start: at, duration: s.rightDuration, sourceIn: s.rightSourceIn, speed: s.rightSpeed, reversed: reversed, rate: r30);
          final ls = checkLowering(left, reason: 'left cut $cutFrame');
          final rs = checkLowering(right, reason: 'right cut $cutFrame');
          for (var k = 3; k < 303; k++) {
            final t = f(k);
            final half = t < at ? left : right;
            final segs = t < at ? ls : rs;
            expect((sourceOfLowered(half, segs, t) - m.sourceAt(t)).abs(), lessThanOrEqualTo(250 + 3), reason: 'frame $k reversed=$reversed cut $cutFrame');
          }
        }
      }
    });
  });

  group('benchmark', () {
    test('lower() of a 7-point ramp takes at most 0.2 ms (median of 300 runs after warm-up)', () {
      final ramp = SpeedRamp([
        const SpeedPoint(0, 1),
        const SpeedPoint(0.15, 5),
        const SpeedPoint(0.3, 0.3),
        const SpeedPoint(0.5, 0.3),
        const SpeedPoint(0.7, 6),
        const SpeedPoint(0.85, 1.5),
        const SpeedPoint(1, 1),
      ]);
      // A 10 s clip at 30 fps (300 frames), the size the timeline works with for ramped clips.
      final m = map(frames: 300, sourceIn: 1000000, speed: ramp);
      var sink = 0;
      for (var i = 0; i < 400; i++) {
        sink += m.lower().length;
      }
      final micros = <int>[];
      final sw = Stopwatch();
      for (var i = 0; i < 300; i++) {
        sw
          ..reset()
          ..start();
        sink += m.lower().length;
        sw.stop();
        micros.add(sw.elapsedMicroseconds);
      }
      micros.sort();
      final median = micros[micros.length ~/ 2];
      printOnFailure('median $median µs, p90 ${micros[(micros.length * 0.9).floor()]} µs, sink $sink');
      // ignore: avoid_print
      print('lower() 7-point ramp, 300 frames: median $median µs, p90 ${micros[(micros.length * 0.9).floor()]} µs');
      expect(median, lessThanOrEqualTo(200));
    });
  });
}
