// OWNER: UX-13
//
// The interaction slot driven by real gestures over the timeline (FakeEditorEngine): every drag's
// ghost is the dryRun placement of the command the drop commits, each gesture is one history
// entry, and trims, ripple offsets, cue edges, fades, keyframes and markers go through the
// commands of ux.md §8.9. A refused drop changes nothing and says why.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/state/editor_events.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_gestures.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_hit.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_interaction.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import 'interaction_support.dart';

Map<ItemId, (TimeRange, TrackId?)> _shape(Map<ItemId, Placement> p) =>
    {for (final e in p.entries) e.key: (e.value.range, e.value.newTrack == null ? e.value.track : null)};

void main() {
  group('move', () {
    testWidgets('a selected clip moves under the mouse; the ghost is the dryRun placement and the drop one entry', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject());
      final i = interactionOf(t);
      final base = t.project;
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(i.isDragging, isTrue);
      expect(i.liftedItems, {const ItemId('it_c')});
      expect(t.canvas(tester).interaction?.liftedItems, {const ItemId('it_c')}, reason: 'the canvas dims what the slot lifts');
      final expected = dryRun(base, i.lastCommand!, EditContext(pool: base.pool));
      expect(_shape(i.ghosts), _shape(expected.placements));
      expect(i.ghosts[const ItemId('it_c')]!.range, const TimeRange(9 * s, 13 * s));
      expect(i.pill, '00:09:00 · -00:01:00');
      expect(find.byKey(const ValueKey('drag-pill')), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(t.item('it_c').range, const TimeRange(9 * s, 13 * s), reason: 'the drop lands where the ghost was');
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Move clip');
      expect(i.isDragging, isFalse);
      expect(i.liftedItems, isEmpty);
      expect(find.byKey(const ValueKey('drag-pill')), findsNothing);
    });

    testWidgets('a long-press lift on touch moves to a compatible lane and commits the ghost', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      final g = await tester.startGesture(t.at(tester, 2 * s, 'tr_ov'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(i.active?.lifted, isTrue);
      await g.moveTo(t.at(tester, 2 * s, 'tr_lock') + const Offset(0, -4));
      await g.moveTo(t.at(tester, 2 * s, 'tr_main'));
      await tester.pump();
      expect((i.lastCommand! as MoveItems).toTrack, const TrackId('tr_main'), reason: 'overlay -> video is compatible');
      final ghost = Map.of(i.ghosts);
      await g.up();
      await tester.pump();
      final loc = t.project.index.locate(const ItemId('it_o'))!;
      final p = ghost[const ItemId('it_o')]!;
      expect(loc.item.range, p.range);
      if (!p.onNewTrack) expect(loc.track.id, p.track);
      expect(t.historyDepth, 1);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a move that needs a lane the drop creates shows the "New track" pill', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject());
      final i = interactionOf(t);
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      await g.moveBy(const Offset(-60, 0));
      await g.moveBy(const Offset(-150, 0)); // 6.5 s: over it_b, no ripple.
      await tester.pump();
      expect(i.ghost!.createsTrack, isTrue);
      expect(i.ghosts[const ItemId('it_c')]!.onNewTrack, isTrue);
      expect(find.byKey(const ValueKey('new-track-pill')), findsOneWidget);
      final lanes = t.project.timeline.tracks.length;
      await g.up();
      await tester.pump();
      expect(t.project.timeline.tracks.length, lanes + 1);
      expect(t.historyDepth, 1);
    });

    testWidgets('a cancelled drag (back) restores everything and records nothing', (tester) async {
      final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject());
      final i = interactionOf(t);
      final g = await mouseAt(tester, t.at(tester, 12 * s, 'tr_main'));
      await click(tester, g, t.at(tester, 12 * s, 'tr_main'));
      await g.down(t.at(tester, 12 * s, 'tr_main'));
      await g.moveBy(const Offset(-40, 0));
      await g.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(t.viewState(tester).arbiter.cancel(), isTrue);
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, 10 * s);
      expect(t.historyDepth, 0);
      expect(i.isDragging, isFalse);
    });
  });

  group('trim', () {
    testWidgets('a head trim shows "In +Δ · length", ghosts the dryRun range and commits one entry', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
      await tester.pump();
      final handle = trimHandleAt(tester, t, 'it_c', TrimEdge.start);
      expect(t.hit(tester, handle), isA<HitTrimHandle>());
      final g = await tester.startGesture(handle);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(i.trimGhost?.delta, 1 * s);
      expect(i.trimGhost?.duration, 3 * s);
      expect(i.pill, 'In +00:01:00 · 00:03:00');
      expect(i.ghosts[const ItemId('it_c')]!.range, const TimeRange(11 * s, 14 * s));
      await g.up();
      await tester.pump();
      expect(t.item('it_c').range, const TimeRange(11 * s, 14 * s));
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Trim clip');
    });

    testWidgets('a tail trim snaps to the next clip edge within 12 px on touch', (tester) async {
      final haptics = HapticRecorder.install(tester);
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 6 * s, 'tr_main'));
      await tester.pump();
      final g = await tester.startGesture(trimHandleAt(tester, t, 'it_b', TrimEdge.end));
      await g.moveBy(const Offset(60, 0));
      await g.moveBy(const Offset(55, 0)); // 9.92 s: 5 px before 10 s.
      await tester.pump();
      expect(i.snapGuide, const SnapGuide(10 * s, SnapKind.itemEdge));
      expect(i.ghosts[const ItemId('it_b')]!.range, const TimeRange(4 * s, 10 * s));
      expect(haptics.selectionClicks, 1);
      expect(find.byKey(const ValueKey('snap-pill')), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(t.item('it_b').range, const TimeRange(4 * s, 10 * s));
      expect(t.historyDepth, 1);
    });

    testWidgets('with ripple on, the clips after a tail trim shift in the ghost exactly as committed', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject(), ripple: true);
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 6 * s, 'tr_main'));
      await tester.pump();
      final g = await tester.startGesture(trimHandleAt(tester, t, 'it_b', TrimEdge.end));
      await g.moveBy(const Offset(15, 0));
      await g.moveBy(const Offset(15, 0));
      await tester.pump();
      expect(i.ghosts[const ItemId('it_b')]!.range, TimeRange(4 * s, 8 * s + s ~/ 2));
      expect(i.ghost!.shifted[const ItemId('it_c')]!.range, TimeRange(10 * s + s ~/ 2, 14 * s + s ~/ 2));
      final shifted = Map.of(i.ghost!.shifted);
      await g.up();
      await tester.pump();
      for (final e in shifted.entries) {
        expect(t.item(e.key.value).range, e.value.range);
      }
      expect(t.historyDepth, 1);
    });

    testWidgets('a cue edge drag retimes the caption and stops at the next cue', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 1500000, 'tr_subs'));
      await tester.pump();
      expect(t.state.selection.items, {const ItemId('cue_1')});
      final g = await tester.startGesture(trimHandleAt(tester, t, 'cue_1', TrimEdge.end));
      await g.moveBy(const Offset(60, 0));
      await g.moveBy(const Offset(90, 0));
      await tester.pump();
      expect(i.lastCommand, isA<SetCueRange>());
      final ghost = i.ghosts[const ItemId('cue_1')]!.range;
      expect(ghost.end, lessThanOrEqualTo(3 * s), reason: 'clamped at cue_2');
      await g.up();
      await tester.pump();
      expect(t.item('cue_1').range, ghost);
      expect(t.undoLabel, 'Retime caption');
      expect(t.historyDepth, 1);
    });
  });

  group('handles', () {
    testWidgets('a fade handle drag sets the fade as one entry with a "Fade in" pill', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 5 * s, 'tr_music'));
      await tester.pump();
      final handle = fadeHandleAt(tester, t, 'it_m', FadeEdge.fadeIn);
      expect(t.hit(tester, handle), isA<HitFadeHandle>());
      final g = await tester.startGesture(handle);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(i.ghostTime, 2 * s);
      expect(i.pill, 'Fade in 00:02:00');
      await g.up();
      await tester.pump();
      expect((t.item('it_m') as MediaClip).audio.fadeIn, 2 * s);
      expect(t.undoLabel, 'Fade in');
      expect(t.historyDepth, 1);
    });

    testWidgets('a marker drag snaps to the playhead', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      final i = interactionOf(t);
      unawaited(t.container.read(playheadProvider(t.id)).seekExact(7 * s));
      await tester.pump();
      final g = await tester.startGesture(t.ruler(tester, 6 * s));
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(27, 0)); // 6.95 s, 3 px before the playhead.
      await tester.pump();
      expect(i.snapGuide?.kind, SnapKind.playhead);
      expect(i.ghostTime, 7 * s);
      await g.up();
      await tester.pump();
      expect(t.project.timeline.markers.single.time, 7 * s);
      expect(t.undoLabel, 'Move marker');
    });

    testWidgets('a keyframe drag moves the key and selects it', (tester) async {
      final t = await pumpTimeline(tester, project: interactionProject());
      await tester.tapAt(t.at(tester, 2500000, 'tr_ov'));
      await tester.pump();
      final c = t.canvas(tester);
      final geo = c.geometry;
      final li = geo.snapshot.laneIndexOf(const TrackId('tr_ov'))!;
      final model = geo.snapshot.item(const ItemId('it_o'))!;
      final key = c.localToGlobal(Offset(t.viewport.xOf(model.start + f(30)), geo.itemRect(li, model).bottom - 4 - 3.5));
      expect(t.hit(tester, key), isA<HitKeyframe>());
      final g = await tester.startGesture(key);
      await g.moveBy(const Offset(15, 0));
      await g.moveBy(const Offset(15, 0));
      await g.up();
      await tester.pump();
      final clip = t.item('it_o') as MediaClip;
      expect(clip.keyframes.byChannel['transform.opacity']!.keys.map((k) => k.t), [0, f(45)]);
      expect(t.state.selection.keyframe?.t, f(45));
      expect(t.historyDepth, 1);
    });
  });

  testWidgets('the mouse marquee selects what it touches through the slot; Shift adds; no history', (tester) async {
    final t = await pumpTimeline(tester, platform: TargetPlatform.macOS, project: interactionProject());
    final i = interactionOf(t);
    final from = t.at(tester, 13 * s, 'tr_music');
    final to = t.at(tester, 9500000, 'tr_main', fraction: 0.2);
    final g = await mouseAt(tester, from);
    await g.down(from);
    await g.moveTo(Offset.lerp(from, to, 0.5)!);
    await g.moveTo(to);
    await tester.pump();
    expect(i.active?.kind, TimelineDragKind.marquee, reason: 'the UX-13 slot takes the marquee');
    expect(i.marquee, isNotNull);
    expect(i.liftedItems, isEmpty, reason: 'a marquee lifts nothing');
    await g.up();
    await tester.pump();
    expect(i.marquee, isNull);
    expect(t.state.selection.items, {const ItemId('it_c'), const ItemId('it_m')});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final from2 = t.at(tester, 9 * s, 'tr_ov');
    await g.moveTo(from2);
    await g.down(from2);
    await g.moveTo(t.at(tester, 5 * s, 'tr_ov', fraction: 0.6));
    await g.moveTo(t.at(tester, 2 * s, 'tr_ov', fraction: 0.8));
    await g.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_c'), const ItemId('it_m'), const ItemId('it_o')});
    expect(t.historyDepth, 0);
  });

  testWidgets('a refused drop records nothing and the editor says why', (tester) async {
    final t = await pumpTimeline(tester, project: interactionProject());
    final i = interactionOf(t);
    final events = <EditorEvent>[];
    final sub = t.rig.controller.events.listen(events.add);
    addTearDown(sub.cancel);
    // A fade on an image without sound is refused (UnsupportedForKind).
    const hit = HitFadeHandle(item: ItemId('it_o'), lane: TrackId('tr_ov'), edge: FadeEdge.fadeIn);
    expect(i.beginDrag(const TimelineDragStart(
        kind: TimelineDragKind.fade, hit: hit, position: Offset(60, 10), time: 1 * s, deviceKind: PointerDeviceKind.touch)), isTrue);
    i.updateDrag(const TimelineDragUpdate(position: Offset(90, 10), time: 1500000, offset: Offset(30, 0)));
    expect(i.rejected, isTrue);
    i.endDrag();
    await tester.pump();
    expect(t.historyDepth, 0);
    expect(events.whereType<EditorRejected>(), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a drag on a locked lane is refused at the start', (tester) async {
    final t = await pumpTimeline(tester, project: interactionProject());
    final i = interactionOf(t);
    const hit = HitTrimHandle(item: ItemId('it_l'), lane: TrackId('tr_lock'), edge: TrimEdge.end);
    expect(i.beginDrag(const TimelineDragStart(
        kind: TimelineDragKind.trim, hit: hit, position: Offset(360, 70), time: 6 * s, deviceKind: PointerDeviceKind.touch)), isFalse);
    expect(i.isDragging, isFalse);
    const key = HitKeyframe(KeyframeRef(ItemId('it_l'), 'transform.opacity', 0), lane: TrackId('tr_lock'));
    expect(i.beginDrag(const TimelineDragStart(
        kind: TimelineDragKind.keyframe, hit: key, position: Offset(120, 70), time: 2 * s, deviceKind: PointerDeviceKind.touch)), isFalse,
        reason: 'keyframes on a locked lane do not move either');
    expect(i.canDrag(TimelineDragKind.scrub), isFalse, reason: 'the view scrubs');
    for (final k in TimelineDragKind.values.where((k) => k != TimelineDragKind.scrub)) {
      expect(i.canDrag(k), isTrue, reason: '$k');
    }
  });
}
