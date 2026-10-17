// OWNER: CORE-06
//
// ClipTimeMap: constant speeds, ramps, reversed clips; the exact inverse; durationFor; split.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../model/core/model_fixtures.dart' show clip, f, r30;
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

void main() {
  group('constant speed', () {
    test('1× is the identity shifted by sourceIn', () {
      final m = map(startFrame: 10, frames: 90, sourceIn: 5000000);
      expect(m.start, f(10));
      expect(m.end, f(100));
      expect(m.sourceIn, 5000000);
      expect(m.sourceOut, 5000000 + (f(100) - f(10)));
      expect(m.toSource(f(10)), 5000000);
      expect(m.toSource(f(40)), 5000000 + f(40) - f(10));
      expect(m.speedAt(f(50)), 1);
      expect(m.sourceRange, TimeRange(5000000, m.sourceOut));
    });

    test('2× plays twice the source in the same time; sourceOut is derived', () {
      final m = map(frames: 90, speed: const ConstantSpeed(2));
      expect(m.sourceLengthUs, 2 * f(90));
      expect(m.sourceOut, 6000000);
      expect(m.toSource(f(30)), 2 * f(30));
      expect(m.speedAt(0), 2);
    });

    test('0.5× and 10× and 0.1×', () {
      expect(map(frames: 30, speed: const ConstantSpeed(0.5)).sourceOut, 500000);
      expect(map(frames: 30, speed: const ConstantSpeed(10)).sourceOut, 10000000);
      expect(map(frames: 30, speed: const ConstantSpeed(0.1)).sourceOut, 100000);
    });

    test('toSource clamps to the clip and to [sourceIn, sourceOut − 1]', () {
      final m = map(startFrame: 10, frames: 30, sourceIn: 1000);
      expect(m.toSource(0), 1000);
      expect(m.toSource(f(10) - 1), 1000);
      expect(m.toSource(m.end), m.sourceOut - 1);
      expect(m.toSource(m.end + 99999999), m.sourceOut - 1);
    });

    test('timelineTimeOf is the exact inverse and null when trimmed away', () {
      final m = map(startFrame: 10, frames: 30, sourceIn: 1000000, speed: const ConstantSpeed(2));
      expect(m.timelineTimeOf(1000000), f(10));
      expect(m.timelineTimeOf(1000000 + 2 * (f(20) - f(10))), f(20));
      expect(m.timelineTimeOf(999999), isNull);
      expect(m.timelineTimeOf(m.sourceOut), isNull);
      expect(m.timelineTimeOf(m.sourceOut - 1), closeTo(m.end, 1));
      expect(m.timelineAt(1000000.5), closeTo(f(10) + 0.25, 1e-9));
      expect(m.timelineAt(0), isNull);
    });

    test('invalid inputs are rejected', () {
      expect(() => map(speed: const ConstantSpeed(0.09)), throwsArgumentError);
      expect(() => map(speed: const ConstantSpeed(10.1)), throwsArgumentError);
      expect(() => ClipTimeMap(start: 0, duration: 0, sourceIn: 0, rate: r30), throwsArgumentError);
      expect(() => map(speed: SpeedRamp([const SpeedPoint(0, 1)])), throwsArgumentError);
    });

    test('forClip and the MediaClip extension agree', () {
      final c = clip('it_a', 5, 60).copyWith(sourceIn: 123456, speed: const ConstantSpeed(1.5));
      final m = c.timeMap(r30);
      expect(m.start, c.start);
      expect(m.duration, c.duration);
      expect(c.sourceOut, m.sourceOut);
      expect(c.sourceRange, m.sourceRange);
      expect(m.sourceOut, 123456 + (c.duration * 1.5).round());
    });
  });

  group('durationFor (duration authority)', () {
    test('keeps the source range: 12 s at 2× is 6 s, at 0.5× 24 s', () {
      const range = TimeRange(0, 12000000);
      expect(ClipTimeMap.durationFor(range, const ConstantSpeed(2), r30), 6000000);
      expect(ClipTimeMap.durationFor(range, const ConstantSpeed(0.5), r30), 24000000);
      expect(ClipTimeMap.durationFor(range, SpeedSpec.normal, r30), 12000000);
    });

    test('is quantized to the nearest frame and at least one frame', () {
      const range = TimeRange(1000, 1000 + 1000000);
      final d = ClipTimeMap.durationFor(range, const ConstantSpeed(3), r30);
      expect(r30.isOnGrid(d), isTrue);
      expect(d, r30.quantizeNearest((1000000 / 3).round()));
      expect(ClipTimeMap.durationFor(const TimeRange(0, 10), const ConstantSpeed(10), r30), r30.timeOfFrame(1));
      expect(ClipTimeMap.durationFor(const TimeRange(5, 5), SpeedSpec.normal, r30), r30.timeOfFrame(1));
    });

    test('uses the ramp total for ramps and round-trips through the map', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 4), const SpeedPoint(1, 0.5)]);
      const range = TimeRange(2000000, 12000000);
      final d = ClipTimeMap.durationFor(range, ramp, r30);
      expect(d, r30.quantizeNearest((10000000 * RampProfile(ramp).total).round()));
      final m = ClipTimeMap(start: 0, duration: d, sourceIn: range.start, speed: ramp, rate: r30);
      expect(m.sourceOut, closeTo(range.end, 70000), reason: 'quantizing the duration moves sourceOut by at most half a frame at the fastest speed (4×)');
      expect(ClipTimeMap.sourceLengthOf(d, ramp), m.sourceLengthUs);
    });

    test('durationFor on every project rate lands on the grid', () {
      for (final fps in FrameRate.supportedProjectRates) {
        final rate = FrameRate(fps, 1);
        for (final speed in [0.1, 0.25, 0.7, 1.0, 1.3, 3.0, 10.0]) {
          final d = ClipTimeMap.durationFor(const TimeRange(0, 7654321), ConstantSpeed(speed), rate);
          expect(rate.isOnGrid(d), isTrue, reason: '$fps fps ×$speed');
        }
      }
    });
  });

  group('ramps', () {
    final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.3, 4), const SpeedPoint(0.7, 0.5), const SpeedPoint(1, 2)]);

    test('the map starts at sourceIn and ends at sourceOut', () {
      final m = map(startFrame: 20, frames: 150, sourceIn: 2000000, speed: ramp);
      expect(m.sourceAt(m.start), closeTo(2000000, 1e-6));
      expect(m.sourceAt(m.end), closeTo(m.sourceOut, 1.0));
      expect(m.toSource(m.start), 2000000);
      expect(m.sourceOut, 2000000 + ClipTimeMap.sourceLengthOf(m.duration, ramp));
    });

    test('speedAt follows the ramp over source position and is continuous in time', () {
      final m = map(frames: 300, speed: ramp);
      expect(m.speedAt(m.start), closeTo(1, 1e-9));
      expect(m.speedAt(m.end), closeTo(2, 1e-6));
      var previous = m.speedAt(m.start);
      for (var k = 1; k <= 300; k++) {
        final v = m.speedAt(f(k));
        expect((v - previous).abs(), lessThan(0.5), reason: 'frame $k');
        expect(v, inInclusiveRange(0.5 - 1e-9, 4 + 1e-9));
        previous = v;
      }
    });

    test('derivative of sourceAt equals speedAt', () {
      final m = map(frames: 300, speed: ramp, sourceIn: 1000000);
      for (var k = 1; k < 299; k += 7) {
        final h = 200;
        final d = (m.sourceAt(f(k) + h) - m.sourceAt(f(k) - h)) / (2 * h);
        expect(d, closeTo(m.speedAt(f(k)), 1e-3), reason: 'frame $k');
      }
    });

    test('the source never goes backwards', () {
      final m = map(frames: 300, speed: ramp);
      var previous = -1.0;
      for (var t = m.start; t <= m.end; t += 9973) {
        final s = m.sourceAt(t);
        expect(s, greaterThanOrEqualTo(previous));
        previous = s;
      }
    });
  });

  group('reversed clips (s\' = sourceIn + sourceOut − s)', () {
    test('constant speed: the first frame shows the end of the source range', () {
      final m = map(startFrame: 5, frames: 60, sourceIn: 1000000, speed: const ConstantSpeed(2), reversed: true);
      expect(m.sourceOut, 1000000 + 2 * (f(65) - f(5)));
      expect(m.sourceAt(m.start), closeTo(m.sourceOut, 1e-9));
      expect(m.toSource(m.start), m.sourceOut - 1, reason: 'clamped to the last source µs');
      expect(m.sourceAt(f(35)), closeTo(m.sourceOut - 2 * (f(35) - f(5)), 1e-6));
      expect(m.sourceAt(m.end), closeTo(1000000, 1e-6));
    });

    test('timelineTimeOf mirrors: sourceOut shows at the start, sourceIn+1 near the end', () {
      final m = map(startFrame: 5, frames: 60, sourceIn: 1000000, reversed: true);
      expect(m.timelineTimeOf(m.sourceOut), m.start);
      expect(m.timelineTimeOf(1000000), isNull, reason: 'the reversed clip never reaches sourceIn itself');
      expect(m.timelineTimeOf(1000001), closeTo(m.end, 2));
      expect(m.timelineTimeOf(m.sourceOut + 1), isNull);
      expect(m.timelineTimeOf(999999), isNull);
    });

    test('reversed ramps use the same functions as forward ramps (mirrored)', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 4), const SpeedPoint(1, 0.5)]);
      final fwd = map(frames: 120, sourceIn: 3000000, speed: ramp);
      final rev = map(frames: 120, sourceIn: 3000000, speed: ramp, reversed: true);
      expect(rev.sourceOut, fwd.sourceOut);
      for (var k = 0; k <= 120; k += 5) {
        final t = f(k);
        expect(rev.sourceAt(t), closeTo(3000000 + fwd.sourceOut - fwd.sourceAt(t), 1e-6), reason: 'frame $k');
        expect(rev.speedAt(t), closeTo(fwd.speedAt(t), 1e-9));
      }
    });
  });

  group('round trips', () {
    test('timelineAt(sourceAt(t)) == t within 1 µs over 10,000 random clips (all speeds, ramps, reversed)', () {
      final rnd = math.Random(606);
      for (var trial = 0; trial < 10000; trial++) {
        final speed = rnd.nextInt(3) == 0 ? ConstantSpeed(math.pow(10, rnd.nextDouble() * 2 - 1).toDouble()) : randomRamp(rnd);
        final frames = 3 + rnd.nextInt(600);
        final m = map(
          startFrame: rnd.nextInt(400),
          frames: frames,
          sourceIn: rnd.nextInt(100000000),
          speed: speed,
          reversed: rnd.nextBool(),
          rate: FrameRate(FrameRate.supportedProjectRates[rnd.nextInt(6)], 1),
        );
        final t = m.start + rnd.nextInt(m.duration - 1);
        final back = m.timelineAt(m.sourceAt(t));
        expect(back, isNotNull, reason: 'trial $trial');
        expect((back! - t).abs(), lessThan(1.0), reason: 'trial $trial t=$t');
      }
    });

    test('timelineTimeOf(toSource(t)) == t ± 1 µs when the speed is at least 1×; bounded by the source quantum below', () {
      final rnd = math.Random(607);
      for (var trial = 0; trial < 5000; trial++) {
        final fast = rnd.nextBool();
        final speed = ConstantSpeed(fast ? 1 + rnd.nextDouble() * 9 : 0.1 + rnd.nextDouble() * 0.9);
        final m = map(frames: 5 + rnd.nextInt(300), sourceIn: rnd.nextInt(1000000), speed: speed, reversed: rnd.nextBool());
        final t = m.start + rnd.nextInt(m.duration - 2);
        final src = m.toSource(t);
        final back = m.timelineTimeOf(src);
        if (back == null) {
          // Only possible when clamping moved a reversed clip's first frame.
          expect(t, m.start);
          continue;
        }
        final tolerance = fast ? 1 : (1 / speed.rate).ceil() + 1;
        expect((back - t).abs(), lessThanOrEqualTo(tolerance), reason: 'trial $trial rate ${speed.rate}');
      }
    });

    test('ramp: timelineTimeOf(toSource(t)) is within 1 µs when every speed is ≥ 1, else within the source quantum', () {
      final rnd = math.Random(608);
      for (var trial = 0; trial < 3000; trial++) {
        final ramp = SpeedRamp([
          const SpeedPoint(0, 1),
          SpeedPoint(0.2 + rnd.nextDouble() * 0.6, 1 + rnd.nextDouble() * 9),
          SpeedPoint(1, 1 + rnd.nextDouble() * 9),
        ]);
        final m = map(frames: 30 + rnd.nextInt(300), sourceIn: rnd.nextInt(1000000), speed: ramp);
        final t = m.start + rnd.nextInt(m.duration - 1);
        final back = m.timelineTimeOf(m.toSource(t))!;
        expect((back - t).abs(), lessThanOrEqualTo(1), reason: 'trial $trial');
      }
    });
  });

  group('splitAt (defined through the time map)', () {
    void expectHalvesMatch(ClipTimeMap original, int cutFrame) {
      final at = f(cutFrame);
      final s = original.splitAt(at);
      expect(s.leftDuration, at - original.start);
      expect(s.rightDuration, original.end - at);
      final left = ClipTimeMap(
        start: original.start,
        duration: s.leftDuration,
        sourceIn: s.leftSourceIn,
        speed: s.leftSpeed,
        reversed: original.reversed,
        rate: original.rate,
      );
      final right = ClipTimeMap(
        start: at,
        duration: s.rightDuration,
        sourceIn: s.rightSourceIn,
        speed: s.rightSpeed,
        reversed: original.reversed,
        rate: original.rate,
      );
      final firstFrame = original.rate.frameIndexOf(original.start);
      final endFrame = original.rate.frameIndexOf(original.end);
      for (var k = firstFrame; k < endFrame; k++) {
        final t = original.rate.timeOfFrame(k);
        final expected = original.sourceAt(t);
        final half = t < at ? left : right;
        expect(half.sourceAt(t), closeTo(expected, 2.5), reason: 'frame $k (cut $cutFrame)');
        expect(half.speedAt(t), closeTo(original.speedAt(t), 1e-6), reason: 'speed at frame $k');
      }
      // Lowered maps of the halves cover the original at every frame, within the lowering error.
      final segs = [...left.lower(), ...right.lower()];
      expect(segs.first.t0, original.start);
      expect(segs.last.t1, original.end);
      for (var i = 1; i < segs.length; i++) {
        expect(segs[i].t0, segs[i - 1].t1);
      }
    }

    test('constant speed, forward and reversed', () {
      for (final reversed in [false, true]) {
        final m = map(startFrame: 7, frames: 100, sourceIn: 4000000, speed: const ConstantSpeed(1.7), reversed: reversed);
        for (final cut in [8, 30, 57, 106]) {
          expectHalvesMatch(m, cut);
        }
      }
    });

    test('ramps, forward and reversed: both halves equal the original at every frame', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.5), const SpeedPoint(0.25, 6), const SpeedPoint(0.6, 1), const SpeedPoint(1, 3)]);
      for (final reversed in [false, true]) {
        final m = map(startFrame: 12, frames: 240, sourceIn: 9000000, speed: ramp, reversed: reversed);
        for (final cut in [13, 40, 77, 120, 200, 251]) {
          expectHalvesMatch(m, cut);
        }
      }
    });

    test('random ramps and cuts', () {
      final rnd = math.Random(99);
      for (var trial = 0; trial < 300; trial++) {
        final frames = 20 + rnd.nextInt(300);
        final m = map(startFrame: rnd.nextInt(100), frames: frames, sourceIn: rnd.nextInt(5000000), speed: randomRamp(rnd), reversed: rnd.nextBool());
        final startFrame = r30.frameIndexOf(m.start);
        expectHalvesMatch(m, startFrame + 1 + rnd.nextInt(frames - 1));
      }
    });

    test('the halves keep the source range (sum of lengths ≈ original length)', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 2), const SpeedPoint(1, 0.5)]);
      final m = map(frames: 150, sourceIn: 1000000, speed: ramp);
      final s = m.splitAt(f(60));
      final leftOut = s.leftSourceIn + ClipTimeMap.sourceLengthOf(s.leftDuration, s.leftSpeed);
      final rightOut = s.rightSourceIn + ClipTimeMap.sourceLengthOf(s.rightDuration, s.rightSpeed);
      expect(leftOut, closeTo(s.rightSourceIn, 2));
      expect(rightOut, closeTo(m.sourceOut, 2));
    });

    test('invalid cut times throw', () {
      final m = map(startFrame: 10, frames: 30);
      expect(() => m.splitAt(m.start), throwsRangeError);
      expect(() => m.splitAt(m.end), throwsRangeError);
      expect(() => m.splitAt(0), throwsRangeError);
    });
  });
}
