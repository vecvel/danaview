// The four-tab Files & Media Home (DESIGN_SYSTEM §10.2–10.4, approved by the owner from a preview):
// * the strip is Home · Videos · Photos · Documents (Documents follows its slice switch), with or
//   without the editor, and the arrow keys walk the four tabs;
// * every "See all" pushes its full screen: Folders (Home), Recent projects and the Videos
//   Projects row (Projects, with Manage in the top bar), the Videos Playlists row (Playlists, with
//   New in the top bar and Play / Shuffle / Rename / Delete in each card's menu); Back pops them;
// * the Videos tab's sections in order (Continue watching with Clear, Projects with a New project
//   card, Playlists, All videos with Sort), with the editor wired and not, on mobile and desktop,
//   and no tabs at all with DANAVIEW_FILES_HOME off;
// * the search field reads "Search everything" and an empty search with the filter's "Show: All"
//   lists every file;
// * the filter's Show menu offers All / Videos / Photos / Documents and checks the shown one.

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/home/home_tab_strip.dart' show HomeTabStrip;
import 'package:danaview_features/src/library/search/library_search_field.dart';
import 'package:danaview_features/src/library/tabs/all_tab.dart';
import 'package:danaview_features/src/library/tabs/videos_tab.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';
import 'home_shell_support.dart';

final DateTime _now = DateTime(2026, 10, 30, 12);

List<HomeProject> _projects(int count) => [
      for (var i = 0; i < count; i++)
        HomeProject(id: 'p$i', name: 'Project $i', updatedAt: _now.subtract(Duration(hours: 1 + i * 5))),
    ];

class _Calls {
  final List<String> opened = [];
  final List<String> playlists = [];
  int created = 0;
  int manage = 0;
  int player = 0;

  HomeCallbacks callbacks({bool editor = true}) => editor
      ? HomeCallbacks(onOpenProjects: () => manage++, onOpenProject: opened.add, onNewProject: () => created++)
      : HomeCallbacks.none;
}

Widget _home(
  _Calls calls, {
  bool editor = true,
  HomeTabSlots slots = HomeTabSlots.none,
}) =>
    DanaviewHomeScreen(
      onOpenPlayer: () => calls.player++,
      onOpenFolder: (_) {},
      onOpenPlaylist: calls.playlists.add,
      onOpenSettings: () {},
      callbacks: calls.callbacks(editor: editor),
      tabSlots: slots,
    );

/// The Home's slots as the app fills them where the editor runs (the overview's Recent projects
/// and the Projects screen's body), plus a search row so the filter button shows.
HomeTabSlots _editorSlots({HomeSlotBuilder? all, HomeSlotBuilder? search}) => HomeTabSlots(
      projectsOverview: (_) => const HomeProjectsSection(),
      projects: (_) => const HomeProjectsTab(showHeader: false),
      search: search ?? (_) => const SizedBox(height: 44),
      all: all,
    );

Future<LibraryTestEnv> _pump(
  WidgetTester tester,
  Widget home, {
  bool filesHome = true,
  Size size = const Size(402, 1600),
  TargetPlatform platform = TargetPlatform.iOS,
  int projects = 3,
  List<Override> overrides = const [],
  bool seed = true,
}) async {
  useFilesHome(filesHome);
  useSurface(tester, TestSurface(size, 1.0, padding: const EdgeInsets.only(top: 47, bottom: 34)));
  final env = await LibraryTestEnv.create();
  if (seed) await seedFixedLibrary(env);
  await tester.pumpWidget(libraryTestApp(
    env,
    home,
    platform: platform,
    overrides: [
      homeProjectsProvider.overrideWithValue(_projects(projects)),
      homeProjectsClockProvider.overrideWithValue(() => _now),
      ...overrides,
    ],
  ));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

final Finder _strip = find.byKey(const ValueKey('home-tab-strip'));

List<HomeTab> _stripTabs(WidgetTester tester) => tester.widget<HomeTabStrip>(_strip).tabs;

HomeTab? _selected(WidgetTester tester) => tester.widget<HomeTabStrip>(_strip).selected;

Finder _page(HomeTab tab) => find.byKey(homeTabPageKey(tab));

Finder _screen(HomeDestination destination) => find.byKey(homeDestinationScreenKey(destination));

Future<void> _tapTab(WidgetTester tester, HomeTab tab) async {
  await tester.ensureVisible(find.byKey(homeTabKey(tab)));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(homeTabKey(tab)));
  await pumpFrames(tester, count: 4);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpFrames(tester, count: 8);
  expect(tester.takeException(), isNull);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Back').last);
  await pumpFrames(tester, count: 8);
}

