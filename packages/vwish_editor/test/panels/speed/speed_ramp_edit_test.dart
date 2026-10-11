// OWNER: UX-25
//
// The pure edits of the speed curve editor (ux.md §10.3): every result is a valid ramp
// (`speedRampIssues` empty: 2-16 points, x from 0 to 1 strictly increasing, speeds in [0.1, 10]),
// the editor keeps 3-7 points, the end points keep their x, a speed near 1x snaps to 1x, and every
// edit makes the curve custom. Plus the plot's coordinate mapping.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/panels/speed_curve_editor.dart';
import 'package:vwish_editor_core/eval.dart' show speedRampIssues;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show SpeedRampPresets;

SpeedRamp ramp(List<(double, double)> points) => SpeedRamp([for (final p in points) SpeedPoint(p.$1, p.$2)]);

void expectValid(SpeedRamp r, {String? why}) => expect(speedRampIssues(r), isEmpty, reason: why ?? r.points.toString());

void main() {
  group('movePoint', () {
    final base = ramp([(0, 1), (0.4, 2), (0.7, 0.5), (1, 1)]);

    test('an interior point moves in x and y, between its neighbours', () {
      final r = SpeedRampEdit.movePoint(base, 1, x: 0.5, y: 3);
      expect(r.points[1], const SpeedPoint(0.5, 3));
      expectValid(r);
      final blocked = SpeedRampEdit.movePoint(base, 1, x: 0.9);
      expect(blocked.points[1].x, closeTo(0.7 - SpeedRampEdit.minGap, 1e-9), reason: 'stays left of its right neighbour');
      final left = SpeedRampEdit.movePoint(base, 2, x: -4);
      expect(left.points[2].x, closeTo(0.4 + SpeedRampEdit.minGap, 1e-9));
    });

    test('the end points keep x = 0 and x = 1 and only change speed', () {
      final r = SpeedRampEdit.movePoint(base, 0, x: 0.3, y: 4);
      expect(r.points.first, const SpeedPoint(0, 4));
      final end = SpeedRampEdit.movePoint(base, 3, x: 0.2, y: 0.25);
      expect(end.points.last, const SpeedPoint(1, 0.25));
      expectValid(r);
      expectValid(end);
    });

    test('speeds are limited to the range and rounded to two decimals', () {
      expect(SpeedRampEdit.movePoint(base, 1, y: 99).points[1].y, 10);
      expect(SpeedRampEdit.movePoint(base, 1, y: 0.001).points[1].y, 0.1);
      expect(SpeedRampEdit.movePoint(base, 1, y: 1.23456).points[1].y, 1.23);
      expect(SpeedRampEdit.movePoint(base, 1, y: 99, hi: 4).points[1].y, 4, reason: 'the device range');
      expect(SpeedRampEdit.movePoint(base, 1, y: 0.1, lo: 0.25).points[1].y, 0.25);
    });

    test('a speed within 5% of 1x snaps to 1x; outside it does not', () {
      expect(SpeedRampEdit.movePoint(base, 1, y: 1.03).points[1].y, 1);
      expect(SpeedRampEdit.movePoint(base, 1, y: 0.97).points[1].y, 1);
      expect(SpeedRampEdit.movePoint(base, 1, y: 1.1).points[1].y, 1.1);
      expect(SpeedRampEdit.movePoint(base, 1, y: 0.9).points[1].y, 0.9);
    });

    test('an edit makes a preset custom; a move that changes nothing returns the same ramp', () {
      final preset = SpeedRampPresets.byId('hero')!;
      expect(preset.presetId, 'hero');
      expect(SpeedRampEdit.movePoint(preset, 1, y: 5).presetId, isNull);
      expect(identical(SpeedRampEdit.movePoint(preset, 1, y: preset.points[1].y), preset), isTrue);
      expect(SpeedRampEdit.movePoint(preset, 1, y: preset.points[1].y).presetId, 'hero');
    });

    test('an index outside the ramp changes nothing', () {
      expect(identical(SpeedRampEdit.movePoint(base, 9, y: 2), base), isTrue);
      expect(identical(SpeedRampEdit.movePoint(base, -1, y: 2), base), isTrue);
    });
  });

  group('steps', () {
    final base = ramp([(0, 1), (0.5, 2), (1, 1)]);

    test('a speed step multiplies by 10^0.1 (about +26%) and rounds', () {
      expect(SpeedRampEdit.stepSpeed(base, 1, 1).points[1].y, 2.52);
      expect(SpeedRampEdit.stepSpeed(base, 1, -1).points[1].y, 1.59);
      expect(SpeedRampEdit.stepSpeed(base, 0, 1).points[0].y, 1.26);
    });

    test('steps stop at the limits', () {
      final top = ramp([(0, 10), (0.5, 10), (1, 10)]);
      expect(identical(SpeedRampEdit.stepSpeed(top, 1, 1), top), isTrue);
      final capped = ramp([(0, 1), (0.5, 4), (1, 1)]);
      expect(identical(SpeedRampEdit.stepSpeed(capped, 1, 1, hi: 4), capped), isTrue);
    });

    test('a position step moves 1% of the clip; the end points do not move', () {
      expect(SpeedRampEdit.stepPosition(base, 1, 1).points[1].x, 0.51);
      expect(SpeedRampEdit.stepPosition(base, 1, -5).points[1].x, 0.45);
      expect(identical(SpeedRampEdit.stepPosition(base, 0, 1), base), isTrue);
      expect(identical(SpeedRampEdit.stepPosition(base, 2, -1), base), isTrue);
    });
  });

  group('adding and deleting', () {
    final base = ramp([(0, 1), (0.5, 2), (1, 1)]);

    test('addPoint puts a point on the curve, keeping its shape', () {
      final r = SpeedRampEdit.addPoint(base, 0.25)!;
      expect(r.points.map((p) => p.x), [0, 0.25, 0.5, 1]);
      expect(r.points[1].y, 1.5, reason: 'speed is linear between points');
      expect(SpeedRampEdit.speedAt(r, 0.25), SpeedRampEdit.speedAt(base, 0.25));
      expect(r.presetId, isNull);
      expectValid(r);
    });

    test('no point goes too close to a neighbour, on a point or outside the clip', () {
      expect(SpeedRampEdit.addPoint(base, 0.51), isNull);
      expect(SpeedRampEdit.addPoint(base, 0.01), isNull);
      expect(SpeedRampEdit.addPoint(base, 0.5), isNull);
      expect(SpeedRampEdit.addPoint(base, 0), isNull);
      expect(SpeedRampEdit.addPoint(base, 1), isNull);
      expect(SpeedRampEdit.addPoint(base, 1.4), isNull);
    });

    test('at most 7 points', () {
      var r = base;
      for (final x in [0.1, 0.2, 0.3, 0.7]) {
        r = SpeedRampEdit.addPoint(r, x)!;
      }
      expect(r.points, hasLength(SpeedRampEdit.maxPoints));
      expect(SpeedRampEdit.addPoint(r, 0.85), isNull);
      expect(SpeedRampEdit.addAtWidestGap(r), isNull);
      expect(SpeedRampEdit.canAddAt(r, 0.85), isFalse);
      expectValid(r);
    });

    test('addAtWidestGap splits the widest gap in the middle and says where the point went', () {
      final r = ramp([(0, 1), (0.1, 2), (1, 1)]);
      final (next, at) = SpeedRampEdit.addAtWidestGap(r)!;
      expect(at, 2);
      expect(next.points[2].x, 0.55);
      expectValid(next);
    });

    test('addAtWidestGap refuses when every gap is too narrow', () {
      final tight = SpeedRamp([for (var i = 0; i < 4; i++) SpeedPoint(i / 3, 1)]);
      expect(SpeedRampEdit.addAtWidestGap(tight), isNotNull, reason: 'gaps of 0.33 fit');
      final crammed = ramp([(0, 1), (0.03, 1), (1, 1)]);
      expect(SpeedRampEdit.addAtWidestGap(crammed), isNotNull);
      final none = ramp([(0, 1), (0.03, 1), (0.05, 1), (0.07, 1), (0.09, 1), (0.11, 1), (1, 1)]);
      expect(SpeedRampEdit.addAtWidestGap(none), isNull, reason: 'full');
    });

    test('only interior points go, never below 3 points', () {
      final r = ramp([(0, 1), (0.3, 2), (0.6, 0.5), (1, 1)]);
      expect(SpeedRampEdit.canRemove(r, 0), isFalse);
      expect(SpeedRampEdit.canRemove(r, 3), isFalse);
      final fewer = SpeedRampEdit.removePoint(r, 1)!;
      expect(fewer.points.map((p) => p.x), [0, 0.6, 1]);
      expect(fewer.presetId, isNull);
      expect(SpeedRampEdit.removePoint(fewer, 1), isNull, reason: 'three points is the least');
      expect(SpeedRampEdit.removePoint(r, 0), isNull);
      expect(SpeedRampEdit.removePoint(r, 3), isNull);
      expect(SpeedRampEdit.removePoint(r, 7), isNull);
      expectValid(fewer);
    });
  });

  group('helpers', () {
    test('flat is a valid 3-point curve at the rate; speedAt and fastest', () {
      final f = SpeedRampEdit.flat(2.5);
      expectValid(f);
      expect(f.points, hasLength(3));
      expect(f.points.every((p) => p.y == 2.5), isTrue);
      expect(f.presetId, isNull);
      final r = ramp([(0, 1), (0.5, 3), (1, 2)]);
      expect(SpeedRampEdit.speedAt(r, 0), 1);
      expect(SpeedRampEdit.speedAt(r, 0.25), 2);
      expect(SpeedRampEdit.speedAt(r, 0.75), 2.5);
      expect(SpeedRampEdit.speedAt(r, 1), 2);
      expect(SpeedRampEdit.speedAt(r, 7), 2);
      expect(SpeedRampEdit.fastest(r), 3);
    });

    test('every bundled preset is a valid, editable curve', () {
      for (final id in SpeedRampPresets.ids) {
        final r = SpeedRampPresets.byId(id)!;
        expectValid(r, why: id);
        expect(r.points.length, inInclusiveRange(SpeedRampEdit.minPoints, SpeedRampEdit.maxPoints), reason: id);
      }
    });
  });

  group('random edits never produce an invalid ramp', () {
    for (var seed = 1; seed <= 12; seed++) {
      test('seed $seed', () {
        final random = math.Random(seed);
        var r = seed.isEven ? SpeedRampPresets.byId(SpeedRampPresets.ids[seed % 6])! : SpeedRampEdit.flat(0.1 + random.nextDouble() * 9.9);
        for (var step = 0; step < 400; step++) {
          final n = r.points.length;
          final i = random.nextInt(n);
          final lo = random.nextBool() ? minClipSpeed : 0.25;
          final hi = random.nextBool() ? maxClipSpeed : 4.0;
          switch (random.nextInt(6)) {
            case 0:
              r = SpeedRampEdit.movePoint(r, i,
                  x: random.nextDouble() * 1.4 - 0.2, y: math.exp(random.nextDouble() * 7 - 3.5), lo: lo, hi: hi);
            case 1:
              r = SpeedRampEdit.stepSpeed(r, i, random.nextInt(9) - 4, lo: lo, hi: hi);
            case 2:
              r = SpeedRampEdit.stepPosition(r, i, random.nextInt(21) - 10);
            case 3:
              r = SpeedRampEdit.addPoint(r, random.nextDouble(), lo: lo, hi: hi) ?? r;
            case 4:
              r = SpeedRampEdit.removePoint(r, i) ?? r;
            case 5:
              r = SpeedRampEdit.addAtWidestGap(r, lo: lo, hi: hi)?.$1 ?? r;
          }
          expectValid(r, why: 'seed $seed step $step: ${r.points}');
          expect(r.points.first.x, 0);
          expect(r.points.last.x, 1);
          expect(r.points.length, lessThanOrEqualTo(math.max(n, SpeedRampEdit.maxPoints)));
        }
      });
    }
  });

  group('SpeedPlot', () {
    const plot = SpeedPlot(Rect.fromLTWH(10, 20, 300, 100));

    test('x is linear and speed is logarithmic: 1x is the middle, 0.1x the bottom, 10x the top', () {
      expect(plot.dx(0), 10);
      expect(plot.dx(1), 310);
      expect(plot.dy(1), closeTo(70, 1e-9));
      expect(plot.dy(0.1), closeTo(120, 1e-9));
      expect(plot.dy(10), closeTo(20, 1e-9));
      expect(plot.dy(math.sqrt(10)), closeTo(45, 1e-9), reason: 'half a decade up is a quarter of the height');
    });

    test('pixels map back to positions and speeds, clamped to the plot', () {
      expect(plot.x(160), closeTo(0.5, 1e-9));
      expect(plot.x(-100), 0);
      expect(plot.x(9999), 1);
      expect(plot.v(70), closeTo(1, 1e-9));
      expect(plot.v(-100), closeTo(10, 1e-9));
      expect(plot.v(900), closeTo(0.1, 1e-9));
      for (final v in [0.1, 0.33, 1, 2.5, 10]) {
        expect(plot.v(plot.dy(v.toDouble())), closeTo(v, 1e-9));
      }
    });

    test('of() is the pixel position of a point', () {
      expect(plot.of(const SpeedPoint(0.5, 1)), const Offset(160, 70));
    });
  });
}
