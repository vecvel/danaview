// OWNER: UX-12
//
// Timeline semantics (ARCH §17.9): clip nodes carry custom actions that run the right commands
// (split, delete, move and trim by a frame and by a second, one history entry each); the playhead
// is an adjustable slider; markers, transitions and keyframes are nodes; results are announced
// through editorAnnounce, at most once per second (V-U4, SemanticsService captured by the test
// binding).
//
// V-U4 record (2026-10-11, Flutter 3.44.2): `SemanticsService.announce` is deprecated since
// 3.35 (it is not view-aware and breaks with multiple windows); `editorAnnounce` therefore calls
// `SemanticsService.sendAnnouncement(view, message, textDirection)` with the widget's `View`, and the
// tests below see every announcement through the binding's capture (`tester.takeAnnouncements`,
// the SemanticsService mock). The manual VoiceOver/TalkBack listening check belongs in the PR /
// QA-00 run on a device: deferred this round (no device session available to this build).

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:vwish_editor_core/model.dart';

import 'gesture_support.dart';

void main() {
  FinderBase<SemanticsNode> clipNode(String label) => find.semantics.byLabel(RegExp('^(Video clip|Image|Audio clip), $label,'));

  testWidgets('clip actions run the right commands, one history entry each', (tester) async {
    final t = await pumpTimeline(tester);
    final c = clipNode('Beach 2');
    expect(c, findsOne);

    tester.semantics.customAction(c, TimelineItemSemantics.moveActions[1]); // +1 frame
    await tester.pump();
    expect(t.item('it_c').start, 10 * s + f(1));
    expect(t.undoLabel, 'Move clip');

    tester.semantics.customAction(clipNode('Beach 2'), TimelineItemSemantics.moveActions[2]); // −1 s
    await tester.pump();
    expect(t.item('it_c').start, 9 * s + f(1));
    expect(t.historyDepth, 2);

    tester.semantics.customAction(clipNode('Beach 2'), TimelineItemSemantics.trimEndActions[2]); // end −1 s
    await tester.pump();
    expect(t.item('it_c').end, 12 * s + f(1));
    expect(t.undoLabel, 'Trim clip');

    tester.semantics.customAction(clipNode('Beach 2'), TimelineItemSemantics.trimStartActions[1]); // start +1 frame
    await tester.pump();
    expect(t.item('it_c').start, 9 * s + f(2));
    expect(t.historyDepth, 4);

    // Split at the playhead (seek into "City" first).
    unawaited(t.container.read(playheadProvider(t.id)).seekExact(6 * s));
    await tester.pump();
    tester.semantics.customAction(clipNode('City'), TimelineItemSemantics.splitAction);
    await tester.pump();
    expect(t.undoLabel, 'Split');
    final main = t.project.timeline.tracks.firstWhere((tr) => tr.id == const TrackId('tr_main'));
    expect(main.items.where((i) => i.start == 6 * s), hasLength(1));

    tester.semantics.customAction(clipNode('Beach'), TimelineItemSemantics.deleteAction);
    await tester.pump();
    expect(t.project.index.locate(const ItemId('it_a')), isNull);
    expect(t.undoLabel, 'Delete');

    // Tap selects.
    tester.semantics.tap(clipNode('Beach 2'));
    await tester.pump();
    expect(t.state.selection.items, {const ItemId('it_c')});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('locked clips have no edit actions', (tester) async {
    await pumpTimeline(tester);
    final node = clipNode('Locked').evaluate().single;
    final actions = node.getSemanticsData().customSemanticsActionIds ?? const <int>[];
    expect(actions, isEmpty);
  });

  testWidgets('the playhead is an adjustable slider stepping one frame', (tester) async {
    final t = await pumpTimeline(tester);
    final playhead = t.container.read(playheadProvider(t.id));
    final slider = find.semantics.byLabel(TimelineSemanticsStrings.playhead);
    expect(slider, findsOne);
    final data = slider.evaluate().single.getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.value, '00:00:00');
    tester.semantics.increase(slider);
    await tester.pump();
    expect(playhead.value, f(1));
    tester.semantics.increase(slider);
    await tester.pump();
    expect(playhead.value, f(2));
    tester.semantics.decrease(slider);
    await tester.pump();
    expect(playhead.value, f(1));
    expect(find.semantics.byLabel(TimelineSemanticsStrings.playhead).evaluate().single.getSemanticsData().value, '00:00:01');
  });

  testWidgets('markers, transitions and keyframes are nodes that act on tap', (tester) async {
    final t = await pumpTimeline(tester);
    final marker = find.semantics.byLabel('Marker Beat at 0:06');
    expect(marker, findsOne);
    tester.semantics.tap(marker);
    await tester.pump();
    expect(t.state.selection.marker, const MarkerId('mk_beat'));
    expect(t.container.read(playheadProvider(t.id)).value, 6 * s);

    final transition = find.semantics.byLabel('Cross dissolve transition at 0:04');
    expect(transition, findsOne);
    tester.semantics.tap(transition);
    await tester.pump();
    expect(t.state.inspector, isA<TransitionInspector>());

    expect(find.semantics.byLabel(RegExp('keyframe')), findsNothing, reason: 'keys show for selected clips');
    t.rig.controller.select(const ItemId('it_o'));
    await tester.pump();
    final key = find.semantics.byLabel('Opacity keyframe at 0:02');
    expect(key, findsOne);
    tester.semantics.tap(key);
    await tester.pump();
    expect(t.state.selection.keyframe, const KeyframeRef(ItemId('it_o'), 'transform.opacity', 1 * s));
  });

  testWidgets('the lanes scroll through semantics scroll actions', (tester) async {
    final t = await pumpTimeline(tester, size: const Size(1000, 170));
    final lanes = find.semantics.scrollable();
    tester.semantics.scrollLeft(scrollable: lanes);
    await tester.pump();
    expect(t.viewport.scrollTimeSec, closeTo(t.viewport.scrollBounds.max, 1e-6), reason: 'a page later, clamped to the end');
    tester.semantics.scrollRight(scrollable: find.semantics.scrollable());
    await tester.pump();
    expect(t.viewport.scrollTimeSec, lessThan(0.01));
    tester.semantics.scrollUp(scrollable: find.semantics.scrollable());
    await tester.pump();
    expect(t.viewport.scrollY, greaterThan(0));
  });

  testWidgets('results are announced through editorAnnounce, at most once per second (V-U4)', (tester) async {
    await pumpTimeline(tester);
    tester.takeAnnouncements();
    final c = clipNode('Beach 2');
    tester.semantics.customAction(c, TimelineItemSemantics.moveActions[1]);
    await tester.pump();
    var said = tester.takeAnnouncements();
    expect(said.map((a) => a.message), ['Moved to 0:10']);

    // A burst within the second: the newest is spoken when the window ends.
    tester.semantics.customAction(clipNode('Beach 2'), TimelineItemSemantics.moveActions[3]);
    await tester.pump();
    tester.semantics.customAction(clipNode('Beach 2'), TimelineItemSemantics.moveActions[3]);
    await tester.pump();
    expect(tester.takeAnnouncements(), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    said = tester.takeAnnouncements();
    expect(said.map((a) => a.message), ['Moved to 0:12']);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('EditorAnnouncer throttles to one per interval and keeps the newest', (tester) async {
    final sent = <String>[];
    final a = EditorAnnouncer(send: (_, m, __) => sent.add(m));
    a.announce(tester.view, 'one');
    a.announce(tester.view, 'two');
    a.announce(tester.view, 'three');
    expect(sent, ['one']);
    expect(a.hasPending, isTrue);
    await tester.pump(const Duration(milliseconds: 999));
    expect(sent, ['one']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, ['one', 'three']);
    await tester.pump(const Duration(seconds: 2));
    a.announce(tester.view, 'four');
    expect(sent, ['one', 'three', 'four']);
    expect(a.sent, 3);
    a.reset();
  });
}
