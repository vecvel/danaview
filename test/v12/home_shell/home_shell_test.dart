// OWNER: HOM-05
//
// BUILD_PLAN HOM-05 acceptance (ARCH v1.2 V2-101, V2-32, §1.4, §3):
// * flag off: no tab shell (the 1.1 tree; pixel-equal goldens in flag_off_golden_test.dart and the
//   unchanged test/home_screen_test.dart);
// * flag on: every tab reachable by tap and by keyboard (Tab/Enter, Left/Right, Home/End);
// * the `Home` tab hosts the 1.1 sections plus the Recent photos and Favourites slots;
// * tab bodies come from HomeTabSlots, with the 1.1 Playlists/Folders sections and neutral panes
//   as fallbacks; visited tabs keep their state;
// * semantics labels and selected state on tabs, ≥ 44 px targets, computed contrast ≥ 4.5:1;
// * `Projects` only where the editor runs: desktop shows no editor tab;
// * the matrix 280–1280 px × text scale 0.85–1.35 with no overflow on every tab.

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/home/home_tab_host.dart';
import 'package:danaview_features/src/library/home/home_tab_strip.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'home_shell_support.dart';

const _libraryTabs = [
  HomeTab.home,
  HomeTab.all,
  HomeTab.videos,
  HomeTab.photos,
  HomeTab.documents,
  HomeTab.playlists,
  HomeTab.folders,
];

Widget _home({
  HomeCallbacks callbacks = HomeCallbacks.none,
  HomeTabSlots slots = HomeTabSlots.none,
  HomeTab initialTab = HomeTab.home,
  VoidCallback? onOpenEditor,
}) =>
    DanaviewHomeScreen(
      onOpenPlayer: () {},
      onOpenFolder: (_) {},
      onOpenPlaylist: (_) {},
      onOpenSettings: () {},
      onOpenEditor: onOpenEditor,
      callbacks: callbacks,
      tabSlots: slots,
      initialTab: initialTab,
    );

Future<LibraryTestEnv> _pump(
  WidgetTester tester,
  Widget home, {
  TestSurface? surface,
  TargetPlatform platform = TargetPlatform.iOS,
  bool seed = true,
}) async {
  final s = surface ?? const TestSurface(Size(402, 874), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34));
  useSurface(tester, s);
  final env = await LibraryTestEnv.create();
  if (seed) await seedFixedLibrary(env);
  await tester.pumpWidget(libraryTestApp(env, home, textScale: s.textScale, platform: platform));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

/// The tabs in the strip, in order.
List<HomeTab> _stripTabs(WidgetTester tester) {
  final strip = tester.widget<HomeTabStrip>(find.byKey(const ValueKey('home-tab-strip')));
  return strip.tabs;
}

HomeTab _selectedTab(WidgetTester tester) =>
    tester.widget<HomeTabStrip>(find.byKey(const ValueKey('home-tab-strip'))).selected;

Future<void> _tapTab(WidgetTester tester, HomeTab tab) async {
  final finder = find.byKey(homeTabKey(tab));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await pumpFrames(tester, count: 4);
  expect(tester.takeException(), isNull);
}

/// The page of [tab] on screen (hidden pages are kept but not hit-testable).
Finder _page(HomeTab tab) => find.byKey(ValueKey('home-tab-page-${tab.name}'));

FocusNode _focusOfTab(WidgetTester tester, HomeTab tab) => Focus.of(
      tester.element(find.descendant(of: find.byKey(homeTabKey(tab)), matching: find.text(tab.label))),
    );

