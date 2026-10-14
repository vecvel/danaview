// OWNER: UX-35
//
// The clip action bindings (ARCH §17.6, ux.md §10.15): reverse, freeze, replace, clipInfo and tasks
// are bound once by clip_bindings; enablement and reasons; reverse toggles through the registry;
// freeze asks for the duration (confirm and cancel); replace picks, imports, replaces and shows the
// trim notice; clip info opens the panel; tasks opens the sheet.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/clip_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/clip_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/tasks_sheet.dart';
import 'package:danaview_editor/src/editor/panels/clip_info_panel.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickSource;

import 'tasks_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  test('reverse, freeze, replace, clipInfo and tasks are bound exactly once, by clip_bindings', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'clip_bindings');
    expect(source.owner, 'UX-35');
    expect(source.bindings().map((b) => b.id),
        [EditorActionId.reverse, EditorActionId.freeze, EditorActionId.replace, EditorActionId.clipInfo, EditorActionId.tasks]);
    expect(identical(source.bindings(), source.bindings()), isTrue);
    final merged = mergeEditorActionBindings();
    for (final b in source.bindings()) {
      expect(merged[b.id], same(b), reason: b.id.name);
    }
  });

  test('clip length labels and replace pick kinds', () {
    expect(clipLengthLabel(4 * s), '0:04');
    expect(clipLengthLabel(65 * s + 999999), '1:05');
    expect(clipLengthLabel(3725 * s), '1:02:05');
    expect(replacePickKinds(TrackKind.video), {MediaPickKind.video, MediaPickKind.image});
    expect(replacePickKinds(TrackKind.overlay), {MediaPickKind.video, MediaPickKind.image});
    expect(replacePickKinds(TrackKind.audio), {MediaPickKind.audio});
  });

  group('enablement', () {
    testWidgets('nothing selected: every clip action explains itself', (tester) async {
      final rig = await TasksRig.pump(tester);
      final ctx = rig.ctx;
      for (final id in [EditorActionId.reverse, EditorActionId.freeze, EditorActionId.replace, EditorActionId.clipInfo]) {
        expect(rig.registry.spec(id).isEnabled(ctx), isFalse, reason: id.name);
        expect(rig.registry.spec(id).disabledReason(ctx), ClipStrings.selectClip, reason: id.name);
      }
      expect(rig.registry.spec(EditorActionId.tasks).isEnabled(ctx), isTrue);
      await rig.finish();
    });

    testWidgets('images and audio cannot be reversed or frozen; locked lanes refuse edits but show info', (tester) async {
      final rig = await TasksRig.pump(tester);
      final ctx = rig.ctx;
      for (final item in [TaskIds.image, TaskIds.audio]) {
        rig.editor.select(item);
        await rig.settle();
        expect(rig.registry.spec(EditorActionId.reverse).disabledReason(ctx), ClipStrings.selectVideo);
        expect(rig.registry.spec(EditorActionId.freeze).isEnabled(ctx), isFalse);
        expect(rig.registry.spec(EditorActionId.replace).isEnabled(ctx), isTrue);
        expect(rig.registry.spec(EditorActionId.clipInfo).isEnabled(ctx), isTrue);
      }
      rig.editor.select(TaskIds.locked);
      await rig.settle();
      expect(rig.registry.spec(EditorActionId.reverse).disabledReason(ctx), ClipStrings.trackLocked);
      expect(rig.registry.spec(EditorActionId.replace).disabledReason(ctx), ClipStrings.trackLocked);
      expect(rig.registry.spec(EditorActionId.clipInfo).isEnabled(ctx), isTrue);
      await rig.finish();
    });

    testWidgets('freeze needs the playhead over the clip', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.video);
      await rig.seek(13 * s);
      expect(rig.registry.spec(EditorActionId.freeze).isEnabled(rig.ctx), isFalse);
      expect(rig.registry.spec(EditorActionId.freeze).disabledReason(rig.ctx), ClipStrings.playheadOutside);
      await rig.seek(2 * s);
      expect(rig.registry.spec(EditorActionId.freeze).isEnabled(rig.ctx), isTrue);
      await rig.finish();
    });
  });

  group('reverse', () {
    testWidgets('toggles reverse through the registry and starts the job; again plays forward', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.video);
      await rig.settle();
      expect(rig.registry.invoke(EditorActionId.reverse, rig.ctx), EditorActionResult.ran);
      await rig.settle();
      expect(rig.clip(TaskIds.video).reversed, isTrue);
      expect(rig.state.tasks.single.kind.name, 'reverse');
      rig.registry.invoke(EditorActionId.reverse, rig.ctx);
      await rig.settle();
      expect(rig.clip(TaskIds.video).reversed, isFalse);
      expect(rig.entries, 2);
      await rig.finish();
    });
  });

  group('freeze', () {
    testWidgets('asks for the duration (default 3 s) and inserts the still on confirm', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.video);
      await rig.seek(2 * s);
      rig.registry.invoke(EditorActionId.freeze, rig.ctx);
      await tester.pumpAndSettle();
      expect(key('freeze.sheet'), findsOneWidget);
      expect(find.text(ClipStrings.freezeTitle), findsWidgets);
      final field = tester.widget<FreezeFrameSheet>(find.byType(FreezeFrameSheet));
      expect(field.initial, 3);
      // One stepper step up: 3.5 s.
      await tester.enterText(find.descendant(of: key('freeze.duration'), matching: find.byType(EditableText)), '1.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(key('freeze.confirm'));
      await tester.pumpAndSettle();
      expect(key('freeze.sheet'), findsNothing);
      final still = rig.project.tracks.first.items.whereType<MediaClip>().firstWhere((c) => rig.asset(c.media).kind == MediaKind.still);
      expect(still.start, 2 * s);
      expect(still.duration, rate.quantizeNearest(15 * s ~/ 10));
      expect(rig.state.tasks.single.kind.name, 'freeze');
      await rig.finish();
    });

    testWidgets('Cancel in the sheet changes nothing', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.video);
      await rig.seek(2 * s);
      final before = rig.project.timeline;
      rig.registry.invoke(EditorActionId.freeze, rig.ctx);
      await tester.pumpAndSettle();
      await tester.tap(key('freeze.cancel'));
      await tester.pumpAndSettle();
      expect(rig.project.timeline, before);
      expect(rig.jobs.created, isEmpty);
      await rig.finish();
    });
  });

  group('replace', () {
    testWidgets('picks one video or image, imports it without placing and replaces the clip, keeping its range', (tester) async {
      final pool = ScriptedPool()..steps['city.mov'] = const AddStep();
      final rig = await TasksRig.pump(tester, pool: pool);
      rig.editor.select(TaskIds.silent);
      await rig.settle();
      rig.engine.picker.nextPicks = [pickOf('city.mov', size: 1000)];
      expect(rig.registry.invoke(EditorActionId.replace, rig.ctx), EditorActionResult.ran);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final request = rig.engine.picker.requests.single;
      expect(request.source, MediaPickSource.photos);
      expect(request.kinds, {MediaPickKind.video, MediaPickKind.image});
      expect(request.multiple, isFalse);
      expect(pool.imported, ['city.mov']);
      final clip = rig.clip(TaskIds.silent);
      expect(rig.asset(clip.media).displayName, 'city.mov');
      expect(clip.start, 12 * s);
      expect(clip.duration, 2 * s);
      expect(rig.entries, 1);
      expect(rig.project.tracks.first.items, hasLength(3), reason: 'nothing placed');
      await rig.finish();
    });

    testWidgets('shorter media trims the clip with the notice', (tester) async {
      final pool = ScriptedPool()..steps['short.mp4'] = const AddStep();
      final rig = await TasksRig.pump(tester, pool: pool);
      rig.editor.select(TaskIds.video);
      await rig.settle();
      rig.engine.picker.nextPicks = [pickOf('short.mp4', size: 1000)];
      rig.registry.invoke(EditorActionId.replace, rig.ctx);
      // Step (not settle): the toast animates itself away.
      final notice = find.text(ClipStrings.replaceTrimmed(MediaKind.video, '0:04'));
      for (var i = 0; i < 40 && notice.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final clip = rig.clip(TaskIds.video);
      expect(rig.asset(clip.media).displayName, 'short.mp4');
      expect(clip.duration, 4 * s, reason: 'the scripted import is 4 s long');
      expect(notice, findsOneWidget);
      expect(ClipStrings.replaceTrimmed(MediaKind.video, '0:04'), 'The new video is shorter, so the clip was trimmed to 0:04.');
      await tester.pumpAndSettle();
      await rig.finish();
    });

    testWidgets('audio clips pick audio files only', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.audio);
      await rig.settle();
      rig.registry.invoke(EditorActionId.replace, rig.ctx);
      await tester.pumpAndSettle();
      final request = rig.engine.picker.requests.single;
      expect(request.source, MediaPickSource.files);
      expect(request.kinds, {MediaPickKind.audio});
      expect(rig.entries, 0, reason: 'cancelled picker');
      await rig.finish();
    });
  });

  group('info and tasks', () {
    testWidgets('clip info opens the panel on the selected clip', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.editor.select(TaskIds.locked);
      await rig.settle();
      rig.registry.invoke(EditorActionId.clipInfo, rig.ctx);
      await rig.settle();
      expect(rig.state.inspector, const ClipInfoInspector(TaskIds.locked));
      expect(find.byType(ClipInfoPanel), findsOneWidget);
      await rig.finish();
    });

    testWidgets('tasks opens the sheet', (tester) async {
      final rig = await TasksRig.pump(tester);
      rig.registry.invoke(EditorActionId.tasks, rig.ctx);
      await tester.pumpAndSettle();
      expect(find.byType(TasksSheet), findsOneWidget);
      expect(find.text(ClipStrings.tasksEmpty), findsOneWidget);
      await rig.finish();
    });
  });
}
