// OWNER: UX-13
//
// Snapping UI (ux.md §8.9): the reach is 8 px with a pointer and 12 px on touch at the current
// zoom; a move snaps the nearer edge of the dragged group; each new engagement plays one
// selection click and shows the guide and time pill; leaving the reach clears them; Alt/Option and
// the project's snapping mode (N) turn it off.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/timeline/snapping.dart';
import 'package:vwish_editor_core/model.dart';

import 'interaction_support.dart';

void main() {
  group('TimelineSnapping', () {
    final project = interactionProject();

    test('reach: 8 px pointer, 12 px touch, converted at the zoom', () {
      expect(TimelineSnapping.thresholdFor(touch: false), 8);
      expect(TimelineSnapping.thresholdFor(touch: true), 12);
      expect(TimelineSnapping.toleranceUs(8, 60), 133333);
      expect(TimelineSnapping.toleranceUs(12, 120), 100000);
      expect(TimelineSnapping.toleranceUs(8, 0), 0);
    });

    test('engages within reach, keeps quiet while engaged on the same target, re-engages after leaving', () {
      var clicks = 0;
      final snap = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_c')}, thresholdPx: 8, onEngage: () => clicks++);
      expect(snap.snapTime(8 * s + 100000, pxPerSecond: 60), 8 * s);
      expect(snap.guide, const SnapGuide(8 * s, SnapKind.itemEdge));
      expect(clicks, 1);
      expect(snap.snapTime(8 * s + 50000, pxPerSecond: 60), 8 * s);
      expect(clicks, 1, reason: 'the same target is not a new engagement');
      expect(snap.snapTime(8 * s + 400000, pxPerSecond: 60), 8 * s + 400000);
      expect(snap.guide, isNull);
      expect(snap.snapTime(8 * s - 20000, pxPerSecond: 60), 8 * s);
      expect(clicks, 2);
      expect(snap.engagements, 2);
    });

    test('the reach follows the zoom', () {
      final snap = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_c')}, thresholdPx: 8);
      // 100 ms off: 6 px at 60 px/s (in reach), 30 px at 300 px/s (out of reach).
      expect(snap.snapTime(8 * s + 100000, pxPerSecond: 60), 8 * s);
      expect(snap.snapTime(8 * s + 100000, pxPerSecond: 300), 8 * s + 100000);
    });

    test('disabled lookups do not snap and clear the guide', () {
      final snap = TimelineSnapping.forDrag(project, thresholdPx: 8);
      expect(snap.snapTime(6 * s + 10000, pxPerSecond: 60), 6 * s);
      expect(snap.guide?.kind, SnapKind.marker);
      expect(snap.snapTime(6 * s + 10000, pxPerSecond: 60, enabled: false), 6 * s + 10000);
      expect(snap.guide, isNull);
      expect(snap.snapRange(TimeRange(6 * s + 10000, 7 * s), pxPerSecond: 60, enabled: false), 0);
    });

    test('a group snaps the nearer of its edges; dragged items and partners are not targets', () {
      final snap = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_c')}, thresholdPx: 8);
      // it_c shifted to 8.05..12.05: the start is 50 ms from it_b's end.
      expect(snap.snapRange(TimeRange(8 * s + 50000, 12 * s + 50000), pxPerSecond: 60), -50000);
      // Its own edges (10 and 14 s) are excluded: 14.05 s does not snap back to 14 s.
      expect(snap.snapRange(TimeRange(10 * s + 50000, 14 * s + 50000), pxPerSecond: 60), -50000,
          reason: '10 s is still it_m\'s end (another lane), 14 s is excluded');
      // Only the end is in reach: 8.5..10.05 s ends 50 ms after 10 s.
      expect(snap.snapRange(TimeRange(8 * s + s ~/ 2, 10 * s + 50000), pxPerSecond: 60), -50000);
      expect(snap.guide, const SnapGuide(10 * s, SnapKind.itemEdge));
      final none = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_c')}, thresholdPx: 8);
      expect(none.snapRange(TimeRange(12 * s, 13 * s), pxPerSecond: 60), 0);
      expect(none.guide, isNull);
    });

    test('the playhead is a target and wins ties', () {
      final snap = TimelineSnapping.forDrag(project, playhead: 6 * s, thresholdPx: 8);
      expect(snap.snapTime(6 * s + 1000, pxPerSecond: 60), 6 * s);
      expect(snap.guide?.kind, SnapKind.playhead, reason: 'the playhead beats the marker at 6 s');
      final noMarkers = TimelineSnapping.forDrag(project, markers: false, thresholdPx: 8);
      expect(noMarkers.snapTime(6 * s + 1000, pxPerSecond: 60), 6 * s, reason: 'it_l ends at 6 s');
      expect(noMarkers.guide?.kind, SnapKind.itemEdge);
    });
  });

  group('during a mouse move', () {
    Future<(TimelineRig, TestGesture)> grabClipC(WidgetTester tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject());
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      return (t, g);
    }

    testWidgets('engage (guide, pill, one click), disengage, re-engage, Alt turns it off', (tester) async {
      final haptics = HapticRecorder.install(tester);
      final (t, g) = await grabClipC(tester);
      final i = interactionOf(t);
      await g.moveBy(const Offset(-60, 0)); // 9..13 s: nothing in reach.
      await tester.pump();
      expect(i.snapGuide, isNull);
      expect(i.ghosts[const ItemId('it_c')]!.range.start, 9 * s);

      await g.moveBy(const Offset(-55, 0)); // 8.083 s: 5 px from it_b's end.
      await tester.pump();
      expect(i.snapGuide, const SnapGuide(8 * s, SnapKind.itemEdge));
      expect(i.ghosts[const ItemId('it_c')]!.range, const TimeRange(8 * s, 12 * s));
      expect(haptics.selectionClicks, 1);
      expect(find.byKey(const ValueKey('snap-pill')), findsOneWidget);

      await g.moveBy(const Offset(3, 0)); // still in reach of the same target.
      await tester.pump();
      expect(i.snapGuide, isNotNull);
      expect(haptics.selectionClicks, 1);

      await g.moveBy(const Offset(20, 0)); // 8.47 s: out of reach.
      await tester.pump();
      expect(i.snapGuide, isNull);
      expect(find.byKey(const ValueKey('snap-pill')), findsNothing);
      expect(i.ghosts[const ItemId('it_c')]!.range.start, isNot(8 * s));

      await g.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(i.snapGuide?.time, 8 * s);
      expect(haptics.selectionClicks, 2, reason: 'a new engagement after leaving');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await g.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(i.snapGuide, isNull);
      expect(i.ghosts[const ItemId('it_c')]!.range.start, isNot(8 * s));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      await g.moveBy(const Offset(-1, 0));
      await tester.pump();
      expect(i.snapGuide?.time, 8 * s);
      await g.up();
      await tester.pump();
      expect(t.item('it_c').range, const TimeRange(8 * s, 12 * s));
      expect(t.historyDepth, 1);
      expect(i.snapGuide, isNull);
    });

    testWidgets('snapping mode off (N) never snaps', (tester) async {
      final (t, g) = await grabClipC(tester);
      final i = interactionOf(t);
      t.rig.controller.setModes((m) => m.copyWith(snapping: false));
      await g.moveBy(const Offset(-60, 0));
      await g.moveBy(const Offset(-55, 0));
      await tester.pump();
      expect(i.snapGuide, isNull);
      expect(i.ghosts[const ItemId('it_c')]!.range.start, isNot(8 * s));
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, isNot(8 * s));
    });
  });
}
