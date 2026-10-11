// OWNER: UX-09
//
// TimelineRuler (ux.md §8.5, §19.2): sizes to the width and the text-derived ruler height, repaints
// (never rebuilds or relayouts) when the viewport moves, paints labels inside the ruler and apart
// from each other at the narrowest width and the largest text scale, paints the marker flags from
// the snapshot's list with the selected one outlined, and hit-tests flags with the touch target.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/ruler.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_style.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';

const _s = microsPerSecond;
final _style = TimelineStyle.standard.withFontFamily('Ahem');

TimelineViewportController _viewport({double width = 400, TimeUs duration = 120 * _s, FrameRate rate = FrameRate.fps30}) {
  final c = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android);
  c.setContent(duration: duration, frameRate: rate);
  c.setViewport(Size(width, 200), 0, rulerHeight: 24);
  addTearDown(c.dispose);
  return c;
}

/// Pumps a ruler of [width] and counts the builds of its parent.
Future<RenderTimelineRuler> _pump(
  WidgetTester tester,
  TimelineViewportController viewport, {
  double width = 400,
  double textScale = 1,
  List<Marker> markers = const [],
  MarkerId? selected,
  ValueNotifier<int>? builds,
}) async {
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: Builder(builder: (context) {
          builds?.value++;
          return TimelineRuler(
            viewport: viewport,
            markers: markers,
            selectedMarker: selected,
            style: _style,
            metrics: TimelineMetrics(textScale: textScale),
          );
        }),
      ),
    ),
  ));
  return tester.renderObject<RenderTimelineRuler>(find.byType(TimelineRuler));
}