void main() {
  group('flag off', () {
    testWidgets('no tab strip, no host, and the slots and callbacks are ignored', (tester) async {
      useFilesHome(false);
      var built = 0;
      final env = await _pump(
        tester,
        _home(
          callbacks: HomeCallbacks(onOpenProjects: () {}),
          slots: HomeTabSlots(
            recentPhotos: (_) {
              built++;
              return const SizedBox(height: 10);
            },
          ),
        ),
      );
      expect(find.byKey(const ValueKey('home-tab-strip')), findsNothing);
      expect(find.byType(HomeTabHost), findsNothing);
      expect(find.byKey(const ValueKey('home-slot-recent-photos')), findsNothing);
      expect(built, 0);
      expect(find.text('Continue watching'), findsOneWidget);
      await finishHome(tester, env);
    });
  });

  group('flag on', () {
    testWidgets('the strip lists the library tabs in order; Home is selected first', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home());
      expect(_stripTabs(tester), _libraryTabs);
      expect(_selectedTab(tester), HomeTab.home);
      for (final tab in _libraryTabs) {
        expect(find.byKey(homeTabKey(tab)), findsOneWidget);
      }
      expect(find.byKey(homeTabKey(HomeTab.projects)), findsNothing);
      await finishHome(tester, env);
    });

    testWidgets('the Home tab hosts the 1.1 sections with the Recent photos and Favourites slots', (tester) async {
      useFilesHome(true);
      final env = await _pump(
        tester,
        _home(
          slots: HomeTabSlots(
            recentPhotos: (_) => const SizedBox(height: 40, child: Text('TRAY')),
            favourites: (_) => const SizedBox(height: 40, child: Text('FAVS')),
          ),
        ),
        surface: const TestSurface(Size(402, 2400), 1.0),
      );
      for (final label in ['Continue watching', 'Playlists', 'Folders']) {
        expect(find.descendant(of: _page(HomeTab.home), matching: find.text(label)), findsWidgets, reason: label);
      }
      // The header stays in the top bar, with Open file / folder / link in its Import (+) menu.
      expect(find.text('Danaview'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('home-files-top-bar')), matching: find.byTooltip('Import')),
          findsOneWidget);
      double y(String text) =>
          tester.getTopLeft(find.descendant(of: _page(HomeTab.home), matching: find.text(text)).first).dy;
      expect(y('Continue watching'), lessThan(y('TRAY')));
      expect(y('TRAY'), lessThan(y('FAVS')));
      expect(y('FAVS'), lessThan(y('Playlists')));
      await finishHome(tester, env);
    });

    testWidgets('every tab is reachable by tap and shows its page', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home(callbacks: HomeCallbacks(onOpenProjects: () {})));
      final tabs = _stripTabs(tester);
      expect(tabs, [..._libraryTabs, HomeTab.projects]);
      for (final tab in tabs.reversed) {
        await _tapTab(tester, tab);
        expect(_selectedTab(tester), tab);
        expect(_page(tab).hitTestable(), findsOneWidget, reason: '$tab');
      }
      // Fallbacks: the 1.1 sections for Playlists and Folders, neutral panes for the others.
      await _tapTab(tester, HomeTab.playlists);
      expect(find.descendant(of: _page(HomeTab.playlists), matching: find.text('Docs')), findsOneWidget);
      await _tapTab(tester, HomeTab.folders);
      expect(find.descendant(of: _page(HomeTab.folders), matching: find.text('Movies')), findsOneWidget);
      await _tapTab(tester, HomeTab.photos);
      expect(find.descendant(of: _page(HomeTab.photos), matching: find.text('Nothing here yet')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('every tab is reachable by keyboard', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home(callbacks: HomeCallbacks(onOpenProjects: () {})));
      final tabs = _stripTabs(tester);

      // Tab moves focus into the strip; Enter selects the focused tab.
      var reached = false;
      for (var i = 0; i < 20 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        reached = _focusOfTab(tester, HomeTab.home).hasFocus;
      }
      expect(reached, isTrue, reason: 'Tab never reached the Home tab');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusOfTab(tester, HomeTab.all).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester, count: 3);
      expect(_selectedTab(tester), HomeTab.all);

      // Right walks the whole strip, selecting and focusing each tab; Home/End jump to the ends.
      for (var i = tabs.indexOf(HomeTab.all) + 1; i < tabs.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await pumpFrames(tester, count: 3);
        expect(_selectedTab(tester), tabs[i]);
        expect(_focusOfTab(tester, tabs[i]).hasFocus, isTrue);
        expect(_page(tabs[i]).hitTestable(), findsOneWidget);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await pumpFrames(tester, count: 2);
      expect(_selectedTab(tester), tabs.last);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await pumpFrames(tester, count: 3);
      expect(_selectedTab(tester), HomeTab.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await pumpFrames(tester, count: 2);
      expect(_selectedTab(tester), HomeTab.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await pumpFrames(tester, count: 3);
      expect(_selectedTab(tester), tabs.last);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await pumpFrames(tester, count: 3);
      expect(_selectedTab(tester), tabs[tabs.length - 2]);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpFrames(tester, count: 2);
      expect(_selectedTab(tester), tabs[tabs.length - 2]);
      expect(tester.takeException(), isNull);
      await finishHome(tester, env);
    });

    testWidgets('tabs carry semantics labels, selected state and button role', (tester) async {
      useFilesHome(true);
      final handle = tester.ensureSemantics();
      final env = await _pump(tester, _home());
      final tabs = _stripTabs(tester);
      for (var i = 0; i < tabs.length; i++) {
        final tab = tabs[i];
        final label = '${tab.label} tab, ${i + 1} of ${tabs.length}';
        // Tabs scrolled out of the strip are hidden from accessibility focus until revealed.
        await tester.ensureVisible(find.byKey(homeTabKey(tab)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          matchesSemantics(
            label: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasSelectedState: true,
            isSelected: tab == HomeTab.home,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      }
      expect(find.bySemanticsLabel('Home sections'), findsOneWidget);
      await _tapTab(tester, HomeTab.photos);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Photos tab'))),
        isSemantics(isSelected: true),
      );
      handle.dispose();
      await finishHome(tester, env);
    });

    testWidgets('targets are at least 44 px and the labels meet 4.5:1', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home());
      for (final tab in _stripTabs(tester)) {
        final size = tester.getSize(find.byKey(homeTabKey(tab)));
        expect(size.height, greaterThanOrEqualTo(DanaviewSpacing.minTapTarget), reason: '$tab');
        expect(size.width, greaterThanOrEqualTo(DanaviewSpacing.minTapTarget), reason: '$tab');
      }
      expect(
        DanaviewColors.contrastRatio(HomeTabStripColors.selectedForeground, HomeTabStripColors.selectedFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        DanaviewColors.contrastRatio(HomeTabStripColors.idleForeground, HomeTabStripColors.idleFill),
        greaterThanOrEqualTo(4.5),
      );
      await finishHome(tester, env);
    });

    testWidgets('supplied bodies replace the fallbacks and read the callbacks in scope', (tester) async {
      useFilesHome(true);
      HomeCallbacks? seen;
      final callbacks = HomeCallbacks(onOpenProjects: () {}, onSearchWithAi: (_) {});
      Widget body(String text) => Builder(builder: (context) {
            seen = HomeCallbacksScope.of(context);
            return Center(child: Text(text));
          });
      final env = await _pump(
        tester,
        _home(
          callbacks: callbacks,
          slots: HomeTabSlots(
            all: (_) => body('ALL BODY'),
            videos: (_) => body('VIDEOS BODY'),
            photos: (_) => body('PHOTOS BODY'),
            documents: (_) => body('DOCS BODY'),
            folders: (_) => body('FOLDERS BODY'),
            projects: (_) => body('PROJECTS BODY'),
            selectionBar: (_) => const SizedBox(height: 56, child: Text('SELECTION BAR')),
          ),
        ),
      );
      for (final (tab, text) in [
        (HomeTab.all, 'ALL BODY'),
        (HomeTab.videos, 'VIDEOS BODY'),
        (HomeTab.photos, 'PHOTOS BODY'),
        (HomeTab.documents, 'DOCS BODY'),
        (HomeTab.folders, 'FOLDERS BODY'),
        (HomeTab.projects, 'PROJECTS BODY'),
      ]) {
        await _tapTab(tester, tab);
        expect(find.descendant(of: _page(tab), matching: find.text(text)), findsOneWidget);
      }
      expect(seen, same(callbacks));
      expect(find.text('SELECTION BAR'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-slot-selection-bar')), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('visited tabs keep their state across switches', (tester) async {
      useFilesHome(true);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var builds = 0;
      final env = await _pump(
        tester,
        _home(
          slots: HomeTabSlots(
            photos: (_) {
              builds++;
              return ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (_, i) => SizedBox(height: 60, child: Text('photo row $i')),
              );
            },
          ),
        ),
      );
      expect(builds, 0, reason: 'an unvisited tab is not built');
      await _tapTab(tester, HomeTab.photos);
      controller.jumpTo(1800);
      await tester.pump();
      await _tapTab(tester, HomeTab.playlists);
      expect(find.text('photo row 30').hitTestable(), findsNothing);
      await _tapTab(tester, HomeTab.photos);
      expect(controller.offset, 1800);
      expect(find.text('photo row 30').hitTestable(), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('hidden pages take no pointer, focus or semantics', (tester) async {
      useFilesHome(true);
      final handle = tester.ensureSemantics();
      var taps = 0;
      final env = await _pump(
        tester,
        _home(slots: HomeTabSlots(photos: (_) => Center(child: DanaviewButton.primary(label: 'Photo action', onPressed: () => taps++)))),
      );
      await _tapTab(tester, HomeTab.photos);
      expect(find.bySemanticsLabel('Photo action'), findsOneWidget);
      await _tapTab(tester, HomeTab.home);
      expect(find.bySemanticsLabel('Photo action'), findsNothing);
      expect(find.text('Photo action').hitTestable(), findsNothing);
      expect(taps, 0);
      handle.dispose();
      await finishHome(tester, env);
    });

    testWidgets('showDocuments false hides the Documents tab (slice S2)', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home(slots: const HomeTabSlots(showDocuments: false), initialTab: HomeTab.documents));
      expect(_stripTabs(tester), isNot(contains(HomeTab.documents)));
      expect(_selectedTab(tester), HomeTab.home, reason: 'a hidden initial tab falls back to Home');
      await finishHome(tester, env);
    });

    testWidgets('initialTab opens that tab', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home(initialTab: HomeTab.folders));
      expect(_selectedTab(tester), HomeTab.folders);
      expect(_page(HomeTab.folders).hitTestable(), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('the Projects pane opens the projects', (tester) async {
      useFilesHome(true);
      var opened = 0;
      final env = await _pump(tester, _home(callbacks: HomeCallbacks(onOpenProjects: () => opened++)));
      await _tapTab(tester, HomeTab.projects);
      await tester.tap(find.text('Open projects'));
      await tester.pump();
      expect(opened, 1);
      await finishHome(tester, env);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('Projects is shown on ${platform.name} when the editor is wired', (tester) async {
        useFilesHome(true);
        final env = await _pump(tester, _home(callbacks: HomeCallbacks(onOpenProjects: () {})), platform: platform);
        expect(_stripTabs(tester).last, HomeTab.projects);
        await finishHome(tester, env);
      });
    }

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('desktop (${platform.name}) shows no editor tab', (tester) async {
        useFilesHome(true);
        final env = await _pump(
          tester,
          _home(
            callbacks: HomeCallbacks(onOpenProjects: () {}),
            slots: HomeTabSlots(projects: (_) => const Text('PROJECTS BODY')),
          ),
          platform: platform,
          surface: const TestSurface(Size(1280, 800), 1.0),
        );
        expect(_stripTabs(tester), _libraryTabs);
        expect(find.byKey(homeTabKey(HomeTab.projects)), findsNothing);
        expect(find.text('PROJECTS BODY'), findsNothing);
        await finishHome(tester, env);
      });
    }

    testWidgets('mobile without the editor wired shows no Projects tab', (tester) async {
      useFilesHome(true);
      final env = await _pump(tester, _home(), platform: TargetPlatform.android);
      expect(_stripTabs(tester), _libraryTabs);
      await finishHome(tester, env);
    });

    testWidgets('pure helpers: visibleHomeTabs and homeEditorPlatform', (tester) async {
      expect(visibleHomeTabs(platform: TargetPlatform.iOS, projectsAvailable: true).last, HomeTab.projects);
      expect(visibleHomeTabs(platform: TargetPlatform.macOS, projectsAvailable: true), _libraryTabs);
      expect(
        visibleHomeTabs(platform: TargetPlatform.android, projectsAvailable: false, showDocuments: false),
        [HomeTab.home, HomeTab.all, HomeTab.videos, HomeTab.photos, HomeTab.playlists, HomeTab.folders],
      );
      expect(homeEditorPlatform(TargetPlatform.fuchsia), isFalse);
      expect(HomeTabSlots.none.bodyOf(HomeTab.home), isNull);
      expect(HomeCallbacks.none.onOpenProjects, isNull);
    });
  });

  group('selection bar inset, flag on', () {
    const barKey = ValueKey('test-selection-bar');

    /// A bar that shows only while [selecting], like HomeSelectionBar (which is empty without a
    /// selection), and includes the bottom safe area.
    HomeSlotBuilder bar(ValueNotifier<bool> selecting) => (_) => ValueListenableBuilder<bool>(
          valueListenable: selecting,
          builder: (_, on, __) => on
              ? const SafeArea(top: false, child: SizedBox(key: barKey, height: 120, child: Text('SELECTION BAR')))
              : const SizedBox.shrink(),
        );

    /// Scrolls the visible scrollable of [tab] to its end.
    Future<void> scrollToEnd(WidgetTester tester, HomeTab tab) async {
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: _page(tab), matching: find.byType(Scrollable)).first,
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await pumpFrames(tester, count: 4);
    }

    /// The bottom edge, in global coordinates, of the last laid-out row of [tab]'s list.
    double lastRowBottom(WidgetTester tester, HomeTab tab) {
      final list = tester.renderObject<RenderSliverMultiBoxAdaptor>(
        find.descendant(of: _page(tab), matching: find.byWidgetPredicate((w) => w is SliverMultiBoxAdaptorWidget)).first,
      );
      final last = list.lastChild!;
      return last.localToGlobal(Offset(0, last.size.height)).dy;
    }

    testWidgets('the last row of a shell page and of a supplied body scrolls above the bar', (tester) async {
      useFilesHome(true);
      final selecting = ValueNotifier(false);
      addTearDown(selecting.dispose);
      const surface = TestSurface(Size(402, 874), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34));
      useSurface(tester, surface);
      final env = await LibraryTestEnv.create();
      await seedFixedLibrary(env);
      for (var i = 0; i < 30; i++) {
        await env.library.createPlaylist('Inset playlist $i');
      }
      await tester.pumpWidget(libraryTestApp(
        env,
        _home(
          slots: HomeTabSlots(
            photos: (_) => ListView.builder(
              itemCount: 80,
              itemBuilder: (_, i) => SizedBox(height: 60, child: Text('photo row $i')),
            ),
            selectionBar: bar(selecting),
          ),
        ),
      ));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);

      for (final tab in [HomeTab.playlists, HomeTab.photos]) {
        await _tapTab(tester, tab);
        await scrollToEnd(tester, tab);
        final offsetBefore = tester
            .state<ScrollableState>(find.descendant(of: _page(tab), matching: find.byType(Scrollable)).first)
            .position
            .pixels;

        selecting.value = true; // an item is selected: the bar appears
        await pumpFrames(tester, count: 4);
        expect(find.byKey(barKey), findsOneWidget);
        // The page keeps its state (scroll offset) when the bar appears.
        expect(
          tester
              .state<ScrollableState>(find.descendant(of: _page(tab), matching: find.byType(Scrollable)).first)
              .position
              .pixels,
          offsetBefore,
        );
        await scrollToEnd(tester, tab);
        final barTop = tester.getTopLeft(find.byKey(const ValueKey('home-slot-selection-bar'))).dy;
        expect(lastRowBottom(tester, tab), lessThanOrEqualTo(barTop), reason: '$tab last row under the bar');

        selecting.value = false;
        await pumpFrames(tester, count: 4);
        expect(find.byKey(barKey), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await finishHome(tester, env);
    });
  });

  group('matrix 280–1280 px × 0.85–1.35, flag on', () {
    for (final surface in homeShellSurfaces) {
      testWidgets('every tab at $surface', (tester) async {
        useFilesHome(true);
        final env = await _pump(
          tester,
          _home(
            callbacks: HomeCallbacks(onOpenProjects: () {}),
            onOpenEditor: () {},
            slots: HomeTabSlots(
              recentPhotos: (_) => const SizedBox(height: 96),
              favourites: (_) => const SizedBox(height: 96),
            ),
          ),
          surface: surface,
        );
        for (final tab in _stripTabs(tester)) {
          await _tapTab(tester, tab);
          expect(_selectedTab(tester), tab);
          final scrollables = find.descendant(of: _page(tab), matching: find.byType(Scrollable));
          if (scrollables.evaluate().isNotEmpty) {
            await tester.drag(scrollables.first, const Offset(0, -2000));
            await pumpFrames(tester, count: 3);
          }
          expect(tester.takeException(), isNull, reason: '$tab at $surface');
        }
        await finishHome(tester, env);
      });
    }
  });
}
