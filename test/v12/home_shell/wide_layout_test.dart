// OWNER: HOM-05
//
// Owner UI decisions of 2026-10-23 for the library screens:
// * no max-width cap: content spans the width minus the 16 / 24 / 32 pt side margins;
// * wide screens wrap library rows into card grids (~280 pt columns, 12 pt gaps, equal heights per
//   row); phones keep the list rows;
// * the tab strip has no fixed height: the pills fit their label, every tab keeps an invisible
//   44 pt minimum target, and the strip grows with the text scale instead of clipping.

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/home/home_tab_strip.dart';
import 'package:danaview_features/src/library/library_widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'home_shell_support.dart';

Widget _home() => DanaviewHomeScreen(
      onOpenPlayer: () {},
      onOpenFolder: (_) {},
      onOpenPlaylist: (_) {},
      onOpenSettings: () {},
    );

Future<LibraryTestEnv> _pump(WidgetTester tester, Size size, {double textScale = 1.0, bool filesHome = true}) async {
  useFilesHome(filesHome);
  useSurface(tester, TestSurface(size, textScale));
  final env = await LibraryTestEnv.create();
  await seedFixedLibrary(env);
  await tester.pumpWidget(libraryTestApp(env, _home(), textScale: textScale));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

final _grids = find.byKey(const ValueKey('library-card-grid'));

/// The cards of the first row of the first grid (Continue watching).
List<Rect> _firstRowCards(WidgetTester tester) {
  final row = find.descendant(of: _grids.first, matching: find.byType(DanaviewLibraryGridRow)).first;
  return [
    for (final e in find.descendant(of: row, matching: find.byType(DanaviewLibraryCard)).evaluate())
      tester.getRect(find.byWidget(e.widget)),
  ];
}

Rect _pill(WidgetTester tester, HomeTab tab) => tester.getRect(
      find.descendant(of: find.byKey(homeTabKey(tab)), matching: find.byType(AnimatedContainer)).first,
    );

void main() {
  group('margins, no max width', () {
    test('16 pt below 600, 24 pt below 1024, 32 pt from 1024; never capped', () {
      expect(danaviewLibraryInsets(375), const EdgeInsets.symmetric(horizontal: 16));
      expect(danaviewLibraryInsets(599), const EdgeInsets.symmetric(horizontal: 16));
      expect(danaviewLibraryInsets(600), const EdgeInsets.symmetric(horizontal: 24));
      expect(danaviewLibraryInsets(1023), const EdgeInsets.symmetric(horizontal: 24));
      expect(danaviewLibraryInsets(1024), const EdgeInsets.symmetric(horizontal: 32));
      expect(danaviewLibraryInsets(2560), const EdgeInsets.symmetric(horizontal: 32));
    });

    for (final filesHome in [false, true]) {
      testWidgets('1280 px (flag ${filesHome ? 'on' : 'off'}): the sections span the width minus 32 pt margins', (tester) async {
        final env = await _pump(tester, const Size(1280, 800), filesHome: filesHome);
        expect(_grids, findsWidgets);
        for (final e in _grids.evaluate()) {
          final rect = tester.getRect(find.byWidget(e.widget));
          expect(rect.left, moreOrLessEquals(32));
          expect(rect.right, moreOrLessEquals(1280 - 32));
        }
        await finishHome(tester, env);
      });
    }
  });

  group('card grids', () {
    test('columns: list below 600 px, then as many ~280 pt columns as fit', () {
      expect(danaviewLibraryGridColumns(375 - 32), 1);
      expect(danaviewLibraryGridColumns(600 - 48), 2);
      expect(danaviewLibraryGridColumns(1024 - 64), 3);
      expect(danaviewLibraryGridColumns(1280 - 64), 4);
    });

    for (final (width, columns) in [(600.0, 2), (1024.0, 3), (1280.0, 4)]) {
      testWidgets('${width.toInt()} px: $columns columns, 12 pt gaps, equal heights per row', (tester) async {
        final env = await _pump(tester, Size(width, 900));
        final cards = _firstRowCards(tester);
        expect(cards, hasLength(columns));
        for (var i = 1; i < cards.length; i++) {
          expect(cards[i].left - cards[i - 1].right, moreOrLessEquals(12));
          expect(cards[i].height, moreOrLessEquals(cards[0].height));
          expect(cards[i].width, moreOrLessEquals(cards[0].width));
        }
        await finishHome(tester, env);
      });
    }

    testWidgets('375 px: list rows in one group, no grid', (tester) async {
      final env = await _pump(tester, const Size(375, 812));
      expect(_grids, findsNothing);
      expect(find.byType(DanaviewLibraryGroup), findsWidgets);
      await finishHome(tester, env);
    });
  });

  group('tab strip', () {
    testWidgets('fits its content: 8 pt above and below, tabs at least 44 pt, pills fit the label', (tester) async {
      final env = await _pump(tester, const Size(402, 874));
      final strip = tester.getRect(find.byKey(const ValueKey('home-tab-strip')));
      final tab = tester.getRect(find.byKey(homeTabKey(HomeTab.home)));
      final pill = _pill(tester, HomeTab.home);
      expect(tab.height, greaterThanOrEqualTo(44));
      expect(strip.height, moreOrLessEquals(tab.height + 2 * HomeTabStrip.verticalPadding));
      expect(pill.height, lessThan(44), reason: 'the 44 pt minimum is an invisible hit area');
      await finishHome(tester, env);
    });

    for (final scale in [1.35, 2.0]) {
      testWidgets('grows at text scale $scale instead of clipping the pills', (tester) async {
        var env = await _pump(tester, const Size(402, 874));
        final pillAt1 = _pill(tester, HomeTab.home).height;
        final stripAt1 = tester.getRect(find.byKey(const ValueKey('home-tab-strip'))).height;
        await finishHome(tester, env);
        env = await _pump(tester, const Size(402, 874), textScale: scale);
        final strip = tester.getRect(find.byKey(const ValueKey('home-tab-strip')));
        final pill = _pill(tester, HomeTab.home);
        expect(pill.height, greaterThan(pillAt1));
        expect(pill.top, greaterThanOrEqualTo(strip.top + HomeTabStrip.verticalPadding - 0.01));
        expect(pill.bottom, lessThanOrEqualTo(strip.bottom - HomeTabStrip.verticalPadding + 0.01));
        expect(tester.getRect(find.byKey(homeTabKey(HomeTab.home))).height, greaterThanOrEqualTo(44));
        if (pill.height > 44) expect(strip.height, greaterThan(stripAt1));
        await finishHome(tester, env);
      });
    }
  });

  testWidgets('no overflow across the 280–1280 px × 0.85–1.35 matrix on Home', (tester) async {
    for (final surface in homeShellSurfaces) {
      final env = await _pump(tester, surface.size, textScale: surface.textScale);
      expect(tester.takeException(), isNull, reason: '$surface');
      await finishHome(tester, env);
    }
  });
}
