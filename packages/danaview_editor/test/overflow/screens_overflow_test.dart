// OWNER: QA-09
//
// No-overflow matrix (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9) for the editor's screens outside
// the editor: Projects (a long list with every badge, the recovery banner, the storage footer,
// scrolled through; the empty state), the New project sheet, the Rename sheet, the editor
// settings screen (scrolled through, Auto captions on and off), the "Restore unsaved changes?"
// recovery dialog and the editor's "This project isn't available" state. Long-content fixtures
// and real fonts; each state: takeException() == null, the primary actions inside the screen, no
// truncated button label or section header.
//
// The Home header and the player surfaces live in danaview_features, which danaview_editor may not
// import (ARCH §4.2 rule 7); overflow_full.sh runs their matrix tests at the repository root.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/flows/relink/recovery_dialog.dart';
import 'package:danaview_editor/src/projects/new_project_sheet.dart';
import 'package:danaview_editor/src/projects/project_actions.dart';
import 'package:danaview_editor/src/projects/projects_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';

import '../projects/projects_test_support.dart';
import '../support/support.dart';
import 'overflow_fixtures.dart';
import 'overflow_rig.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Scrolls the first scrollable to its end, checking each step.
Future<void> _scrollThrough(WidgetTester tester, String state, {List<Finder> inside = const []}) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -300), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    ProblemLog.current.check(tester, '$state scrolled', inside: inside);
  }
}

/// A repository with many long-named projects carrying every badge and two recoverable sessions.
ProjectsRepository _busyRepo() {
  final repo = ProjectsRepository();
  repo.add(
    projectNamed(longProjectName, aspect: AspectRatio.portrait9x16),
    const SummaryExtras(missing: 128, recovery: true, duration: 37230000000, bytes: 98765432100),
  );
  for (var i = 0; i < 10; i++) {
    repo.add(
      projectNamed('${longFileName.substring(0, 20 + i * 5)} $i', updatedAt: DateTime.utc(2026, 9, 1 + i), aspect: AspectRatio.standard[i % 6]),
      SummaryExtras(health: ProjectHealth.values[i % ProjectHealth.values.length], missing: i % 3 * 7, bytes: 1000000 * i, recovery: i.isEven),
    );
  }
  for (final (i, name) in [longProjectName, 'Second $longProjectName'].indexed) {
    repo.recoverableSessions.add(RecoverableSession(
      projectId: ProjectId('pr_recover000$i'),
      projectName: name.substring(0, 80.clamp(0, name.length)),
      journalRevision: 3,
      mainRevision: 2,
      journalSavedAt: DateTime.utc(2026, 10, 8, 12, 32),
    ));
  }
  return repo;
}

EditorTestHarness _harness(ProjectsRepository repo) => EditorTestHarness(
      repository: repo,
      overrides: [projectsClockProvider.overrideWithValue(() => projectsNow)],
    );

Future<void> _pumpProjects(WidgetTester tester, EditorTestHarness h, EditorSurface surface) async {
  await h.pumpApp(
    tester,
    ProjectsScreen(onBack: () {}, onOpenProject: (_, {initialPlayhead}) {}, onManageStorage: () {}),
    surface: surface,
  );
  await _settle(tester);
}

void main() {
  setUpAll(loadRealFonts);

  testOverflow('Projects: long list with badges, recovery banner and footer, scrolled through', (tester, surface) async {
    final h = _harness(_busyRepo());
    await _pumpProjects(tester, h, surface);
    final newButton = find.byKey(const ValueKey('projects-new'));
    if (newButton.evaluate().isEmpty) ProblemLog.current.add('[projects] no New button');
    ProblemLog.current.check(tester, 'projects', inside: [newButton]);
    await _scrollThrough(tester, 'projects');
  });

  testOverflow('Projects: empty state', (tester, surface) async {
    await _pumpProjects(tester, _harness(ProjectsRepository()), surface);
    ProblemLog.current.check(tester, 'projects empty');
  });

  testOverflow('New project and Rename sheets', (tester, surface) async {
    final h = _harness(ProjectsRepository());
    await _pumpProjects(tester, h, surface);
    final context = tester.element(find.byType(ProjectsScreen));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    for (final (name, open) in <(String, void Function())>[
      ('new project', () => showNewProjectSheet(context)),
      ('rename', () => showRenameProjectSheet(context, initialName: longProjectName)),
    ]) {
      open();
      await _settle(tester);
      if (!navigator.canPop()) {
        ProblemLog.current.add('[$name] did not open');
        continue;
      }
      ProblemLog.current.check(tester, name);
      navigator.pop();
      await _settle(tester);
    }
  });

  for (final captions in [false, true]) {
    testOverflow('editor settings, Auto captions ${captions ? 'on' : 'off'}, scrolled through', (tester, surface) async {
      EditorFlags.debugAutoCaptionsOverride = captions;
      try {
        final h = EditorTestHarness(prefs: EditorPrefs.memory({EditorPrefKeys.proxyMedia: 'always'}));
        await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}), surface: surface);
        await _settle(tester);
        ProblemLog.current.check(tester, 'settings');
        await _scrollThrough(tester, 'settings');
      } finally {
        EditorFlags.debugAutoCaptionsOverride = null;
      }
    });
  }

  testOverflow('recovery dialog with the longest project name', (tester, surface) async {
    final h = EditorTestHarness();
    await h.pumpApp(tester, const Scaffold(body: SizedBox.expand()), surface: surface);
    final context = tester.element(find.byType(Scaffold));
    final session = RecoverableSession(
      projectId: LongIds.project,
      projectName: longProjectName,
      journalRevision: 3,
      mainRevision: 2,
      journalSavedAt: DateTime(2026, 10, 8, 14, 32),
    );
    showEditorRecoveryDialog(context, session, now: DateTime(2026, 10, 9, 9));
    await _settle(tester);
    final restore = find.byKey(const ValueKey('recovery-restore'));
    final lastSaved = find.byKey(const ValueKey('recovery-open-last-saved'));
    if (restore.evaluate().isEmpty || lastSaved.evaluate().isEmpty) ProblemLog.current.add('[recovery] buttons missing');
    ProblemLog.current.check(tester, 'recovery dialog', inside: [restore, lastSaved]);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await _settle(tester);
  });

  testOverflow('editor: project not available', (tester, surface) async {
    final h = EditorTestHarness();
    await tester.runAsync(() async {
      await h.pumpEditor(tester, projectId: const ProjectId('pr_missing00001'), surface: surface);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await _settle(tester);
    if (find.byType(EditorScreen).evaluate().isEmpty) ProblemLog.current.add('[unavailable] no editor screen');
    ProblemLog.current.check(tester, 'unavailable');
  });
}
