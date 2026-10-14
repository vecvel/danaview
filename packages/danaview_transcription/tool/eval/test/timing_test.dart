// OWNER: QA-06
//
// Boundary error matching, CPS distribution and percentiles (tool/eval/src/timing.dart).

import 'package:flutter_test/flutter_test.dart';

import '../src/timing.dart';

void main() {
  test('percentile interpolates between ranks', () {
    expect(percentile(const [], 50), isNull);
    expect(percentile(const [7], 90), 7);
    expect(percentile(const [1, 2, 3, 4], 50), 2.5);
    expect(percentile(const [4, 1, 3, 2], 0), 1);
    expect(percentile(const [4, 1, 3, 2], 100), 4);
  });

  group('boundaryErrors', () {
    test('matches each reference cue to the generated cue with the most overlap', () {
      const ref = [TimedCue(0, 2000, 'a'), TimedCue(2500, 5000, 'b')];
      const gen = [TimedCue(100, 1900, 'a'), TimedCue(2000, 2600, 'x'), TimedCue(2700, 5300, 'b')];
      final e = boundaryErrors(ref, gen);
      expect(e.matchedCues, 2);
      expect(e.errorsMs, [100, 100, 200, 300]);
      expect(e.medianMs, 150);
      expect(e.matchedFraction, 1);
    });

    test('a reference cue no generated cue overlaps is unmatched', () {
      final e = boundaryErrors(const [TimedCue(0, 1000, 'a'), TimedCue(5000, 6000, 'b')], const [TimedCue(0, 1000, 'a')]);
      expect(e.matchedCues, 1);
      expect(e.matchedFraction, 0.5);
      expect(e.medianMs, 0);
    });

    test('pooling keeps every error', () {
      final a = boundaryErrors(const [TimedCue(0, 1000, 'a')], const [TimedCue(100, 1000, 'a')]);
      final b = boundaryErrors(const [TimedCue(0, 1000, 'a')], const [TimedCue(0, 1300, 'a')]);
      final both = a + b;
      expect(both.errorsMs, [100, 0, 0, 300]);
      expect(both.referenceCues, 2);
    });
  });

  group('cps', () {
    test('counts graphemes with line breaks as spaces', () {
      expect(const TimedCue(0, 1000, 'ab\ncd').cps, 5);
      expect(const TimedCue(0, 2000, '日本語です').cps, 2.5);
      expect(const TimedCue(1000, 1000, 'x').cps, double.infinity);
    });

    test('distribution and over-limit fraction', () {
      final d = cpsDistribution(const [
        TimedCue(0, 1000, 'abcdefghij'), // 10
        TimedCue(0, 1000, 'abcdefghijklmnopqrst'), // 20
        TimedCue(0, 0, 'skip'),
      ], 17);
      expect(d.values, [10, 20]);
      expect(d.p50, 15);
      expect(d.max, 20);
      expect(d.overLimitFraction, 0.5);
    });
  });
}