Future<void> _openFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('home-filter')));
  await pumpFrames(tester);
}

/// The labels of the open filter menu's rows (the header excluded), and the checked one.
(List<String>, String?) _filterMenu(WidgetTester tester) {
  final items = tester.widgetList<DanaviewMenuAnchor>(find.byType(DanaviewMenuAnchor)).expand((a) => a.entries);
  final rows = [for (final e in items) if (e is DanaviewMenuItem && ['All', ...HomeTab.values.map((t) => t.label)].contains(e.label)) e];
  final checked = rows.where((e) => e.selected).map((e) => e.label);
  return ([for (final e in rows) e.label], checked.isEmpty ? null : checked.single);
}

double _top(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;

void main() {
  group('the four tabs', () {
    for (final editor in [false, true]) {
      testWidgets('Home · Videos · Photos · Documents ${editor ? 'with' : 'without'} the editor', (tester) async {
        final calls = _Calls();
        final env = await _pump(tester, _home(calls, editor: editor, slots: _editorSlots()));
        expect(_stripTabs(tester), [HomeTab.home, HomeTab.videos, HomeTab.photos, HomeTab.documents]);
        for (final tab in HomeTab.values) {
          expect(find.descendant(of: find.byKey(homeTabKey(tab)), matching: find.text(tab.label)), findsOneWidget);
        }
        for (final gone in ['All', 'Playlists', 'Folders', 'Projects']) {
          expect(find.descendant(of: _strip, matching: find.text(gone)), findsNothing, reason: '$gone is no tab');
        }
        expect(_selected(tester), HomeTab.home);
        await finishHome(tester, env);
      });
    }

    testWidgets('Documents follows its slice switch: three tabs while it is off', (tester) async {
      final env = await _pump(tester, _home(_Calls(), slots: const HomeTabSlots(showDocuments: false)));
      expect(_stripTabs(tester), [HomeTab.home, HomeTab.videos, HomeTab.photos]);
      await finishHome(tester, env);
    });

    testWidgets('arrow keys walk the four tabs and stop at the ends', (tester) async {
      final env = await _pump(tester, _home(_Calls()));
      Focus.of(tester.element(find.descendant(of: find.byKey(homeTabKey(HomeTab.home)), matching: find.text('Home'))))
          .requestFocus();
      await tester.pump();
      for (final tab in [HomeTab.videos, HomeTab.photos, HomeTab.documents, HomeTab.documents]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await pumpFrames(tester, count: 2);
        expect(_selected(tester), tab);
        expect(_page(tab).hitTestable(), findsOneWidget);
      }
      for (final tab in [HomeTab.photos, HomeTab.videos, HomeTab.home, HomeTab.home]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await pumpFrames(tester, count: 2);
        expect(_selected(tester), tab);
      }
      await finishHome(tester, env);
    });

    testWidgets('flag off: the 1.1 Home, no tabs, no Videos tab, no screens', (tester) async {
      final calls = _Calls();
      final env = await _pump(tester, _home(calls, slots: _editorSlots()), filesHome: false);
      expect(_strip, findsNothing);
      expect(find.byKey(const ValueKey('home-filter')), findsNothing);
      expect(find.byKey(const ValueKey('home-projects-row')), findsNothing);
      expect(find.byKey(const ValueKey('home-folders-see-all')), findsNothing);
      // The 1.1 sections: Continue watching, Playlists (New), Folders.
      for (final label in ['Continue watching', 'Playlists', 'Folders']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await finishHome(tester, env);
    });
  });

  group('See all opens a full screen', () {
    testWidgets('Home: Folders See all opens the Folders screen; Back returns to Home', (tester) async {
      final env = await _pump(tester, _home(_Calls()));
      final shell = tester.state(find.byType(DanaviewHomeScreen));
      expect(find.descendant(of: _page(HomeTab.home), matching: find.text('Folders')), findsOneWidget);
      await _tapKey(tester, 'home-folders-see-all');
      expect(_screen(HomeDestination.folders), findsOneWidget);
      expect(find.descendant(of: _screen(HomeDestination.folders), matching: find.text('Movies')), findsOneWidget);
      expect(find.descendant(of: _screen(HomeDestination.folders), matching: find.byTooltip('Back')), findsOneWidget);
      await _back(tester);
      expect(_screen(HomeDestination.folders), findsNothing);
      expect(_page(HomeTab.home).hitTestable(), findsOneWidget);
      expect(tester.state(find.byType(DanaviewHomeScreen)), same(shell), reason: 'the Home is kept under the screen');
      await finishHome(tester, env);
    });

    testWidgets('Home: the Folders screen shows the supplied body (HOM-18)', (tester) async {
      final env = await _pump(tester, _home(_Calls(), slots: HomeTabSlots(folders: (_) => const Text('FOLDERS BODY'))));
      await _tapKey(tester, 'home-folders-see-all');
      expect(find.descendant(of: _screen(HomeDestination.folders), matching: find.text('FOLDERS BODY')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('Home: Recent projects shows the newest two; See all opens the Projects screen', (tester) async {
      final calls = _Calls();
      final env = await _pump(tester, _home(calls, slots: _editorSlots()), projects: 5);
      final section = find.byKey(const ValueKey('home-projects'));
      expect(find.descendant(of: section, matching: find.text('Recent projects')), findsOneWidget);
      expect(find.descendant(of: section, matching: find.byType(HomeProjectCard)), findsNWidgets(2));
      expect(find.descendant(of: section, matching: find.text('Project 0')), findsOneWidget);
      expect(find.descendant(of: section, matching: find.text('Project 2')), findsNothing);
      await _tapKey(tester, 'home-projects-see-all');
      final screen = _screen(HomeDestination.projects);
      expect(screen, findsOneWidget);
      expect(find.descendant(of: screen, matching: find.byType(HomeProjectCard)), findsNWidgets(5));
      // Manage in the top bar opens the editor's own list; New project is the screen's primary.
      await tester.tap(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-projects-manage'))));
      await tester.pump();
      expect(calls.manage, 1);
      await tester.tap(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-projects-new'))));
      await tester.pump();
      expect(calls.created, 1);
      await tester.tap(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-project-p4'))));
      await tester.pump();
      expect(calls.opened, ['p4']);
      await _back(tester);
      expect(screen, findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('Videos: the Projects row See all opens the Projects screen', (tester) async {
      final env = await _pump(tester, _home(_Calls(), slots: _editorSlots()));
      await _tapTab(tester, HomeTab.videos);
      await _tapKey(tester, 'home-projects-row-see-all');
      expect(_screen(HomeDestination.projects), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('Videos: the Playlists row See all opens the Playlists screen with New and the card menu',
        (tester) async {
      final calls = _Calls();
      final env = await _pump(tester, _home(calls));
      await _tapTab(tester, HomeTab.videos);
      final row = find.byKey(const ValueKey('home-playlists-row'));
      expect(find.descendant(of: row, matching: find.byType(HomePlaylistCard)), findsNWidgets(3));
      await _tapKey(tester, 'home-playlists-see-all');
      final screen = _screen(HomeDestination.playlists);
      expect(screen, findsOneWidget);
      expect(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-playlists-grid'))), findsOneWidget);
      expect(find.descendant(of: screen, matching: find.byType(HomePlaylistCard)), findsNWidgets(3));
      expect(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-playlists-new'))), findsOneWidget);
      // Each card's menu: Play, Shuffle, Rename, Delete.
      await tester.tap(find.descendant(
        of: find.descendant(of: screen, matching: find.byKey(const ValueKey('home-playlist-Docs'))),
        matching: find.byTooltip('More'),
      ));
      await pumpFrames(tester);
      for (final item in ['Play', 'Shuffle', 'Rename', 'Delete']) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      await tester.tap(find.text('Play'));
      await pumpFrames(tester);
      expect(calls.player, 1);
      // A card opens its playlist.
      await tester.tap(find.descendant(of: screen, matching: find.text('Docs')));
      await pumpFrames(tester);
      expect(calls.playlists, ['Docs']);
      // New in the top bar asks for a name.
      await tester.tap(find.descendant(of: screen, matching: find.byKey(const ValueKey('home-playlists-new'))));
      await pumpFrames(tester);
      expect(find.text('New playlist'), findsOneWidget);
      await finishHome(tester, env);
    });
  });

  group('the Videos tab', () {
    testWidgets('editor on: Continue watching, Projects, Playlists, All videos, in that order', (tester) async {
      final calls = _Calls();
      final env = await _pump(tester, _home(calls, slots: _editorSlots()));
      await _tapTab(tester, HomeTab.videos);
      final page = _page(HomeTab.videos);
      Finder inPage(Finder f) => find.descendant(of: page, matching: f);
      final continueWatching = inPage(find.byKey(const ValueKey('videos-continue-watching')));
      final projects = inPage(find.byKey(const ValueKey('home-projects-row')));
      final playlists = inPage(find.byKey(const ValueKey('home-playlists-row')));
      final all = inPage(find.byKey(const ValueKey('videos-all-header')));
      for (final f in [continueWatching, projects, playlists, all]) {
        expect(f, findsOneWidget);
      }
      expect(_top(tester, continueWatching), lessThan(_top(tester, projects)));
      expect(_top(tester, projects), lessThan(_top(tester, playlists)));
      expect(_top(tester, playlists), lessThan(_top(tester, all)));
      expect(find.descendant(of: continueWatching, matching: find.text('Clear')), findsOneWidget);
      expect(find.descendant(of: all, matching: find.text('All videos')), findsOneWidget);
      // The Projects row: the New project card first, then the projects, newest first.
      final cards = tester.widgetList(find.descendant(
        of: projects,
        matching: find.byWidgetPredicate((w) => w is HomeProjectCard || w.key == const ValueKey('home-projects-new-card')),
      ));
      expect(cards.first.key, const ValueKey('home-projects-new-card'));
      expect([for (final c in cards.skip(1)) (c as HomeProjectCard).project.id], ['p0', 'p1', 'p2']);
      await tester.tap(find.byKey(const ValueKey('home-projects-new-card')));
      await tester.pump();
      expect(calls.created, 1);
      final p1 = find.descendant(of: projects, matching: find.byKey(const ValueKey('home-project-p1')));
      await tester.ensureVisible(p1);
      await pumpFrames(tester);
      await tester.tap(p1);
      await tester.pump();
      expect(calls.opened, ['p1']);
      await finishHome(tester, env);
    });

    testWidgets('editor on, no projects yet: the row holds New project alone', (tester) async {
      final env = await _pump(tester, _home(_Calls(), slots: _editorSlots()), projects: 0);
      await _tapTab(tester, HomeTab.videos);
      expect(find.byKey(const ValueKey('home-projects-new-card')), findsOneWidget);
      expect(find.byType(HomeProjectCard), findsNothing);
      await finishHome(tester, env);
    });

    for (final (label, editor, platform) in [
      ('editor off', false, TargetPlatform.iOS),
      ('desktop (macOS) with the callbacks', true, TargetPlatform.macOS),
    ]) {
      testWidgets('$label: no Projects row, the other sections stay', (tester) async {
        final env = await _pump(tester, _home(_Calls(), editor: editor, slots: _editorSlots()), platform: platform);
        await _tapTab(tester, HomeTab.videos);
        expect(find.byKey(const ValueKey('home-projects-row')), findsNothing);
        expect(find.byKey(const ValueKey('videos-continue-watching')), findsOneWidget);
        expect(find.byKey(const ValueKey('home-playlists-row')), findsOneWidget);
        expect(find.byKey(const ValueKey('videos-all-header')), findsOneWidget);
        await finishHome(tester, env);
      });
    }

    testWidgets('an empty library hides the empty sections; All videos keeps its empty state', (tester) async {
      final env = await _pump(tester, _home(_Calls(), editor: false), seed: false);
      await _tapTab(tester, HomeTab.videos);
      expect(find.byKey(const ValueKey('videos-continue-watching')), findsNothing);
      expect(find.byKey(const ValueKey('home-playlists-row')), findsNothing);
      expect(find.text('All videos'), findsOneWidget);
      expect(find.descendant(of: _page(HomeTab.videos), matching: find.text('Nothing here yet')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('Clear asks first, then empties Continue watching', (tester) async {
      final env = await _pump(tester, _home(_Calls()));
      await _tapTab(tester, HomeTab.videos);
      await _tapKey(tester, 'videos-continue-clear');
      expect(find.text('Clear Continue watching'), findsOneWidget);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Clear').last);
      await pumpFrames(tester);
      expect(find.byKey(const ValueKey('videos-continue-watching')), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('All videos: Sort orders by Newest, Oldest and Name', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 2000), 1.0));
      final env = await LibraryTestEnv.create();
      final lib = await FixtureLibrary.open(tester);
      for (final name in ['Beta.mp4', 'Alpha.mp4', 'Gamma.mp4']) {
        await lib.add(tester, name);
        lib.now = lib.now.add(const Duration(minutes: 1));
      }
      await tester.pumpWidget(filtersApp(env, VideosTab(onOpenPlayer: () {}), lib: lib));
      await pumpFrames(tester);
      List<String> order() {
        final names = ['Alpha.mp4', 'Beta.mp4', 'Gamma.mp4'];
        return names..sort((a, b) => tester.getTopLeft(find.text(a)).dx.compareTo(tester.getTopLeft(find.text(b)).dx));
      }

      expect(order(), ['Gamma.mp4', 'Alpha.mp4', 'Beta.mp4'], reason: 'Newest first');
      for (final (sort, expected) in [
        ('Oldest', ['Beta.mp4', 'Alpha.mp4', 'Gamma.mp4']),
        ('Name', ['Alpha.mp4', 'Beta.mp4', 'Gamma.mp4']),
        ('Newest', ['Gamma.mp4', 'Alpha.mp4', 'Beta.mp4']),
      ]) {
        await tester.tap(find.byKey(const ValueKey('videos-sort')));
        await pumpFrames(tester);
        expect(find.text('Sort by'), findsOneWidget);
        await tester.tap(find.text(sort).last);
        await pumpFrames(tester);
        expect(order(), expected, reason: sort);
      }
      expect(tester.takeException(), isNull);
      await lib.close(tester);
      await env.dispose();
    });
  });

  group('the filter and the search', () {
    testWidgets('Show offers All / Videos / Photos / Documents and checks the shown one', (tester) async {
      final env = await _pump(tester, _home(_Calls(), slots: _editorSlots(all: (_) => const Text('ALL BODY'))));
      await _openFilter(tester);
      expect(find.text('Show'), findsOneWidget);
      expect(_filterMenu(tester).$1, ['All', 'Videos', 'Photos', 'Documents']);
      expect(_filterMenu(tester).$2, isNull, reason: 'Home: nothing checked');

      // Videos: the tab.
      await tester.tap(find.text('Videos').hitTestable().last);
      await pumpFrames(tester);
      expect(_selected(tester), HomeTab.videos);
      await _openFilter(tester);
      expect(_filterMenu(tester).$2, 'Videos');

      // All: every file in place of the tab; no pill selected.
      await tester.tap(find.text('All').hitTestable().last);
      await pumpFrames(tester, count: 4);
      expect(_selected(tester), isNull);
      expect(find.byKey(homeAllPageKey).hitTestable(), findsOneWidget);
      expect(find.text('ALL BODY').hitTestable(), findsOneWidget);
      expect(_page(HomeTab.videos).hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('Filter: showing All'), findsOneWidget);
      await _openFilter(tester);
      expect(_filterMenu(tester).$2, 'All');

      // Photos from the menu leaves All; so does a tab.
      await tester.tap(find.text('Photos').hitTestable().last);
      await pumpFrames(tester);
      expect(_selected(tester), HomeTab.photos);
      expect(find.text('ALL BODY').hitTestable(), findsNothing);
      await _openFilter(tester);
      await tester.tap(find.text('All').hitTestable().last);
      await pumpFrames(tester);
      await _tapTab(tester, HomeTab.home);
      expect(_selected(tester), HomeTab.home);
      expect(find.text('ALL BODY').hitTestable(), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('Show omits Documents while the Documents tab is hidden', (tester) async {
      final env = await _pump(
        tester,
        _home(_Calls(), slots: HomeTabSlots(search: (_) => const SizedBox(height: 44), showDocuments: false)),
      );
      await _openFilter(tester);
      expect(_filterMenu(tester).$1, ['All', 'Videos', 'Photos']);
      await finishHome(tester, env);
    });

    testWidgets('an empty search with Show: All lists every file', (tester) async {
      useFilesHome(true);
      useSurface(tester, const TestSurface(Size(1280, 3000), 1.0));
      final env = await LibraryTestEnv.create();
      final lib = await FixtureLibrary.open(tester);
      final entries = await lib.seedFixture(tester);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(
          onOpenPlayer: () {},
          onOpenFolder: (_) {},
          onOpenPlaylist: (_) {},
          tabSlots: HomeTabSlots(
            all: (_) => const AllTab(),
            search: (_) => LibrarySearchField(hint: 'Search everything', onOpen: (_) {}),
          ),
        ),
        overrides: [libraryStoreProvider.overrideWithValue(lib.store)],
      ));
      await pumpFrames(tester);
      expect(find.text('Search everything'), findsOneWidget);
      Set<String> shown() => {
            for (final e in entries.values)
              if (find.byKey(ValueKey('library-entry-${e.id.value}')).hitTestable().evaluate().isNotEmpty) e.displayName,
          };

      await _openFilter(tester);
      await tester.tap(find.text('All').hitTestable().last);
      await pumpFrames(tester, count: 4);
      expect(shown(), entries.keys.toSet(), reason: 'every kind, the unknown one included');

      // A query lists its hits under the field; clearing it leaves every file listed.
      await tester.enterText(find.byType(EditableText), 'pdf');
      for (var i = 0; i < 5 && find.byKey(const ValueKey('library-search-count')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await pumpFrames(tester, count: 2);
      }
      expect(find.byKey(const ValueKey('library-search-count')), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '');
      await pumpFrames(tester);
      expect(find.byKey(const ValueKey('library-search-count')), findsNothing);
      expect(shown(), entries.keys.toSet());
      expect(tester.takeException(), isNull);
      await lib.close(tester);
      await env.dispose();
    });
  });
}
