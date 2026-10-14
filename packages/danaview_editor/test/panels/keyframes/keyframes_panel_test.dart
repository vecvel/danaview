// OWNER: UX-26
//
// The Keyframes panel (ux.md §10.11, §9.4): properties grouped as Transform / Adjust / Mask /
// Audio, add / remove at the playhead through the property toggles (with their three states),
// jump to the previous / next key, select, drag (snapped to frames, one entry), nudge by a frame
// (joined within 500 ms), edit the value, jump here, delete, clear one property, remove all, the
// header's keyframe-all and reset, "Animate a property", the locked lane, semantics, and the
// surface matrix. Every edit is checked against the CORE-13 command it dispatches (the model change
// and its history entry).

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/semantics.dart' show CustomSemanticsAction, SemanticsAction, SemanticsActionEvent, SemanticsBinding, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/keyframe_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/keyframes_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewIconButton;

import '../../support/support.dart';
import 'keyframes_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

Finder block(PropertyKey<Object?> p) => key('kf.block.${p.id}');

Finder strip(PropertyKey<Object?> p) => key('kf.strip.${p.id}');

Finder card(PropertyKey<Object?> p) => key('kf.selected.${p.id}');

/// The tooltip [tooltip] inside the block of [p].
Finder inBlock(PropertyKey<Object?> p, Finder finder) => find.descendant(of: block(p), matching: finder);

/// The number fields of the selected key's card of [p].
Finder valueFields(PropertyKey<Object?> p) => find.descendant(of: card(p), matching: find.byType(EditableText));

/// The global position of the diamond of a key at item-local [t] of an item of [duration].
Offset diamondAt(WidgetTester tester, PropertyKey<Object?> p, TimeUs t, TimeUs duration) {
  final r = tester.getRect(strip(p));
  return Offset(r.left + KeyframeStrip.xOf(r.width, t, duration), r.center.dy);
}

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump();
}

/// Taps the diamond of the key at [t] of [p] on [rig]'s item [item].
Future<void> selectKey(KfRig rig, PropertyKey<Object?> p, TimeUs t, {ItemId item = KfIds.video}) async {
  final tester = rig.tester;
  await tester.ensureVisible(strip(p));
  await tester.pumpAndSettle();
  await tester.tapAt(diamondAt(tester, p, t, rig.item(item).duration));
  await tester.pump();
  await tester.pump();
}

/// Performs [action] on [n] as assistive technology would.
void perform(WidgetTester tester, SemanticsNode n, SemanticsAction action, [Object? arguments]) {
  SemanticsBinding.instance
      // ignore: invalid_use_of_protected_member
      .performSemanticsAction(SemanticsActionEvent(type: action, nodeId: n.id, viewId: tester.view.viewId, arguments: arguments));
}

