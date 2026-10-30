// OWNER: HOM-05
//
// Owner UI decisions of 2026-10-23 for the library screens:
// * no max-width cap: content spans the width minus the 16 / 24 / 32 pt side margins;
// * wide screens wrap library rows into card grids (~280 pt columns, 12 pt gaps, equal heights per
//   row); phones keep the list rows;
// * the Cinema B Home (DESIGN_SYSTEM §10.3): two columns (media ≈ 60 %, lists ≈ 40 %) from 1100 pt,
//   the grouped lists 2-up on tablets in portrait, one column on phones; Continue watching is a row
//   of equal-height media cards; with the Files Home the lists are Documents and Folders, and the
//   playlist cards live on the Playlists screen (DESIGN_SYSTEM §10.4);
// * the tab strip has no fixed height: the pills fit their label, every tab keeps an invisible
//   44 pt minimum target, and the strip grows with the text scale instead of clipping.

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/home/home_tab_strip.dart';
import 'package:danaview_features/src/library/library_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'home_shell_support.dart';

Widget _home({HomeTabSlots slots = HomeTabSlots.none}) => DanaviewHomeScreen(
      onOpenPlayer: () {},
      onOpenFolder: (_) {},
      onOpenPlaylist: (_) {},
      onOpenSettings: () {},
      tabSlots: slots,
    );

Future<LibraryTestEnv> _pump(
  WidgetTester tester,
  Size size, {
  double textScale = 1.0,
  bool filesHome = true,
  HomeTabSlots slots = HomeTabSlots.none,
}) async {
  useFilesHome(filesHome);
  useSurface(tester, TestSurface(size, textScale));
  final env = await LibraryTestEnv.create();
  await seedFixedLibrary(env);
  await tester.pumpWidget(libraryTestApp(env, _home(slots: slots), textScale: textScale));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

final _grids = find.byKey(const ValueKey('library-card-grid'));

Future<void> _openTab(WidgetTester tester, HomeTab tab) async {
  await tester.ensureVisible(find.byKey(homeTabKey(tab)));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(homeTabKey(tab)));
  await pumpFrames(tester);
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
        final columns = find.byKey(const ValueKey('home-two-columns'));
        expect(columns, findsOneWidget);
        final rect = tester.getRect(columns);
        expect(rect.left, moreOrLessEquals(32));
        expect(rect.right, moreOrLessEquals(1280 - 32));
        // Media on the left (≈ 60 %), the grouped lists on the right (≈ 40 %).
        final media = tester.getRect(find.byKey(const ValueKey('home-continue-watching')));
        // The lists column: Playlists and Folders on the 1.1 Home, Documents and Folders on the
        // Files Home's `Home` tab (no documents here, so Folders alone).
        final lists = tester.getRect(find.byKey(ValueKey(filesHome ? 'home-folders' : 'home-playlists')));
        expect(media.left, moreOrLessEquals(32));
        expect(lists.right, moreOrLessEquals(1280 - 32));
        expect(media.width / (media.width + lists.width), closeTo(0.6, 0.01));
        expect(media.right, lessThan(lists.left));
        await finishHome(tester, env);
      });
    }

    for (final filesHome in [false, true]) {
      testWidgets('768 px portrait (flag ${filesHome ? 'on' : 'off'}): one column with the grouped lists 2-up',
          (tester) async {
        final env = await _pump(
          tester,
          const Size(768, 1024),
          filesHome: filesHome,
          // The Files Home pairs Documents with Folders.
          slots: HomeTabSlots(documentsOverview: (_) => const SizedBox(key: ValueKey('documents-probe'), height: 120)),
        );
        expect(find.byKey(const ValueKey('home-two-columns')), findsNothing);
        final media = tester.getRect(find.byKey(const ValueKey('home-continue-watching')));
        final first = tester.getRect(find.byKey(ValueKey(filesHome ? 'home-slot-documents' : 'home-playlists')));
        final folders = tester.getRect(find.byKey(const ValueKey('home-folders')));
        expect(media.left, moreOrLessEquals(24));
        expect(media.right, moreOrLessEquals(768 - 24));
        expect(first.top, moreOrLessEquals(folders.top));
        expect(first.left, moreOrLessEquals(24));
        expect(folders.right, moreOrLessEquals(768 - 24));
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

    // The Playlists screen (DESIGN_SYSTEM §10.4), opened by the Videos tab's See all: playlist
    // cards in the adaptive 2 / 4 / 6 column grid, 10 pt gaps, every card of a row the same height.
    for (final (width, columns) in [(375.0, 2), (600.0, 2), (820.0, 4), (1024.0, 6), (1280.0, 6)]) {
      testWidgets('${width.toInt()} px Playlists screen: $columns columns, 10 pt gaps, equal heights per row',
          (tester) async {
        final env = await _pump(tester, Size(width, 900));
        await _openTab(tester, HomeTab.videos);
        await tester.tap(find.byKey(const ValueKey('home-playlists-see-all')));
        await pumpFrames(tester, count: 8);
        expect(find.byKey(homeDestinationScreenKey(HomeDestination.playlists)), findsOneWidget);
        final gutter = danaviewLibraryInsets(width).left;
        final grid = tester.getRect(find.byKey(const ValueKey('home-playlists-grid')));
        expect(grid.left, moreOrLessEquals(gutter));
        expect(grid.right, moreOrLessEquals(width - gutter));
        expect(homePlaylistColumns(grid.width), columns);
        final cards = [for (final e in find.byType(HomePlaylistCard).evaluate()) tester.getRect(find.byWidget(e.widget))]
          ..sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));
        final firstRow = cards.where((c) => c.top == cards.first.top).toList();
        // Three playlists: a row holds min(columns, 3) cards at the column width.
        expect(firstRow, hasLength(columns < 3 ? columns : 3));
        final cell = (grid.width - 10 * (columns - 1)) / columns;
        for (var i = 0; i < firstRow.length; i++) {
          expect(firstRow[i].width, moreOrLessEquals(cell));
          if (i == 0) continue;
          expect(firstRow[i].left - firstRow[i - 1].right, moreOrLessEquals(10));
          expect(firstRow[i].height, moreOrLessEquals(firstRow[0].height));
        }
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });
    }

    for (final width in [375.0, 1280.0]) {
      testWidgets('${width.toInt()} px: Continue watching cards share one height, 10 pt gaps', (tester) async {
        final env = await _pump(tester, Size(width, 900));
        final cards = [
          for (final e in find.byType(HomeMediaCard).evaluate()) tester.getRect(find.byWidget(e.widget)),
        ];
        expect(cards.length, greaterThan(1));
        for (var i = 1; i < cards.length; i++) {
          expect(cards[i].height, moreOrLessEquals(cards[0].height));
          expect(cards[i].left - cards[i - 1].right, moreOrLessEquals(10));
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
