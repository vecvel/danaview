// OWNER: UX-40
//
// Recovery UX (ux.md §13.3) with the fake repository: the Projects screen's banner (one project,
// several, restore, discard with confirmation, failures) and the editor's "Restore unsaved
// changes?" dialog (Restore rebuilds the editor on the restored project, Open last saved keeps the
// journal), plus the surface matrix.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/strings/relink_strings.dart';
import 'package:vwish_editor/src/editor/editor_lifecycle.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/editor_screen.dart' show editorShellProvider;
import 'package:vwish_editor/src/editor/flows/relink/editor_health_host.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/projects/projects_controller.dart';
import 'package:vwish_editor/src/projects/recovery_banner.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';

import '../../projects/projects_test_support.dart' show ProjectsRepository, projectNamed;
import '../../support/support.dart';
import 'relink_support.dart';

RecoverableSession _session(ProjectId id, String name, {DateTime? at}) => RecoverableSession(
      projectId: id,
      projectName: name,
      journalRevision: 3,
      mainRevision: 2,
      journalSavedAt: at ?? DateTime(2026, 10, 8, 12, 32),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  group('RecoveryBanner (Projects)', () {
    EditorTestHarness harness(ProjectsRepository repo) =>
        EditorTestHarness(repository: repo, overrides: [projectsClockProvider.overrideWithValue(() => DateTime(2026, 10, 8, 14))]);

    Future<List<ProjectId>> pump(WidgetTester tester, ProjectsRepository repo, List<(String, DateTime?)> crashed,
        {EditorSurface surface = SurfaceMatrix.phone, ValueChanged<ProjectId>? onRestored}) async {
      final ids = <ProjectId>[];
      for (final (name, at) in crashed) {
        final id = repo.add(projectNamed(name));
        ids.add(id);
        repo.recoverableSessions.add(_session(id, name, at: at));
      }
      // The controller builds its list in the constructor: the sessions must exist before.
      await harness(repo).pumpApp(tester, Scaffold(body: SingleChildScrollView(child: RecoveryBanner(onRestored: onRestored))), surface: surface);
      await _settle(tester);
      return ids;
    }

    testWidgets('shows nothing without recoverable projects', (tester) async {
      await pump(tester, ProjectsRepository(), const []);
      expect(find.byKey(const ValueKey('recovery-banner')), findsNothing);
    });

    testWidgets('one project: name, time of the changes, Restore and Discard', (tester) async {
      final repo = ProjectsRepository();
      await pump(tester, repo, [('Goa trip', DateTime(2026, 10, 8, 12, 32))]);
      expect(find.text('Unsaved changes found'), findsOneWidget);
      expect(find.textContaining('Vwish closed before "Goa trip" was saved'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testWidgets('several projects: each has its own name, time and buttons', (tester) async {
      final repo = ProjectsRepository();
      await pump(tester, repo, [
        ('Goa trip', DateTime(2026, 10, 8, 12, 32)),
        ('Birthday', DateTime(2026, 10, 7, 9, 5)),
      ]);
      expect(find.text('2 projects have unsaved changes'), findsOneWidget);
      expect(find.text('Goa trip'), findsOneWidget);
      expect(find.text('Birthday'), findsOneWidget);
      expect(find.text('Changes from 12:32'), findsOneWidget);
      expect(find.textContaining('Changes from 7 Oct, '), findsOneWidget);
      expect(find.text('Restore'), findsNWidgets(2));
    });

    testWidgets('Restore promotes the journal, closes the project again and tells where it is', (tester) async {
      final repo = ProjectsRepository();
      final restored = <ProjectId>[];
      final ids = await pump(tester, repo, [('Goa trip', null), ('Birthday', null)], onRestored: restored.add);
      await _tap(tester, find.byKey(ValueKey('recovery-restore-${ids.first.value}')));
      expect(repo.calls, containsAllInOrder(['restore:${ids.first}', 'close:${ids.first}']));
      expect(repo.calls, isNot(contains('restore:${ids.last}')));
      expect(restored, [ids.first]);
      expect(find.text('Restored "Goa trip". Open it from your projects.'), findsOneWidget);
      expect(find.byKey(ValueKey('recovery-${ids.first.value}')), findsNothing, reason: 'the banner row is gone');
      expect(find.byKey(ValueKey('recovery-${ids.last.value}')), findsOneWidget, reason: 'the other project is still offered');
      expect(find.text('Unsaved changes found'), findsOneWidget);
      expect(find.textContaining('"Birthday"'), findsOneWidget);
    });

    testWidgets('Discard asks first, keeps the last saved version, and goes when confirmed', (tester) async {
      final repo = ProjectsRepository();
      final ids = await pump(tester, repo, [('Goa trip', null)]);
      await _tap(tester, find.byKey(ValueKey('recovery-discard-${ids.single.value}')));
      expect(find.text('Discard changes to "Goa trip"?'), findsOneWidget);
      expect(find.text('The unsaved changes are deleted. The last saved version of the project is kept.'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(repo.calls, isNot(contains('discard:${ids.single}')));
      expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);

      await _tap(tester, find.byKey(ValueKey('recovery-discard-${ids.single.value}')));
      await _tap(tester, find.text('Discard changes'));
      expect(repo.calls, contains('discard:${ids.single}'));
      expect(find.byKey(const ValueKey('recovery-banner')), findsNothing);
      expect(find.text('Discarded the unsaved changes to "Goa trip"'), findsOneWidget);
      expect(repo.projects.containsKey(ids.single), isTrue, reason: 'the project itself stays');
    });

    testWidgets('failures say nothing changed and keep the banner', (tester) async {
      final repo = ProjectsRepository();
      final ids = await pump(tester, repo, [('Goa trip', null)]);
      repo.failNext['restore'] = const StoreFailure(StoreFailureKind.io);
      await _tap(tester, find.byKey(ValueKey('recovery-restore-${ids.single.value}')));
      expect(find.text("That didn't work. Nothing was changed. Try again."), findsOneWidget);
      expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);
      repo.failNext['discard'] = const StoreFailure(StoreFailureKind.io);
      await _tap(tester, find.byKey(ValueKey('recovery-discard-${ids.single.value}')));
      await _tap(tester, find.text('Discard changes'));
      expect(find.text("That didn't work. Nothing was changed. Try again."), findsOneWidget);
      expect(find.byKey(const ValueKey('recovery-banner')), findsOneWidget);
    });

    testSurfaces('no overflow with one and with many projects', (tester, surface) async {
      final repo = ProjectsRepository();
      await pump(tester, repo, [
        ('A very long project name that goes on and on and on for the Goa trip', DateTime(2026, 10, 8, 12, 32)),
        ('Birthday', DateTime(2026, 9, 7, 9, 5)),
        ('Third', null),
      ], surface: surface);
      expectNoOverflow(tester);
      expect(fitsFullyProblems(tester, find.byKey(const ValueKey('recovery-banner'))).where((p) => p.contains('truncated')), isEmpty);
      expectOwnerUiRules(tester);
    });
  });

  group('the editor dialog', () {
    /// An editor shell like EditorScreen's (lifecycle opens and re-opens the controller) with the
    /// health host as its only content.
    Widget editor(ProjectId id) => Consumer(
          builder: (context, ref, _) {
            final shell = ref.watch(editorShellProvider(id));
            return EditorScope(
              projectId: id,
              child: EditorLifecycle(
                delegate: shell,
                onExit: () {},
                child: const Scaffold(body: SafeArea(child: Align(alignment: Alignment.topCenter, child: EditorHealthHost()))),
              ),
            );
          },
        );

    Future<RelinkRig> pump(WidgetTester tester, {bool pending = true, EditorSurface surface = SurfaceMatrix.phone}) async {
      final rig = RelinkRig([videoAsset('md_1')], overrides: [projectsClockProvider.overrideWithValue(() => DateTime(2026, 10, 8, 15))]);
      var first = true;
      rig.repo.openResults[rig.id] = (p) {
        final withPending = pending && first;
        first = false;
        return LoadedProject(
          project: p,
          pendingRecovery: withPending ? _session(rig.id, 'Goa trip', at: DateTime(2026, 10, 8, 14, 32)) : null,
        );
      };
      await rig.harness.pumpApp(tester, editor(rig.id), surface: surface);
      rig.useContainer(rig.harness.containerOf(tester));
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await _settle(tester);
      return rig;
    }

    testWidgets('opening a project with a pending recovery asks "Restore unsaved changes?"', (tester) async {
      await pump(tester);
      expect(find.text('Restore unsaved changes?'), findsOneWidget);
      expect(find.text('Vwish closed before your last changes to "Goa trip" were saved (changes from 14:32).'), findsOneWidget);
      expect(find.text('You can still restore them from Projects until you save.'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Open last saved'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testWidgets('a project without a pending recovery never asks', (tester) async {
      await pump(tester, pending: false);
      expect(find.text('Restore unsaved changes?'), findsNothing);
    });

    testWidgets('Open last saved keeps the journal and the editor as it is', (tester) async {
      final rig = await pump(tester);
      await _tap(tester, find.byKey(const ValueKey('recovery-open-last-saved')));
      expect(find.text('Restore unsaved changes?'), findsNothing);
      expect(rig.repo.calls.where((c) => c.startsWith('restore')), isEmpty);
      expect(rig.repo.calls.where((c) => c.startsWith('discard')), isEmpty);
      expect(rig.editor.state.phase, EditorPhase.ready);
      expect(rig.repo.calls.where((c) => c.startsWith('open')), hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Restore unsaved changes?'), findsNothing, reason: 'asked once');
    });

    testWidgets('Restore promotes the journal and rebuilds the editor on the restored project', (tester) async {
      final rig = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('recovery-restore')));
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await _settle(tester);
      expect(rig.repo.calls, containsAllInOrder(['open:${rig.id}', 'close:${rig.id}', 'restore:${rig.id}', 'close:${rig.id}', 'open:${rig.id}']));
      expect(rig.repo.calls.where((c) => c.startsWith('open')), hasLength(2));
      expect(rig.editor.state.phase, EditorPhase.ready, reason: 'a new controller opened the restored project');
      expect(find.text('Unsaved changes restored'), findsOneWidget);
      expect(find.text('Restore unsaved changes?'), findsNothing);
    });

    testWidgets('a refused restore says so, reopens the last saved version and offers the journal again', (tester) async {
      final rig = await pump(tester);
      rig.repo.failNext['restore'] = const StoreFailure(StoreFailureKind.io);
      await tester.tap(find.byKey(const ValueKey('recovery-restore')));
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await _settle(tester);
      expect(find.text("Couldn't restore the unsaved changes. The last saved version is unchanged."), findsOneWidget);
      expect(rig.editor.state.phase, EditorPhase.ready);
      expect(rig.repo.calls.where((c) => c.startsWith('open')), hasLength(2));
    });

    testSurfaces('the dialog has no overflow', (tester, surface) async {
      await pump(tester, surface: surface);
      expect(find.text('Restore unsaved changes?'), findsOneWidget);
      expectNoOverflow(tester);
      // Button labels ellipsize in the test font (Ahem); the buttons themselves must be on screen.
      expectInside(tester, find.byKey(const ValueKey('recovery-restore')));
      expectInside(tester, find.byKey(const ValueKey('recovery-open-last-saved')));
    });
  });

  test('RelinkStrings.when reads as a clock time today and a date otherwise', () {
    final now = DateTime(2026, 10, 8, 14);
    expect(RelinkStrings.when(DateTime(2026, 10, 8, 9, 5), now), '09:05');
    expect(RelinkStrings.when(DateTime(2026, 9, 30, 23, 59), now), '30 Sep, 23:59');
  });
}
