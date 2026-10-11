// OWNER: UX-40
//
// What opening a project says about its state (ux.md §13.3, §13.4, D-12): a migrated project (the
// one-time notice), a newer schema that opens read-only (banner, notice, nothing saved) or is
// blocked (the editor's message), a damaged project that opened from its last good copy (banner),
// and a repaired project.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_messages.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/flows/relink/editor_health_host.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/eval.dart' show ProjectOpenWarning;
import 'package:danaview_editor_core/store.dart';

import 'relink_support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('migration', () {
    test('a migrated project opens normally and says so once', () async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.openResults[rig.id] = (p) => LoadedProject(project: p, migratedFrom: 1);
      rig.useContainer(rig.harness.container());
      final events = <EditorEvent>[];
      final sub = rig.editor.events.listen(events.add);
      addTearDown(sub.cancel);
      await rig.open();
      final toasts = events.whereType<EditorToast>().map((e) => e.message).toList();
      expect(toasts, [EditorMessages.migrated]);
      expect(rig.editor.state.phase, EditorPhase.ready);
      expect(rig.editor.readOnly, isFalse);
      expect(rig.editor.state.save, SaveStatus.clean);
    });

    test('a project that was not migrated shows no notice', () async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.useContainer(rig.harness.container());
      final events = <EditorEvent>[];
      final sub = rig.editor.events.listen(events.add);
      addTearDown(sub.cancel);
      await rig.open();
      expect(events.whereType<EditorToast>(), isEmpty);
    });
  });

  group('newer schema', () {
    testWidgets('read-only: a banner, the notice, edits stay in memory and nothing is saved', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.openResults[rig.id] = (p) => LoadedProject(project: p, health: ProjectHealth.readOnlyNewer);
      await rig.harness.pumpApp(
        tester,
        EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
      );
      rig.useContainer(rig.harness.containerOf(tester));
      final events = <EditorEvent>[];
      final sub = rig.editor.events.listen(events.add);
      addTearDown(sub.cancel);
      expect(find.byKey(const ValueKey('read-only-banner')), findsNothing, reason: 'not opened yet');
      await tester.runAsync(rig.open);
      await _settle(tester);
      expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
      expect(find.text('Read-only: made with a newer Danaview'), findsOneWidget);
      expect(find.text('You can look at it and export it. Update Danaview to save changes.'), findsOneWidget);
      expect(events.whereType<EditorToast>().map((e) => e.message), contains(EditorMessages.openedReadOnly));
      expect(rig.editor.readOnly, isTrue);
      expect(rig.editor.state.save, SaveStatus.readOnly);
      expect(rig.repo.autosaveRequests, 0);
      expect((await rig.editor.saveNow(manual: true)).skipped, isTrue);
      expect(rig.repo.calls, isNot(contains('save')));
    });

    testWidgets('a normal project has no read-only banner', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      await rig.harness.pumpApp(
        tester,
        EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
      );
      rig.useContainer(rig.harness.containerOf(tester));
      await tester.runAsync(rig.open);
      await _settle(tester);
      expect(find.byKey(const ValueKey('read-only-banner')), findsNothing);
    });

    testWidgets('blocked: the editor shows the newer-app message and the project is unchanged', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.failNext['open'] = const StoreFailure(StoreFailureKind.newerSchema);
      await rig.harness.pumpEditor(tester, projectId: rig.id);
      await _settle(tester);
      expect(find.text('This project was made with a newer version of Danaview'), findsOneWidget);
      expect(find.text('Update Danaview to open it. The project is unchanged.'), findsOneWidget);
      final c = rig.harness.containerOf(tester);
      final state = c.read(editorControllerProvider(rig.id));
      expect(state.phase, EditorPhase.failed);
      expect(state.failure, isA<ProjectNeedsNewerApp>());
      expect(rig.repo.calls, isNot(contains('save')));
    });
  });

  group('damaged projects', () {
    testWidgets('a project that opened from its last good copy says so until dismissed', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.openResults[rig.id] = (p) => LoadedProject(project: p, warnings: const [ProjectOpenWarning(restoredFromBackupWarning)]);
      await rig.harness.pumpApp(
        tester,
        EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
      );
      rig.useContainer(rig.harness.containerOf(tester));
      final events = <EditorEvent>[];
      final sub = rig.editor.events.listen(events.add);
      addTearDown(sub.cancel);
      await tester.runAsync(rig.open);
      await _settle(tester);
      expect(find.text('Opened the last good version'), findsOneWidget);
      expect(find.textContaining('may be missing'), findsOneWidget);
      expect(events.whereType<EditorToast>().map((e) => e.message), contains(EditorMessages.repaired));
      await tester.tap(find.byKey(const ValueKey('backup-restored-dismiss')));
      await _settle(tester);
      expect(find.text('Opened the last good version'), findsNothing);
    });

    testWidgets('a repaired project without a backup restore shows no such banner', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.openResults[rig.id] = (p) => LoadedProject(project: p, warnings: const [ProjectOpenWarning('overlapRepaired')]);
      await rig.harness.pumpApp(
        tester,
        EditorScope(projectId: rig.id, child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost())))),
      );
      rig.useContainer(rig.harness.containerOf(tester));
      await tester.runAsync(rig.open);
      await _settle(tester);
      expect(find.byKey(const ValueKey('backup-restored-banner')), findsNothing);
    });

    testWidgets('no valid copy at all: the editor says it could not open it', (tester) async {
      final rig = RelinkRig([videoAsset('md_1')]);
      rig.repo.failNext['open'] = const StoreFailure(StoreFailureKind.corrupt);
      await rig.harness.pumpEditor(tester, projectId: rig.id);
      await _settle(tester);
      expect(find.text("This project couldn't be opened"), findsOneWidget);
      expect(find.textContaining('no backup could be read'), findsOneWidget);
    });
  });
}
