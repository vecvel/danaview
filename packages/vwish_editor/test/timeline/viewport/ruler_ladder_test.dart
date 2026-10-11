// OWNER: UX-09
//
// Ruler ladder (ux.md §8.5, §21.1): spacing >= label width + 24 at every zoom on every v1 frame
// rate, the smallest such step is chosen, frame-level labels, 4 h durations, minor subdivisions and
// the per-second frame ticks; plus the LRU label cache.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/ruler.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_style.dart';
import 'package:vwish_editor_core/model.dart';

const _s = microsPerSecond;

/// A deterministic label width (tabular figures: every character the same advance).
double _width(String template, double scale) => template.length * 11 * 0.62 * scale;

final _rates = [for (final fps in FrameRate.supportedProjectRates) FrameRate.project(fps)];

RulerScale _choose(double pps, FrameRate rate, TimeUs maxTime, double scale) {
  final frameTemplate = RulerScale(const RulerStep.frames(1), rate).labelTemplate(maxTime);
  final secondTemplate = RulerScale(const RulerStep.seconds(1), rate).labelTemplate(maxTime);
  return RulerLadder.choose(
    pxPerSecond: pps,
    rate: rate,
    frameLabelWidth: _width(frameTemplate, scale),
    secondLabelWidth: _width(secondTemplate, scale),
  );
}

/// Zoom levels from the smallest of a 4 h project at 280 px to 48 px per frame, geometric.
Iterable<double> _zooms(FrameRate rate) sync* {
  final min = 280 / (4 * 3600 + 10);
  final max = rate.fps * 48;
  for (var pps = min; pps <= max; pps *= 1.07) {
    yield pps;
  }
  yield max;
}

