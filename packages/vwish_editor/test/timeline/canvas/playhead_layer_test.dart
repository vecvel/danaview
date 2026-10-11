// OWNER: UX-10
//
// PlayheadLayer (ux.md §8.7): a separate repaint boundary driven by a ValueListenable; it repaints
// only when the line moves, sits at the centre in centre-locked mode (static while the content
// moves), draws the knob only in free mode, and takes no hits.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/playhead_layer.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';

const _s = microsPerSecond;

TimelineViewportController _viewport(PlayheadFollowMode mode) =>
    TimelineViewportController(defaultMode: mode, platform: TargetPlatform.android)
      ..setViewport(const Size(600, 200), 0, rulerHeight: 24)
      ..setContent(duration: 60 * _s, frameRate: FrameRate.fps30, contentHeight: 300)
      ..setPxPerSecond(100)
      ..jumpTo(scrollTimeSec: 0);

Future<RenderPlayheadLayer> _pump(WidgetTester tester, TimelineViewportController viewport, ValueListenable<TimeUs> playhead) async {
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 600,
        height: 224,
        child: Stack(children: [
          Positioned.fill(child: RepaintBoundary(child: Container(color: const Color(0xFF000000)))),
          Positioned.fill(child: PlayheadLayer(viewport: viewport, playhead: playhead, metrics: const TimelineMetrics())),
        ]),
      ),
    ),
  ));
  return tester.renderObject<RenderPlayheadLayer>(find.byType(PlayheadLayer));
}

void main() {
  testWidgets('free mode: follows the playhead, repaints only when the line moves', (tester) async {
    final viewport = _viewport(PlayheadFollowMode.free);
    addTearDown(viewport.dispose);
    final playhead = ValueNotifier<TimeUs>(2 * _s);
    addTearDown(playhead.dispose);
    final layer = await _pump(tester, viewport, playhead);
    expect(layer.isRepaintBoundary, isTrue);
    expect(layer.debugLastX, 200);
    final n = layer.debugPaintCount;
    playhead.value = 3 * _s;
    await tester.pump();
    expect(layer.debugPaintCount, n + 1);
    expect(layer.debugLastX, 300);
    playhead.value = 3 * _s + 10; // under one physical pixel
    await tester.pump();
    expect(layer.debugPaintCount, n + 1);
    viewport.scrollByPx(100, 0);
    await tester.pump();
    expect(layer.debugLastX, 200);
    expect(layer.debugPaintCount, n + 2);
  });

  testWidgets('centre-locked: the line stays at the centre while the content moves', (tester) async {
    final viewport = _viewport(PlayheadFollowMode.centreLocked);
    addTearDown(viewport.dispose);
    final playhead = ValueNotifier<TimeUs>(10 * _s);
    addTearDown(playhead.dispose);
    final layer = await _pump(tester, viewport, playhead);
    expect(layer.debugLastX, 300);
    final n = layer.debugPaintCount;
    playhead.value = 11 * _s;
    viewport.scrollByPx(100, 0);
    await tester.pump();
    expect(layer.debugPaintCount, n, reason: 'nothing it draws moved');
  });

  testWidgets('the knob shows in free mode only, and the layer takes no hits', (tester) async {
    final playhead = ValueNotifier<TimeUs>(2 * _s);
    addTearDown(playhead.dispose);
    Future<int> knobPixels(PlayheadFollowMode mode) async {
      final viewport = _viewport(mode);
      addTearDown(viewport.dispose);
      final layer = await _pump(tester, viewport, playhead);
      final image = (await tester.runAsync<ui.Image>(() => (layer.debugLayer! as OffsetLayer).toImage(Offset.zero & layer.size)))!;
      addTearDown(image.dispose);
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      // Count lit pixels in the ruler band 4 px left of the line (inside the knob only).
      final x = layer.debugLastX!.round() - 4;
      var lit = 0;
      for (var y = 0; y < 24; y++) {
        if (bytes.getUint8((y * image.width + x) * 4 + 3) > 0) lit++;
      }
      return lit;
    }

    expect(await knobPixels(PlayheadFollowMode.free), greaterThan(8));
    expect(await knobPixels(PlayheadFollowMode.centreLocked), 0);
    final result = BoxHitTestResult();
    final layer = tester.renderObject<RenderPlayheadLayer>(find.byType(PlayheadLayer));
    expect(layer.hitTest(result, position: Offset(layer.debugLastX!, 10)), isFalse);
  });
}
