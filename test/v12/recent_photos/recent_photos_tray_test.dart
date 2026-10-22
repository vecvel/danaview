// OWNER: HOM-09
//
// BUILD_PLAN HOM-09 acceptance (HOM plan §5.1, §2 item 6; ARCH v1.2 V2-101, V2-103, §1.4; Q-N8):
// * empty: the tray draws nothing (no header, no list);
// * few: one tile per photo, newest first; a tap opens the viewer callback with the whole list at
//   that index; See all calls `onSeeAll`, or bubbles a HomeTabRequestNotification for Photos;
// * many: at most `recentPhotosTrayLimit` tiles plus a "+N See all" tile, scrollable sideways;
// * the system library joins only after the "Show my photo library" opt-in, never asks for access
//   before it, and is loaded by the tray once opted in;
// * DANAVIEW_FILES_HOME off: the tray is absent (standalone and inside the Home slot); on: it sits
//   in the Overview below Continue watching;
// * the matrix 280–1280 px × text scale 0.85–1.35: no overflow, targets ≥ 44 px, semantics
//   labels, computed contrast ≥ 4.5:1 on the See all tile.

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/home/home_tab_host.dart';
import 'package:danaview_features/src/library/home/recent_photos_tray.dart';
import 'package:danaview_features/src/library/library_widgets.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart';
import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../home_shell/home_shell_support.dart';
import '../photos_tab/photo_masonry_layout_test.dart' show synthetic;

/// A fake system library of [assets] (newest first).
class _FakeLibrary implements SystemPhotoLibrary {
  _FakeLibrary(this.assets, {this.albums = const {}});

  final List<SystemPhotoAsset> assets;

  /// Album id -> the ids of its assets.
  final Map<String, Set<String>> albums;
  PhotoLibraryAuthorization status = PhotoLibraryAuthorization.notDetermined;
  int requests = 0;
  int fetches = 0;
  final _changes = StreamController<SystemPhotoChange>.broadcast();
  final _auth = StreamController<PhotoLibraryAuthorization>.broadcast();

  @override
  Future<PhotoLibraryAuthorization> authorizationStatus() async => status;

  @override
  Future<PhotoLibraryAuthorization> requestAuthorization() async {
    requests++;
    if (status == PhotoLibraryAuthorization.notDetermined) status = PhotoLibraryAuthorization.authorized;
    return status;
  }

  @override
  Future<List<String>> presentLimitedLibraryPicker() async => const [];

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<void> startObserving() async {}

  @override
  Future<void> stopObserving() async {}

  @override
  Future<SystemPhotoPage> fetchPage({
    SystemPhotoFilter filter = SystemPhotoFilter.all,
    SystemPhotoSort sort = SystemPhotoSort.creationNewestFirst,
    String? albumId,
    int offset = 0,
    int limit = 200,
    String? changeToken,
  }) async {
    fetches++;
    final list = [
      for (final a in assets)
        if ((filter != SystemPhotoFilter.photos || a.kind == SystemAssetKind.photo) &&
            (albumId == null || (albums[albumId]?.contains(a.localIdentifier) ?? false)))
          a,
    ];
    final start = offset.clamp(0, list.length);
    final end = (start + limit).clamp(0, list.length);
    return SystemPhotoPage(assets: list.sublist(start, end), offset: offset, totalCount: list.length, changeToken: 't1', tokenStale: false);
  }

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> ids) async => const [];

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() async => const [];

  @override
  Future<SystemPhotoDetail> assetDetail(String localIdentifier) async => SystemPhotoDetail(localIdentifier: localIdentifier, locallyAvailable: true);

  @override
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId}) async =>
      SystemPhotoCopy(path: '$destinationDirectory/x', sizeBytes: 1);

  @override
  Future<void> cancelCopy(String requestId) async {}

  @override
  Stream<SystemPhotoChange> get changes => _changes.stream;

  @override
  Stream<PhotoLibraryAuthorization> get authorizationChanges => _auth.stream;
}

SystemPhotoAsset _asset(String id, DateTime created) => SystemPhotoAsset(
      localIdentifier: id,
      kind: SystemAssetKind.photo,
      width: 3024,
      height: 4032,
      createdAt: created,
      modifiedAt: created,
      originalFilename: 'IMG_$id.HEIC',
      mimeType: 'image/heic',
    );

