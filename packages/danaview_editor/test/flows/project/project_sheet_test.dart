// OWNER: UX-29
//
// The Project sheet (ux.md §6.4, §14.3) and the project bindings: header and save status; every
// row runs its action after the sheet closes; Save now and ⌘S call `repository.save(manual)`;
// rename (validation, success, a store that refuses an open project); disabled rows explain
// themselves; undo/redo/save/projectSheet/history/format bindings; surface matrix.

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/project_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/project_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/history_sheet.dart';
import 'package:danaview_editor/src/editor/flows/project_sheet.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddMarker, SetCanvas;
import 'package:danaview_editor_core/store.dart' show SaveReason, StoreFailure, StoreFailureKind;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'project_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

DanaviewListTile row(WidgetTester tester, ProjectSheetChoice c) => tester.widget<DanaviewListTile>(key('project.${c.name}'));

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  EditorAnnouncer.instance.reset();
}

void testProject(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

/// Taps the row of [c] (scrolled into view) and lets the sheet close.
Future<void> choose(WidgetTester tester, ProjectSheetChoice c) async {
  await tester.ensureVisible(key('project.${c.name}'));
  await tester.pumpAndSettle();
  await tester.tap(key('project.${c.name}'));
  await tester.pumpAndSettle();
}

/// The merged bindings with recording handlers for the actions other tickets bind.
Override recordingBindings(List<EditorActionId> ran) => editorActionBindingsProvider.overrideWithValue({
      ...mergeEditorActionBindings(),
      for (final id in [EditorActionId.media, EditorActionId.tasks])
        id: EditorActionBinding(id: id, handler: (_) => ran.add(id)),
    });

void main() {
  group('sheet', () {
    testProject('the projectSheet action shows the name, the save status and every row', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      expect(await rig.invoke(EditorActionId.projectSheet), EditorActionResult.ran);
      expect(find.text(ProjectStrings.projectTitle), findsOneWidget);
      expect(find.text('Holiday edit'), findsOneWidget);
      expect(tester.widget<Text>(key('project.status')).data, ProjectStrings.statusSaved);
      for (final c in ProjectSheetChoice.values) {
        expect(key('project.${c.name}'), findsOneWidget, reason: c.name);
        expect(find.text(c.title), findsOneWidget, reason: c.name);
      }
      expect(row(tester, ProjectSheetChoice.format).subtitle, ProjectStrings.formatSummary(AspectRatio.landscape16x9, FrameRate.fps30, 1080));
      expect(row(tester, ProjectSheetChoice.media).subtitle, ProjectStrings.mediaCount(2));
      expect(row(tester, ProjectSheetChoice.history).subtitle, ProjectStrings.historyCount(0));
    });

    testProject('the status follows the save state (Edited after an edit)', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      rig.editor.apply(const AddMarker(3 * s));
      await tester.pump();
      await rig.invoke(EditorActionId.projectSheet);
      expect(tester.widget<Text>(key('project.status')).data, ProjectStrings.statusEdited);
      expect(row(tester, ProjectSheetChoice.history).subtitle, ProjectStrings.historyCount(1));
    });

    testProject('Save now closes the sheet and calls repository.save(manual); status becomes Saved', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      rig.editor.apply(const AddMarker(3 * s));
      await tester.pump();
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.save);
      await rig.real(() async {});
      expect(find.text(ProjectStrings.projectTitle), findsNothing);
      expect(rig.repository.reasons, [SaveReason.manual]);
      expect(rig.state.save.phase, SavePhase.saved);
      expect(rig.repository.projects[rig.id]!.markers.length, rig.project.markers.length);
    });

    testProject('a failed save shows "Couldn\'t save" and Save now says it retries', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      rig.repository.failNext['save'] = const StoreFailure(StoreFailureKind.diskFull, 'full');
      await rig.real(() => rig.editor.saveNow(manual: true));
      expect(rig.state.save.phase, SavePhase.failed);
      await rig.invoke(EditorActionId.projectSheet);
      expect(tester.widget<Text>(key('project.status')).data, ProjectStrings.statusFailed);
      expect(row(tester, ProjectSheetChoice.save).subtitle, ProjectStrings.saveRetry);
      await choose(tester, ProjectSheetChoice.save);
      await rig.real(() async {});
      expect(rig.state.save.phase, SavePhase.saved);
    });

    testProject('Format opens the Format panel', (tester) async {
      final rig = await ProjectRig.pump(tester);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.format);
      expect(rig.state.inspector, const CanvasInspector());
    });

    testProject('Edit history opens the History sheet', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      rig.editor.apply(const AddMarker(3 * s));
      await tester.pump();
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.history);
      expect(find.byType(HistorySheet), findsOneWidget);
      expect(find.text(ProjectStrings.historyTitle), findsOneWidget);
    });

    testProject('Keyboard shortcuts opens the shortcuts sheet', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.shortcuts);
      expect(find.text(EditorActionStrings.sheetTitle), findsWidgets);
    });

    testProject('Media in project and Background tasks run their actions', (tester) async {
      final ran = <EditorActionId>[];
      final rig = await ProjectRig.pump(tester, withPanel: false, overrides: [recordingBindings(ran)]);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.media);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.tasks);
      expect(ran, [EditorActionId.media, EditorActionId.tasks]);
    });

    testProject('a row whose action is disabled is disabled and gives the reason', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, readOnly: true);
      await rig.invoke(EditorActionId.projectSheet);
      expect(tester.widget<Text>(key('project.status')).data, ProjectStrings.statusReadOnly);
      final save = row(tester, ProjectSheetChoice.save);
      expect(save.enabled, isFalse);
      expect(save.subtitle, EditorActionStrings.readOnly);
      expect(row(tester, ProjectSheetChoice.format).enabled, isTrue, reason: 'the Format panel opens to show the settings (read-only)');
      expect(row(tester, ProjectSheetChoice.rename).enabled, isFalse);
      // A row bound by nobody (or disabled) matches the registry's reason.
      final tasks = rig.registry.spec(EditorActionId.tasks);
      expect(row(tester, ProjectSheetChoice.tasks).enabled, tasks.isEnabled(rig.ctx));
      if (!tasks.isEnabled(rig.ctx)) expect(row(tester, ProjectSheetChoice.tasks).subtitle, tasks.disabledReason(rig.ctx));
    });

    testProject('the save shortcut is shown on pointer platforms and tablets, not on phones', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS));
      await rig.invoke(EditorActionId.projectSheet);
      expect(find.descendant(of: key('project.save'), matching: find.text('⌘S')), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    });

    testProject('no shortcut on a phone', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, surface: const EditorSurface(Size(390, 844), platform: TargetPlatform.android));
      await rig.invoke(EditorActionId.projectSheet);
      expect(find.descendant(of: key('project.save'), matching: find.text('Ctrl+S')), findsNothing);
    });
  });

  group('rename', () {
    testProject('Rename asks for a name, validates it and renames through projectRenameProvider', (tester) async {
      final renamed = <(ProjectId, String)>[];
      final rig = await ProjectRig.pump(tester, withPanel: false, overrides: [
        projectRenameProvider.overrideWithValue((id, name) async => renamed.add((id, name))),
      ]);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.rename);
      expect(find.text(ProjectStrings.renameTitle), findsOneWidget);
      final field = find.byType(EditableText);
      await tester.enterText(field, '   ');
      await tester.tap(find.text(ProjectStrings.renameConfirm));
      await tester.pump();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(renamed, isEmpty);
      await tester.enterText(field, '  Summer cut ');
      await tester.tap(find.text(ProjectStrings.renameConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(renamed, [(rig.id, 'Summer cut')]);
      expect(find.text(ProjectStrings.renamed('Summer cut')), findsOneWidget);
    });

    testProject('the default rename calls the repository', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.rename);
      await tester.enterText(find.byType(EditableText), 'Trip');
      await tester.tap(find.text(ProjectStrings.renameConfirm));
      await rig.real(() async {});
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.repository.calls, contains('rename:${rig.id}'));
      expect(rig.repository.projects[rig.id]!.name, 'Trip');
    });

    testProject('a store that refuses to rename an open project gets a toast with the next step', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, overrides: [
        projectRenameProvider.overrideWithValue((id, name) async => throw const StoreFailure(StoreFailureKind.busy)),
      ]);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.rename);
      await tester.enterText(find.byType(EditableText), 'Trip');
      await tester.tap(find.text(ProjectStrings.renameConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(ProjectStrings.renameBusy), findsOneWidget);
    });

    testProject('Cancel or the same name renames nothing', (tester) async {
      final renamed = <String>[];
      final rig = await ProjectRig.pump(tester, withPanel: false, overrides: [
        projectRenameProvider.overrideWithValue((id, name) async => renamed.add(name)),
      ]);
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.rename);
      await tester.tap(find.text(ProjectStrings.cancel));
      await tester.pumpAndSettle();
      await rig.invoke(EditorActionId.projectSheet);
      await choose(tester, ProjectSheetChoice.rename);
      await tester.tap(find.text(ProjectStrings.renameConfirm));
      await tester.pumpAndSettle();
      expect(renamed, isEmpty);
    });
  });

  group('bindings', () {
    test('bind save, undo, redo, projectSheet, history and format once each', () {
      expect(projectBindings.map((b) => b.id).toSet(), {
        EditorActionId.save,
        EditorActionId.undo,
        EditorActionId.redo,
        EditorActionId.projectSheet,
        EditorActionId.history,
        EditorActionId.format,
      });
      expect(identical(projectBindings, projectBindings), isTrue);
      final merged = mergeEditorActionBindings();
      for (final b in projectBindings) {
        expect(identical(merged[b.id], b), isTrue, reason: b.id.name);
      }
    });

    testProject('before the project opens every project action is disabled with a reason', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, open: false);
      final r = rig.registry;
      expect(r.spec(EditorActionId.save).disabledReason(rig.ctx), EditorActionStrings.notOpen);
      expect(r.spec(EditorActionId.undo).disabledReason(rig.ctx), EditorActionStrings.notOpen);
      expect(r.spec(EditorActionId.redo).disabledReason(rig.ctx), EditorActionStrings.notOpen);
      expect(r.spec(EditorActionId.projectSheet).disabledReason(rig.ctx), ProjectStrings.notOpen);
      expect(r.invoke(EditorActionId.projectSheet, rig.ctx), EditorActionResult.disabled);
    });

    testProject('undo and redo step one entry each and explain when there is nothing', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      final r = rig.registry;
      expect(r.spec(EditorActionId.undo).disabledReason(rig.ctx), EditorActionStrings.nothingToUndo);
      expect(r.spec(EditorActionId.redo).disabledReason(rig.ctx), EditorActionStrings.nothingToRedo);
      rig.editor.apply(const SetCanvas(baseShortSide: 720));
      final patches = rig.sync.schedules;
      expect(r.invoke(EditorActionId.undo, rig.ctx), EditorActionResult.ran);
      expect(rig.settings.canvas.baseShortSide, 1080);
      expect(rig.sync.schedules, patches + 1);
      expect(r.invoke(EditorActionId.redo, rig.ctx), EditorActionResult.ran);
      expect(rig.settings.canvas.baseShortSide, 720);
      expect(r.spec(EditorActionId.redo).isEnabled(rig.ctx), isFalse);
    });

    testProject('save is a manual save; disabled for a read-only project', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false);
      expect(rig.registry.invoke(EditorActionId.save, rig.ctx), EditorActionResult.ran);
      await rig.real(() async {});
      expect(rig.repository.reasons, [SaveReason.manual]);
      expect(find.text('Saved'), findsNothing, reason: 'the controller emits the toast; the editor screen shows it');
      final ro = rig.state.save.phase == SavePhase.readOnly;
      expect(ro, isFalse);
    });

    testProject('save is disabled for a read-only project', (tester) async {
      final rig = await ProjectRig.pump(tester, withPanel: false, readOnly: true);
      expect(rig.registry.spec(EditorActionId.save).isEnabled(rig.ctx), isFalse);
      expect(rig.registry.spec(EditorActionId.save).disabledReason(rig.ctx), EditorActionStrings.readOnly);
    });

    testProject('⌘S saves (manual) through the shortcuts, also on Android as Ctrl+S', (tester) async {
      final rig = await ProjectRig.pump(tester,
          withPanel: false, shortcuts: true, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.android));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await rig.real(() async {});
      expect(rig.repository.reasons, contains(SaveReason.manual));
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testSurfaces('Project sheet', (tester, surface) async {
      try {
        final rig = await ProjectRig.pump(
          tester,
          surface: surface,
          withPanel: false,
          name: 'A very long project name that keeps going well past the width of a phone',
        );
        rig.editor.apply(const AddMarker(3 * s));
        await tester.pump();
        await rig.invoke(EditorActionId.projectSheet);
        expect(key('project.header'), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        for (final c in ProjectSheetChoice.values) {
          await tester.ensureVisible(key('project.${c.name}'));
          await tester.pumpAndSettle();
          expectInside(tester, key('project.${c.name}'));
        }
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

    testSurfaces('Rename prompt', (tester, surface) async {
      try {
        final rig = await ProjectRig.pump(tester, surface: surface, withPanel: false);
        await rig.invoke(EditorActionId.projectSheet);
        await choose(tester, ProjectSheetChoice.rename);
        expect(find.text(ProjectStrings.renameTitle), findsOneWidget);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.tap(find.text(ProjectStrings.cancel));
        await drain(tester);
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });
  });
}
