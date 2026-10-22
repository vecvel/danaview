// OWNER: HOM-11
//
// BUILD_PLAN HOM-11, widget half: the fullscreen photo viewer over a real library store and a fake
// system library — opening at the tapped photo, swiping and arrow keys between items, double-tap
// and pinch zoom (page swipes paused while zoomed), a single tap toggling the chrome, Escape and
// Close; the toolbar: Edit calls `onEditPhoto` (from the Home's HomeCallbacksScope) and is hidden
// with a null callback and on desktop, Favourite stars in library.db, Delete moves to Recently
// deleted after the confirmation (and closes on the last photo), File info opens the EXIF sheet,
// Share calls its hook; the Live Photo indicator; Recents recorded; and the layout matrix 280–1280
// px × text scale 0.85–1.35 with ≥ 44 px targets, semantics labels and computed bar contrast
// (ARCH §1.4).

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/home/home_callbacks.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_info.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_actions.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_entry.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_screen.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_zoom_view.dart';
import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'photo_viewer_fixtures.dart';

/// A launcher screen with one button per photo that opens the viewer at it.
Widget _launcher(List<PhotoGridItem> photos, {HomeCallbacks callbacks = HomeCallbacks.none}) => HomeCallbacksScope(
      callbacks: callbacks,
      child: ColoredBox(
        color: DanaviewColors.background,
        child: Builder(
          builder: (context) => Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < photos.length; i++)
                GestureDetector(
                  key: ValueKey('open-$i'),
                  onTap: () => openPhotoViewer(context, photos, i),
                  child: SizedBox(width: 60, height: 30, child: Text('open $i')),
                ),
            ]),
          ),
        ),
      ),
    );

Widget _app(
  LibraryTestEnv env,
  Widget home, {
  LibraryStore? store,
  SystemPhotoLibrary? system,
  PhotoViewerHooks hooks = PhotoViewerHooks.none,
  TargetPlatform platform = TargetPlatform.iOS,
  double textScale = 1.0,
}) =>
    libraryTestApp(
      env,
      home,
      platform: platform,
      textScale: textScale,
      overrides: [
        if (store != null) libraryStoreProvider.overrideWithValue(store),
        systemPhotoLibraryProvider.overrideWithValue(system),
        photoViewerHooksProvider.overrideWithValue(hooks),
      ],
    );

PhotoViewerScreenState _viewer(WidgetTester tester) => tester.state<PhotoViewerScreenState>(find.byType(PhotoViewerScreen));

String _position(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('photo-viewer-position'))).data!;

PhotoZoomViewState _zoom(WidgetTester tester) => tester.state<PhotoZoomViewState>(find.byType(PhotoZoomView).hitTestable().first);

Future<void> _open(WidgetTester tester, int i) async {
  await tester.tap(find.byKey(ValueKey('open-$i')));
  await tester.pumpAndSettle();
}

/// Lets toasts expire so no timer is left pending.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Future<List<PhotoGridItem>> _seed(WidgetTester tester, ViewerLib lib) async {
  await lib.addPhoto(tester, 'one.jpg', DateTime(2026, 10, 3, 9));
  await lib.addPhoto(tester, 'two.heic', DateTime(2026, 10, 2, 9), flags: EntryMeta.flagLive);
  await lib.addPhoto(tester, 'three.dng', DateTime(2026, 10, 1, 9));
  return danaviewItems(lib.store);
}

