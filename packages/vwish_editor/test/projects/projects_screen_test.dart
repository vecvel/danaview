// OWNER: UX-05
//
// The Projects screen (ux.md §5) with the fake repository: every state (loading, error and retry,
// empty, list, no search match, unsupported device), cards (meta line, badges, posters), grid and
// list layouts, open (with the newer-app and damaged dialogs), rename, duplicate, delete with the
// undo window, sort and search, New (UX-06's sheet, then the editor), the recovery banner slot,
// the storage footer, the first-paint perf mark, and the surface matrix.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/strings/projects_strings.dart';
import 'package:vwish_editor/src/debug/perf_hooks.dart';
import 'package:vwish_editor/src/projects/project_card.dart';
import 'package:vwish_editor/src/projects/projects_controller.dart';
import 'package:vwish_editor/src/projects/recovery_banner.dart';
import 'package:vwish_editor/vwish_editor.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'projects_test_support.dart';

class _Nav {
  int back = 0;
  int storage = 0;
  final List<ProjectId> opened = [];
}

EditorTestHarness _harness(ProjectsRepository repo, {EditorPrefs? prefs}) => EditorTestHarness(
      repository: repo,
      prefs: prefs,
      overrides: [projectsClockProvider.overrideWithValue(() => projectsNow)],
    );