void main() {
  test('the ladder: 1f, 2f, 5f, 10f, half a second, then the seconds of ux.md §8.5 (+ long steps)', () {
    expect(RulerLadder.stepsFor(FrameRate.fps30).map((s) => '$s').toList(), [
      '1f', '2f', '5f', '10f', '15f', //
      '1s', '2s', '5s', '10s', '15s', '30s', '60s', '120s', '300s', '600s', '900s', '1800s', '3600s',
      '7200s', '10800s', '21600s', '43200s',
    ]);
    expect(RulerLadder.stepsFor(FrameRate.fps25).where((s) => s.isFrameStep).map((s) => s.frames), [1, 2, 5, 10, 12]);
    expect(RulerLadder.stepsFor(FrameRate.fps60).where((s) => s.isFrameStep).map((s) => s.frames), [1, 2, 5, 10, 30]);
    for (final rate in _rates) {
      final steps = RulerLadder.stepsFor(rate);
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].minSpacingSec(rate), greaterThan(steps[i - 1].minSpacingSec(rate)), reason: '$rate ${steps[i]}');
      }
    }
  });

  for (final scale in [0.85, 1.0, 1.35]) {
    test('at text scale $scale every zoom on every rate gets the smallest step with spacing >= label + 24', () {
      for (final rate in _rates) {
        for (final maxTime in [30 * _s, 75 * 60 * _s, 4 * 3600 * _s]) {
          final steps = RulerLadder.stepsFor(rate);
          for (final pps in _zooms(rate)) {
            final chosen = _choose(pps, rate, maxTime, scale);
            final need = _width(chosen.labelTemplate(maxTime), scale) + RulerLadder.labelGap;
            final i = steps.indexOf(chosen.step);
            if (i < steps.length - 1) {
              expect(chosen.step.minSpacingSec(rate) * pps, greaterThanOrEqualTo(need - 1e-9), reason: '$rate pps $pps');
            }
            for (final smaller in steps.take(i)) {
              final w = _width(RulerScale(smaller, rate).labelTemplate(maxTime), scale) + RulerLadder.labelGap;
              expect(smaller.minSpacingSec(rate) * pps, lessThan(w), reason: '$smaller fits at $pps on $rate, $chosen is not the smallest');
            }
          }
        }
      }
    });
  }

  test('painted majors (including the frame steps restarting each second) are never closer than label + 24', () {
    for (final rate in _rates) {
      for (final pps in _zooms(rate)) {
        const maxTime = 2 * 3600 * _s;
        final chosen = _choose(pps, rate, maxTime, 1.35);
        if (chosen.step == RulerLadder.stepsFor(rate).last) continue;
        final need = _width(chosen.labelTemplate(maxTime), 1.35) + RulerLadder.labelGap;
        // A 1280 px window somewhere in the middle of the project.
        final start = 3000.0;
        final end = start + 1280 / pps;
        final majors = <TimeUs>[];
        var minors = 0;
        chosen.forEachTick(start, end, (t, major) => major ? majors.add(t) : minors++);
        expect(majors.length, greaterThanOrEqualTo(1));
        for (var i = 1; i < majors.length; i++) {
          final dx = (majors[i] - majors[i - 1]) / _s * pps;
          expect(dx, greaterThanOrEqualTo(need - 1e-6), reason: '$rate $chosen pps $pps');
        }
        if (chosen.minorDivisions > 1) {
          expect(minors, greaterThan(0));
          // Minor ticks are at least 8 px apart.
          final all = <TimeUs>[];
          chosen.forEachTick(start, end, (t, _) => all.add(t));
          for (var i = 1; i < all.length; i++) {
            expect((all[i] - all[i - 1]) / _s * pps, greaterThanOrEqualTo(RulerLadder.minMinorSpacing - 1e-6));
          }
        }
      }
    }
  });

  test('ticks are on the frame grid and sorted, and none are before 0', () {
    for (final rate in _rates) {
      for (final pps in [rate.fps * 48, rate.fps * 10, 50.0, 3.0]) {
        final chosen = _choose(pps, rate, 600 * _s, 1);
        final ticks = <TimeUs>[];
        chosen.forEachTick(-5, 40, (t, _) => ticks.add(t));
        expect(ticks.first, greaterThanOrEqualTo(0));
        for (var i = 1; i < ticks.length; i++) {
          expect(ticks[i], greaterThan(ticks[i - 1]));
        }
        if (chosen.step.isFrameStep) {
          for (final t in ticks) {
            expect(rate.isOnGrid(t), isTrue);
          }
        }
      }
    }
  });

  test('frame steps restart every second and drop a major closer than one step to the next second', () {
    final scale = RulerScale(const RulerStep.frames(10), FrameRate.fps24, minorDivisions: 5);
    final majors = <int>[], minors = <int>[];
    scale.forEachTick(0, 2, (t, major) => (major ? majors : minors).add(FrameRate.fps24.frameIndexOf(t)));
    expect(majors, [0, 10, 24, 34, 48]);
    expect(minors.take(10), [2, 4, 6, 8, 12, 14, 16, 18, 20, 22]);
    final half = RulerScale(const RulerStep.frames(12), FrameRate.fps25, minorDivisions: 2);
    final halfMajors = <int>[];
    half.forEachTick(0, 1.99, (t, major) => major ? halfMajors.add(FrameRate.fps25.frameIndexOf(t)) : null);
    expect(halfMajors, [0, 12, 25, 37]);
  });

  test('labels: m:ss:ff for frame steps, m:ss for seconds, h:mm:ss for hours', () {
    const fps30 = FrameRate.fps30;
    final frames = _choose(fps30.fps * 48, fps30, 60 * _s, 1);
    expect(frames.step.isFrameStep, isTrue);
    expect(frames.label(fps30.timeOfFrame(30 * 65 + 12)), '1:05:12');
    expect(frames.label(0), '0:00:00');
    expect(frames.label(fps30.timeOfFrame(30 * 754)), '12:34:00');
    expect(frames.label(fps30.timeOfFrame(30 * 3725 + 3)), '1:02:05:03');
    final seconds = _choose(20, fps30, 60 * _s, 1);
    expect(seconds.step.isFrameStep, isFalse);
    expect(seconds.label(65 * _s), '1:05');
    expect(seconds.label(3725 * _s), '1:02:05');
    expect(seconds.labelTemplate(3725 * _s), '0:00:00');
    expect(frames.labelTemplate(75 * 60 * _s), '00:00:00');
  });

  test('4 h projects: the smallest zoom at the narrowest width still separates hour labels', () {
    for (final rate in _rates) {
      const duration = 4 * 3600 * _s;
      final pps = 280 / (4 * 3600 + 10);
      final chosen = _choose(pps, rate, duration, 1.35);
      expect(chosen.step.seconds, greaterThanOrEqualTo(3600));
      final labels = <String>[];
      chosen.forEachTick(0, 4 * 3600.0, (t, major) => major ? labels.add(chosen.label(t)) : null);
      expect(labels.first, '0:00:00');
      expect(labels.last, '4:00:00');
      final need = _width(chosen.labelTemplate(duration), 1.35) + RulerLadder.labelGap;
      expect(chosen.step.seconds * pps, greaterThanOrEqualTo(need));
    }
  });

  test('minor ticks: fifths, else halves (>= 8 px), frame steps only by whole frames', () {
    expect(RulerLadder.minorDivisionsFor(const RulerStep.seconds(10), 100), 5);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.seconds(10), 39), 2);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.seconds(10), 15), 1);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.frames(10), 100), 5);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.frames(12), 100), 2);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.frames(5), 100), 5);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.frames(2), 100), 2);
    expect(RulerLadder.minorDivisionsFor(const RulerStep.frames(1), 100), 1);
  });

  test('tick visits are bounded', () {
    const scale = RulerScale(RulerStep.seconds(1), FrameRate.fps30, minorDivisions: 5);
    var n = 0;
    scale.forEachTick(0, 1e9, (_, __) => n++);
    expect(n, RulerScale.maxTicks);
    scale.forEachTick(10, 5, (_, __) => fail('empty range'));
    scale.forEachTick(-10, -5, (_, __) => fail('before 0'));
  });

  group('label cache', () {
    final style = TimelineStyle.standard.withFontFamily('Ahem');

    test('LRU of 256 keyed by (text, scale)', () {
      final cache = RulerLabelCache();
      for (var i = 0; i < 300; i++) {
        cache.paragraph('l$i', 1, style);
      }
      expect(cache.length, 256);
      expect(cache.contains('l0', 1), isFalse);
      expect(cache.contains('l299', 1), isTrue);
      // A hit moves to the most recent end.
      final p = cache.paragraph('l44', 1, style);
      expect(identical(cache.paragraph('l44', 1, style), p), isTrue);
      cache.paragraph('fresh', 1, style);
      expect(cache.contains('l44', 1), isTrue);
      expect(cache.contains('l45', 1), isFalse);
      // The scale is part of the key.
      expect(identical(cache.paragraph('l44', 1.35, style), p), isFalse);
    });

    test('a different style clears it; widths grow with the scale', () {
      final cache = RulerLabelCache(capacity: 8);
      final w1 = cache.widthOf('0:00:00', 1, style);
      final w2 = cache.widthOf('0:00:00', 1.35, style);
      expect(w2, greaterThan(w1));
      expect(cache.length, 2);
      cache.paragraph('x', 1, TimelineStyle.standard.withFontFamily('Ahem'));
      expect(cache.length, 1);
      cache.clear();
      expect(cache.length, 0);
      expect(math.max(w1, 1), greaterThan(0));
    });
  });
}