List<Override> _overrides({List<PhotoGridItem> photos = const [], SystemPhotoLibrary? system, SortPreferenceStore? prefs}) => [
      danaviewPhotoItemsProvider.overrideWithValue(photos),
      systemPhotoLibraryProvider.overrideWithValue(system),
      systemPhotosControllerProvider.overrideWith(
        (ref) => SystemPhotosController(library: system, platform: system == null ? null : SystemPhotoPlatform.photoKit),
      ),
      desktopRootResolverProvider.overrideWithValue(null),
      if (prefs != null) sortPreferenceStoreProvider.overrideWithValue(prefs),
    ];

/// The tray on an Overview-like page: library insets, vertical scroll.
Widget _page(Widget tray) => ColoredBox(
      color: DanaviewColors.background,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(slivers: [
            SliverPadding(
              padding: danaviewLibraryInsets(constraints.maxWidth),
              sliver: SliverList.list(children: [tray, const SizedBox(height: 40, child: Text('BELOW'))]),
            ),
          ]),
        ),
      ),
    );

Future<LibraryTestEnv> _pump(
  WidgetTester tester,
  Widget tray, {
  List<PhotoGridItem> photos = const [],
  SystemPhotoLibrary? system,
  SortPreferenceStore? prefs,
  TestSurface surface = const TestSurface(Size(402, 874), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)),
}) async {
  useSurface(tester, surface);
  final env = await LibraryTestEnv.create();
  await tester.pumpWidget(libraryTestApp(
    env,
    _page(tray),
    textScale: surface.textScale,
    overrides: _overrides(photos: photos, system: system, prefs: prefs),
  ));
  await pumpFrames(tester, count: 3);
  expect(tester.takeException(), isNull);
  return env;
}

Finder _tiles() => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('recent-photo-'));

