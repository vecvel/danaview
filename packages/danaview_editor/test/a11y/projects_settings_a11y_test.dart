// OWNER: QA-08
//
// Accessibility of the screens around the editor (ARCH §17.1, §17.10): Projects (empty, a list
// with every badge and the recovery banner, the project actions menu, the New project sheet) and
// Editor settings, on the narrowest, a phone and a tablet surface. Tap targets ≥ 44×44 with labels,
// text contrast ≥ 4.5:1, nothing overflows. (The licences screen, UX-42, was removed by the owner.)

import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/projects/project_card.dart';
import 'package:danaview_editor/src/projects/projects_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../projects/projects_test_support.dart';
import '../support/support.dart';
import 'a11y_support.dart';

const List<EditorSurface> _surfaces = [
  EditorSurface(Size(280, 500), textScale: 1.35),
  EditorSurface(Size(390, 844)),
  EditorSurface(Size(1194, 834), textScale: 1.35, platform: TargetPlatform.iOS),
];

ProjectsRepository _busy() {
  final repo = ProjectsRepository()
    ..add(projectNamed('Goa trip with friends, the long version with every single beach and sunset in it'),
        const SummaryExtras(missing: 2, recovery: true, duration: 4 * 3600 * microsPerSecond))
    ..add(projectNamed('Birthday', updatedAt: DateTime.utc(2026, 10, 7), aspect: AspectRatio.portrait9x16))
    ..add(projectNamed('Old format', updatedAt: DateTime.utc(2026, 9, 1)), const SummaryExtras(health: ProjectHealth.readOnlyNewer));
  repo.recoverableSessions.add(RecoverableSession(
    projectId: repo.projects.keys.first,
    projectName: 'Goa trip with friends',
    journalRevision: 2,
    mainRevision: 1,
    journalSavedAt: DateTime.utc(2026, 10, 8),
  ));
  return repo;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpProjects(WidgetTester tester, ProjectsRepository repo, EditorSurface surface) async {
  final h = EditorTestHarness(repository: repo, overrides: [projectsClockProvider.overrideWithValue(() => projectsNow)]);
  await h.pumpApp(
    tester,
    ProjectsScreen(onBack: () {}, onOpenProject: (id, {initialPlayhead}) {}, onManageStorage: () {}),
    surface: surface,
  );
  await _settle(tester);
}

void main() {
  tearDown(DanaviewToast.dismiss);

  for (final surface in _surfaces) {
    group('[$surface]', () {
      testWidgets('Projects, empty', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpProjects(tester, ProjectsRepository(), surface);
        expect(find.byKey(const ValueKey('projects-empty')), findsOneWidget);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'Projects empty');
        semantics.dispose();
      });

      testWidgets('Projects, list with badges and the recovery banner', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpProjects(tester, _busy(), surface);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'Projects list');
        semantics.dispose();
      });

      testWidgets('Projects, the project actions menu', (tester) async {
        final semantics = tester.ensureSemantics();
        final repo = ProjectsRepository()
          ..add(projectNamed('Birthday party at the beach with everyone from school'))
          ..add(projectNamed('Old format', updatedAt: DateTime.utc(2026, 9, 1)), const SummaryExtras(missing: 1));
        await _pumpProjects(tester, repo, surface);
        // The menu opens from the more button, a long press or a secondary click (UX-05).
        final card = find.byType(ProjectCard).first;
        await tester.ensureVisible(card);
        await tester.pump();
        await tester.longPress(card);
        await _settle(tester);
        expect(find.text('Rename'), findsWidgets, reason: 'the menu is open');
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'project actions menu');
        semantics.dispose();
      });

      testWidgets('Projects, the New project sheet', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpProjects(tester, ProjectsRepository(), surface);
        await tester.tap(find.byKey(const ValueKey('projects-new')));
        await _settle(tester);
        expect(find.byKey(const ValueKey('new-project-sheet')), findsOneWidget);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'New project sheet');
        semantics.dispose();
      });

      testWidgets('Editor settings', (tester) async {
        final semantics = tester.ensureSemantics();
        final h = EditorTestHarness();
        await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}), surface: surface);
        await _settle(tester);
        expectNoOverflow(tester);
        await expectA11yGuidelines(tester, where: 'Editor settings');
        semantics.dispose();
      });
    });
  }
}
