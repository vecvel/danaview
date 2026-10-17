// OWNER: UX-13
//
// The edit actions (ux.md §8.9, §14.4) through the registry and the keyboard, over the real
// controller and FakeEditorEngine: split (playhead, selection, cues, nothing there), delete vs
// ripple delete vs delete gap, copy / cut / paste / duplicate with the in-app clipboard, select
// all, the Esc chain, multi-select, move to track and the snapping / ripple toggles. Every edit is
// one history entry.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/edit_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/edit_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/state/edit_transaction.dart' show EditApplied;
import 'package:danaview_editor/src/editor/state/editor_clipboard.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SelectMode;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'interaction_support.dart';

const _ids = {
  EditorActionId.split,
  EditorActionId.delete,
  EditorActionId.rippleDelete,
  EditorActionId.deleteGap,
  EditorActionId.copy,
  EditorActionId.cut,
  EditorActionId.paste,
  EditorActionId.duplicate,
  EditorActionId.selectAll,
  EditorActionId.escape,
  EditorActionId.multiSelect,
  EditorActionId.moveToTrack,
  EditorActionId.toggleSnapping,
  EditorActionId.toggleRipple,
};

void main() {
  test('the file binds exactly the edit actions of UX-13 and merges without duplicates', () {
    expect({for (final b in editBindings) b.id}, _ids);
    expect(identical(editBindings, editBindings), isTrue);
    final merged = mergeEditorActionBindings();
    for (final id in _ids) {
      expect(merged.containsKey(id), isTrue, reason: '$id');
    }
    expect(editorBindingSources.any((s) => s.file == 'edit_bindings' && s.owner == 'UX-13'), isTrue);
  });

  Future<(TimelineRig, EditorActionRegistry, WidgetActionContext)> rig(WidgetTester tester, {bool ripple = false}) async {
    final t = await pumpTimeline(tester, project: interactionProject(), ripple: ripple);
    final a = actionsOf(tester, t);
    return (t, a.registry, a.ctx);
  }

  void seek(TimelineRig t, TimeUs at) => unawaited(t.container.read(playheadProvider(t.id)).seekExact(at));

  group('split', () {
    testWidgets('nothing selected: the main-lane clip under the playhead, one entry, light haptic', (tester) async {
      final haptics = HapticRecorder.install(tester);
      final (t, registry, ctx) = await rig(tester);
      seek(t, 6 * s);
      expect(registry.invoke(EditorActionId.split, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(t.item('it_b').range, const TimeRange(4 * s, 6 * s));
      expect(t.project.timeline.tracks.firstWhere((tr) => tr.isMain).items.map((i) => i.range),
          contains(const TimeRange(6 * s, 8 * s)));
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Split');
      expect(haptics.lightImpacts, 1);
    });

    testWidgets('the selected items under the playhead, cues through SplitCue', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      seek(t, 1500000);
      t.rig.controller.select(const ItemId('cue_1'));
      registry.invoke(EditorActionId.split, ctx);
      await tester.pump();
      expect(t.item('cue_1').range, TimeRange(1 * s, 1 * s + s ~/ 2));
      expect(t.item('it_a').range, const TimeRange(0, 4 * s), reason: 'the main lane is not the target');
      expect(t.historyDepth, 1);

      seek(t, 5 * s);
      t.rig.controller.select(const ItemId('it_m'));
      registry.invoke(EditorActionId.split, ctx);
      await tester.pump();
      expect(t.item('it_m').range, const TimeRange(0, 5 * s));
      expect(t.historyDepth, 2);
    });

    testWidgets('the split tool splits at a tapped position, not the playhead (quantized to a frame)', (tester) async {
      final (t, _, ctx) = await rig(tester);
      seek(t, 1 * s);
      final ops = EditOperations.of(ctx);
      expect(ops.splitCommand(at: 9 * s), isNull, reason: 'the main-lane gap has nothing to split');
      final result = ops.split(at: 11 * s + 10);
      await tester.pump();
      expect(result, isA<EditApplied>());
      expect(t.item('it_c').range, const TimeRange(10 * s, 11 * s));
      expect(t.item('it_a').range, const TimeRange(0, 4 * s), reason: 'the clip under the playhead is untouched');
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Split');
    });

    testWidgets('nothing under the playhead: the toast explains, nothing changes', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      seek(t, 9 * s); // the main-lane gap
      registry.invoke(EditorActionId.split, ctx);
      await tester.pump();
      expect(find.text(EditStrings.splitNoTarget), findsOneWidget);
      expect(t.historyDepth, 0);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('delete', () {
    testWidgets('Delete leaves a gap with ripple off; Ripple delete always closes it', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      t.rig.controller.select(const ItemId('it_b'));
      registry.invoke(EditorActionId.delete, ctx);
      await tester.pump();
      expect(t.project.index.locate(const ItemId('it_b')), isNull);
      expect(t.item('it_c').start, 10 * s);
      expect(t.undoLabel, 'Delete');
      t.rig.controller.undo();
      t.rig.controller.select(const ItemId('it_b'));
      registry.invoke(EditorActionId.rippleDelete, ctx);
      await tester.pump();
      expect(t.item('it_c').start, 6 * s);
      expect(t.undoLabel, 'Ripple delete');
    });

    testWidgets('Delete closes the gap in ripple mode', (tester) async {
      final (t, registry, ctx) = await rig(tester, ripple: true);
      t.rig.controller.select(const ItemId('it_b'));
      registry.invoke(EditorActionId.delete, ctx);
      await tester.pump();
      expect(t.item('it_c').start, 6 * s);
      expect(t.historyDepth, 1);
    });

    testWidgets('a selected gap: Delete gap (and Delete) remove it; disabled without a gap', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      final spec = registry.spec(EditorActionId.deleteGap);
      expect(spec.isEnabled(ctx), isFalse);
      expect(spec.disabledReason(ctx), EditStrings.selectGapFirst);
      t.rig.controller.selectGap(const GapRef(TrackId('tr_main'), TimeRange(8 * s, 10 * s)));
      expect(spec.isEnabled(ctx), isTrue);
      registry.invoke(EditorActionId.deleteGap, ctx);
      await tester.pump();
      expect(t.item('it_c').start, 8 * s);
      expect(t.undoLabel, 'Delete gap');
      expect(t.historyDepth, 1);
    });

    testWidgets('Delete removes a selected marker or transition; nothing selected disables it', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      expect(registry.spec(EditorActionId.delete).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.delete).disabledReason(ctx), EditStrings.selectClipFirst);
      t.rig.controller.selectMarker(const MarkerId('mk_beat'));
      registry.invoke(EditorActionId.delete, ctx);
      await tester.pump();
      expect(t.project.timeline.markers, isEmpty);
      t.rig.controller.selectTransition(const TransitionRef(TrackId('tr_main'), ItemId('it_a'), ItemId('it_b')));
      registry.invoke(EditorActionId.delete, ctx);
      await tester.pump();
      expect(t.project.timeline.tracks.firstWhere((tr) => tr.isMain).transitions, isEmpty);
      expect(t.historyDepth, 2);
    });
  });

  group('clipboard', () {
    testWidgets('copy (no entry), paste at the playhead (one entry), duplicate after the selection', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      final paste = registry.spec(EditorActionId.paste);
      expect(paste.isEnabled(ctx), isFalse);
      expect(paste.disabledReason(ctx), EditStrings.clipboardEmpty);
      t.rig.controller.select(const ItemId('it_c'));
      registry.invoke(EditorActionId.copy, ctx);
      await tester.pump();
      expect(find.text(EditStrings.copied(1)), findsOneWidget);
      expect(t.historyDepth, 0);
      final clip = t.container.read(editorClipboardProvider)!;
      expect(clip.sourceProject, t.id);
      expect(clip.items.single.item.id, const ItemId('it_c'));
      expect(paste.isEnabled(ctx), isTrue);

      seek(t, 14 * s);
      registry.invoke(EditorActionId.paste, ctx);
      await tester.pump();
      final main = t.project.timeline.tracks.firstWhere((tr) => tr.isMain);
      expect(main.items.map((i) => i.range), contains(const TimeRange(14 * s, 18 * s)));
      expect(t.undoLabel, 'Paste');
      expect(t.historyDepth, 1);

      t.rig.controller.select(const ItemId('it_a'));
      registry.invoke(EditorActionId.duplicate, ctx);
      await tester.pump();
      expect(t.undoLabel, 'Duplicate');
      expect(t.historyDepth, 2);
      expect(t.state.selection.items.single, isNot(const ItemId('it_a')), reason: 'the copy is selected');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('cut = copy + delete as one entry "Cut"; paste brings it back', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      t.rig.controller.select(const ItemId('it_c'));
      registry.invoke(EditorActionId.cut, ctx);
      await tester.pump();
      expect(t.project.index.locate(const ItemId('it_c')), isNull);
      expect(t.historyDepth, 1);
      expect(t.undoLabel, 'Cut');
      expect(t.container.read(editorClipboardProvider)!.items.single.item.id, const ItemId('it_c'));
      seek(t, 9 * s);
      registry.invoke(EditorActionId.paste, ctx);
      await tester.pump();
      final main = t.project.timeline.tracks.firstWhere((tr) => tr.isMain);
      expect(main.items.map((i) => i.range), contains(const TimeRange(9 * s, 13 * s)));
      expect(t.historyDepth, 2);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('copied cue text also goes to the system clipboard; clips do not', (tester) async {
      final texts = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') texts.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final (t, registry, ctx) = await rig(tester);
      t.rig.controller.select(const ItemId('it_c'));
      registry.invoke(EditorActionId.copy, ctx);
      await tester.pump();
      expect(texts, isEmpty);
      t.rig.controller.select(const ItemId('cue_1'));
      t.rig.controller.select(const ItemId('cue_2'), mode: SelectMode.extend);
      registry.invoke(EditorActionId.copy, ctx);
      await tester.pump();
      expect(texts, ['Hello\n\nWorld']);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('selection and modes', () {
    testWidgets('select all, then Esc leaves multi-select, then clears the selection, then has nothing to do', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      registry.invoke(EditorActionId.selectAll, ctx);
      expect(t.state.selection.items, SelectionRules.all(t.project));
      expect(t.state.selection.items, isNot(contains(const ItemId('it_l'))), reason: 'locked lanes are skipped');
      registry.invoke(EditorActionId.multiSelect, ctx);
      expect(t.state.modes.multiSelect, isTrue);
      registry.invoke(EditorActionId.escape, ctx);
      await tester.pump();
      expect(t.state.modes.multiSelect, isFalse);
      expect(t.state.selection.items, isNotEmpty);
      registry.invoke(EditorActionId.escape, ctx);
      await tester.pump();
      expect(t.state.selection.isEmpty, isTrue);
      expect(registry.spec(EditorActionId.escape).isEnabled(ctx), isFalse);
      expect(t.historyDepth, 0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Esc during a drag cancels it', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      final i = interactionOf(t);
      await tester.tapAt(t.at(tester, 12 * s, 'tr_main'));
      await tester.pump();
      final g = await tester.startGesture(trimHandleAt(tester, t, 'it_c', TrimEdge.start));
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(i.isDragging, isTrue);
      registry.invoke(EditorActionId.escape, ctx);
      await tester.pump();
      expect(i.isDragging, isFalse);
      await g.up();
      await tester.pump();
      expect(t.item('it_c').start, 10 * s);
      expect(t.historyDepth, 0);
    });

    testWidgets('N and R toggle snapping and ripple, persisted in the project view', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      final snapping = t.state.modes.snapping;
      registry.invoke(EditorActionId.toggleSnapping, ctx);
      await tester.pump();
      expect(t.state.modes.snapping, !snapping);
      expect(t.project.view.snappingEnabled, !snapping);
      expect(find.text(EditStrings.snapping(!snapping)), findsOneWidget);
      registry.invoke(EditorActionId.toggleRipple, ctx);
      await tester.pump();
      expect(t.state.modes.ripple, isTrue);
      expect(t.project.view.rippleEnabled, isTrue);
      expect(t.historyDepth, 0, reason: 'modes are not edits');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Move to track lists the compatible unlocked lanes and moves there as one entry', (tester) async {
      final (t, registry, ctx) = await rig(tester);
      final spec = registry.spec(EditorActionId.moveToTrack);
      expect(spec.isEnabled(ctx), isFalse);
      t.rig.controller.select(const ItemId('it_c'));
      t.rig.controller.select(const ItemId('it_m'), mode: SelectMode.extend);
      expect(spec.isEnabled(ctx), isFalse, reason: 'two lanes');
      expect(spec.disabledReason(ctx), EditStrings.noOtherTrack);
      t.rig.controller.select(const ItemId('it_c'));
      expect(spec.isEnabled(ctx), isTrue);
      registry.invoke(EditorActionId.moveToTrack, ctx);
      await tester.pumpAndSettle();
      expect(find.text(EditStrings.moveToTrackTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('move-to-tr_ov')), findsOneWidget);
      expect(find.byKey(const ValueKey('move-to-tr_lock')), findsNothing, reason: 'locked');
      expect(find.byKey(const ValueKey('move-to-tr_music')), findsNothing, reason: 'another kind');
      await tester.tap(find.byKey(const ValueKey('move-to-tr_ov')));
      await tester.pumpAndSettle();
      final loc = t.project.index.locate(const ItemId('it_c'))!;
      expect(loc.track.id, const TrackId('tr_ov'));
      expect(loc.item.range, const TimeRange(10 * s, 14 * s));
      expect(t.historyDepth, 1);
    });
  });

  testWidgets('the keyboard reaches the bindings: S splits, Delete deletes, ⌘C/⌘V copy and paste', (tester) async {
    final t = await pumpTimeline(tester,
        project: interactionProject(), platform: TargetPlatform.macOS, wrap: (timeline) => EditorShortcuts(child: timeline));
    await tester.pump();
    seek(t, 6 * s);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(t.item('it_b').range, const TimeRange(4 * s, 6 * s));
    expect(t.historyDepth, 1);

    t.rig.controller.select(const ItemId('it_c'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(t.container.read(editorClipboardProvider), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(t.project.index.locate(const ItemId('it_c')), isNull);
    expect(t.historyDepth, 2);

    seek(t, 9 * s);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(t.historyDepth, 3);
    expect(t.undoLabel, 'Paste');
    await tester.pump(const Duration(seconds: 3));
  });

  test('EditorClipboard: cue text, empty payloads are ignored', () {
    final texts = <String>[];
    final c = EditorClipboardController(systemText: texts.add);
    final project = interactionProject();
    c.put(copyItems(project, const {}));
    expect(c.hasContent, isFalse);
    c.put(copyItems(project, {const ItemId('cue_2'), const ItemId('cue_1')}));
    expect(c.contents!.cueText, 'Hello\n\nWorld');
    expect(c.contents!.length, 2);
    expect(texts, ['Hello\n\nWorld']);
    c.put(copyItems(project, {const ItemId('it_a')}));
    expect(c.contents!.cueText, isNull);
    expect(texts, hasLength(1));
    c.clear();
    expect(c.contents, isNull);
  });
}
