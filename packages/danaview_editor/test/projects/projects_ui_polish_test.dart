// OWNER: UX-05
//
// Owner UI polish of the Projects screen: the recovery box has no warning outline (same dark card
// surface and hairline as the project cards), several recoverable projects are a wrapping grid of
// equal-height cards with "Show all (N)" past four, and the search field sits left with the Sort
// control right next to it (an icon button below 480 px). Plus the surface matrix.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/projects/project_card.dart';
import 'package:danaview_editor/src/projects/projects_controller.dart';
import 'package:danaview_editor/src/projects/recovery_banner.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import 'projects_test_support.dart';

const EditorSurface _ipad = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

EditorTestHarness _harness(ProjectsRepository repo) =>
    EditorTestHarness(repository: repo, overrides: [projectsClockProvider.overrideWithValue(() => projectsNow)]);

List<ProjectId> _addRecoverable(ProjectsRepository repo, List<String> names) => [
      for (final (i, name) in names.indexed)
        () {
          final id = repo.add(projectNamed(name));
          repo.recoverableSessions.add(RecoverableSession(
            projectId: id,
            projectName: name,
            journalRevision: 3,
            mainRevision: 2,
            journalSavedAt: DateTime.utc(2026, 10, 8, 12, 30 - i),
          ));
          return id;
        }(),
    ];

Future<List<ProjectId>> _pumpBanner(WidgetTester tester, List<String> names, {EditorSurface surface = _ipad}) async {
  final repo = ProjectsRepository();
  final ids = _addRecoverable(repo, names);
  await _harness(repo).pumpApp(tester, Scaffold(body: SingleChildScrollView(child: RecoveryBanner())), surface: surface);
  await _settle(tester);
  return ids;
}

Future<void> _pumpProjects(WidgetTester tester, {required int count, EditorSurface surface = _ipad}) async {
  final repo = ProjectsRepository();
  for (var i = 1; i <= count; i++) {
    repo.add(projectNamed('Clip $i', updatedAt: DateTime.utc(2026, 9, i)));
  }
  await _harness(repo).pumpApp(
    tester,
    ProjectsScreen(onBack: () {}, onOpenProject: (_, {initialPlayhead}) {}),
    surface: surface,
  );
  await _settle(tester);
}

List<Rect> _cardRects(WidgetTester tester, List<ProjectId> ids) => [
      for (final id in ids)
        if (find.byKey(ValueKey('recovery-${id.value}')).evaluate().isNotEmpty) tester.getRect(find.byKey(ValueKey('recovery-${id.value}'))),
    ];

void _expectGridClean(List<Rect> rects) {
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      expect(rects[i].intersect(rects[j]).isEmpty || rects[i].intersect(rects[j]).width <= 0 || rects[i].intersect(rects[j]).height <= 0, isTrue,
          reason: 'cards $i and $j overlap: ${rects[i]} / ${rects[j]}');
      if ((rects[i].top - rects[j].top).abs() < 0.5) {
        expect(rects[i].height, moreOrLessEquals(rects[j].height, epsilon: 0.5), reason: 'cards in one row have equal heights');
      }
    }
  }
}

const List<String> _six = ['Goa trip', 'Birthday', 'A long wedding highlight reel name that wraps', 'Fourth', 'Fifth', 'Sixth'];