Future<_Nav> _pump(
  WidgetTester tester,
  EditorTestHarness h, {
  EditorSurface surface = SurfaceMatrix.phone,
  bool storageLink = false,
}) async {
  final nav = _Nav();
  await h.pumpApp(
    tester,
    ProjectsScreen(
      onBack: () => nav.back++,
      onOpenProject: (id, {initialPlayhead}) => nav.opened.add(id),
      onManageStorage: storageLink ? () => nav.storage++ : null,
    ),
    surface: surface,
  );
  await _settle(tester);
  return nav;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _card(ProjectId id) => find.byKey(ValueKey('project-card-$id'));

Future<void> _openMenu(WidgetTester tester, String name) async {
  final more = find.bySemanticsLabel('Project actions: $name');
  await tester.ensureVisible(more);
  await tester.pump();
  await tester.tap(more);
  await _settle(tester);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text).last;
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

List<String> _cardNames(WidgetTester tester) => [
      for (final card in tester.widgetList<ProjectCard>(find.byType(ProjectCard))) card.summary.name,
    ];

void main() {
  test('edited times read like a person would say them', () {
    final now = DateTime(2026, 10, 8, 14);
    expect(ProjectsStrings.edited(DateTime(2026, 10, 8, 13, 59, 40), now), 'Edited just now');
    expect(ProjectsStrings.edited(DateTime(2026, 10, 8, 13, 15), now), 'Edited 45 min ago');
    expect(ProjectsStrings.edited(DateTime(2026, 10, 8, 9), now), 'Edited 5 h ago');
    expect(ProjectsStrings.edited(DateTime(2026, 10, 7, 23), now), 'Edited yesterday');
    expect(ProjectsStrings.edited(DateTime(2026, 10, 4), now), 'Edited 4 days ago');
    expect(ProjectsStrings.edited(DateTime(2026, 10, 1), now), 'Edited 1 Oct');
    expect(ProjectsStrings.edited(DateTime(2025, 3, 2), now), 'Edited 2 Mar 2025');
    expect(ProjectsStrings.clock(0), '0:00');
    expect(ProjectsStrings.clock(84000000), '1:24');
    expect(ProjectsStrings.clock(3723000000), '1:02:03');
    expect(ProjectsStrings.validateName(' a '), isNull);
    expect(ProjectsStrings.validateName('x' * 80), isNull);
    expect(ProjectsStrings.validateName('x' * 81), isNotNull);
  });

  tearDown(() {
    VwishToast.dismiss();
    EditorFlags.debugEditorOverride = null;
    debugDefaultTargetPlatformOverride = null;
    EditorPerfHooks.enabled = false;
    EditorPerfHooks.clear();
  });

  group('states', () {
    testWidgets('loading shows a spinner until the list arrives', (tester) async {
      final repo = ProjectsRepository()
        ..listingGate = Completer<void>()
        ..add(projectNamed('Late'));
      final h = _harness(repo);
      await _pump(tester, h);
      expect(find.byType(VwishSpinner), findsOneWidget);
      repo.listingGate!.complete();
      await _settle(tester);
      expect(_cardNames(tester), ['Late']);
    });

    testWidgets('empty: explains and offers New project', (tester) async {
      final h = _harness(ProjectsRepository());
      await _pump(tester, h);
      expect(find.byKey(const ValueKey('projects-empty')), findsOneWidget);
      expect(find.text('No projects yet'), findsOneWidget);
      await tester.tap(find.text('New project'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('new-project-sheet')), findsOneWidget);
    });

    testWidgets('error: explains and retries', (tester) async {
      final repo = ProjectsRepository()
        ..failListing = const StoreFailure(StoreFailureKind.io)
        ..add(projectNamed('Back again'));
      final h = _harness(repo);
      await _pump(tester, h);
      expect(find.text("Projects couldn't be loaded"), findsOneWidget);
      expect(find.byKey(const ValueKey('projects-new')), findsNothing);
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(_cardNames(tester), ['Back again']);
    });

    for (final (reason, copy) in [
      (UnsupportedReasons.androidTooOld, 'Video editing needs Android 10 or later.'),
      (UnsupportedReasons.gles3Missing, "This device's graphics can't run the video editor."),
      (UnsupportedReasons.insufficientMemory, 'at least 2 GB of memory'),
      (UnsupportedReasons.engineNotAvailable, "This version of Vwish can't edit videos on this device."),
    ]) {
      testWidgets('unsupported device ($reason): explains, hides New, and Back leaves', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        EditorFlags.debugEditorOverride = true;
        final repo = ProjectsRepository()..add(projectNamed('Hidden'));
        final h = _harness(repo);
        h.engine.caps = EditorCapabilities.unsupported(reason);
        final nav = await _pump(tester, h);
        expect(find.byKey(const ValueKey('projects-unsupported')), findsOneWidget);
        expect(find.text("Video editing isn't available on this device"), findsOneWidget);
        expect(find.textContaining(copy), findsOneWidget);
        expect(find.byKey(const ValueKey('projects-new')), findsNothing);
        expect(find.byType(ProjectCard), findsNothing);
        await tester.tap(find.text('Back'));
        expect(nav.back, 1);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });

  group('cards', () {
    testWidgets('show name, duration, aspect, edited time and badges', (tester) async {
      final repo = ProjectsRepository();
      final trip = repo.add(
        projectNamed('Goa trip', aspect: AspectRatio.portrait9x16),
        const SummaryExtras(missing: 2, recovery: true, duration: 84000000),
      );
      repo
        ..add(projectNamed('Newer', updatedAt: DateTime.utc(2026, 10, 7, 9)), const SummaryExtras(health: ProjectHealth.needsNewerApp))
        ..add(projectNamed('Readonly', updatedAt: DateTime.utc(2026, 10, 1)), const SummaryExtras(health: ProjectHealth.readOnlyNewer))
        ..add(projectNamed('Broken', updatedAt: DateTime.utc(2025, 3, 2)), const SummaryExtras(health: ProjectHealth.corrupt));
      final h = _harness(repo);
      await _pump(tester, h, surface: const EditorSurface(Size(1280, 800)));
      expect(find.text('1:24 · 9:16 · ${ProjectsStrings.edited(DateTime.utc(2026, 10, 8, 12), projectsNow)}'), findsOneWidget);
      expect(find.text('2 missing'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.text('Needs update'), findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.text('Damaged'), findsOneWidget);
      for (final at in [DateTime.utc(2026, 10, 7, 9), DateTime.utc(2026, 10, 1), DateTime.utc(2025, 3, 2)]) {
        expect(find.textContaining(ProjectsStrings.edited(at, projectsNow)), findsOneWidget);
      }
      final semantics = tester.getSemantics(_card(trip));
      expect(semantics.label, contains('Goa trip'));
      expect(semantics.label, contains('2 missing'));
      expect(find.text('4 projects'), findsOneWidget);
    });

    testWidgets('a poster that cannot be read falls back to the placeholder', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Poster'), const SummaryExtras(thumbnailPath: '/no/such/poster.jpg'));
      final h = _harness(repo);
      await _pump(tester, h);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await _settle(tester);
      expect(find.byIcon(Icons.movie_edit), findsWidgets);
      expectNoOverflow(tester);
    });

    for (final (width, columns, layout) in [
      (280.0, 1, ProjectCardLayout.row),
      (360.0, 2, ProjectCardLayout.grid),
      (834.0, 4, ProjectCardLayout.grid),
      (1280.0, 6, ProjectCardLayout.grid),
    ]) {
      testWidgets('$width px: $columns column(s) of ${layout.name} cards', (tester) async {
        expect(projectsColumns(width), columns);
        final repo = ProjectsRepository();
        for (var i = 0; i < 7; i++) {
          repo.add(projectNamed('P$i', updatedAt: DateTime.utc(2026, 10, 1 + i)));
        }
        final h = _harness(repo);
        await _pump(tester, h, surface: EditorSurface(Size(width, 900)));
        final cards = tester.widgetList<ProjectCard>(find.byType(ProjectCard)).toList();
        expect(cards.first.layout, layout);
        final tops = {for (final c in find.byType(ProjectCard).evaluate().take(columns)) tester.getTopLeft(find.byWidget(c.widget)).dy};
        expect(tops, hasLength(1), reason: 'the first $columns cards share a row');
        expectNoOverflow(tester);
      });
    }
  });

  group('actions', () {
    testWidgets('tapping a card opens it; a newer-app or damaged project explains instead', (tester) async {
      final repo = ProjectsRepository();
      final ok = repo.add(projectNamed('Fine', updatedAt: DateTime.utc(2026, 10, 8)));
      final ro = repo.add(
          projectNamed('Readonly', updatedAt: DateTime.utc(2026, 10, 7)), const SummaryExtras(health: ProjectHealth.readOnlyNewer));
      final newer =
          repo.add(projectNamed('Newer', updatedAt: DateTime.utc(2026, 10, 6)), const SummaryExtras(health: ProjectHealth.needsNewerApp));
      final broken =
          repo.add(projectNamed('Broken', updatedAt: DateTime.utc(2026, 10, 5)), const SummaryExtras(health: ProjectHealth.corrupt));
      final h = _harness(repo);
      final nav = await _pump(tester, h, surface: const EditorSurface(Size(1280, 800)));
      await tester.tap(_card(ok));
      await tester.tap(_card(ro));
      await tester.pump();
      expect(nav.opened, [ok, ro]);

      await tester.tap(_card(newer));
      await _settle(tester);
      expect(find.text('Update Vwish to open this project'), findsOneWidget);
      await _tapText(tester, 'OK');
      await tester.tap(_card(broken));
      await _settle(tester);
      expect(find.text("This project can't be opened"), findsOneWidget);
      await _tapText(tester, 'OK');
      expect(nav.opened, [ok, ro]);
    });

    testWidgets('rename: a sheet with the current name, validation, then the new name', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Trip'));
      final h = _harness(repo);
      await _pump(tester, h);
      await _openMenu(tester, 'Trip');
      await _tapText(tester, 'Rename');
      expect(find.text('Rename project'), findsOneWidget);
      expect(tester.widget<VwishTextField>(find.byKey(const ValueKey('rename-project-field'))).controller!.text, 'Trip');
      await tester.enterText(find.byKey(const ValueKey('rename-project-field')), '   ');
      await tester.tap(find.byKey(const ValueKey('rename-project-save')));
      await _settle(tester);
      expect(find.text('Enter a name.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('rename-project-field')), 'x' * 81);
      await tester.tap(find.byKey(const ValueKey('rename-project-save')));
      await _settle(tester);
      expect(find.text('Use 80 characters or fewer.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('rename-project-field')), ' Goa ');
      await tester.tap(find.byKey(const ValueKey('rename-project-save')));
      await _settle(tester);
      expect(repo.projects[id]!.name, 'Goa');
      expect(find.text('Renamed to "Goa"'), findsOneWidget);
      expect(_cardNames(tester), ['Goa']);
    });

    testWidgets('a rename of an open project explains what to do', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Open'));
      final h = _harness(repo);
      await _pump(tester, h);
      repo.failNext['rename'] = const StoreFailure(StoreFailureKind.busy);
      await _openMenu(tester, 'Open');
      await _tapText(tester, 'Rename');
      await tester.enterText(find.byKey(const ValueKey('rename-project-field')), 'Other');
      await tester.tap(find.byKey(const ValueKey('rename-project-save')));
      await _settle(tester);
      expect(find.text('Couldn\'t rename "Open". Close it in the editor, then try again.'), findsOneWidget);
    });

    testWidgets('duplicate adds "<name> copy" and says so', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Reel'));
      final h = _harness(repo);
      await _pump(tester, h);
      await _openMenu(tester, 'Reel');
      await _tapText(tester, 'Duplicate');
      expect(find.text('Duplicated as "Reel copy"'), findsOneWidget);
      expect(_cardNames(tester).toSet(), {'Reel', 'Reel copy'});
    });

    testWidgets('rename and duplicate are off for newer or damaged projects; delete stays', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Broken'), const SummaryExtras(health: ProjectHealth.corrupt));
      final h = _harness(repo);
      await _pump(tester, h);
      final card = tester.widget<ProjectCard>(find.byType(ProjectCard));
      final items = card.menuEntries.whereType<VwishMenuItem>().toList();
      expect({for (final i in items) i.label: i.enabled}, {'Open': true, 'Rename': false, 'Duplicate': false, 'Delete': true});
      expect([for (final a in card.semanticActions) a.label], ['Delete']);
    });

    testWidgets('delete: confirm, the card hides with an undo bar, Undo brings it back', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Holiday'));
      final h = _harness(repo);
      await _pump(tester, h);
      await _openMenu(tester, 'Holiday');
      await _tapText(tester, 'Delete');
      expect(find.text('Delete "Holiday"?'), findsOneWidget);
      expect(find.textContaining('Your original videos, photos and music stay where they are.'), findsOneWidget);
      await _tapText(tester, 'Delete');
      expect(_card(id), findsNothing);
      expect(find.text('Deleted "Holiday"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('projects-undo')));
      await _settle(tester);
      expect(_card(id), findsOneWidget);
      expect(find.byKey(const ValueKey('projects-undo-bar')), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(repo.calls, isNot(contains('delete:$id')));
    });

    testWidgets('delete happens when the undo window ends', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Old'));
      repo.add(projectNamed('Keep', updatedAt: DateTime.utc(2026, 10, 1)));
      final h = _harness(repo);
      await _pump(tester, h);
      await _openMenu(tester, 'Old');
      await _tapText(tester, 'Delete');
      await _tapText(tester, 'Delete');
      await tester.pump(const Duration(seconds: 4));
      expect(repo.calls, isNot(contains('delete:$id')));
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(repo.calls, contains('delete:$id'));
      expect(find.byKey(const ValueKey('projects-undo-bar')), findsNothing);
      expect(_cardNames(tester), ['Keep']);
    });

    testWidgets('cancelling the confirmation deletes nothing', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Safe'));
      final h = _harness(repo);
      await _pump(tester, h);
      await _openMenu(tester, 'Safe');
      await _tapText(tester, 'Delete');
      await _tapText(tester, 'Cancel');
      expect(_card(id), findsOneWidget);
      expect(find.byKey(const ValueKey('projects-undo-bar')), findsNothing);
    });

    testWidgets('a deferred delete that fails brings the card back and says why', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Busy'));
      final h = _harness(repo);
      await _pump(tester, h);
      repo.failNext['delete'] = const StoreFailure(StoreFailureKind.busy);
      await _openMenu(tester, 'Busy');
      await _tapText(tester, 'Delete');
      await _tapText(tester, 'Delete');
      await tester.pump(projectUndoWindow + const Duration(milliseconds: 10));
      await _settle(tester);
      expect(_card(id), findsOneWidget);
      expect(find.text('Couldn\'t delete "Busy". Close it in the editor, then try again.'), findsOneWidget);
    });

    testWidgets('long-press opens the same menu', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Pressed'));
      final h = _harness(repo);
      await _pump(tester, h);
      await tester.longPress(_card(id));
      await _settle(tester);
      expect(find.text('Duplicate'), findsOneWidget);
    });

    testWidgets('semantics actions rename, duplicate and delete', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Spoken'));
      final h = _harness(repo);
      await _pump(tester, h);
      final card = tester.widget<ProjectCard>(find.byType(ProjectCard));
      expect([for (final a in card.semanticActions) a.label], ['Rename', 'Duplicate', 'Delete']);
      card.semanticActions[1].onInvoke();
      await _settle(tester);
      expect(_cardNames(tester).toSet(), {'Spoken', 'Spoken copy'});
    });
  });

  group('sort, search and New', () {
    testWidgets('sort by name is remembered', (tester) async {
      final prefs = EditorPrefs.memory();
      final repo = ProjectsRepository()
        ..add(projectNamed('Bravo', updatedAt: DateTime.utc(2026, 10, 3)))
        ..add(projectNamed('alpha', updatedAt: DateTime.utc(2026, 10, 1)))
        ..add(projectNamed('Charlie', updatedAt: DateTime.utc(2026, 10, 2)));
      final h = _harness(repo, prefs: prefs);
      await _pump(tester, h);
      expect(_cardNames(tester), ['Bravo', 'Charlie', 'alpha']);
      await tester.tap(find.byKey(const ValueKey('projects-sort')));
      await _settle(tester);
      await _tapText(tester, 'Name');
      expect(_cardNames(tester), ['alpha', 'Bravo', 'Charlie']);
      expect(prefs.projectsSort, ProjectSortPreference.name);
    });

    testWidgets('search appears above 8 projects, filters, and says when nothing matches', (tester) async {
      final repo = ProjectsRepository();
      for (var i = 1; i <= 9; i++) {
        repo.add(projectNamed(i == 5 ? 'Goa trip' : 'Clip $i', updatedAt: DateTime.utc(2026, 9, i)));
      }
      final h = _harness(repo);
      await _pump(tester, h);
      final search = find.byKey(const ValueKey('projects-search'));
      expect(search, findsOneWidget);
      await tester.enterText(find.descendant(of: search, matching: find.byType(EditableText)), 'GOA');
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
      expect(_cardNames(tester), ['Goa trip']);
      await tester.enterText(find.descendant(of: search, matching: find.byType(EditableText)), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
      expect(find.byKey(const ValueKey('projects-no-match')), findsOneWidget);
      expect(find.text('No projects match "zzz"'), findsOneWidget);
    });

    testWidgets('no search with 8 projects or fewer', (tester) async {
      final repo = ProjectsRepository();
      for (var i = 1; i <= 8; i++) {
        repo.add(projectNamed('Clip $i', updatedAt: DateTime.utc(2026, 9, i)));
      }
      await _pump(tester, _harness(repo));
      expect(find.byKey(const ValueKey('projects-search')), findsNothing);
    });

    testWidgets('New opens the New project sheet and then the created project', (tester) async {
      final repo = ProjectsRepository()..add(projectNamed('Existing'));
      final h = _harness(repo);
      final nav = await _pump(tester, h);
      await tester.tap(find.byKey(const ValueKey('projects-new')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('new-project-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new-project-start-empty')));
      await _settle(tester);
      final created = repo.projects.keys.where((k) => k != ProjectId('pr_existing')).single;
      expect(nav.opened, [created]);
    });

    testWidgets('back goes through the router callback', (tester) async {
      final nav = await _pump(tester, _harness(ProjectsRepository()..add(projectNamed('A'))));
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      expect(nav.back, 1);
    });
  });

  group('recovery, footer and perf', () {
    testWidgets('the recovery banner slot appears when a project closed unexpectedly', (tester) async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Crashed'));
      await _pump(tester, _harness(repo));
      expect(find.byType(RecoveryBanner), findsNothing);
      repo.recoverableSessions.add(RecoverableSession(
        projectId: id,
        projectName: 'Crashed',
        journalRevision: 2,
        mainRevision: 1,
        journalSavedAt: DateTime.utc(2026, 10, 8),
      ));
      await _pump(tester, _harness(repo));
      expect(find.byType(RecoveryBanner), findsOneWidget);
    });

    testWidgets('the footer shows what projects use and links to Storage', (tester) async {
      final repo = ProjectsRepository()
        ..add(projectNamed('A'), const SummaryExtras(bytes: 1000000000))
        ..add(projectNamed('B'), const SummaryExtras(bytes: 400000000));
      final nav = await _pump(tester, _harness(repo), storageLink: true);
      final footer = find.byKey(const ValueKey('projects-footer'));
      await tester.ensureVisible(footer);
      expect(find.text('Projects use 1.4 GB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('projects-manage-storage')));
      expect(nav.storage, 1);
    });

    testWidgets('first paint is measured once (QA-04)', (tester) async {
      EditorPerfHooks.clear();
      EditorPerfHooks.enabled = true;
      final repo = ProjectsRepository()
        ..add(projectNamed('A'))
        ..add(projectNamed('B', updatedAt: DateTime.utc(2026, 10, 2)));
      await _pump(tester, _harness(repo));
      final samples = EditorPerfHooks.samplesOf(EditorPerfMarks.projectsFirstPaint);
      expect(samples, hasLength(1));
      expect(samples.single.args, {'projects': 2});
    });
  });

  group('no overflow', () {
    ProjectsRepository busyRepo() {
      final repo = ProjectsRepository();
      final long = 'A family holiday edit with an extremely long project name that never seems to end';
      repo.add(
        projectNamed(long, aspect: AspectRatio.portrait9x16),
        const SummaryExtras(missing: 12, recovery: true, duration: 3723000000, bytes: 987654321),
      );
      for (var i = 0; i < 10; i++) {
        repo.add(
          projectNamed('Project $i ${'with words ' * (i % 3)}',
              updatedAt: DateTime.utc(2026, 9, 1 + i), aspect: AspectRatio.standard[i % 6]),
          SummaryExtras(health: ProjectHealth.values[i % 4], missing: i % 2, bytes: 1000 * i),
        );
      }
      return repo;
    }

    Future<void> scrollThrough(WidgetTester tester) async {
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 30; i++) {
        final position = tester.state<ScrollableState>(scrollable).position;
        if (position.pixels >= position.maxScrollExtent) break;
        await tester.drag(scrollable, const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 50));
        expectNoOverflow(tester);
      }
    }

    testSurfaces('the list with long names, every badge and the footer', (tester, surface) async {
      final h = _harness(busyRepo());
      await _pump(tester, h, surface: surface, storageLink: true);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expectInside(tester, find.byKey(const ValueKey('projects-new')));
      await scrollThrough(tester);
      expectOwnerUiRules(tester);
    });

    testSurfaces('the undo bar', (tester, surface) async {
      final repo = busyRepo();
      final h = _harness(repo);
      await _pump(tester, h, surface: surface);
      final first = tester.widgetList<ProjectCard>(find.byType(ProjectCard)).first.summary;
      h.containerOf(tester).read(projectsControllerProvider.notifier).requestDelete(first.id);
      await _settle(tester);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expectInside(tester, find.byKey(const ValueKey('projects-undo')));
    });

    testSurfaces('the empty state', (tester, surface) async {
      await _pump(tester, _harness(ProjectsRepository()), surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testSurfaces('the unsupported state', (tester, surface) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      EditorFlags.debugEditorOverride = true;
      final h = _harness(ProjectsRepository());
      h.engine.caps = EditorCapabilities.unsupported(UnsupportedReasons.insufficientMemory);
      await _pump(tester, h, surface: surface);
      expect(find.byKey(const ValueKey('projects-unsupported')), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testSurfaces('the rename sheet', (tester, surface) async {
      final repo = ProjectsRepository()..add(projectNamed('Rename me ${'long ' * 12}'));
      await _pump(tester, _harness(repo), surface: surface);
      final card = tester.widget<ProjectCard>(find.byType(ProjectCard));
      await _openMenu(tester, card.summary.name);
      await _tapText(tester, 'Rename');
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('rename-project-save')));
      await tester.pump();
      expectInside(tester, find.byKey(const ValueKey('rename-project-save')));
    });
  });
}
