// OWNER: UX-12
//
// Long-press lift (ux.md §8.8): a long press on a clip lifts it, moving drags a ghost that equals
// the dryRun placement of the move, release commits exactly one history entry; releasing without
// moving opens the context menu instead. Also the interaction slot contract: a slot that takes a
// drag kind receives it instead of the basic interaction. The rig runs without UX-13's slot
// (`basicOnly`) unless a test passes its own.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_gestures.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_hit.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'gesture_support.dart';

void main() {
  testWidgets('long press lifts a clip; the ghost is the dryRun placement; drop is one history entry', (tester) async {
    final t = await pumpTimeline(tester, basicOnly: true);
    final base = t.project;
    final g = await tester.startGesture(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 400));
    final basic = t.basic(tester);
    expect(basic.active?.lifted, isTrue);
    expect(basic.liftedItems, {const ItemId('it_c')});
    expect(t.canvas(tester).interaction?.liftedItems, {const ItemId('it_c')}, reason: 'the canvas dims the lifted clip');
    expect(t.state.selection.items, {const ItemId('it_c')}, reason: 'lifting selects the clip');

    // Move 1.5 s to the left (into the gap) and check every step against dryRun.
    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(-30, 0));
      await tester.pump();
      final command = basic.lastCommand!;
      final expected = dryRun(base, command, EditContext(pool: base.pool));
      expect(expected.isRejected, isFalse);
      expect(basic.ghosts, expected.placements, reason: 'ghost after step $i equals dryRun of $command');
    }
    expect(basic.ghosts[const ItemId('it_c')]!.range, const TimeRange(8500000, 12500000));
    expect(t.item('it_c').start, 10 * s, reason: 'nothing is committed during the drag');

    await g.up();
    await tester.pump();
    expect(t.item('it_c').start, 8500000);
    expect(t.historyDepth, 1);
    expect(t.undoLabel, 'Move clip');
    expect(basic.liftedItems, isEmpty);

    // One undo restores the whole drag.
    t.rig.controller.undo();
    await tester.pump();
    expect(t.item('it_c').start, 10 * s);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a lifted clip can move to another lane of a compatible kind', (tester) async {
    final t = await pumpTimeline(tester, basicOnly: true);
    final base = t.project;
    final g = await tester.startGesture(t.at(tester, 2 * s, 'tr_ov'));
    await tester.pump(const Duration(milliseconds: 400));
    final target = t.at(tester, 2 * s, 'tr_main');
    await g.moveTo(target + const Offset(0, -2));
    await g.moveTo(target);
    await tester.pump();
    final basic = t.basic(tester);
    final expected = dryRun(base, basic.lastCommand!, EditContext(pool: base.pool));
    expect((basic.lastCommand! as MoveItems).toTrack, const TrackId('tr_main'));
    // Ids of lanes a drop would create come from the session's generator: compare ranges and
    // existing lanes.
    Map<ItemId, (TimeRange, TrackId?)> shape(Map<ItemId, Placement> p) =>
        {for (final e in p.entries) e.key: (e.value.range, e.value.newTrack == null ? e.value.track : null)};
    expect(shape(basic.ghosts), shape(expected.placements));
    expect(basic.rejected, expected.isRejected);
    await g.up();
    await tester.pump();
    expect(t.historyDepth, expected.isRejected ? 0 : 1);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a long press released without moving opens the clip menu with "Select multiple"', (tester) async {
    final t = await pumpTimeline(tester, basicOnly: true);
    await tester.longPressAt(t.at(tester, 6 * s, 'tr_main'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.viewState(tester).menuOpen, isTrue);
    expect(find.text('Select multiple'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    expect(t.historyDepth, 0);
    expect(t.basic(tester).liftedItems, isEmpty);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a slot that takes a drag kind receives it; the basic interaction keeps the rest', (tester) async {
    final slot = _RecordingSlot({TimelineDragKind.trim});
    final t = await pumpTimeline(tester, basicOnly: true, interaction: slot);
    await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump();
    final edge = t.at(tester, 10 * s, 'tr_main', fraction: 0.9) + const Offset(3, 0);
    final g = await tester.startGesture(edge);
    await g.moveBy(const Offset(20, 0));
    await g.moveBy(const Offset(20, 0));
    await g.up();
    await tester.pump();
    expect(slot.log.first, startsWith('begin trim'));
    expect(slot.log.where((e) => e == 'update'), hasLength(2));
    expect(slot.log.last, 'end');
    expect(find.byKey(_RecordingSlot.layerKey), findsOneWidget, reason: 'the slot draws the interaction layer');

    // A long-press move is not taken by the slot: the basic interaction runs it.
    final m = await tester.startGesture(t.at(tester, 6 * s, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 400));
    await m.moveBy(const Offset(10, 0));
    expect(t.basic(tester).active?.kind, TimelineDragKind.move);
    await m.up();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a fade handle claims the pointer at once and goes to the slot that takes fades', (tester) async {
    final slot = _RecordingSlot({TimelineDragKind.fade});
    final t = await pumpTimeline(tester, basicOnly: true, interaction: slot);
    await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump();
    final c = t.canvas(tester);
    final g = c.geometry;
    final li = g.snapshot.laneIndexOf(const TrackId('tr_main'))!;
    final item = g.snapshot.item(const ItemId('it_c'))!;
    final body = g.itemRect(li, item);
    final handle = c.localToGlobal(g.fadeHandleCentre(body, item, FadeEdge.fadeOut));
    expect(t.hit(tester, handle), isA<HitFadeHandle>());
    final gesture = await tester.startGesture(handle);
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.up();
    await tester.pump();
    expect(slot.log.first, startsWith('begin fade'));
    expect(slot.log.last, 'end');
    expect(t.viewport.scrollTimeSec, 0, reason: 'the handle drag never scrolled');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('back cancels a drag in progress (the transaction is dropped)', (tester) async {
    final t = await pumpTimeline(tester, basicOnly: true);
    final g = await tester.startGesture(t.at(tester, 12 * s, 'tr_main'));
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(t.viewState(tester).arbiter.cancel(), isTrue);
    await g.up();
    await tester.pump();
    expect(t.item('it_c').start, 10 * s);
    expect(t.historyDepth, 0);
    expect(t.basic(tester).active, isNull);
    await tester.pump(const Duration(seconds: 2));
  });
}

class _RecordingSlot extends ChangeNotifier implements TimelineInteractionSlot {
  _RecordingSlot(this.kinds);

  static const Key layerKey = ValueKey<String>('recording-layer');

  final Set<TimelineDragKind> kinds;
  final List<String> log = [];

  @override
  Set<ItemId> get liftedItems => const {};

  @override
  bool canDrag(TimelineDragKind kind) => kinds.contains(kind);

  @override
  bool beginDrag(TimelineDragStart start) {
    log.add('begin ${start.kind.name} ${start.hit is HitTrimHandle}');
    return true;
  }

  @override
  void updateDrag(TimelineDragUpdate update) => log.add('update');

  @override
  void endDrag({bool cancelled = false}) => log.add(cancelled ? 'cancel' : 'end');

  @override
  Widget buildLayer(BuildContext context, TimelineLayerContext layer) => const SizedBox.expand(key: layerKey);
}
