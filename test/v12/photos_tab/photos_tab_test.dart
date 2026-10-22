// OWNER: HOM-10
//
// BUILD_PLAN HOM-10, widget half: the Photos tab over a real library store and a fake system
// library — date-group headers and cells, tap opens the viewer callback at the right index, album
// chips (All photos, Favourites, Danaview folders, system albums once shown), the "Show my photo
// library" opt-in (Q-N8: never asks for access until turned on; denied and limited states), a
// 50,000-photo library that builds only the visible cells, the scroll position restored across a
// tab switch, pinch / buttons / keyboard changing the density while keeping the first photo in
// view, and the layout matrix 280–1280 px × text scale 0.85–1.35 with ≥ 44 px targets and
// semantics labels (ARCH §1.4).

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/photos/photo_masonry_layout.dart';
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart';
import 'package:danaview_features/src/library/photos/photos_tab_widgets.dart';
import 'package:danaview_features/src/library/photos/sliver_photo_masonry.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart';
import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_features/src/library/tabs/photos_tab.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'photo_masonry_layout_test.dart' show synthetic;

final DateTime _now = DateTime(2026, 10, 22, 20);

/// A fake system library of [assets] (newest first) and [albums].
class _FakeLibrary implements SystemPhotoLibrary {
  _FakeLibrary(this.assets, {this.status = PhotoLibraryAuthorization.notDetermined, this.albums = const []});

  final List<SystemPhotoAsset> assets;
  PhotoLibraryAuthorization status;
  final List<SystemPhotoAlbum> albums;
  int requests = 0;
  int settingsCalls = 0;
  int pickerCalls = 0;
  final List<String?> albumFetches = [];
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
  Future<List<String>> presentLimitedLibraryPicker() async {
    pickerCalls++;
    return const [];
  }

  @override
  Future<bool> openAppSettings() async {
    settingsCalls++;
    return true;
  }

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
    albumFetches.add(albumId);
    final list = [
      for (final a in assets)
        if ((filter != SystemPhotoFilter.videos || a.kind == SystemAssetKind.video) &&
            (filter != SystemPhotoFilter.photos || a.kind == SystemAssetKind.photo) &&
            (albumId == null || a.localIdentifier.startsWith(albumId)))
          a,
    ];
    final start = offset.clamp(0, list.length);
    final end = (start + limit).clamp(0, list.length);
    return SystemPhotoPage(assets: list.sublist(start, end), offset: offset, totalCount: list.length, changeToken: 't1', tokenStale: false);
  }

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> ids) async => const [];

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() async => albums;

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

SystemPhotoAsset _asset(String id, DateTime created, {SystemAssetKind kind = SystemAssetKind.photo}) => SystemPhotoAsset(
      localIdentifier: id,
      kind: kind,
      width: 3024,
      height: 4032,
      createdAt: created,
      modifiedAt: created,
      originalFilename: 'IMG_$id.HEIC',
      mimeType: 'image/heic',
    );

/// An in-process store in a temp dir.
class _Lib {
  _Lib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<_Lib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom10_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return _Lib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  Future<FileEntry> addPhoto(WidgetTester tester, String name, DateTime taken, {FolderId? folder, int w = 4032, int h = 3024}) =>
      run(tester, (s) => s.write((wr, now) {
            final job = wr.beginImport(target: folder, now: now);
            (wr.fs.openPart(job.id)..writeFromSync(const [1, 2, 3])).closeSync();
            return wr.commitImport(
              job.id,
              ImportedFileInfo(displayName: name, kind: FileKind.photo, modifiedAt: taken, meta: EntryMeta(width: w, height: h, takenAt: taken)),
              now: now,
            );
          }));

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
  }
}

/// Switches between the Photos tab and another tab (the tab host disposes the hidden tab).
class _TabSwitcher extends StatefulWidget {
  const _TabSwitcher({super.key, required this.photos});

  final Widget photos;