/// A widget test that clears the throttled announcement and toast timers before the framework checks.
void testKf(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void testKfSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      try {
        await body(tester, surface);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    now = DateTime.utc(2026, 10, 14, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('the list', () {
    testKf('groups the animated properties of a clip: Transform, then Adjust, with key counts', (tester) async {
      await KfRig.pump(tester);
      expect(find.byType(KeyframesPanel), findsOneWidget);
      expect(find.text(KeyframeStrings.groupTransform), findsOneWidget);
      expect(find.text(KeyframeStrings.groupAdjust), findsOneWidget);
      expect(find.text(KeyframeStrings.groupMask), findsNothing);
      expect(find.text(KeyframeStrings.groupAudio), findsNothing);
      expect(inBlock(PropertyKeys.opacity, find.text('3 keyframes')), findsOneWidget);
      expect(inBlock(PropertyKeys.exposure, find.text('2 keyframes')), findsOneWidget);
      final transformY = tester.getTopLeft(find.text(KeyframeStrings.groupTransform)).dy;
      final adjustY = tester.getTopLeft(find.text(KeyframeStrings.groupAdjust)).dy;
      expect(transformY, lessThan(adjustY));
      expect(tester.getTopLeft(block(PropertyKeys.opacity)).dy, lessThan(adjustY));
      expect(tester.getTopLeft(block(PropertyKeys.exposure)).dy, greaterThan(adjustY));
      expect(find.text(KeyframeStrings.emptyTitle), findsNothing);
      expect(key('kf.removeAll'), findsOneWidget);
    });

    testKf('an audio clip lists its volume under Audio', (tester) async {
      await KfRig.pump(tester, open: KfIds.audio);
      expect(find.text(KeyframeStrings.groupAudio), findsOneWidget);
      expect(find.text(KeyframeStrings.groupTransform), findsNothing);
      expect(inBlock(PropertyKeys.volume, find.text('2 keyframes')), findsOneWidget);
    });

    test('groups, labels and the lists of animated and addable properties', () {
      expect(KeyframeCommands.groupOf(PropertyKeys.position), KeyframeGroup.transform);
      expect(KeyframeCommands.groupOf(PropertyKeys.rotation), KeyframeGroup.transform);
      expect(KeyframeCommands.groupOf(PropertyKeys.exposure), KeyframeGroup.adjust);
      expect(KeyframeCommands.groupOf(PropertyKeys.lookup('detail.blur')!), KeyframeGroup.adjust);
      expect(KeyframeCommands.groupOf(PropertyKeys.maskSize), KeyframeGroup.mask);
      expect(KeyframeCommands.groupOf(PropertyKeys.volume), KeyframeGroup.audio);
      expect(KeyframeCommands.resolve('transform.position.x'), PropertyKeys.position);
      expect(KeyframeCommands.resolve('visual.fit'), isNull, reason: 'not keyframable');
      final project = keyframesProject(const ProjectId('p'));
      final video = project.index.item(KfIds.video)!;
      expect(KeyframeCommands.animated(video), [PropertyKeys.opacity, PropertyKeys.exposure]);
      final addable = KeyframeCommands.addable(video, project.pool);
      expect(addable, contains(PropertyKeys.position));
      expect(addable, contains(PropertyKeys.maskCenter));
      expect(addable, isNot(contains(PropertyKeys.opacity)));
      expect(addable, isNot(contains(PropertyKeys.volume)), reason: 'volume belongs to the audio part');
      final text = project.index.item(KfIds.text)!;
      expect(KeyframeCommands.addable(text, project.pool), [PropertyKeys.position, PropertyKeys.scale, PropertyKeys.rotation, PropertyKeys.opacity]);
      expect(KeyframeCommands.animatable(text), isTrue);
    });

    testKf('a clip with no keys shows the empty state and "Animate a property"', (tester) async {
      await KfRig.pump(tester, open: KfIds.plain, at: 7 * s);
      expect(find.text(KeyframeStrings.emptyTitle), findsOneWidget);
      expect(find.text(KeyframeStrings.emptyBody), findsOneWidget);
      expect(find.text(KeyframeStrings.addTitle), findsOneWidget);
      expect(key('kf.removeAll'), findsNothing);
      expect(find.byType(InspectorHeader), findsOneWidget);
      expect(find.byTooltip(InspectorStrings.reset), findsNothing, reason: 'nothing to reset');
    });
  });

  group('add', () {
    testKf('"Animate a property" adds the first key at the playhead (AddKeyframe) and selects it', (tester) async {
      final rig = await KfRig.pump(tester, open: KfIds.plain, at: 7 * s);
      final before = rig.entries;
      await tap(tester, key('kf.add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rotation').last);
      await tester.pumpAndSettle();
      expect(rig.keys(KfIds.plain, PropertyKeys.rotation), [1 * s]);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Add keyframe');
      expect(rig.state.selection.keyframe?.property, PropertyKeys.rotation.id);
      expect(block(PropertyKeys.rotation), findsOneWidget);
      expect(card(PropertyKeys.rotation), findsOneWidget);
      expect(find.text(KeyframeStrings.selectedTitle('Rotation', 1, 1)), findsOneWidget);
      expect(find.text(KeyframeStrings.emptyTitle), findsNothing);
    });

    testKf('"Add keyframe" is disabled with the playhead outside the clip and says why', (tester) async {
      final rig = await KfRig.pump(tester, open: KfIds.plain, at: 1 * s);
      expect(find.text(KeyframeStrings.outsideItem), findsOneWidget);
      await tester.tap(key('kf.add'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Rotation'), findsNothing, reason: 'the menu does not open');
      expect(KeyframeCommands.animated(rig.item(KfIds.plain)), isEmpty);
      await rig.seek(8 * s);
      expect(find.text(KeyframeStrings.outsideItem), findsNothing);
    });
  });

  group('the property toggle', () {
    KeyframeToggle toggleOf(WidgetTester tester, PropertyKey<Object?> p) =>
        tester.widget<KeyframeToggle>(find.descendant(of: key('kf.toggle.${p.id}'), matching: find.byType(KeyframeToggle)));

    testKf('three states follow the playhead: on a key, between keys, and outside the item', (tester) async {
      final rig = await KfRig.pump(tester, at: 1 * s);
      expect(toggleOf(tester, PropertyKeys.opacity).status.state, KeyframeToggleState.atPlayhead);
      expect(toggleOf(tester, PropertyKeys.exposure).status.state, KeyframeToggleState.animated);
      await rig.seek(2 * s);
      expect(toggleOf(tester, PropertyKeys.opacity).status.state, KeyframeToggleState.animated);
      expect(toggleOf(tester, PropertyKeys.exposure).status.state, KeyframeToggleState.atPlayhead);
      await rig.seek(7 * s);
      expect(toggleOf(tester, PropertyKeys.opacity).status.enabled, isFalse);
    });

    testKf('a tap on a key removes it (RemoveKeyframe); a tap between keys adds one (AddKeyframe)', (tester) async {
      final rig = await KfRig.pump(tester, at: 1 * s);
      var before = rig.entries;
      await tap(tester, inBlock(PropertyKeys.opacity, find.byIcon(Icons.diamond_rounded)));
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 3 * s]);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Remove keyframe');
      expect(inBlock(PropertyKeys.opacity, find.text('2 keyframes')), findsOneWidget);

      await rig.seek(2 * s);
      before = rig.entries;
      await tap(tester, inBlock(PropertyKeys.opacity, find.byIcon(Icons.diamond_outlined)));
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 2 * s, 3 * s]);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Add keyframe');
      expect(toggleOf(tester, PropertyKeys.opacity).status.state, KeyframeToggleState.atPlayhead);
    });

    testKf('‹ › jump the playhead to the previous and next key', (tester) async {
      final rig = await KfRig.pump(tester, at: 2 * s);
      await tap(tester, inBlock(PropertyKeys.opacity, find.byTooltip(KeyframeToggleStrings.next)));
      await rig.real(() async {});
      expect(rig.playhead.value, 3 * s);
      await tap(tester, inBlock(PropertyKeys.opacity, find.byTooltip(KeyframeToggleStrings.previous)));
      await rig.real(() async {});
      expect(rig.playhead.value, 1 * s);
      await tap(tester, inBlock(PropertyKeys.opacity, find.byTooltip(KeyframeToggleStrings.previous)));
      await rig.real(() async {});
      expect(rig.playhead.value, 0);
    });
  });

  group('the selected key', () {
    testKf('a tap on a diamond selects it (the shared keyframe selection) and opens its card', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      final sel = rig.state.selection.keyframe;
      expect(sel?.item, KfIds.video);
      expect(sel?.property, PropertyKeys.opacity.id);
      expect(sel?.t, 1 * s);
      expect(find.text(KeyframeStrings.selectedTitle('Opacity', 2, 3)), findsOneWidget);
      expect(find.descendant(of: card(PropertyKeys.opacity), matching: find.text(KeyframeStrings.linear)), findsOneWidget);
      expect(tester.widget<Text>(key('kf.time')).data, Timecode.format(1 * s, rate));
      expect(card(PropertyKeys.exposure), findsNothing);
    });

    testKf('-1 / +1 frame nudge the key (MoveKeyframe), joined into one entry within 500 ms', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      final before = rig.entries;
      await tap(tester, key('kf.frameForward'));
      await tap(tester, key('kf.frameForward'));
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, frames(32), 3 * s]);
      expect(rig.entries, before + 1, reason: 'two quick nudges are one entry');
      expect(rig.state.history.undoLabel, KeyframeStrings.historyNudge);
      expect(rig.values(KfIds.video, 'transform.opacity')[frames(32)], 0.5, reason: 'the key keeps its value');
      expect(tester.widget<Text>(key('kf.time')).data, Timecode.format(frames(32), rate));
      now = now.add(const Duration(seconds: 1));
      await tap(tester, key('kf.frameBack'));
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, frames(31), 3 * s]);
      expect(rig.entries, before + 2, reason: 'a later nudge is a new entry');
    });

    testKf('nudging is disabled toward a neighbour key or the item edge', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 0);
      expect(tester.widget<DanaviewIconButton>(key('kf.frameBack')).onPressed, isNull);
      expect(tester.widget<DanaviewIconButton>(key('kf.frameForward')).onPressed, isNotNull);
      final before = rig.entries;
      await tester.tap(key('kf.frameBack'), warnIfMissed: false);
      await tester.pump();
      expect(rig.entries, before, reason: 'no frame before 0');
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 1 * s, 3 * s]);
    });

    testKf('editing the value sets the key (SetKeyframeValue, display units)', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      final before = rig.entries;
      await tester.ensureVisible(valueFields(PropertyKeys.opacity).first);
      await tester.pumpAndSettle();
      await tester.enterText(valueFields(PropertyKeys.opacity).first, '25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.values(KfIds.video, 'transform.opacity')[1 * s], closeTo(0.25, 1e-9));
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, KeyframeStrings.historyValue);
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 1 * s, 3 * s], reason: 'times unchanged');
    });

    testKf('a value outside the range is clamped to the property range', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      await tester.ensureVisible(valueFields(PropertyKeys.opacity).first);
      await tester.pumpAndSettle();
      await tester.enterText(valueFields(PropertyKeys.opacity).first, '400');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.values(KfIds.video, 'transform.opacity')[1 * s], closeTo(1.0, 1e-9));
    });

    testKf('"Jump here" seeks the playhead onto the key', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 3 * s);
      await tap(tester, key('kf.jumpHere'));
      await rig.real(() async {});
      expect(rig.playhead.value, 3 * s);
    });

    testKf('"Delete keyframe" removes the key (RemoveKeyframe) and selects the item again', (tester) async {
      final rig = await KfRig.pump(tester);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      final before = rig.entries;
      await tap(tester, key('kf.delete'));
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 3 * s]);
      expect(rig.entries, before + 1);
      expect(rig.state.selection.keyframe, isNull);
      expect(rig.state.selection.primary, KfIds.video);
      expect(card(PropertyKeys.opacity), findsNothing);
    });

    testKf('a key selected on the timeline (stored time) opens its card in the panel', (tester) async {
      final rig = await KfRig.pump(tester);
      rig.editor.selectKeyframe(const KeyframeRef(KfIds.video, 'adjust.exposure', 2 * s));
      await tester.pump();
      await tester.pump();
      expect(card(PropertyKeys.exposure), findsOneWidget);
      expect(find.text(KeyframeStrings.selectedTitle('Exposure', 2, 2)), findsOneWidget);
    });
  });

  group('drag in the list', () {
    testKf('dragging a diamond moves the key, snapped to frames, as one "Move keyframe" entry', (tester) async {
      final rig = await KfRig.pump(tester);
      await tester.ensureVisible(strip(PropertyKeys.opacity));
      await tester.pumpAndSettle();
      final duration = rig.item(KfIds.video).duration;
      final from = diamondAt(tester, PropertyKeys.opacity, 1 * s, duration);
      final to = diamondAt(tester, PropertyKeys.opacity, 2 * s + 7000, duration);
      final before = rig.entries;
      final gesture = await tester.startGesture(from);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(Offset((from.dx + to.dx) / 2, from.dy));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      final times = rig.keys(KfIds.video, PropertyKeys.opacity);
      expect(times.length, 3);
      expect(times.first, 0);
      expect(times.last, 3 * s);
      final moved = times[1];
      expect(rate.quantizeNearest(moved), moved, reason: 'on the frame grid');
      expect((moved - 2 * s).abs(), lessThanOrEqualTo(rate.frameUs * 2));
      expect(rig.values(KfIds.video, 'transform.opacity')[moved], 0.5);
      expect(rig.entries, before + 1, reason: 'the whole drag is one entry');
      expect(rig.state.history.undoLabel, KeyframeStrings.historyNudge);
      expect(rig.state.selection.keyframe?.t, moved, reason: 'the moved key stays selected');
      rig.editor.undo();
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 1 * s, 3 * s]);
    });

    testKf('a drag onto another key of the property leaves the diamond where it was', (tester) async {
      final rig = await KfRig.pump(tester);
      await tester.ensureVisible(strip(PropertyKeys.opacity));
      await tester.pumpAndSettle();
      final duration = rig.item(KfIds.video).duration;
      final from = diamondAt(tester, PropertyKeys.opacity, 1 * s, duration);
      final onto = diamondAt(tester, PropertyKeys.opacity, 3 * s, duration);
      final before = rig.entries;
      final gesture = await tester.startGesture(from);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(onto);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final times = rig.keys(KfIds.video, PropertyKeys.opacity);
      expect(times.toSet().length, 3);
      expect(times.last, 3 * s);
      expect(rig.values(KfIds.video, 'transform.opacity')[3 * s], 0.0, reason: 'the other key is untouched');
      expect(rig.entries, lessThanOrEqualTo(before + 1));
    });

    testKf('a dragged diamond snaps to the playhead', (tester) async {
      final rig = await KfRig.pump(tester, at: frames(75));
      await tester.ensureVisible(strip(PropertyKeys.opacity));
      await tester.pumpAndSettle();
      final duration = rig.item(KfIds.video).duration;
      final from = diamondAt(tester, PropertyKeys.opacity, 1 * s, duration);
      final near = diamondAt(tester, PropertyKeys.opacity, frames(75), duration) + const Offset(5, 0);
      final gesture = await tester.startGesture(from);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(near);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, frames(75), 3 * s]);
    });
  });

  group('clear', () {
    testKf('the row menu clears one property (ClearKeyframes); it keeps its value at the playhead', (tester) async {
      final rig = await KfRig.pump(tester, at: 2 * s);
      final before = rig.entries;
      await tap(tester, key('kf.menu.${PropertyKeys.opacity.id}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(KeyframeStrings.removeAllOfProperty).last);
      await tester.pumpAndSettle();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), isEmpty);
      expect(rig.keys(KfIds.video, PropertyKeys.exposure), [0, 2 * s], reason: 'other properties stay');
      expect(rig.entries, before + 1);
      final clip = rig.item(KfIds.video) as MediaClip;
      expect(clip.visual!.transform.opacity, closeTo(0.25, 1e-6), reason: 'the value at 2 s between 50% and 0%');
      expect(block(PropertyKeys.opacity), findsNothing);
    });

    testKf('"Remove all keyframes" clears the item in one entry and confirms with a toast', (tester) async {
      final rig = await KfRig.pump(tester, at: 1 * s);
      final before = rig.entries;
      await tap(tester, key('kf.removeAll'));
      expect(KeyframeCommands.animated(rig.item(KfIds.video)), isEmpty);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, KeyframeStrings.historyRemoveAll);
      expect(find.text(KeyframeStrings.removedAll), findsOneWidget);
      expect(find.text(KeyframeStrings.emptyTitle), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      await tester.pump();
      expect(KeyframeCommands.animated(rig.item(KfIds.video)), [PropertyKeys.opacity, PropertyKeys.exposure]);
    });

    testKf('the header reset asks first, then removes every key', (tester) async {
      final rig = await KfRig.pump(tester);
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(find.text('Reset Keyframes?'), findsOneWidget);
      await tester.tap(find.text(InspectorStrings.reset).last);
      await tester.pumpAndSettle();
      expect(KeyframeCommands.animated(rig.item(KfIds.video)), isEmpty);
    });
  });

  group('header keyframe-all', () {
    KeyframeToggle headerToggle(WidgetTester tester) =>
        tester.widget<KeyframeToggle>(find.descendant(of: find.byType(InspectorHeader), matching: find.byType(KeyframeToggle)));

    testKf('adds a key to every animated property at the playhead in one entry, then removes them', (tester) async {
      final rig = await KfRig.pump(tester, at: frames(45));
      expect(headerToggle(tester).status.state, KeyframeToggleState.animated);
      final before = rig.entries;
      await tester.tap(find.descendant(of: find.byType(InspectorHeader), matching: find.byIcon(Icons.diamond_outlined)));
      await tester.pump();
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), contains(frames(45)));
      expect(rig.keys(KfIds.video, PropertyKeys.exposure), contains(frames(45)));
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, KeyframeStrings.historyKeyframeAll);
      expect(headerToggle(tester).status.state, KeyframeToggleState.atPlayhead);
      await tester.tap(find.descendant(of: find.byType(InspectorHeader), matching: find.byIcon(Icons.diamond_rounded)));
      await tester.pump();
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 1 * s, 3 * s]);
      expect(rig.keys(KfIds.video, PropertyKeys.exposure), [0, 2 * s]);
      expect(rig.entries, before + 2);
      expect(rig.state.history.undoLabel, KeyframeStrings.historyRemoveKeys);
    });

    test('aggregate status: at the playhead only when every property has a key there', () {
      final project = keyframesProject(const ProjectId('p'));
      final video = project.index.item(KfIds.video)!;
      final keys = KeyframeCommands.animated(video);
      expect(KeyframeCommands.aggregateStatus(video, keys, 0).state, KeyframeToggleState.atPlayhead);
      expect(KeyframeCommands.aggregateStatus(video, keys, 1 * s).state, KeyframeToggleState.animated);
      expect(KeyframeCommands.aggregateStatus(video, const [], 1 * s).state, KeyframeToggleState.none);
    });
  });

  group('locked lane', () {
    testKf('every edit is disabled; selecting and jumping still work', (tester) async {
      final rig = await KfRig.pump(tester, open: KfIds.locked, selectOpen: false, at: 1 * s);
      expect(find.text(KeyframeStrings.trackLocked), findsOneWidget);
      expect(find.byTooltip(InspectorStrings.reset), findsNothing);
      final before = rig.project;
      await tap(tester, key('kf.removeAll'));
      expect(rig.project.timeline, before.timeline);
      await selectKey(rig, PropertyKeys.opacity, 2 * s, item: KfIds.locked);
      expect(card(PropertyKeys.opacity), findsOneWidget);
      await tap(tester, key('kf.delete'));
      await tap(tester, key('kf.frameForward'));
      expect(rig.keys(KfIds.locked, PropertyKeys.opacity), [0, 2 * s]);
      await tap(tester, key('kf.jumpHere'));
      await rig.real(() async {});
      expect(rig.playhead.value, 2 * s);

      // A drag does nothing.
      final duration = rig.item(KfIds.locked).duration;
      final gesture = await tester.startGesture(diamondAt(tester, PropertyKeys.opacity, 2 * s, duration));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(rig.keys(KfIds.locked, PropertyKeys.opacity), [0, 2 * s]);
      expect(rig.project.timeline, before.timeline);
    });
  });

  group('semantics', () {
    testKf('each diamond is a node with its time and value and frame-nudge actions', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await KfRig.pump(tester);
      final label = KeyframeStrings.diamondLabel('Opacity', Timecode.format(1 * s, rate));
      final node = find.bySemanticsLabel(label);
      expect(node, findsOneWidget);
      SemanticsNode n = tester.getSemantics(node);
      expect(n.value, '50%');
      expect(n.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      final ids = CustomSemanticsAction.getIdentifier;
      expect(n.getSemanticsData().customSemanticsActionIds,
          containsAll([ids(KeyframeStrip.nudgeEarlierAction), ids(KeyframeStrip.nudgeLaterAction)]));
      perform(tester, n, SemanticsAction.tap);
      await tester.pump();
      await tester.pump();
      expect(rig.state.selection.keyframe?.t, 1 * s);
      final before = rig.entries;
      n = tester.getSemantics(node);
      perform(tester, n, SemanticsAction.customAction, ids(KeyframeStrip.nudgeLaterAction));
      await tester.pump();
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, frames(31), 3 * s]);
      expect(rig.entries, before + 1);
      handle.dispose();
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testKfSurfaces('the list with a selected key', (tester, surface) async {
      final rig = await KfRig.pump(tester, surface: surface, at: 1 * s);
      await selectKey(rig, PropertyKeys.opacity, 1 * s);
      expect(card(PropertyKeys.opacity), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in ['kf.frameBack', 'kf.frameForward', 'kf.jumpHere', 'kf.delete', 'kf.strip.transform.opacity']) {
        await tester.ensureVisible(key(k));
        await tester.pumpAndSettle();
        final r = tester.getRect(key(k));
        expect(r.left, greaterThanOrEqualTo(0), reason: k);
        expect(r.right, lessThanOrEqualTo(surface.size.width), reason: k);
      }
      expectNoOverflow(tester);
    });

    testKfSurfaces('a position key (two value rows)', (tester, surface) async {
      final rig = await KfRig.pump(tester, surface: surface, open: KfIds.text, at: 1 * s);
      await tap(tester, key('kf.add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Position').last);
      await tester.pumpAndSettle();
      expect(rig.keys(KfIds.text, PropertyKeys.position), [1 * s]);
      expect(valueFields(PropertyKeys.position), findsNWidgets(2));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testKfSurfaces('empty and locked', (tester, surface) async {
      await KfRig.pump(tester, surface: surface, open: KfIds.locked, selectOpen: false);
      expect(find.text(KeyframeStrings.trackLocked), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
