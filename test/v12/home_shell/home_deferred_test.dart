// The deferred items of the Home redesign (DESIGN_SYSTEM §10):
// * the collapsing large title (§10.1): the "Danaview" title shrinks into the inline title as the
//   content scrolls, iOS style; the bar and the search row stay pinned; Reduce Motion shows only
//   the end state; one "Danaview" header for screen readers throughout;
// * the Projects section (§10.3 #3) and the Projects tab (§10.4), editor only;
// * the §10.4 grids' column counts at 320 / 820 / 1280 pt;
// * the empty-state rule: every content type counts, so a library of photos alone isn't "empty".

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/home/home_chrome.dart' show homeInlineTitleSize;
import 'package:danaview_features/src/library/home/recent_photos_tray.dart';
import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_features/src/library/photos/photo_masonry_layout.dart';
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart';
import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_features/src/library/tabs/documents_tab.dart' show documentsTabColumns;
import 'package:danaview_features/src/library/library_widgets.dart' show danaviewLibraryInsets;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../photos_tab/photo_masonry_layout_test.dart' show synthetic;
import 'home_shell_support.dart';

final DateTime _now = DateTime(2026, 10, 29, 12);

List<HomeProject> _projects(int count) => [
      for (var i = 0; i < count; i++)
        HomeProject(id: 'p$i', name: 'Project $i', updatedAt: _now.subtract(Duration(hours: 2 + i * 30))),
    ];

List<Override> _photoOverrides(List<PhotoGridItem> photos) => [
      danaviewPhotoItemsProvider.overrideWithValue(photos),
      systemPhotoLibraryProvider.overrideWithValue(null),
      systemPhotosControllerProvider.overrideWith((ref) => SystemPhotosController(library: null, platform: null)),
      desktopRootResolverProvider.overrideWithValue(null),
    ];

/// The Home with the editor's project slots wired as the app does where the editor runs.
Widget _home({
  HomeCallbacks callbacks = HomeCallbacks.none,
  HomeTabSlots slots = HomeTabSlots.none,
  bool reduceMotion = false,
}) {
  final home = DanaviewHomeScreen(
    onOpenPlayer: () {},
    onOpenFolder: (_) {},
    onOpenPlaylist: (_) {},
    onOpenSettings: () {},
    callbacks: callbacks,
    tabSlots: slots,
  );
  if (!reduceMotion) return home;
  return Builder(
    builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: home),
  );
}

Future<LibraryTestEnv> _pump(
  WidgetTester tester,
  Widget home, {
  required bool filesHome,
  Size size = const Size(402, 600),
  double textScale = 1.0,
  bool seed = true,
  List<Override> overrides = const [],
}) async {
  useFilesHome(filesHome);
  useSurface(tester, TestSurface(size, textScale, padding: const EdgeInsets.only(top: 20)));
  final env = await LibraryTestEnv.create();
  if (seed) await seedFixedLibrary(env);
  await tester.pumpWidget(libraryTestApp(env, home, textScale: textScale, overrides: [..._photoOverrides(const []), ...overrides]));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

HomeTopBar _bar(WidgetTester tester) => tester.widget<HomeTopBar>(find.byKey(const ValueKey('home-top-bar')));

double _titleScale(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(const ValueKey('home-title'))).transform.storage[0];

/// Jumps [scrollable] to [offset] (below the drag slop a finger drag wouldn't scroll at all).
Future<void> _jump(WidgetTester tester, Finder scrollable, double offset) async {
  tester.state<ScrollableState>(scrollable).position.jumpTo(offset);
  await tester.pump();
}

/// The title is one "Danaview" header for screen readers.
void _expectTitleHeader(WidgetTester tester) =>
    expect(tester.getSemantics(find.text('Danaview')), isSemantics(label: 'Danaview', isHeader: true));

Finder _pageScrollable(HomeTab tab) =>
    find.descendant(of: find.byKey(ValueKey('home-tab-page-${tab.name}')), matching: find.byType(Scrollable)).first;

Future<void> _openTab(WidgetTester tester, HomeTab tab) async {
  await tester.ensureVisible(find.byKey(homeTabKey(tab)));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(homeTabKey(tab)));
  await pumpFrames(tester);
}