void main() {
  testWidgets('empty: the tray draws nothing', (tester) async {
    useFilesHome(true);
    final env = await _pump(tester, const RecentPhotosTray());
    expect(find.byKey(const ValueKey('recent-photos-tray')), findsNothing);
    expect(find.byKey(const ValueKey('recent-photos-hidden'), skipOffstage: false), findsOneWidget);
    expect(find.text('Recent photos'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('recent-photos-hidden'), skipOffstage: false)).height, 0);
    await finishHome(tester, env);
  });

  testWidgets('few: one tile per photo newest first; tap opens the viewer; See all calls back', (tester) async {
    useFilesHome(true);
    final opened = <(int, int, String)>[];
    var seeAll = 0;
    final photos = synthetic(3);
    final env = await _pump(
      tester,
      RecentPhotosTray(onOpenPhoto: (list, i) => opened.add((list.length, i, list[i].id.value)), onSeeAll: () => seeAll++),
      photos: photos,
    );
    expect(find.byKey(const ValueKey('recent-photos-tray')), findsOneWidget);
    expect(find.text('Recent photos'), findsOneWidget);
    expect(_tiles(), findsNWidgets(3));
    expect(find.byKey(const ValueKey('recent-photos-more')), findsNothing);
    // Newest first, left to right.
    final xs = [for (final p in photos) tester.getTopLeft(find.byKey(ValueKey('recent-photo-${p.id.value}'))).dx];
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    await tester.tap(find.byKey(ValueKey('recent-photo-${photos[1].id.value}')));
    await tester.pump();
    expect(opened, [(3, 1, photos[1].id.value)]);
    await tester.tap(find.byKey(const ValueKey('recent-photos-see-all')));
    await tester.pump();
    expect(seeAll, 1);
    await finishHome(tester, env);
  });

  testWidgets('many: the limit, a "+N See all" tile, sideways scrolling and the whole list to the viewer', (tester) async {
    useFilesHome(true);
    final opened = <(int, int)>[];
    var seeAll = 0;
    final photos = synthetic(50);
    final env = await _pump(
      tester,
      RecentPhotosTray(onOpenPhoto: (list, i) => opened.add((list.length, i)), onSeeAll: () => seeAll++),
      photos: photos,
    );
    final list = find.descendant(of: find.byKey(const ValueKey('recent-photos-tray')), matching: find.byType(Scrollable)).first;
    // Lazily built: only the visible tiles exist.
    expect(_tiles().evaluate().length, lessThan(recentPhotosTrayLimit));
    await tester.tap(find.byKey(ValueKey('recent-photo-${photos[0].id.value}')));
    await tester.pump();
    expect(opened, [(50, 0)]);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('recent-photos-more')), 200, scrollable: list);
    await pumpFrames(tester, count: 2);
    expect(find.text('+${50 - recentPhotosTrayLimit}'), findsOneWidget);
    expect(find.byKey(ValueKey('recent-photo-${photos[recentPhotosTrayLimit - 1].id.value}')), findsOneWidget);
    expect(find.byKey(ValueKey('recent-photo-${photos[recentPhotosTrayLimit].id.value}')), findsNothing);
    expect(find.bySemanticsLabel('See all photos, ${50 - recentPhotosTrayLimit} more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recent-photos-more')));
    await tester.pump();
    expect(seeAll, 1);
    await finishHome(tester, env);
  });

  testWidgets('exactly the limit shows no "See all" tile', (tester) async {
    useFilesHome(true);
    final env = await _pump(tester, const RecentPhotosTray(limit: 4), photos: synthetic(4));
    expect(_tiles(), findsNWidgets(4));
    expect(find.byKey(const ValueKey('recent-photos-more')), findsNothing);
    await finishHome(tester, env);
  });

  testWidgets('See all without a callback asks the Home shell for the Photos tab', (tester) async {
    useFilesHome(true);
    final requests = <HomeTab>[];
    final env = await _pump(
      tester,
      NotificationListener<HomeTabRequestNotification>(
        onNotification: (n) {
          requests.add(n.tab);
          return true;
        },
        child: const RecentPhotosTray(),
      ),
      photos: synthetic(2),
    );
    await tester.tap(find.byKey(const ValueKey('recent-photos-see-all')));
    await tester.pump();
    expect(requests, [HomeTab.photos]);
    await finishHome(tester, env);
  });

  testWidgets('the system library joins only after the opt-in (Q-N8); no access asked before', (tester) async {
    useFilesHome(true);
    final fake = _FakeLibrary([_asset('A', DateTime(2026, 10, 22, 19)), _asset('B', DateTime(2020, 1, 1))]);
    final danaview = synthetic(2, from: DateTime(2026, 10, 22, 18));
    var env = await _pump(tester, const RecentPhotosTray(), photos: danaview, system: fake);
    expect(_tiles(), findsNWidgets(2));
    expect(fake.requests, 0);
    expect(fake.fetches, 0);
    await finishHome(tester, env);

    final prefs = InMemorySortPreferenceStore();
    await prefs.write(photosShowSystemLibraryKey, 'true');
    final opened = <List<PhotoGridItem>>[];
    env = await _pump(tester, RecentPhotosTray(onOpenPhoto: (list, _) => opened.add(list)), photos: danaview, system: fake, prefs: prefs);
    await pumpFrames(tester, count: 3);
    expect(_tiles(), findsNWidgets(4));
    expect(fake.fetches, greaterThan(0));
    // Newest first across sources: the 19:00 system photo leads, the 2020 one trails.
    await tester.tap(_tiles().first);
    await tester.pump();
    expect([for (final p in opened.single) p.origin],
        [PhotoOrigin.system, PhotoOrigin.danaview, PhotoOrigin.danaview, PhotoOrigin.system]);
    expect(find.bySemanticsLabel(RegExp(r'^Photo IMG_A\.HEIC, 22 October 2026$')), findsOneWidget);
    await finishHome(tester, env);
  });

  testWidgets('an album picked on the Photos tab does not narrow the tray (whole library)', (tester) async {
    useFilesHome(true);
    final fake = _FakeLibrary(
      [_asset('A', DateTime(2026, 10, 22, 19)), _asset('B', DateTime(2026, 10, 22, 17)), _asset('C', DateTime(2020, 1, 1))],
      albums: {
        'old': {'C'},
      },
    );
    final prefs = InMemorySortPreferenceStore();
    await prefs.write(photosShowSystemLibraryKey, 'true');
    final danaview = synthetic(1, from: DateTime(2026, 10, 22, 18));
    final env = await _pump(tester, const RecentPhotosTray(), photos: danaview, system: fake, prefs: prefs);
    await pumpFrames(tester, count: 3);
    expect(_tiles(), findsNWidgets(4));

    // The Photos tab's album chip (photos_tab.dart `_selectAlbum`) narrows the shared controller.
    final container = ProviderScope.containerOf(tester.element(find.byType(RecentPhotosTray)));
    await container.read(systemPhotosControllerProvider.notifier).setFilter(SystemPhotoFilter.photos, albumId: 'old');
    await pumpFrames(tester, count: 3);
    expect(container.read(systemPhotosControllerProvider).items.map((i) => i.name), ['IMG_C.HEIC']);
    expect(tester.takeException(), isNull);

    // The tray still shows the newest photos of the whole library, newest first.
    expect(_tiles(), findsNWidgets(4));
    expect(find.bySemanticsLabel(RegExp(r'^Photo IMG_A\.HEIC, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Photo IMG_B\.HEIC, ')), findsOneWidget);
    final first = tester.widget(_tiles().first).key! as ValueKey<String>;
    expect(first.value, 'recent-photo-${systemItemId(_asset('A', DateTime(2026)), SystemPhotoPlatform.photoKit).value}');
    await finishHome(tester, env);
  });

  testWidgets('the "+N" tile counts the whole system library, not only the fetched page', (tester) async {
    useFilesHome(true);
    final fake = _FakeLibrary([for (var i = 0; i < 9; i++) _asset('S$i', DateTime(2026, 10, 22, 12).subtract(Duration(hours: i)))]);
    final prefs = InMemorySortPreferenceStore();
    await prefs.write(photosShowSystemLibraryKey, 'true');
    final env = await _pump(tester, const RecentPhotosTray(limit: 4), photos: synthetic(2, from: DateTime(2020)), system: fake, prefs: prefs);
    await pumpFrames(tester, count: 3);
    final list = find.descendant(of: find.byKey(const ValueKey('recent-photos-tray')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('recent-photos-more')), 200, scrollable: list);
    await pumpFrames(tester, count: 2);
    expect(find.text('+${9 + 2 - 4}'), findsOneWidget);
    await finishHome(tester, env);
  });

  testWidgets('flag off: the tray is absent', (tester) async {
    useFilesHome(false);
    final env = await _pump(tester, const RecentPhotosTray(), photos: synthetic(5));
    expect(find.byKey(const ValueKey('recent-photos-tray')), findsNothing);
    expect(_tiles(), findsNothing);
    expect(find.text('Recent photos'), findsNothing);
    await finishHome(tester, env);
  });

  group('inside the Home', () {
    Widget home() => DanaviewHomeScreen(
          onOpenPlayer: () {},
          onOpenFolder: (_) {},
          onOpenPlaylist: (_) {},
          tabSlots: HomeTabSlots(recentPhotos: (_) => const RecentPhotosTray()),
        );

    Future<LibraryTestEnv> pumpHome(WidgetTester tester) async {
      useSurface(tester, const TestSurface(Size(402, 2400), 1.0));
      final env = await LibraryTestEnv.create();
      await seedFixedLibrary(env);
      await tester.pumpWidget(libraryTestApp(env, home(), overrides: _overrides(photos: synthetic(6))));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
      return env;
    }

    testWidgets('flag off: the 1.1 Home has no tray', (tester) async {
      useFilesHome(false);
      final env = await pumpHome(tester);
      expect(find.byType(RecentPhotosTray), findsNothing);
      expect(find.text('Recent photos'), findsNothing);
      expect(find.text('Continue watching'), findsOneWidget);
      await finishHome(tester, env);
    });

    testWidgets('flag on: the tray sits below Continue watching, above Playlists', (tester) async {
      useFilesHome(true);
      final env = await pumpHome(tester);
      expect(find.byKey(const ValueKey('recent-photos-tray')), findsOneWidget);
      double y(String text) => tester
          .getTopLeft(find.descendant(of: find.byKey(const ValueKey('home-tab-page-home')), matching: find.text(text)).first)
          .dy;
      expect(y('Continue watching'), lessThan(y('Recent photos')));
      expect(y('Recent photos'), lessThan(y('Playlists')));
      await finishHome(tester, env);
    });

    // The shell itself answers the tray's tab request: no listener wraps the Home here.
    for (final (name, tray, key) in [
      ('See all', const RecentPhotosTray(), 'recent-photos-see-all'),
      ('"+N See all"', const RecentPhotosTray(limit: 4), 'recent-photos-more'),
    ]) {
      testWidgets('$name with no onSeeAll opens the Photos tab of the real Home', (tester) async {
        useFilesHome(true);
        useSurface(tester, const TestSurface(Size(402, 2400), 1.0));
        final env = await LibraryTestEnv.create();
        await seedFixedLibrary(env);
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(
            onOpenPlayer: () {},
            onOpenFolder: (_) {},
            onOpenPlaylist: (_) {},
            tabSlots: HomeTabSlots(
              recentPhotos: (_) => tray,
              photos: (_) => const SizedBox.expand(key: ValueKey('photos-tab-body')),
            ),
          ),
          overrides: _overrides(photos: synthetic(6)),
        ));
        await pumpFrames(tester);
        expect(tester.widget<HomeTabHost>(find.byType(HomeTabHost)).selected, HomeTab.home);
        expect(find.byKey(const ValueKey('photos-tab-body')), findsNothing);
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.tap(find.byKey(ValueKey(key)));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(tester.widget<HomeTabHost>(find.byType(HomeTabHost)).selected, HomeTab.photos);
        // The host builds a page only once it is shown, so the Photos body exists only now.
        expect(find.byKey(const ValueKey('photos-tab-body')), findsOneWidget);
        await finishHome(tester, env);
      });
    }
  });

  test('tile extent: about three on a phone, never under 88 px', () {
    expect(recentPhotosTileExtent(248), 88);
    expect(recentPhotosTileExtent(370), closeTo(112, 0.5));
    expect(recentPhotosTileExtent(1200), lessThanOrEqualTo(148));
    expect(recentPhotosTileExtent(double.infinity), 112);
  });

  test('the See all tile text has computed contrast >= 4.5:1', () {
    const fill = DanaviewColors.surfaceElevated;
    expect(DanaviewColors.contrastRatio(DanaviewColors.foregroundOn(fill), fill), greaterThanOrEqualTo(4.5));
  });

  group('matrix 280–1280 px × text scale 0.85–1.35', () {
    for (final surface in homeShellSurfaces) {
      testWidgets('${surface.size.width.toInt()}×${surface.size.height.toInt()} @${surface.textScale}', (tester) async {
        useFilesHome(true);
        final handle = tester.ensureSemantics();
        final env = await _pump(tester, RecentPhotosTray(onOpenPhoto: (_, __) {}, onSeeAll: () {}), photos: synthetic(30), surface: surface);
        expect(tester.takeException(), isNull);
        final tray = tester.getRect(find.byKey(const ValueKey('recent-photos-tray')));
        expect(tray.width, lessThanOrEqualTo(surface.size.width));
        for (final tile in _tiles().evaluate()) {
          final size = tester.getSize(find.byWidget(tile.widget));
          expect(size.width, greaterThanOrEqualTo(44));
          expect(size.height, greaterThanOrEqualTo(44));
        }
        final seeAll = tester.getSize(find.byKey(const ValueKey('recent-photos-see-all')));
        expect(seeAll.height, greaterThanOrEqualTo(44));
        expect(seeAll.width, greaterThanOrEqualTo(44));
        expect(find.bySemanticsLabel(RegExp(r'^Photo IMG_0\.jpg, ')), findsOneWidget);
        final list = find.descendant(of: find.byKey(const ValueKey('recent-photos-tray')), matching: find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(find.byKey(const ValueKey('recent-photos-more')), 300, scrollable: list);
        await pumpFrames(tester, count: 2);
        expect(tester.takeException(), isNull);
        handle.dispose();
        await finishHome(tester, env);
      });
    }
  });
}
