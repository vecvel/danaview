// OWNER: HOM-11
//
// Fixtures of the photo viewer tests (BUILD_PLAN HOM-11): an in-process library store in a temp
// directory, a fake system photo library whose `assetDetail` answers with set EXIF, and grid items
// for system and desktop photos.

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-process store in a temp dir.
class ViewerLib {
  ViewerLib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<ViewerLib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom11_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return ViewerLib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  /// Imports a photo named [name] taken at [taken].
  Future<FileEntry> addPhoto(
    WidgetTester tester,
    String name,
    DateTime taken, {
    int w = 4032,
    int h = 3024,
    int flags = 0,
    String? camera,
    SourceHint hint = SourceHint.photos,
  }) =>
      run(tester, (s) => s.write((wr, now) {
            final job = wr.beginImport(now: now);
            (wr.fs.openPart(job.id)..writeFromSync(List<int>.filled(2048, 7))).closeSync();
            return wr.commitImport(
              job.id,
              ImportedFileInfo(
                displayName: name,
                kind: FileKind.photo,
                modifiedAt: taken,
                sourceHint: hint,
                meta: EntryMeta(width: w, height: h, takenAt: taken, camera: camera, flags: flags),
              ),
              now: now,
            );
          }));

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() async {
      await store.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  }
}

/// The Danaview photos of [store] as grid items, newest first.
List<PhotoGridItem> danaviewItems(LibraryStore store) {
  final entries = store.reader.entriesPage(const EntryQuery(kinds: {FileKind.photo}, sort: EntrySortKey.modifiedAt), limit: 500);
  final out = [
    for (final e in entries)
      PhotoGridItem(
        id: e.id,
        origin: PhotoOrigin.danaview,
        name: e.displayName,
        date: store.reader.meta(e.id)?.takenAt ?? e.modifiedAt,
        modifiedAt: e.modifiedAt,
        thumbSource: store.paths.entryFile(e.id, e.displayName),
        width: store.reader.meta(e.id)?.width ?? 0,
        height: store.reader.meta(e.id)?.height ?? 0,
        folderId: e.folderId,
        isFavourite: e.isFavourite,
      ),
  ]..sort((a, b) => b.date.compareTo(a.date));
  return out;
}

/// A system (PhotoKit) photo grid item.
PhotoGridItem systemPhoto(String localId, {bool live = false, bool raw = false, String name = 'IMG_0001.HEIC', String mime = 'image/heic'}) {
  final t = DateTime(2026, 10, 20, 9, 30);
  final media = PhotoMediaItem(
    id: PhotoKitId.of(localId),
    uri: 'ph://$localId',
    name: name,
    modifiedAt: t,
    mimeType: mime,
    sizeBytes: 2400000,
    width: 4032,
    height: 3024,
    isLivePhoto: live,
    isRaw: raw,
    takenAt: t,
  );
  return photoGridItemOf(media, PhotoOrigin.system);
}

/// A desktop Pictures photo grid item at [path].
PhotoGridItem desktopPhoto(String path, {String name = 'beach.jpg'}) {
  final t = DateTime(2026, 9, 1, 12);
  final media = PhotoMediaItem(
    id: LinkedItemId.of('pictures', name),
    uri: path,
    name: name,
    modifiedAt: t,
    mimeType: 'image/jpeg',
    sizeBytes: 812000,
    width: 1600,
    height: 1200,
    iso: 200,
    aperture: 2.8,
    cameraModel: 'X100V',
    takenAt: t,
  );
  return photoGridItemOf(media, PhotoOrigin.desktop);
}

/// A fake system library answering `assetDetail` from [details].
class FakeViewerSystemLibrary implements SystemPhotoLibrary {
  FakeViewerSystemLibrary({this.details = const {}});

  final Map<String, SystemPhotoDetail> details;
  final List<String> detailRequests = [];

  @override
  Future<SystemPhotoDetail> assetDetail(String localIdentifier) async {
    detailRequests.add(localIdentifier);
    final d = details[localIdentifier];
    if (d == null) throw const LibraryNativeException(LibraryNativeErrorCode.notFound, 'missing');
    return d;
  }

  @override
  Future<PhotoLibraryAuthorization> authorizationStatus() async => PhotoLibraryAuthorization.authorized;

  @override
  Future<PhotoLibraryAuthorization> requestAuthorization() async => PhotoLibraryAuthorization.authorized;

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
  }) async =>
      SystemPhotoPage(assets: const [], offset: offset, totalCount: 0, changeToken: 't', tokenStale: false);

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> ids) async => const [];

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() async => const [];

  @override
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId}) async =>
      SystemPhotoCopy(path: '$destinationDirectory/x', sizeBytes: 1);

  @override
  Future<void> cancelCopy(String requestId) async {}

  @override
  Stream<SystemPhotoChange> get changes => const Stream.empty();

  @override
  Stream<PhotoLibraryAuthorization> get authorizationChanges => const Stream.empty();
}