void main() {
  testWidgets('sizes to the width and the ruler height of the text scale', (tester) async {
    for (final (scale, height) in [(0.85, 24.0), (1.0, 24.0), (1.35, 26.0)]) {
      final ruler = await _pump(tester, _viewport(), textScale: scale);
      expect(ruler.size, Size(400, height), reason: 'text scale $scale');
      expect(TimelineMetrics(textScale: scale).rulerHeight, height);
    }
  });

  testWidgets('scrolling and zooming repaint the ruler without a rebuild or a relayout', (tester) async {
    final viewport = _viewport();
    final builds = ValueNotifier<int>(0);
    final ruler = await _pump(tester, viewport, builds: builds);
    final paints = ruler.debugPaintCount;
    final buildCount = builds.value;
    final firstLabels = ruler.debugLastPaint!.labels.map((l) => l.$1).toList();

    viewport.scrollByPx(150, 0);
    await tester.pump();
    expect(ruler.debugPaintCount, paints + 1);
    expect(ruler.debugNeedsLayout, isFalse);
    expect(ruler.debugLastPaint!.labels.map((l) => l.$1).toList(), isNot(firstLabels));

    viewport.zoomBy(4, anchorX: 200);
    await tester.pump();
    expect(ruler.debugPaintCount, paints + 2);
    expect(builds.value, buildCount, reason: 'the ruler repaints from the viewport; nothing rebuilds');

    // Nothing changed: no paint.
    await tester.pump();
    expect(ruler.debugPaintCount, paints + 2);
  });

  testWidgets('a replaced viewport is listened to instead of the old one', (tester) async {
    final a = _viewport(), b = _viewport();
    final ruler = await _pump(tester, a);
    await _pump(tester, b);
    final paints = ruler.debugPaintCount;
    a.scrollByPx(50, 0);
    await tester.pump();
    expect(ruler.debugPaintCount, paints);
    b.scrollByPx(50, 0);
    await tester.pump();
    expect(ruler.debugPaintCount, paints + 1);
  });

  for (final rate in [FrameRate.fps24, FrameRate.fps30, FrameRate.fps60]) {
    testWidgets('narrowest width, largest text scale: labels inside the ruler and >= 24 px apart at every zoom ($rate)', (tester) async {
      // 280 px screen minus the 44 px compact header column.
      const width = 236.0;
      final viewport = _viewport(width: width, duration: 75 * 60 * _s, rate: rate);
      final ruler = await _pump(tester, viewport, width: width, textScale: 1.35);
      viewport.jumpTo(scrollTimeSec: 59.5);
      for (var pps = viewport.minPxPerSecond; pps <= viewport.maxPxPerSecond * 1.0001; pps *= 1.3) {
        viewport.setPxPerSecond(pps);
        await tester.pump();
        final report = ruler.debugLastPaint!;
        expect(report.scale, isNotNull);
        final rects = report.labels.map((l) => l.$2).toList();
        for (final r in rects) {
          expect(r.top, greaterThanOrEqualTo(0));
          expect(r.bottom, lessThanOrEqualTo(ruler.size.height - RulerPainter.majorTickLength(ruler.size.height) + 1e-6),
              reason: 'labels sit above the major ticks');
        }
        for (var i = 1; i < rects.length; i++) {
          expect(rects[i].left - rects[i - 1].right, greaterThanOrEqualTo(RulerLadder.labelGap - 1e-6),
              reason: '${report.scale} at $pps px/s: ${report.labels}');
        }
        expect(report.majorTicks, greaterThan(0));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('labels: frame timecodes at 48 px per frame, minutes when zoomed out', (tester) async {
    final viewport = _viewport(width: 480, duration: 90 * _s);
    final ruler = await _pump(tester, viewport, width: 480);
    viewport
      ..setPxPerSecond(viewport.maxPxPerSecond)
      ..jumpTo(scrollTimeSec: 60.8);
    await tester.pump();
    var report = ruler.debugLastPaint!;
    expect(report.scale!.step, const RulerStep.frames(5));
    expect(report.scale!.minorDivisions, 5);
    expect(report.labels.map((l) => l.$1), containsAllInOrder(['1:00:25', '1:01:00']));

    final long = _viewport(width: 480, duration: 20 * 60 * _s);
    final longRuler = await _pump(tester, long, width: 480);
    long.zoomToFit();
    await tester.pump();
    report = longRuler.debugLastPaint!;
    expect(report.scale!.step, const RulerStep.seconds(300));
    // The 20:00 tick sits 5 s (2 px) inside the right edge, so its label (right of the tick) is out.
    expect(report.labels.map((l) => l.$1), ['0:00', '5:00', '10:00', '15:00']);
    expect(report.majorTicks, 5);
    expect(report.minorTicks, 16);
  });

  testWidgets('marker flags from the list: only visible ones, selected outlined, hit with the touch target', (tester) async {
    final viewport = _viewport(width: 400, duration: 120 * _s);
    viewport
      ..setPxPerSecond(20)
      ..jumpTo(scrollTimeSec: 0);
    const m1 = Marker(id: MarkerId('mk_000000000001'), time: 2 * _s);
    const m2 = Marker(id: MarkerId('mk_000000000002'), time: 10 * _s, colorIndex: 3);
    const m3 = Marker(id: MarkerId('mk_000000000003'), time: 60 * _s, colorIndex: 9);
    final ruler = await _pump(tester, viewport, markers: const [m1, m2, m3], selected: m2.id);
    expect(ruler.debugLastPaint!.markers, [m1.id, m2.id], reason: 'the 60 s marker is off-screen (x = 1200)');

    // Flag centres: 2 s -> x 40 + 5, 10 s -> x 200 + 5.
    expect(ruler.markerAt(const Offset(45, 5))?.id, m1.id);
    expect(ruler.markerAt(const Offset(45 + 21, 5))?.id, m1.id, reason: 'touch target 44 px');
    expect(ruler.markerAt(const Offset(45 + 21, 5), touch: false), isNull, reason: 'pointer target 24 px');
    expect(ruler.markerAt(const Offset(203, 12))?.id, m2.id);
    expect(ruler.markerAt(const Offset(120, 5)), isNull);
    expect(ruler.markerAt(const Offset(45, 40)), isNull, reason: 'below the ruler');

    // A new list repaints; an equal list does not.
    final paints = ruler.debugPaintCount;
    await _pump(tester, viewport, markers: const [m1, m2, m3], selected: m2.id);
    expect(ruler.debugPaintCount, paints);
    await _pump(tester, viewport, markers: const [m1], selected: m2.id);
    expect(ruler.debugPaintCount, paints + 1);
    expect(ruler.debugLastPaint!.markers, [m1.id]);

    // Out-of-range colour indices (a newer project) paint in the default colour.
    expect(_style.markerColor(m3.colorIndex), _style.marker);
  });

  testWidgets('nothing but the background before the viewport has a zoom', (tester) async {
    final viewport = TimelineViewportController(defaultMode: PlayheadFollowMode.free, platform: TargetPlatform.android);
    addTearDown(viewport.dispose);
    final ruler = await _pump(tester, viewport);
    expect(ruler.debugLastPaint!.scale, isNull);
    expect(ruler.debugLastPaint!.majorTicks, 0);
    expect(tester.takeException(), isNull);
  });
}