void main() {
  group('collapsing large title (§10.1)', () {
    test('collapse follows the scroll over 44 pt; Reduce Motion jumps to the end state', () {
      expect(homeTitleCollapseFor(-20), 0);
      expect(homeTitleCollapseFor(0), 0);
      expect(homeTitleCollapseFor(homeTitleCollapseDistance / 2), closeTo(0.5, 1e-9));
      expect(homeTitleCollapseFor(homeTitleCollapseDistance), 1);
      expect(homeTitleCollapseFor(500), 1);
      expect(homeTitleCollapseFor(0, reduceMotion: true), 0);
      expect(homeTitleCollapseFor(1, reduceMotion: true), 1);
      expect(homeTitleCollapseFor(homeTitleCollapseDistance / 2, reduceMotion: true), 1);
    });

    testWidgets('flag off: the bar is pinned and its title collapses into the inline title', (tester) async {
      final env = await _pump(tester, _home(), filesHome: false);
      final top = tester.getRect(find.byKey(const ValueKey('home-top-bar'))).top;
      expect(_bar(tester).collapse, 0);
      expect(_titleScale(tester), moreOrLessEquals(1));
      _expectTitleHeader(tester);
      final labels = find.bySemanticsLabel('Danaview').evaluate().length;

      // Part-way through the header's shrink: between the large and the inline title.
      await _jump(tester, find.byType(Scrollable).first, 8);
      expect(_bar(tester).collapse, inExclusiveRange(0, 1));
      expect(_titleScale(tester), inExclusiveRange(homeInlineTitleSize / DanaviewTextStyles.largeTitle.fontSize!, 1));

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await pumpFrames(tester);
      expect(_bar(tester).collapse, 1);
      expect(_titleScale(tester), moreOrLessEquals(homeInlineTitleSize / DanaviewTextStyles.largeTitle.fontSize!));
      // Pinned: still on screen, risen only by the shrinking top padding.
      final pinned = tester.getRect(find.byKey(const ValueKey('home-top-bar')));
      expect(pinned.top, lessThan(top));
      expect(pinned.top, greaterThanOrEqualTo(20));
      _expectTitleHeader(tester);
      expect(find.bySemanticsLabel('Danaview').evaluate(), hasLength(labels), reason: 'no second title node');
      // The toolbar keeps working while collapsed.
      expect(find.byTooltip(HomeChromeLabels.import), findsOneWidget);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await pumpFrames(tester);
      expect(_bar(tester).collapse, 0);
      expect(tester.takeException(), isNull);
      await finishHome(tester, env);
    });

    testWidgets('flag off, Reduce Motion: no in-between, just the end state', (tester) async {
      final env = await _pump(tester, _home(reduceMotion: true), filesHome: false);
      await _jump(tester, find.byType(Scrollable).first, 2);
      expect(_bar(tester).collapse, 1);
      await _jump(tester, find.byType(Scrollable).first, 0);
      expect(_bar(tester).collapse, 0);
      await finishHome(tester, env);
    });

    testWidgets('flag on: the visible page drives the title; the search row stays pinned', (tester) async {
      final env = await _pump(
        tester,
        _home(slots: HomeTabSlots(search: (_) => const SizedBox(key: ValueKey('search-probe'), height: 44))),
        filesHome: true,
      );
      final search = tester.getRect(find.byKey(const ValueKey('home-slot-search')));
      expect(_bar(tester).collapse, 0);
      await tester.drag(_pageScrollable(HomeTab.home), const Offset(0, -300));
      await pumpFrames(tester);
      expect(_bar(tester).collapse, 1);
      expect(_titleScale(tester), lessThan(1));
      expect(tester.getRect(find.byKey(const ValueKey('home-slot-search'))), search, reason: 'pinned under the bar');

      // Each tab keeps its own collapse: a fresh tab shows the large title, Home its collapsed one.
      await _openTab(tester, HomeTab.playlists);
      expect(_bar(tester).collapse, 0);
      await _openTab(tester, HomeTab.home);
      expect(_bar(tester).collapse, 1);
      _expectTitleHeader(tester);
      expect(tester.takeException(), isNull);
      await finishHome(tester, env);
    });

    testWidgets('flag on, Reduce Motion: the end state at once', (tester) async {
      final env = await _pump(tester, _home(reduceMotion: true), filesHome: true);
      await _jump(tester, _pageScrollable(HomeTab.home), 2);
      expect(_bar(tester).collapse, 1);
      await finishHome(tester, env);
    });

    for (final filesHome in [false, true]) {
      testWidgets('flag ${filesHome ? 'on' : 'off'}: collapsed at 280 pt and text scale 1.35 without overflow', (tester) async {
        final env = await _pump(tester, _home(), filesHome: filesHome, size: const Size(280, 653), textScale: 1.35);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });
    }
  });

  group('Projects (§10.3 #3, §10.4)', () {
    final opened = <String>[];
    var created = 0;
    HomeCallbacks callbacks({bool open = true}) => HomeCallbacks(
          onOpenProjects: () {},
          onOpenProject: open ? opened.add : null,
          onNewProject: () => created++,
        );
    final slots = HomeTabSlots(
      projectsOverview: (_) => const HomeProjectsSection(),
      projects: (_) => const HomeProjectsTab(),
    );
    List<Override> projects(int count) => [
          homeProjectsProvider.overrideWithValue(_projects(count)),
          homeProjectsClockProvider.overrideWithValue(() => _now),
        ];

    setUp(() {
      opened.clear();
      created = 0;
    });

    testWidgets('the section shows the newest cards with Open projects; a card opens its project', (tester) async {
      final env = await _pump(
        tester,
        _home(callbacks: callbacks(), slots: slots),
        filesHome: true,
        size: const Size(402, 2400),
        overrides: projects(8),
      );
      expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-projects-open-all')), findsOneWidget);
      expect(find.byType(HomeProjectCard), findsNWidgets(homeProjectsOverviewLimit));
      expect(find.text('Edited 2 h ago'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Project Project 0, Edited 2 h ago')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-project-p1')));
      await pumpFrames(tester);
      expect(opened, ['p1']);
      await finishHome(tester, env);
    });

    testWidgets('hidden without projects', (tester) async {
      final env = await _pump(tester, _home(callbacks: callbacks(), slots: slots), filesHome: true, overrides: projects(0));
      expect(find.byKey(const ValueKey('home-projects')), findsNothing);
      expect(find.byType(HomeProjectCard), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('hidden when the editor is off (no open callback)', (tester) async {
      final env = await _pump(tester, _home(callbacks: callbacks(open: false), slots: slots), filesHome: true, overrides: projects(3));
      expect(find.byKey(const ValueKey('home-projects')), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('flag off: the 1.1 Home has no Projects section', (tester) async {
      final env = await _pump(tester, _home(callbacks: callbacks(), slots: slots), filesHome: false, overrides: projects(3));
      expect(find.byKey(const ValueKey('home-projects')), findsNothing);
      expect(find.byType(HomeProjectCard), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('the Projects tab: every project, New project as the one primary button', (tester) async {
      final env = await _pump(tester, _home(callbacks: callbacks(), slots: slots), filesHome: true, size: const Size(402, 2400), overrides: projects(3));
      await _openTab(tester, HomeTab.projects);
      final page = find.byKey(const ValueKey('home-tab-page-projects'));
      expect(find.descendant(of: page, matching: find.byType(HomeProjectCard)), findsNWidgets(3));
      expect(find.descendant(of: page, matching: find.byWidgetPredicate((w) => w is DanaviewButton && w.variant == DanaviewButtonVariant.primary)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-projects-new')));
      await pumpFrames(tester);
      expect(created, 1);
      await tester.tap(find.descendant(of: page, matching: find.byKey(const ValueKey('home-project-p2'))));
      await pumpFrames(tester);
      expect(opened, ['p2']);
      await finishHome(tester, env);
    });
  });

  group('§10.4 grid columns at 320 / 820 / 1280 pt', () {
    double content(double window) => window - danaviewLibraryInsets(window).horizontal;

    test('All, Videos, Playlists and Projects: 2 / 4 / 6', () {
      expect([for (final w in [320.0, 820.0, 1280.0]) homeAdaptiveColumns(content(w))], [2, 4, 6]);
      expect([for (final w in [320.0, 820.0, 1280.0]) homePlaylistColumns(content(w))], [2, 4, 6]);
      expect([for (final w in [320.0, 820.0, 1280.0]) homeProjectColumns(content(w))], [2, 4, 6]);
    });

    test('Photos: a full-width square grid of 3 / 5 / 8 at the default density', () {
      expect([for (final w in [320.0, 820.0, 1280.0]) photoGridSquareColumns(w, photoGridDefaultDensity)], [3, 5, 8]);
      // Density steps keep cells at a 44 pt target, two columns at least.
      for (final w in [280.0, 320.0, 820.0, 1280.0]) {
        for (var d = 0; d < photoGridDensityTargets.length; d++) {
          final c = photoGridSquareColumns(w, d);
          expect(c, greaterThanOrEqualTo(2));
          expect((w - 2 * (c - 1)) / c, greaterThanOrEqualTo(44));
        }
      }
    });

    test('Documents: a grouped list on phones, 2-up from tablets', () {
      expect([for (final w in [320.0, 820.0, 1280.0]) documentsTabColumns(content(w))], [1, 2, 2]);
    });

    for (final (width, columns) in [(320.0, 2), (820.0, 4), (1280.0, 6)]) {
      testWidgets('${width.toInt()} pt Projects tab: $columns cards a row, equal heights, no overflow', (tester) async {
        final env = await _pump(
          tester,
          _home(callbacks: HomeCallbacks(onOpenProjects: () {}, onOpenProject: (_) {}), slots: HomeTabSlots(projects: (_) => const HomeProjectsTab())),
          filesHome: true,
          size: Size(width, 1600),
          overrides: [homeProjectsProvider.overrideWithValue(_projects(7)), homeProjectsClockProvider.overrideWithValue(() => _now)],
        );
        await _openTab(tester, HomeTab.projects);
        final cards = [for (final e in find.byType(HomeProjectCard).evaluate()) tester.getRect(find.byWidget(e.widget))];
        final first = cards.where((c) => c.top == cards.first.top).toList();
        expect(first, hasLength(columns));
        for (final c in first) {
          expect(c.height, moreOrLessEquals(first.first.height));
        }
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });
    }
  });

  group('empty state: every content type counts', () {
    testWidgets('flag on, nothing at all: one empty state', (tester) async {
      final env = await _pump(tester, _home(), filesHome: true, seed: false);
      expect(find.byKey(const ValueKey('home-empty-state')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('flag on, only photos: no empty state', (tester) async {
      final env = await _pump(
        tester,
        _home(slots: HomeTabSlots(recentPhotos: (_) => const RecentPhotosTray())),
        filesHome: true,
        seed: false,
        overrides: _photoOverrides(synthetic(3)),
      );
      expect(find.byKey(const ValueKey('home-empty-state')), findsNothing);
      expect(find.byKey(const ValueKey('recent-photos-tray')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('flag on, only projects: no empty state', (tester) async {
      final env = await _pump(
        tester,
        _home(
          callbacks: HomeCallbacks(onOpenProject: (_) {}),
          slots: HomeTabSlots(projectsOverview: (_) => const HomeProjectsSection()),
        ),
        filesHome: true,
        seed: false,
        overrides: [homeProjectsProvider.overrideWithValue(_projects(1))],
      );
      expect(find.byKey(const ValueKey('home-empty-state')), findsNothing);
      expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
      await finishHome(tester, env);
    });

    test('the content provider counts photos and projects', () {
      final none = ProviderContainer(overrides: _photoOverrides(const []));
      addTearDown(none.dispose);
      expect(none.read(homeHasFilesContentProvider), isFalse);
      final photos = ProviderContainer(overrides: _photoOverrides(synthetic(1)));
      addTearDown(photos.dispose);
      expect(photos.read(homeHasFilesContentProvider), isTrue);
      final projects = ProviderContainer(overrides: [..._photoOverrides(const []), homeProjectsProvider.overrideWithValue(_projects(1))]);
      addTearDown(projects.dispose);
      expect(projects.read(homeHasFilesContentProvider), isTrue);
    });
  });
}
