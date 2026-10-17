// OWNER: CORE-02
//
// Properties of the frame grid, the platform-time rule and TimeRange (ARCH §5, D-35).

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

const _twoPow53 = 1 << 53;

void main() {
  const rates = FrameRate.supportedProjectRates;

  group('floorDiv / ceilDiv', () {
    test('are negative-safe', () {
      expect(floorDiv(7, 2), 3);
      expect(floorDiv(-7, 2), -4);
      expect(floorDiv(-8, 2), -4);
      expect(floorDiv(0, 5), 0);
      expect(ceilDiv(7, 2), 4);
      expect(ceilDiv(-7, 2), -3);
      expect(ceilDiv(-8, 2), -4);
      expect(ceilDiv(0, 5), 0);
    });

    test('agree with the real quotient on a sweep', () {
      for (var a = -50; a <= 50; a++) {
        for (var b = 1; b <= 9; b++) {
          expect(floorDiv(a, b), (a / b).floor(), reason: '$a/$b');
          expect(ceilDiv(a, b), (a / b).ceil(), reason: '$a/$b');
        }
      }
    });
  });

  group('frame grid', () {
    test('frameIndexOf(timeOfFrame(k)) == k and the last µs of frame k maps to k, for every sampled k up to 24 h', () {
      final rnd = Random(20261008);
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        final lastFrame = 24 * 3600 * fps;
        final ks = <int>{
          for (var k = 0; k <= 4 * fps + 3; k++) k,
          for (final base in [3600 * fps, 12 * 3600 * fps, lastFrame - 4]) ...[for (var d = -3; d <= 3; d++) base + d],
          for (var i = 0; i < 20000; i++) rnd.nextInt(lastFrame),
          lastFrame - 1,
        };
        for (final k in ks) {
          if (k < 0 || k >= lastFrame) continue;
          expect(r.frameIndexOf(r.timeOfFrame(k)), k, reason: '$fps fps k=$k');
          expect(r.frameIndexOf(r.timeOfFrame(k + 1) - 1), k, reason: '$fps fps k=$k end');
        }
      }
    });

    test('timeOfFrame is ceil(k·1e6/fps) and strictly increasing', () {
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        var previous = -1;
        for (var k = 0; k < 2 * fps + 5; k++) {
          final t = r.timeOfFrame(k);
          expect(t, (k * 1000000 / fps).ceil(), reason: '$fps fps k=$k');
          expect(t, greaterThan(previous));
          previous = t;
        }
        expect(r.timeOfFrame(fps), 1000000, reason: 'frame fps starts at exactly 1 s');
      }
    });

    test('quantize floors, quantizeNearest rounds (ties later), isOnGrid agrees', () {
      const r = FrameRate.fps30;
      expect(r.quantize(0), 0);
      expect(r.quantize(33333), 0);
      expect(r.quantize(33334), 33334);
      expect(r.isOnGrid(33334), isTrue);
      expect(r.isOnGrid(33333), isFalse);
      expect(r.quantizeNearest(16666), 0);
      expect(r.quantizeNearest(16667), 33334, reason: 'tie between 0 and 33334 goes to the later frame');
      expect(r.quantizeNearest(16668), 33334);
      expect(r.quantizeNearest(50000), 33334);
      expect(r.quantizeNearest(50001), 66667);
      for (var t = 0; t < 200000; t += 997) {
        expect(r.isOnGrid(r.quantize(t)), isTrue);
        expect(r.isOnGrid(r.quantizeNearest(t)), isTrue);
        expect(r.quantize(t), lessThanOrEqualTo(t));
        expect((r.quantizeNearest(t) - t).abs(), lessThanOrEqualTo(16667));
      }
    });

    test('negative times floor correctly', () {
      const r = FrameRate.fps30;
      expect(r.frameIndexOf(-1), -1);
      expect(r.frameIndexOf(-33334), -2);
      expect(r.quantize(-1), r.timeOfFrame(-1));
    });

    test('frameUs and frameDurationAt', () {
      expect(FrameRate.fps30.frameUs, 33333);
      expect(FrameRate.fps24.frameUs, 41667);
      expect(FrameRate.fps25.frameUs, 40000);
      expect(FrameRate.fps60.frameUs, 16667);
      expect(FrameRate.fps30.numerator, 30);
      expect(FrameRate.fps30.denominator, 1);
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        var sum = 0;
        for (var k = 0; k < fps; k++) {
          sum += r.frameDurationAt(k);
        }
        expect(sum, 1000000, reason: '$fps fps frames add up to exactly one second');
      }
    });

    test('rational rates keep the type honest (29.97) without being project rates', () {
      const ntsc = FrameRate(30000, 1001);
      expect(ntsc.isSupportedProjectRate, isFalse);
      expect(ntsc.timeOfFrame(30000), 1001000000);
      expect(ntsc.frameIndexOf(ntsc.timeOfFrame(12345)), 12345);
      expect(const FrameRate(60, 2), FrameRate.fps30, reason: 'equality is rational');
      expect(const FrameRate(60, 2).hashCode, FrameRate.fps30.hashCode);
    });

    test('FrameRate.project validates (D-03)', () {
      for (final fps in rates) {
        expect(FrameRate.project(fps).isSupportedProjectRate, isTrue);
      }
      for (final bad in [0, 1, 23, 29, 31, 59, 120]) {
        expect(() => FrameRate.project(bad), throwsArgumentError, reason: '$bad');
      }
    });

    test('no intermediate product of the grid math exceeds 2^53 up to 24 h', () {
      for (final fps in rates) {
        final k = 24 * 3600 * fps; // last frame count
        final tMax = maxProjectDurationUs;
        final products = [
          k * microsPerSecond, // timeOfFrame numerator
          tMax * fps, // frameIndexOf numerator
          tMax * fps + 500000, // frameIndexNearest numerator
          2 * k * microsPerSecond + fps, // platformTimeOfFrame numerator
          2 * tMax * fps + microsPerSecond, // frameIndexOfRational numerator
        ];
        for (final p in products) {
          expect(p, lessThan(_twoPow53), reason: '$fps fps product $p');
          expect(p, lessThan(22000000000000000), reason: 'ARCH §5: products stay below 2.2e16');
        }
      }
    });
  });

  group('platform-time rule (D-35)', () {
    test('frameIndexNearest(x) == k for the plan, floor and platform forms and the rational, up to 24 h', () {
      final rnd = Random(35);
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        final lastFrame = 24 * 3600 * fps;
        final ks = <int>{
          for (var k = 0; k < 4 * fps; k++) k,
          for (var i = 0; i < 20000; i++) rnd.nextInt(lastFrame),
          lastFrame - 1,
          3600 * fps,
          3600 * fps + 1,
          3600 * fps + 2,
        };
        for (final k in ks) {
          final forms = [r.timeOfFrame(k), floorDiv(k * microsPerSecond, fps), r.platformTimeOfFrame(k)];
          for (final x in forms) {
            expect(r.frameIndexNearest(x), k, reason: '$fps fps k=$k x=$x');
          }
          expect(r.frameIndexOfRational(k, fps), k);
        }
      }
    });

    test('frameIndexNearest(x) == k for every integer x within half a frame − 1 µs of k·1e6/fps', () {
      final rnd = Random(36);
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        final lastFrame = 24 * 3600 * fps;
        final halfFrame = 1000000 / (2 * fps);
        for (var i = 0; i < 20000; i++) {
          final k = rnd.nextInt(lastFrame);
          final exact = k * 1000000 / fps;
          final lo = (exact - halfFrame + 1).ceil();
          final hi = (exact + halfFrame - 1).floor();
          for (final x in [lo, hi, lo + rnd.nextInt(hi - lo + 1)]) {
            expect(r.frameIndexNearest(x), k, reason: '$fps fps k=$k x=$x');
          }
        }
      }
    });

    test('P(k) equals Media3\'s double formula round((1e6/fps)·k) for every sampled k up to 24 h', () {
      final rnd = Random(37);
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        final lastFrame = 24 * 3600 * fps;
        final ks = <int>{
          for (var k = 0; k < 4 * fps; k++) k,
          for (var i = 0; i < 20000; i++) rnd.nextInt(lastFrame),
          lastFrame - 1,
        };
        for (final k in ks) {
          expect(r.platformTimeOfFrame(k), ((1000000 / fps) * k).round(), reason: '$fps fps k=$k');
        }
      }
    });

    test('platform times are within 1 µs of the plan edge; equal for 25 and 50 fps', () {
      for (final fps in rates) {
        final r = FrameRate(fps, 1);
        for (var k = 0; k < 3 * fps; k++) {
          final d = r.timeOfFrame(k) - r.platformTimeOfFrame(k);
          expect(d, anyOf(0, 1), reason: '$fps fps k=$k');
          if (fps == 25 || fps == 50) expect(d, 0);
        }
      }
    });

    test('floor-based mapping of a platform time is wrong exactly where D-35 says it is', () {
      const r = FrameRate.fps30;
      final wrong = [for (var k = 0; k < 90; k++) if (r.frameIndexOf(r.platformTimeOfFrame(k)) != k) k];
      expect(wrong, isNotEmpty);
      expect(wrong.every((k) => k % 3 == 1), isTrue, reason: 'only frames k ≡ 1 (mod 3) have a plan edge after P(k)');
    });
  });

  group('TimeRange', () {
    test('half-open containment and duration', () {
      const a = TimeRange(10, 20);
      expect(a.duration, 10);
      expect(a.isEmpty, isFalse);
      expect(a.contains(10), isTrue);
      expect(a.contains(19), isTrue);
      expect(a.contains(20), isFalse);
      expect(a.contains(9), isFalse);
      expect(const TimeRange(5, 5).isEmpty, isTrue);
      expect(const TimeRange.withDuration(5, 7), const TimeRange(5, 12));
    });

    test('intersect, overlaps and shift', () {
      const a = TimeRange(10, 20);
      expect(a.intersect(const TimeRange(15, 30)), const TimeRange(15, 20));
      expect(a.intersect(const TimeRange(20, 30)), isNull, reason: 'touching ranges do not intersect');
      expect(a.intersect(const TimeRange(0, 10)), isNull);
      expect(a.intersect(const TimeRange(12, 14)), const TimeRange(12, 14));
      expect(a.overlaps(const TimeRange(19, 25)), isTrue);
      expect(a.overlaps(const TimeRange(20, 25)), isFalse);
      expect(a.shift(5), const TimeRange(15, 25));
      expect(a.shift(-15), const TimeRange(-5, 5));
    });

    test('equality and hashCode', () {
      expect(const TimeRange(1, 2), const TimeRange(1, 2));
      expect(const TimeRange(1, 2).hashCode, const TimeRange(1, 2).hashCode);
      expect(const TimeRange(1, 2), isNot(const TimeRange(1, 3)));
    });
  });

  group('MapSegment', () {
    test('rate, sourceAt and contains', () {
      const s = MapSegment(0, 1000, 500, 2500);
      expect(s.rate, 2);
      expect(s.sourceAt(250), 1000);
      expect(s.contains(0), isTrue);
      expect(s.contains(999), isTrue);
      expect(s.contains(1000), isFalse);
      expect(s, const MapSegment(0, 1000, 500, 2500));
      expect(s.hashCode, const MapSegment(0, 1000, 500, 2500).hashCode);
    });
  });
}