  @override
  State<_TabSwitcher> createState() => _TabSwitcherState();
}

class _TabSwitcherState extends State<_TabSwitcher> {
  bool showPhotos = true;

  void toggle() => setState(() => showPhotos = !showPhotos);

  @override
  Widget build(BuildContext context) => showPhotos ? widget.photos : const ColoredBox(key: ValueKey('other-tab'), color: DanaviewColors.background);
}

Widget _app(
  LibraryTestEnv env,
  Widget body, {
  LibraryStore? store,
  SystemPhotoLibrary? system,
  SortPreferenceStore? prefs,
  List<PhotoGridItem>? photos,
  double textScale = 1.0,
}) =>
    libraryTestApp(
      env,
      ColoredBox(color: DanaviewColors.background, child: SafeArea(child: body)),
      textScale: textScale,
      overrides: [
        if (store != null) libraryStoreProvider.overrideWithValue(store),
        if (photos != null) danaviewPhotoItemsProvider.overrideWithValue(photos),
        systemPhotoLibraryProvider.overrideWithValue(system),
        systemPhotosControllerProvider.overrideWith((ref) => SystemPhotosController(library: system, platform: system == null ? null : SystemPhotoPlatform.photoKit)),
        desktopRootResolverProvider.overrideWithValue(null),
        photosTabClockProvider.overrideWithValue(() => _now),
        if (prefs != null) sortPreferenceStoreProvider.overrideWithValue(prefs),
      ],
    );

ScrollPosition _gridPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('photos-grid')), matching: find.byType(Scrollable)).first).position;

RenderSliverPhotoMasonry _sliver(WidgetTester tester) => tester.renderObject<RenderSliverPhotoMasonry>(find.byType(SliverPhotoMasonry));

