// OWNER: UX-09
//
// TimelineMetrics (ux.md §6.2): ruler and lane heights by kind, preset and text scale, header
// widths per layout kind, the lane stack and the shared x <-> time conversions.

import 'package:flutter/painting.dart' show TextScaler;
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart' show EditorLayoutKind;
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor_core/model.dart';

void main() {
  test('ruler height is max(24, 8 + 11·s·1.2), whole pixels', () {
    expect(const TimelineMetrics().rulerHeight, 24);
    expect(const TimelineMetrics(textScale: 0.85).rulerHeight, 24);
    expect(const TimelineMetrics(textScale: 1.35).rulerHeight, 26);
    expect(const TimelineMetrics(textScale: 2).rulerHeight, 35);
  });

  test('lane heights by kind and preset; text lanes follow the text scale', () {
    const m = TimelineMetrics();
    const expected = {
      TrackKind.video: [52.0, 60.0, 76.0],
      TrackKind.overlay: [52.0, 60.0, 76.0],
      TrackKind.audio: [40.0, 48.0, 64.0],
      TrackKind.text: [32.0, 32.0, 32.0],
      TrackKind.subtitle: [32.0, 32.0, 32.0],
    };
    expected.forEach((kind, heights) {
      for (final p in LaneHeightPreset.values) {
        expect(m.laneHeightOf(kind, preset: p), heights[p.index], reason: '$kind $p');
      }
    });
    expect(const TimelineMetrics(laneHeight: LaneHeightPreset.large).laneHeightOf(TrackKind.audio), 64);
    expect(const TimelineMetrics(textScale: 1.35).laneHeightOf(TrackKind.text), 32);
    expect(const TimelineMetrics(textScale: 2).laneHeightOf(TrackKind.subtitle), 41);
  });

  test('every lane fits a label chip at the largest supported text scale', () {
    const m = TimelineMetrics(textScale: 1.35);
    for (final kind in TrackKind.values) {
      for (final p in LaneHeightPreset.values) {
        expect(m.laneHeightOf(kind, preset: p), greaterThanOrEqualTo(m.labelChipHeight + 2 * TimelineMetrics.clipInset));
      }
    }
  });

  test('header widths: compact 44, medium 132, expanded 168 (pointer) / 220 (touch)', () {
    expect(TimelineMetrics.headerWidthFor(EditorLayoutKind.compactPortrait, touch: true), 44);
    expect(TimelineMetrics.headerWidthFor(EditorLayoutKind.compactLandscape, touch: false), 44);
    expect(TimelineMetrics.headerWidthFor(EditorLayoutKind.medium, touch: true), 132);
    expect(TimelineMetrics.headerWidthFor(EditorLayoutKind.expanded, touch: false), 168);
    expect(TimelineMetrics.headerWidthFor(EditorLayoutKind.expanded, touch: true), 220);
    final m = TimelineMetrics.resolve(
      textScaler: const TextScaler.linear(1.35),
      kind: EditorLayoutKind.medium,
      touch: false,
      laneHeight: LaneHeightPreset.compact,
    );
    expect(m.textScale, closeTo(1.35, 1e-12));
    expect(m.headerWidth, 132);
    expect(m.compactHeaders, isFalse);
    expect(m.laneHeight, LaneHeightPreset.compact);
    expect(m.snapThresholdPx, 8);
    expect(m.trimHitOutset, 12);
    expect(m.addTransitionHitSize, 32);
    expect(const TimelineMetrics().compactHeaders, isTrue);
    expect(const TimelineMetrics().snapThresholdPx, 12);
    expect(const TimelineMetrics().trimHitOutset, 20);
    expect(const TimelineMetrics().addTransitionHitSize, 44);
  });

  test('value semantics', () {
    const a = TimelineMetrics(textScale: 1.2);
    expect(a.copyWith(), a);
    expect(a.copyWith(touch: false), isNot(a));
    expect(a.copyWith(touch: false).hashCode, isNot(a.hashCode));
  });

  test('x <-> time conversions', () {
    expect(TimelineMetrics.xOfTime(3 * microsPerSecond, scrollTimeSec: 1, pxPerSecond: 50), 100);
    expect(TimelineMetrics.timeAtX(100, scrollTimeSec: 1, pxPerSecond: 50), 3 * microsPerSecond);
    expect(TimelineMetrics.timeAtX(-25, scrollTimeSec: 0, pxPerSecond: 50), -500000);
    expect(TimelineMetrics.widthOf(2 * microsPerSecond, 48), 96);
    expect(TimelineMetrics.durationOfWidth(96, 48), 2 * microsPerSecond);
  });

  group('lane stack', () {
    final stack = TimelineLaneStack.of(
      [TrackKind.subtitle, TrackKind.text, TrackKind.video, TrackKind.audio],
      const TimelineMetrics(),
      presets: [null, null, LaneHeightPreset.large, null],
    );

    test('tops and content height include the 1 px gaps', () {
      expect(stack.heights, [32, 32, 76, 48]);
      expect(stack.tops, [0, 33, 66, 143]);
      expect(stack.contentHeight, 191);
      expect(stack.bottomOf(2), 142);
    });

    test('indexAt finds the lane, null in gaps and outside', () {
      expect(stack.indexAt(0), 0);
      expect(stack.indexAt(31.9), 0);
      expect(stack.indexAt(32.5), isNull);
      expect(stack.indexAt(33), 1);
      expect(stack.indexAt(100), 2);
      expect(stack.indexAt(190.9), 3);
      expect(stack.indexAt(191), isNull);
      expect(stack.indexAt(-1), isNull);
      expect(TimelineLaneStack(const []).indexAt(0), isNull);
    });

    test('visibleRange returns the lanes intersecting the band', () {
      expect(stack.visibleRange(0, 40), (0, 2));
      expect(stack.visibleRange(32, 1), (1, 1), reason: 'only the gap');
      expect(stack.visibleRange(40, 30), (1, 3));
      expect(stack.visibleRange(150, 500), (3, 4));
      expect(stack.visibleRange(400, 100), (4, 4));
      expect(stack.visibleRange(0, 0), (0, 0));
      // Brute-force agreement.
      for (var y = -10.0; y < 200; y += 3.5) {
        for (final h in [1.0, 20.0, 64.0, 300.0]) {
          final (first, last) = stack.visibleRange(y, h);
          final expected = [
            for (var i = 0; i < stack.length; i++)
              if (stack.bottomOf(i) > y && stack.tops[i] < y + h) i,
          ];
          expect([for (var i = first; i < last; i++) i], expected, reason: 'y $y h $h');
        }
      }
    });
  });
}