void main() {
  testWidgets('opens at the tapped photo; swipe, arrow keys, chrome toggle, Escape and Close', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    final photos = await _seed(tester, lib);
    await tester.pumpWidget(_app(env, _launcher(photos), store: lib.store));
    await _open(tester, 1);
    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    expect(_position(tester), '2 of 3');
    expect(tester.widget<Text>(find.byKey(const ValueKey('photo-viewer-name'))).data, 'two.heic');
    // The Live Photo indicator.
    expect(find.byKey(const ValueKey('photo-viewer-live')), findsOneWidget);
    expect(find.bySemanticsLabel('Live Photo'), findsOneWidget);

    // Swipe left: the next photo.
    await tester.drag(find.byKey(const ValueKey('photo-viewer-pages')), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(_position(tester), '3 of 3');
    expect(find.byKey(const ValueKey('photo-viewer-live')), findsNothing);
    // Swipe right twice: back to the first.
    await tester.drag(find.byKey(const ValueKey('photo-viewer-pages')), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('photo-viewer-pages')), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(_position(tester), '1 of 3');
    // No page before the first.
    await tester.drag(find.byKey(const ValueKey('photo-viewer-pages')), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(_position(tester), '1 of 3');

    // Arrow keys.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_position(tester), '2 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_position(tester), '1 of 3');

    // A single tap hides the chrome (bars take no input), another shows it.
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('photo-viewer-pages'))));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(_viewer(tester).chromeVisible, isFalse);
    expect(find.byKey(const ValueKey('photo-viewer-close')).hitTestable(), findsNothing);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('photo-viewer-pages'))));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(_viewer(tester).chromeVisible, isTrue);

    // Escape closes; Close closes.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
    await _open(tester, 2);
    expect(_position(tester), '3 of 3');
    await tester.tap(find.byKey(const ValueKey('photo-viewer-close')));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
    // Every photo shown was recorded in Recents once.
    final recents = lib.store.reader.recents().map((e) => e.displayName).toSet();
    expect(recents, {'one.jpg', 'two.heic', 'three.dng'});

    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('double tap and pinch zoom; page swipes pause while zoomed', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    final photos = await _seed(tester, lib);
    await tester.pumpWidget(_app(env, _launcher(photos), store: lib.store));
    await _open(tester, 0);
    final pages = find.byKey(const ValueKey('photo-viewer-pages'));
    final centre = tester.getCenter(pages);

    // Double tap zooms in at the tapped point.
    await tester.tapAt(centre + const Offset(40, 40));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre + const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(_zoom(tester).scale, closeTo(photoViewerDoubleTapScale, 0.01));
    expect(_viewer(tester).swipeLocked, isTrue);
    // Zoomed: the full-resolution layer of a decodable file loads (read-only) over the thumbnail.
    expect(find.byKey(const ValueKey('photo-viewer-full')), findsOneWidget);
    expect(_viewer(tester).chromeVisible, isTrue, reason: 'a double tap is not a single tap');
    // A drag pans the photo instead of turning the page.
    await tester.drag(pages, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(_position(tester), '1 of 3');
    // Double tap again: back to fit, swipes work again.
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(_zoom(tester).scale, closeTo(1, 0.01));
    expect(_viewer(tester).swipeLocked, isFalse);

    // Pinch out with two fingers.
    final a = await tester.startGesture(centre - const Offset(20, 0), pointer: 7);
    final b = await tester.startGesture(centre + const Offset(20, 0), pointer: 8);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(centre - Offset(20.0 + i * 10, 0));
      await b.moveTo(centre + Offset(20.0 + i * 10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(_zoom(tester).scale, greaterThan(2));
    expect(_viewer(tester).swipeLocked, isTrue);
    expect(_position(tester), '1 of 3');
    // The arrow key still turns the page and the new page starts at fit.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_position(tester), '2 of 3');
    expect(_zoom(tester).scale, closeTo(1, 0.01));
    expect(_viewer(tester).swipeLocked, isFalse);
    // RAW never decodes in Dart: zoomed, it keeps the native thumbnailer's large image only.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('photo-viewer-name'))).data, 'three.dng');
    _zoom(tester).toggleZoom();
    await tester.pumpAndSettle();
    expect(_zoom(tester).isZoomed, isTrue);
    expect(find.byKey(const ValueKey('photo-viewer-full')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('Edit calls onEditPhoto with the photo; hidden with a null callback and on desktop', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    final photos = await _seed(tester, lib);
    final edited = <PhotoMediaItem>[];
    final callbacks = HomeCallbacks(onEditPhoto: edited.add);
    await tester.pumpWidget(_app(env, _launcher(photos, callbacks: callbacks), store: lib.store));
    await _open(tester, 2);
    expect(find.byKey(const ValueKey('photo-viewer-edit')), findsOneWidget);
    expect(find.bySemanticsLabel('Edit'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-viewer-edit')));
    await tester.pumpAndSettle();
    expect(edited.single.id, photos[2].id);
    expect(edited.single.name, 'three.dng');
    expect(edited.single.isRaw, isTrue);
    expect(edited.single.uri, photos[2].thumbSource);

    // No callback: no Edit.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(env, _launcher(photos), store: lib.store));
    await _open(tester, 0);
    expect(find.byKey(const ValueKey('photo-viewer-edit')), findsNothing);
    expect(find.byKey(const ValueKey('photo-viewer-info')), findsOneWidget);

    // Desktop (the editor doesn't run there in 1.2.0): no Edit even with the callback.
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(env, _launcher(photos, callbacks: callbacks), store: lib.store, platform: platform));
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('photo-viewer-edit')), findsNothing, reason: platform.name);
    }
    // Android shows it.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(env, _launcher(photos, callbacks: callbacks), store: lib.store, platform: TargetPlatform.android));
    await _open(tester, 0);
    expect(find.byKey(const ValueKey('photo-viewer-edit')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('Favourite stars in library.db; Delete moves to Recently deleted and closes after the last', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    final photos = await _seed(tester, lib);
    // A project uses the second photo (the V2-08 warning).
    await lib.run(tester, (s) => s.write((w, _) => w.addRef(EntryId.parse(photos[1].id.value), RefHolder.project('p1'))));
    await tester.pumpWidget(_app(env, _launcher(photos), store: lib.store));
    await _open(tester, 0);

    expect(find.bySemanticsLabel('Add to Favourites'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-viewer-favourite')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(EntryId.parse(photos[0].id.value))!.isFavourite, isTrue);
    expect(find.bySemanticsLabel('Remove from Favourites'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-viewer-favourite')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(EntryId.parse(photos[0].id.value))!.isFavourite, isFalse);
    await _drain(tester);

    // Delete the second photo: the confirmation names the project; Cancel keeps it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('photo-viewer-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this photo?'), findsOneWidget);
    expect(find.textContaining('Used in 1 project.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(EntryId.parse(photos[1].id.value))!.isTrashed, isFalse);
    await tester.tap(find.byKey(const ValueKey('photo-viewer-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(EntryId.parse(photos[1].id.value))!.isTrashed, isTrue);
    expect(lib.store.reader.recentlyDeleted().length, 1);
    expect(_position(tester), '2 of 2');
    expect(tester.widget<Text>(find.byKey(const ValueKey('photo-viewer-name'))).data, 'three.dng');
    await _drain(tester);

    // Delete the rest; the viewer closes after the last one.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('photo-viewer-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PhotoViewerScreen), findsNothing);
    expect(lib.store.reader.recentlyDeleted().length, 3);
    await _drain(tester);

    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('File info opens the EXIF sheet; Share and system Delete call their hooks', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final system = FakeViewerSystemLibrary(details: {
      'A1': SystemPhotoDetail(
        localIdentifier: 'A1',
        locallyAvailable: true,
        iso: 64,
        aperture: 1.78,
        exposureSeconds: 1 / 120,
        focalLengthMm: 6.86,
        cameraMake: 'Apple',
        cameraModel: 'iPhone 15 Pro',
        lensModel: 'Back camera 6.86mm f/1.78',
        takenAt: DateTime(2026, 10, 20, 9, 30),
        isLivePhoto: true,
        originalFilename: 'IMG_0042.HEIC',
        sizeBytes: 3100000,
      ),
    });
    final shared = <PhotoViewerEntry>[];
    final deleted = <PhotoViewerEntry>[];
    final hooks = PhotoViewerHooks(
      share: (_, e) async => shared.add(e),
      deleteSystemPhoto: (_, e) async {
        deleted.add(e);
        return true;
      },
    );
    final photos = [systemPhoto('A1', live: true), systemPhoto('B2', name: 'IMG_0002.JPG', mime: 'image/jpeg')];
    await tester.pumpWidget(_app(env, _launcher(photos), system: system, hooks: hooks));
    await _open(tester, 0);
    // No Danaview star for system photos.
    expect(find.byKey(const ValueKey('photo-viewer-favourite')), findsNothing);
    expect(find.byKey(const ValueKey('photo-viewer-live')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('photo-viewer-info')));
    await tester.pumpAndSettle();
    expect(find.text('File info'), findsWidgets);
    expect(find.byKey(const ValueKey('photo-info-rows')), findsOneWidget);
    expect(find.text('Apple iPhone 15 Pro'), findsOneWidget);
    expect(find.text('Back camera 6.86mm f/1.78'), findsOneWidget);
    expect(find.text('1/120 s · ƒ/1.8 · ISO 64 · 6.9 mm'), findsOneWidget);
    expect(find.text('4032 × 3024 · 12.2 MP'), findsOneWidget);
    expect(find.text('3.1 MB'), findsOneWidget);
    expect(find.text('Photo library'), findsOneWidget);
    expect(find.bySemanticsLabel('Taken: 20 October 2026, 09:30'), findsOneWidget);
    expect(find.bySemanticsLabel('Camera: Apple iPhone 15 Pro'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('photo-viewer-share')));
    await tester.pumpAndSettle();
    expect(shared.single.id, photos[0].id);

    await tester.tap(find.byKey(const ValueKey('photo-viewer-delete')));
    await tester.pumpAndSettle();
    expect(deleted.single.id, photos[0].id);
    expect(_position(tester), '1 of 1');
    await _drain(tester);

    await tester.pumpWidget(const SizedBox());
    await env.dispose();
  });

  testWidgets('the Danaview info sheet shows the folder, import source and size', (tester) async {
    useSurface(tester, librarySurfaces[0]);
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    final photos = await _seed(tester, lib);
    await tester.pumpWidget(_app(env, _launcher(photos), store: lib.store));
    await _open(tester, 1);
    await tester.tap(find.byKey(const ValueKey('photo-viewer-info')));
    await tester.pumpAndSettle();
    expect(find.text('Danaview folder · Imported'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('2.05 KB'), findsOneWidget);
    expect(find.text('HEIC · Live Photo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  test('bar contrast is at least 4.5:1 over white and black photos', () {
    for (final photo in const [Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF808080)]) {
      final bar = Color.alphaBlend(photoViewerBarColor, photo);
      for (final fg in const [DanaviewColors.textPrimary, DanaviewColors.textSecondary]) {
        expect(DanaviewColors.contrastRatio(fg, bar), greaterThanOrEqualTo(4.5), reason: '$fg over $photo');
      }
    }
  });

  testWidgets('layout matrix: no overflow at 280–1280 px and text scale 0.85–1.35; 44 px targets; labels', (tester) async {
    final env = await LibraryTestEnv.create();
    final lib = await ViewerLib.open(tester);
    await lib.addPhoto(tester, '${'A very long photo name that keeps going ' * 3}.heic', DateTime(2026, 10, 2, 9), flags: EntryMeta.flagLive);
    await lib.addPhoto(tester, 'b.jpg', DateTime(2026, 10, 1, 9));
    final photos = danaviewItems(lib.store);
    final callbacks = HomeCallbacks(onEditPhoto: (_) {});
    final hooks = PhotoViewerHooks(share: (_, __) async {});
    final handle = tester.ensureSemantics();
    final sizes = [const Size(280, 560), const Size(320, 568), const Size(402, 874), const Size(874, 402), const Size(1280, 800)];
    for (final size in sizes) {
      for (final scale in const [0.85, 1.0, 1.35]) {
        final surface = TestSurface(size, scale, padding: const EdgeInsets.only(top: 20, bottom: 20));
        useSurface(tester, surface);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_app(env, _launcher(photos, callbacks: callbacks), store: lib.store, hooks: hooks, textScale: scale));
        await _open(tester, 0);
        expect(tester.takeException(), isNull, reason: '$surface');
        for (final key in ['close', 'share', 'favourite', 'edit', 'info', 'delete']) {
          final f = find.byKey(ValueKey('photo-viewer-$key'));
          expect(f, findsOneWidget, reason: '$key $surface');
          final box = tester.getSize(f);
          expect(box.width, greaterThanOrEqualTo(44), reason: '$key $surface');
          expect(box.height, greaterThanOrEqualTo(44), reason: '$key $surface');
          final rect = tester.getRect(f);
          expect(rect.left >= 0 && rect.right <= size.width + 0.5, isTrue, reason: '$key on screen $surface');
        }
        for (final label in ['Close', 'Share', 'Add to Favourites', 'Edit', 'File info', 'Delete', 'Live Photo']) {
          expect(find.bySemanticsLabel(label), findsOneWidget, reason: '$label $surface');
        }
        expect(find.bySemanticsLabel(RegExp(r'^Photo A very long photo name.*, 1 of 2$')), findsOneWidget);
        // The info sheet fits too.
        await tester.tap(find.byKey(const ValueKey('photo-viewer-info')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'sheet $surface');
        expect(find.byKey(const ValueKey('photo-info-name')), findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
      }
    }
    handle.dispose();
    await tester.pumpWidget(const SizedBox());
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('an empty list does not open; a lone photo opens at index 0', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env, Builder(builder: (context) {
      return GestureDetector(
        key: const ValueKey('open-empty'),
        onTap: () => openPhotoViewer(context, const [], 0),
        child: const SizedBox(width: 100, height: 100),
      );
    })));
    await tester.tap(find.byKey(const ValueKey('open-empty')));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(env, _launcher([desktopPhoto('/nowhere/beach.jpg')]), platform: TargetPlatform.macOS));
    await _open(tester, 0);
    expect(_position(tester), '1 of 1');
    // Desktop photos: only File info (no star, no delete, no edit).
    expect(find.byKey(const ValueKey('photo-viewer-info')), findsOneWidget);
    for (final key in ['favourite', 'delete', 'edit', 'share']) {
      expect(find.byKey(ValueKey('photo-viewer-$key')), findsNothing, reason: key);
    }
    await tester.pumpWidget(const SizedBox());
    await env.dispose();
  });

  test('photoInfoProvider family keys by grid item', () {
    final container = ProviderContainer(overrides: [systemPhotoLibraryProvider.overrideWithValue(null)]);
    addTearDown(container.dispose);
    final item = desktopPhoto('/p/beach.jpg');
    expect(container.read(photoInfoProvider(item)), isA<AsyncValue<PhotoInfo>>());
  });
}