void main() {
  testWidgets('Danaview photos group by date; a tap opens the viewer at that photo', (tester) async {
    useSurface(tester, librarySurfaces[4]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    await lib.addPhoto(tester, 'today.jpg', DateTime(2026, 10, 22, 9));
    await lib.addPhoto(tester, 'yesterday.jpg', DateTime(2026, 10, 21, 9), w: 1080, h: 1920);
    await lib.addPhoto(tester, 'month.jpg', DateTime(2026, 10, 2, 9));
    await lib.addPhoto(tester, 'august.jpg', DateTime(2026, 8, 2, 9));
    await lib.addPhoto(tester, 'old.jpg', DateTime(2024, 3, 2, 9));
    final opened = <(int, int)>[];
    await tester.pumpWidget(_app(env, PhotosTab(onOpenPhoto: (photos, i) => opened.add((photos.length, i))), store: lib.store));
    await pumpFrames(tester, count: 2);
    expect(tester.takeException(), isNull);
    for (final label in ['Today', 'Yesterday', 'This month', 'August', 'March 2024']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.bySemanticsLabel(RegExp(r'^Photo yesterday\.jpg, 21 October 2026$')), findsOneWidget);
    // No system library on this device: no opt-in row.
    expect(find.byKey(const ValueKey('photos-show-library')), findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Photo month\.jpg')));
    await tester.pump();
    expect(opened, [(5, 2)]);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('an empty library shows the empty state', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env, const PhotosTab()));
    await pumpFrames(tester, count: 2);
    expect(find.byKey(const ValueKey('photos-empty')), findsOneWidget);
    expect(find.text('No photos yet'), findsOneWidget);
    expect(find.byType(SliverPhotoMasonry), findsNothing);
    await env.dispose();
  });

  testWidgets('album chips: Favourites and each Danaview folder holding photos', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final trips = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('Trips', now: now)));
    await lib.run(tester, (s) => s.write((w, now) => w.createFolder('Empty folder', now: now)));
    final a = await lib.addPhoto(tester, 'a.jpg', DateTime(2026, 10, 22, 9));
    await lib.addPhoto(tester, 'b.jpg', DateTime(2026, 10, 22, 8), folder: trips);
    await lib.addPhoto(tester, 'c.jpg', DateTime(2026, 10, 22, 7), folder: trips);
    await lib.run(tester, (s) => s.write((w, now) => w.setEntryFavourite(a.id, true)));
    await tester.pumpWidget(_app(env, const PhotosTab(), store: lib.store));
    await pumpFrames(tester, count: 2);
    expect(find.byType(PhotoGridCell), findsNWidgets(3));
    expect(find.byKey(ValueKey('photos-album-${trips.value}')), findsOneWidget);
    expect(find.text('Empty folder'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('photos-album-favourites')));
    await pumpFrames(tester, count: 2);
    expect(find.byType(PhotoGridCell), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Photo a\.jpg')), findsOneWidget);

    await tester.ensureVisible(find.byKey(ValueKey('photos-album-${trips.value}')));
    await tester.tap(find.byKey(ValueKey('photos-album-${trips.value}')));
    await pumpFrames(tester, count: 2);
    expect(find.byType(PhotoGridCell), findsNWidgets(2));
    expect(find.bySemanticsLabel(RegExp(r'^Photo a\.jpg')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('photos-album-all')));
    await tester.tap(find.byKey(const ValueKey('photos-album-all')));
    await pumpFrames(tester, count: 2);
    expect(find.byType(PhotoGridCell), findsNWidgets(3));
    await lib.close(tester);
    await env.dispose();
  });

  group('Show my photo library (Q-N8)', () {
    testWidgets('off by default: Danaview photos only and access is never asked', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final fake = _FakeLibrary([_asset('S1', DateTime(2026, 10, 22, 12))]);
      await tester.pumpWidget(_app(env, const PhotosTab(), system: fake, photos: synthetic(3)));
      await pumpFrames(tester, count: 3);
      expect(find.byKey(const ValueKey('photos-show-library')), findsOneWidget);
      expect(find.text('Show my photo library'), findsOneWidget);
      expect(fake.requests, 0);
      expect(fake.albumFetches, isEmpty);
      expect(find.byType(PhotoGridCell), findsNWidgets(3));
      await env.dispose();
    });

    testWidgets('turning it on asks once, merges system photos and adds the system albums', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final prefs = InMemorySortPreferenceStore();
      final fake = _FakeLibrary(
        [
          _asset('FAV-1', DateTime(2026, 10, 22, 19)),
          _asset('FAV-2', DateTime(2026, 10, 20, 12)),
          _asset('V-1', DateTime(2026, 10, 20, 11), kind: SystemAssetKind.video),
          _asset('S-3', DateTime(2026, 9, 2, 12)),
        ],
        albums: const [
          SystemPhotoAlbum(albumId: 'FAV', title: 'Favorites', kind: SystemAlbumKind.smart, estimatedCount: 2),
          SystemPhotoAlbum(albumId: 'EMPTY', title: 'Bursts', kind: SystemAlbumKind.smart, estimatedCount: 0),
        ],
      );
      await tester.pumpWidget(_app(env, const PhotosTab(), system: fake, photos: synthetic(2, from: DateTime(2026, 10, 22, 18)), prefs: prefs));
      await pumpFrames(tester, count: 2);
      await tester.tap(find.byKey(const ValueKey('photos-show-library')));
      await pumpFrames(tester, count: 4);
      expect(fake.requests, 1);
      expect(prefs.read(photosShowSystemLibraryKey), 'true');
      // 2 Danaview + 3 system photos (the video is not a photo).
      expect(find.byType(PhotoGridCell), findsNWidgets(5));
      expect(find.byKey(const ValueKey('photos-album-system-FAV')), findsOneWidget);
      expect(find.text('Bursts'), findsNothing, reason: 'empty albums are left out');

      await tester.ensureVisible(find.byKey(const ValueKey('photos-album-system-FAV')));
      await tester.tap(find.byKey(const ValueKey('photos-album-system-FAV')));
      await pumpFrames(tester, count: 4);
      expect(fake.albumFetches.last, 'FAV');
      expect(find.byType(PhotoGridCell), findsNWidgets(2));

      await tester.ensureVisible(find.byKey(const ValueKey('photos-album-all')));
      await tester.tap(find.byKey(const ValueKey('photos-album-all')));
      await pumpFrames(tester, count: 4);
      expect(fake.albumFetches.last, isNull);
      expect(find.byType(PhotoGridCell), findsNWidgets(5));

      // Turning it off hides the system photos and albums again.
      await tester.tap(find.byKey(const ValueKey('photos-show-library')));
      await pumpFrames(tester, count: 3);
      expect(prefs.read(photosShowSystemLibraryKey), isNull);
      expect(find.byType(PhotoGridCell), findsNWidgets(2));
      expect(find.byKey(const ValueKey('photos-album-system-FAV')), findsNothing);
      await env.dispose();
    });

    testWidgets('remembered opt-in with denied access offers Settings; limited offers Manage selection', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final prefs = InMemorySortPreferenceStore();
      await prefs.write(photosShowSystemLibraryKey, 'true');
      final denied = _FakeLibrary(const [], status: PhotoLibraryAuthorization.denied);
      await tester.pumpWidget(_app(env, const PhotosTab(), system: denied, photos: synthetic(2), prefs: prefs));
      await pumpFrames(tester, count: 4);
      expect(find.byKey(const ValueKey('photos-open-settings')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('photos-open-settings')));
      await pumpFrames(tester, count: 2);
      expect(denied.settingsCalls, 1);
      expect(find.byType(PhotoGridCell), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
      final limited = _FakeLibrary([_asset('L1', DateTime(2026, 10, 1))], status: PhotoLibraryAuthorization.limited);
      await tester.pumpWidget(_app(env, const PhotosTab(), system: limited, photos: synthetic(2), prefs: prefs));
      await pumpFrames(tester, count: 4);
      expect(find.byKey(const ValueKey('photos-manage-selection')), findsOneWidget);
      expect(find.byType(PhotoGridCell), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('photos-manage-selection')));
      await pumpFrames(tester, count: 2);
      expect(limited.pickerCalls, 1);
      await env.dispose();
    });
  });

  testWidgets('50,000 photos: only the visible cells are built, and a jump to the end is cheap', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final photos = synthetic(50000, step: const Duration(minutes: 37));
    await tester.pumpWidget(_app(env, const PhotosTab(), photos: photos));
    await pumpFrames(tester, count: 2);
    expect(tester.takeException(), isNull);
    final built = find.byType(PhotoGridCell, skipOffstage: false).evaluate().length;
    expect(built, greaterThan(10));
    expect(built, lessThan(150), reason: 'only the viewport and its cache extent');
    final position = _gridPosition(tester);
    expect(position.maxScrollExtent, greaterThan(500000));
    final sw = Stopwatch()..start();
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    sw.stop();
    expect(tester.takeException(), isNull);
    expect(find.byType(PhotoGridCell, skipOffstage: false).evaluate().length, lessThan(150));
    expect(find.bySemanticsLabel(RegExp('^Photo IMG_49999\\.jpg')), findsOneWidget);
    // ignore: avoid_print
    print('HOM-10 50k jump-to-end frame: ${sw.elapsedMicroseconds} µs (test mode)');
    // Fling back up for a while: no exceptions, the cell count stays bounded.
    await tester.fling(find.byKey(const ValueKey('photos-grid')), const Offset(0, 3000), 6000);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(PhotoGridCell, skipOffstage: false).evaluate().length, lessThan(150));
    }
    expect(tester.takeException(), isNull);
    await env.dispose();
  });

  testWidgets('the scroll position is restored across a tab switch', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final switcher = GlobalKey<_TabSwitcherState>();
    await tester.pumpWidget(_app(env, _TabSwitcher(key: switcher, photos: const PhotosTab()), photos: synthetic(2000)));
    await pumpFrames(tester, count: 2);
    await tester.drag(find.byKey(const ValueKey('photos-grid')), const Offset(0, -3000));
    await tester.pumpAndSettle();
    final offset = _gridPosition(tester).pixels;
    expect(offset, greaterThan(1000));
    final visibleBefore = {
      for (final e in find.byType(PhotoGridCell).hitTestable().evaluate()) (e.widget as PhotoGridCell).photo.id.value,
    };

    switcher.currentState!.toggle();
    await pumpFrames(tester, count: 2);
    expect(find.byType(PhotosTab), findsNothing);
    expect(find.byKey(const ValueKey('other-tab')), findsOneWidget);

    switcher.currentState!.toggle();
    await pumpFrames(tester, count: 2);
    expect(_gridPosition(tester).pixels, closeTo(offset, 0.5));
    final visibleAfter = {
      for (final e in find.byType(PhotoGridCell).hitTestable().evaluate()) (e.widget as PhotoGridCell).photo.id.value,
    };
    expect(visibleAfter, visibleBefore);
    await env.dispose();
  });

  testWidgets('pinch, the density buttons and Ctrl +/- change the columns and keep the first photo in view', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env, const PhotosTab(), photos: synthetic(3000)));
    await pumpFrames(tester, count: 2);
    final defaultColumns = _sliver(tester).masonry.columns;
    _gridPosition(tester).jumpTo(20000);
    await pumpFrames(tester, count: 2);

    int? firstVisible() {
      final layout = _sliver(tester).masonry;
      final grid = _gridPosition(tester);
      final start = _sliver(tester).constraints.precedingScrollExtent;
      final r = layout.visibleRange(grid.pixels - start, grid.pixels - start + 1)!;
      for (var i = r.$1; i < layout.childCount; i++) {
        if (!layout.isHeader(i)) return layout.photoOf(i);
      }
      return null;
    }

    final anchor = firstVisible()!;
    final centre = tester.getCenter(find.byKey(const ValueKey('photos-grid')));
    // Pinch out: larger photos, fewer columns.
    final a = await tester.startGesture(centre - const Offset(30, 0));
    final b = await tester.startGesture(centre + const Offset(30, 0));
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await pumpFrames(tester, count: 3);
    final larger = _sliver(tester).masonry.columns;
    expect(larger, lessThan(defaultColumns));
    final afterPinch = firstVisible()!;
    expect((afterPinch - anchor).abs(), lessThanOrEqualTo(defaultColumns * 2), reason: 'the first visible photo stays in place');
    final cell = find.byWidgetPredicate((w) => w is PhotoGridCell && w.photo == synthetic(3000)[anchor]);
    expect(cell, findsOneWidget);

    // Pinch in: smaller photos, more columns.
    final c = await tester.startGesture(centre - const Offset(80, 0));
    final d = await tester.startGesture(centre + const Offset(80, 0));
    await c.moveBy(const Offset(50, 0));
    await d.moveBy(const Offset(-50, 0));
    await tester.pump();
    await c.up();
    await d.up();
    await pumpFrames(tester, count: 3);
    expect(_sliver(tester).masonry.columns, greaterThan(larger));

    // The buttons step one level each way and disable at the ends.
    final before = _sliver(tester).masonry.columns;
    await tester.tap(find.byKey(const ValueKey('photos-density-smaller')));
    await pumpFrames(tester, count: 2);
    expect(_sliver(tester).masonry.columns, greaterThanOrEqualTo(before));
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('photos-density-smaller')));
      await pumpFrames(tester, count: 1);
    }
    int density() => ProviderScope.containerOf(tester.element(find.byType(PhotosTab))).read(photosTabMemoryProvider).density;
    expect(density(), photoGridDensityTargets.length - 1);
    expect(find.byKey(const ValueKey('photos-density-smaller')), findsOneWidget);
    final densest = _sliver(tester).masonry.columns;
    expect(densest, photoGridColumnsFor(402 - 2 * 12, photoGridDensityTargets.length - 1));

    // Ctrl + = enlarges again (desktop).
    tester.widget<Focus>(find.byKey(const ValueKey('photos-tab-focus'))).focusNode!.requestFocus();
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await pumpFrames(tester, count: 2);
    }
    expect(density(), photoGridDensityTargets.length - 3);
    expect(_sliver(tester).masonry.columns, lessThan(densest));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await pumpFrames(tester, count: 2);
    expect(density(), photoGridDensityTargets.length - 2);
    expect(tester.takeException(), isNull);
    await env.dispose();
  });

  group('layout matrix', () {
    for (final scale in [0.85, 1.0, 1.35]) {
      for (final size in const [Size(280, 653), Size(320, 568), Size(375, 667), Size(768, 1024), Size(874, 402), Size(1280, 800)]) {
        final surface = TestSurface(size, scale);
        testWidgets('fits at $surface', (tester) async {
          useSurface(tester, surface);
          final env = await LibraryTestEnv.create();
          final lib = await _Lib.open(tester);
          final folder = await lib.run(tester, (s) => s.write((w, now) => w.createFolder(longTitle, now: now)));
          await lib.addPhoto(tester, '$longTitle.jpg', DateTime(2026, 10, 22, 9), folder: folder, w: 6000, h: 1000);
          await lib.addPhoto(tester, 'tall.jpg', DateTime(2026, 10, 21, 9), w: 1000, h: 6000);
          for (var i = 0; i < 40; i++) {
            await lib.addPhoto(tester, 'p$i.jpg', DateTime(2026, 9 - i % 3, 1 + i % 27, 9), w: i.isEven ? 1920 : 1080, h: i.isEven ? 1080 : 1920);
          }
          final prefs = InMemorySortPreferenceStore();
          await prefs.write(photosShowSystemLibraryKey, 'true');
          final denied = _FakeLibrary(const [], status: PhotoLibraryAuthorization.denied);
          await tester.pumpWidget(_app(env, const PhotosTab(), store: lib.store, system: denied, prefs: prefs, textScale: scale));
          await pumpFrames(tester, count: 4);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('photos-open-settings')), findsOneWidget);
          for (final key in ['photos-density-smaller', 'photos-density-larger', 'photos-show-library', 'photos-open-settings']) {
            final box = tester.getSize(find.byKey(ValueKey(key)));
            expect(box.height, greaterThanOrEqualTo(44), reason: key);
            expect(box.width, greaterThanOrEqualTo(44), reason: key);
          }
          for (final key in ['photos-album-all', 'photos-album-favourites', 'photos-album-${folder.value}']) {
            expect(tester.getSize(find.byKey(ValueKey(key))).height, greaterThanOrEqualTo(44), reason: key);
          }
          for (final e in find.byType(PhotoGridCell).evaluate()) {
            final s = (e.renderObject! as RenderBox).size;
            expect(s.width, greaterThanOrEqualTo(44));
            expect(s.height, greaterThanOrEqualTo(44));
          }
          // The grid fits the width (no horizontal overflow).
          final layout = _sliver(tester).masonry;
          for (var i = 0; i < layout.childCount; i++) {
            expect(layout.leftOf(i) + layout.widthOf(i), lessThanOrEqualTo(size.width + 0.01));
          }
          expect(find.bySemanticsLabel(RegExp(r'^Photo ')), findsWidgets);
          expect(find.bySemanticsLabel('Show smaller photos'), findsOneWidget);
          expect(find.bySemanticsLabel('Show larger photos'), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp(r'^Today, 1 photo$')), findsOneWidget);
          // Scroll to the end: every header and cell lays out without overflow.
          _gridPosition(tester).jumpTo(_gridPosition(tester).maxScrollExtent);
          await pumpFrames(tester, count: 2);
          expect(tester.takeException(), isNull);
          await lib.close(tester);
          await env.dispose();
        });
      }
    }
  });
}