void main() {
  group('recoveryColumns', () {
    test('fits as many ~280 px cards as the width allows, with 12 px gaps', () {
      expect(recoveryColumns(200), 1);
      expect(recoveryColumns(280), 1);
      expect(recoveryColumns(571), 1);
      expect(recoveryColumns(572), 2);
      expect(recoveryColumns(864), 3);
      expect(recoveryColumns(1146), 3);
      expect(recoveryColumns(1156), 4);
      expect(recoveryColumns(double.infinity), 1);
    });
  });

  group('recovery box', () {
    testWidgets('no warning outline: the project-card surface and hairline; the clock tile keeps the warning colour', (tester) async {
      await _pumpBanner(tester, _six.take(2).toList());
      final surface = tester.widget<DanaviewSurface>(find.byKey(const ValueKey('recovery-banner')));
      expect(surface.borderColor, DanaviewColors.hairline);
      expect(surface.color, DanaviewColors.surface);
      final tile = tester.widget<DanaviewTileIcon>(find.byType(DanaviewTileIcon));
      expect(tile.color, DanaviewColors.warning);
      for (final s in tester.widgetList<DanaviewSurface>(find.byType(DanaviewSurface))) {
        expect(s.borderColor.a, lessThan(0.2), reason: 'only near-transparent borders');
      }
      expectOwnerUiRules(tester);
    });

    testWidgets('several projects lay out side by side on a wide screen, equal heights, 12 px gaps', (tester) async {
      final ids = await _pumpBanner(tester, _six.take(3).toList());
      final rects = _cardRects(tester, ids);
      expect(rects, hasLength(3));
      expect(rects[0].top, moreOrLessEquals(rects[1].top), reason: 'same row');
      expect(rects[1].left - rects[0].right, moreOrLessEquals(DanaviewSpacing.md));
      expect(rects[0].width, greaterThanOrEqualTo(recoveryCardMinWidth));
      _expectGridClean(rects);
      expect(find.textContaining('Changes from '), findsNWidgets(3));
      expect(find.byKey(const ValueKey('recovery-show-all')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('more than four: the first four and "Show all (N)" expands and collapses', (tester) async {
      final ids = await _pumpBanner(tester, _six);
      expect(_cardRects(tester, ids), hasLength(4));
      expect(find.text('Show all (6)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recovery-show-all')));
      await _settle(tester);
      expect(_cardRects(tester, ids), hasLength(6));
      _expectGridClean(_cardRects(tester, ids));
      expect(find.text('Show fewer'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recovery-show-all')));
      await _settle(tester);
      expect(_cardRects(tester, ids), hasLength(4));
      expectNoOverflow(tester);
    });

    testWidgets('one project keeps the compact message and buttons (no inner card)', (tester) async {
      await _pumpBanner(tester, ['Goa trip']);
      expect(find.text('Unsaved changes found'), findsOneWidget);
      expect(find.byKey(const ValueKey('recovery-grid')), findsNothing);
      expect(find.text('Restore'), findsOneWidget);
    });

    testSurfaces('grid wraps without overlap or overflow, collapsed and expanded', (tester, surface) async {
      final ids = await _pumpBanner(tester, _six, surface: surface);
      for (final expanded in [false, true]) {
        if (expanded) {
          await tester.ensureVisible(find.byKey(const ValueKey('recovery-show-all')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('recovery-show-all')));
          await _settle(tester);
        }
        expectNoOverflow(tester);
        final rects = _cardRects(tester, ids);
        expect(rects, hasLength(expanded ? 6 : 4));
        _expectGridClean(rects);
        for (final r in rects) {
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(surface.size.width));
        }
        expect(fitsFullyProblems(tester, find.byKey(const ValueKey('recovery-banner'))).where((p) => p.contains('truncated')), isEmpty);
      }
      expectOwnerUiRules(tester);
    });
  });

  group('search and sort row', () {
    testWidgets('wide: search first (capped at 480 px) and Sort 12 px right of it, left-aligned', (tester) async {
      await _pumpProjects(tester, count: 9);
      final search = tester.getRect(find.byKey(const ValueKey('projects-search')));
      final sort = tester.getRect(find.byKey(const ValueKey('projects-sort')));
      final firstCard = tester.getRect(find.byType(ProjectCard).first);
      expect(search.left, moreOrLessEquals(firstCard.left), reason: 'search starts at the content edge');
      expect(search.width, lessThanOrEqualTo(projectsSearchMaxWidth));
      expect(search.width, greaterThan(projectsSearchMaxWidth - 1));
      expect(sort.left - search.right, moreOrLessEquals(DanaviewSpacing.md));
      expect(sort.center.dy, moreOrLessEquals(search.center.dy, epsilon: 1));
    });

    testWidgets('narrow: search fills and Sort is a 44 px icon button with the same menu', (tester) async {
      await _pumpProjects(tester, count: 9, surface: const EditorSurface(Size(390, 844)));
      expect(find.byKey(const ValueKey('projects-toolbar-compact')), findsOneWidget);
      final sort = find.byKey(const ValueKey('projects-sort'));
      expect(tester.getSize(sort), const Size(44, 44));
      expect(find.bySemanticsLabel('Sort: Recent'), findsOneWidget);
      final search = tester.getRect(find.byKey(const ValueKey('projects-search')));
      expect(tester.getRect(sort).left - search.right, moreOrLessEquals(DanaviewSpacing.md));
      await tester.tap(sort);
      await _settle(tester);
      await tester.tap(find.text('Name').last);
      await _settle(tester);
      final names = [for (final c in tester.widgetList<ProjectCard>(find.byType(ProjectCard))) c.summary.name];
      expect(names.take(3), ['Clip 1', 'Clip 2', 'Clip 3']);
      expect(find.bySemanticsLabel('Sort: Name'), findsOneWidget);
    });

    test('the compact breakpoint is 480 px', () => expect(projectsToolbarCompactWidth, 480));

    testSurfaces('toolbar row never overflows', (tester, surface) async {
      await _pumpProjects(tester, count: 9, surface: surface);
      expectNoOverflow(tester);
      final sort = tester.getRect(find.byKey(const ValueKey('projects-sort')));
      final search = tester.getRect(find.byKey(const ValueKey('projects-search')));
      expect(sort.right, lessThanOrEqualTo(surface.size.width));
      expect(sort.left, greaterThan(search.right));
      expect(sort.height, greaterThanOrEqualTo(40));
      expectOwnerUiRules(tester);
    });
  });
}
