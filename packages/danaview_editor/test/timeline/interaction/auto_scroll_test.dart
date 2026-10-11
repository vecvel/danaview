// OWNER: UX-13
//
// Auto-scroll (ux.md §8.9): within 48 px of an edge of the lanes area a drag scrolls the view
// (without scrubbing) at a speed proportional to the depth, up to 1.5 viewports per second, and
// the dragged ghost follows the pointer's new time; leaving the edge stops it; the drop is still
// one history entry at the ghost.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_hit.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_interaction.dart';
import 'package:danaview_editor_core/model.dart';

import 'interaction_support.dart';

void main() {
  testWidgets('a move held at the right edge scrolls time and carries the ghost; leaving the edge stops', (tester) async {
    final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject(), pxPerSecond: 200);
    final i = interactionOf(t);
    final playhead = t.container.read(playheadProvider(t.id)).value;
    final canvas = t.canvas(tester);
    final right = canvas.localToGlobal(Offset(t.viewport.lanesWidth - 12, 0)).dx;
    final g = await mouseAt(tester, t.at(tester, 2 * s, 'tr_main'));
    await click(tester, g, t.at(tester, 2 * s, 'tr_main'));
    await g.down(t.at(tester, 2 * s, 'tr_main'));
    await g.moveBy(const Offset(20, 0));
    await g.moveTo(Offset(right, t.at(tester, 2 * s, 'tr_main').dy));
    await tester.pump();
    expect(i.autoScrollVelocity.dx, greaterThan(0));
    expect(i.autoScrollVelocity.dx, lessThanOrEqualTo(TimelineInteractionController.maxAutoScrollViewportsPerSecond * t.viewport.lanesWidth));
    expect(i.autoScrollVelocity.dy, 0);
    final scroll0 = t.viewport.scrollTimeSec;
    final ghost0 = i.ghosts[const ItemId('it_a')]!.range.start;
    for (var k = 0; k < 20; k++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final scroll1 = t.viewport.scrollTimeSec;
    expect(scroll1, greaterThan(scroll0));
    expect(i.ghosts[const ItemId('it_a')]!.range.start, greaterThan(ghost0), reason: 'the ghost follows the time under the pointer');
    expect(t.container.read(playheadProvider(t.id)).value, playhead, reason: 'auto-scroll never scrubs');

    // Back inside: the scroll stops.
    await g.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(i.autoScrollVelocity, Offset.zero);
    final scroll2 = t.viewport.scrollTimeSec;
    await tester.pump(const Duration(milliseconds: 200));
    expect(t.viewport.scrollTimeSec, scroll2);

    final ghost = i.ghosts[const ItemId('it_a')]!;
    await g.up();
    await tester.pump();
    expect(t.item('it_a').range, ghost.range);
    expect(t.historyDepth, 1);
  });

  testWidgets('deeper into the edge zone scrolls faster', (tester) async {
    final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject(), pxPerSecond: 200);
    final i = interactionOf(t);
    final canvas = t.canvas(tester);
    final y = t.at(tester, 2 * s, 'tr_main').dy;
    final g = await mouseAt(tester, t.at(tester, 2 * s, 'tr_main'));
    await click(tester, g, t.at(tester, 2 * s, 'tr_main'));
    await g.down(t.at(tester, 2 * s, 'tr_main'));
    await g.moveBy(const Offset(20, 0));
    await g.moveTo(Offset(canvas.localToGlobal(Offset(t.viewport.lanesWidth - 40, 0)).dx, y));
    await tester.pump();
    final shallow = i.autoScrollVelocity.dx;
    await g.moveTo(Offset(canvas.localToGlobal(Offset(t.viewport.lanesWidth - 4, 0)).dx, y));
    await tester.pump();
    expect(i.autoScrollVelocity.dx, greaterThan(shallow));
    await g.up();
    await tester.pump();
    expect(i.autoScrollVelocity, Offset.zero);
  });

  testWidgets('a trim at the left edge scrolls back; handles never scroll vertically', (tester) async {
    final t = await pumpTimeline(tester, project: interactionProject(), pxPerSecond: 200);
    final i = interactionOf(t);
    t.viewport.jumpTo(scrollTimeSec: 9.5);
    await tester.pump();
    await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump();
    final handle = trimHandleAt(tester, t, 'it_c', TrimEdge.end);
    final canvas = t.canvas(tester);
    final g = await tester.startGesture(handle);
    await g.moveBy(const Offset(-20, 0));
    await g.moveTo(Offset(canvas.localToGlobal(const Offset(6, 0)).dx, handle.dy));
    await tester.pump();
    expect(i.autoScrollVelocity.dx, lessThan(0));
    expect(i.autoScrollVelocity.dy, 0);
    final before = t.viewport.scrollTimeSec;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(t.viewport.scrollTimeSec, lessThan(before));
    await g.up();
    await tester.pump();
    expect(t.historyDepth, 1);
    expect(i.autoScrollVelocity, Offset.zero);
  });
}
