// OWNER: HOM-02
//
// The system photo library source of the Photos tab (BUILD_PLAN HOM-02; ARCH v1.2 V2-09, V2-103,
// V2-111) over a fake SystemPhotoLibrary: assets map to PhotoMediaItem / VideoMediaItem with
// ph: / ms: ids, access is asked only when the tab's system view opens, limited and denied access,
// paging with change tokens, and change events (insert, delete, in-place, non-incremental).
//
// The root package has no direct dependency on danaview_library or danaview_library_native (they
// arrive through danaview_features), so this test imports them transitively.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

SystemPhotoAsset _asset(String id, {SystemAssetKind kind = SystemAssetKind.photo, int t = 0, bool favorite = false}) => SystemPhotoAsset(
      localIdentifier: id,
      kind: kind,
      width: 4032,
      height: 3024,
      createdAt: DateTime.utc(2024, 1, 1).add(Duration(minutes: t)),
      modifiedAt: DateTime.utc(2024, 1, 2).add(Duration(minutes: t)),
      duration: kind == SystemAssetKind.video ? const Duration(seconds: 12) : Duration.zero,
      isFavorite: favorite,
      originalFilename: kind == SystemAssetKind.video ? 'clip_$id.mov' : 'IMG_$id.HEIC',
      mimeType: kind == SystemAssetKind.video ? 'video/quicktime' : 'image/heic',
    );

/// A fake library: [assets] newest first, a generation token, and controllable events.
class FakePhotoLibrary implements SystemPhotoLibrary {
  FakePhotoLibrary(this.assets, {this.status = PhotoLibraryAuthorization.notDetermined, this.grant = PhotoLibraryAuthorization.authorized});

  List<SystemPhotoAsset> assets;
  PhotoLibraryAuthorization status;
  final PhotoLibraryAuthorization grant;
  int generation = 1;
  int requests = 0;
  int pageCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int pickerCalls = 0;
  final changeEvents = StreamController<SystemPhotoChange>.broadcast();
  final authEvents = StreamController<PhotoLibraryAuthorization>.broadcast();
  LibraryNativeException? failWith;

  String get token => 'g$generation';

  /// Replaces the library and moves the token (what a native insert or delete does).
  void mutate(List<SystemPhotoAsset> next) {
    assets = next;
    generation++;
  }

  @override
  Future<PhotoLibraryAuthorization> authorizationStatus() async {
    if (failWith != null) throw failWith!;
    return status;
  }

  @override
  Future<PhotoLibraryAuthorization> requestAuthorization() async {
    requests++;
    if (status == PhotoLibraryAuthorization.notDetermined) status = grant;
    return status;
  }

  @override
  Future<List<String>> presentLimitedLibraryPicker() async {
    pickerCalls++;
    return [for (final a in assets) a.localIdentifier];
  }

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<void> startObserving() async => startCalls++;

  @override
  Future<void> stopObserving() async => stopCalls++;

  @override
  Future<SystemPhotoPage> fetchPage({
    SystemPhotoFilter filter = SystemPhotoFilter.all,
    SystemPhotoSort sort = SystemPhotoSort.creationNewestFirst,
    String? albumId,
    int offset = 0,
    int limit = 200,
    String? changeToken,
  }) async {
    pageCalls++;
    if (!status.canRead) throw const LibraryNativeException(LibraryNativeErrorCode.permissionDenied, 'no access');
    final list = assets.where((a) => switch (filter) {
          SystemPhotoFilter.all => true,
          SystemPhotoFilter.photos => a.kind == SystemAssetKind.photo,
          SystemPhotoFilter.videos => a.kind == SystemAssetKind.video,
        }).toList();
    final start = offset.clamp(0, list.length);
    final end = (start + limit).clamp(0, list.length);
    return SystemPhotoPage(
      assets: list.sublist(start, end),
      offset: offset,
      totalCount: list.length,
      changeToken: token,
      tokenStale: changeToken != null && changeToken != token,
    );
  }

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> ids) async => [
        for (final id in ids)
          ...assets.where((a) => a.localIdentifier == id),
      ];

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() async => const [];

  @override
  Future<SystemPhotoDetail> assetDetail(String localIdentifier) async =>
      SystemPhotoDetail(localIdentifier: localIdentifier, locallyAvailable: true);

  @override
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId}) async =>
      SystemPhotoCopy(path: '$destinationDirectory/x', sizeBytes: 1);

  @override
  Future<void> cancelCopy(String requestId) async {}

  @override
  Stream<SystemPhotoChange> get changes => changeEvents.stream;

  @override
  Stream<PhotoLibraryAuthorization> get authorizationChanges => authEvents.stream;
}

List<SystemPhotoAsset> _library(int n) => [for (var i = n; i > 0; i--) _asset('A$i/L0/001', kind: i % 5 == 0 ? SystemAssetKind.video : SystemAssetKind.photo, t: i)];

void main() {
  group('systemPhotoPlatformFor', () {
    test('PhotoKit on iOS and macOS, MediaStore on Android, none elsewhere', () {
      expect(systemPhotoPlatformFor(TargetPlatform.iOS, isWeb: false), SystemPhotoPlatform.photoKit);
      expect(systemPhotoPlatformFor(TargetPlatform.macOS, isWeb: false), SystemPhotoPlatform.photoKit);
      expect(systemPhotoPlatformFor(TargetPlatform.android, isWeb: false), SystemPhotoPlatform.mediaStore);
      expect(systemPhotoPlatformFor(TargetPlatform.windows, isWeb: false), isNull);
      expect(systemPhotoPlatformFor(TargetPlatform.linux, isWeb: false), isNull);
      expect(systemPhotoPlatformFor(TargetPlatform.iOS, isWeb: true), isNull);
    });
  });

  group('systemMediaItem', () {
    test('a PhotoKit photo becomes a PhotoMediaItem with a ph: id', () {
      final asset = SystemPhotoAsset(
        localIdentifier: 'ABC-123/L0/001',
        kind: SystemAssetKind.photo,
        width: 6000,
        height: 4000,
        createdAt: DateTime.utc(2024, 5, 6),
        modifiedAt: DateTime.utc(2024, 5, 7),
        isRaw: true,
        isHdr: true,
        isLivePhoto: true,
        originalFilename: 'IMG_0001.DNG',
        mimeType: 'image/x-adobe-dng',
        sizeBytes: 25000000,
      );
      final item = systemMediaItem(asset, SystemPhotoPlatform.photoKit) as PhotoMediaItem;
      expect(item.id, PhotoKitId.of('ABC-123/L0/001'));
      expect(item.id.namespace, IdNamespace.photoKit);
      expect(item.uri, 'ph://ABC-123/L0/001');
      expect(item.name, 'IMG_0001.DNG');
      expect((item.width, item.height), (6000, 4000));
      expect([item.isRaw, item.isHdr, item.isLivePhoto], [true, true, true]);
      expect(item.takenAt, DateTime.utc(2024, 5, 6));
      expect(item.modifiedAt, DateTime.utc(2024, 5, 7));
      expect(item.mimeType, 'image/x-adobe-dng');
      expect(item.sizeBytes, 25000000);
      expect(item.megapixels, 24);
    });

    test('a MediaStore video becomes a VideoMediaItem with an ms: id and a content URI', () {
      final asset = _asset('42', kind: SystemAssetKind.video);
      final item = systemMediaItem(asset, SystemPhotoPlatform.mediaStore) as VideoMediaItem;
      expect(item.id, MediaStoreId.of(42));
      expect(item.uri, 'content://media/external/video/media/42');
      expect(item.duration, const Duration(seconds: 12));
      expect((item.width, item.height), (4032, 3024));
      expect(item.toMediaRef().pathOrUri, item.uri, reason: 'the player keeps receiving MediaRef');
      expect(systemItemUri(_asset('7'), SystemPhotoPlatform.mediaStore), 'content://media/external/images/media/7');
    });

    test('missing metadata falls back safely', () {
      const asset = SystemPhotoAsset(localIdentifier: 'X/L0/001', kind: SystemAssetKind.photo, width: -1, height: 0);
      final item = systemMediaItem(asset, SystemPhotoPlatform.photoKit) as PhotoMediaItem;
      expect(item.name, isEmpty);
      expect(item.mimeType, 'application/octet-stream');
      expect(item.modifiedAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect((item.width, item.height), (0, 0));
      expect(() => systemMediaItem(_asset('not-a-number'), SystemPhotoPlatform.mediaStore), throwsFormatException);
    });
  });

  group('SystemPhotosController', () {
    test('no library on this platform: unavailable, nothing asked', () async {
      final c = SystemPhotosController(library: null, platform: null);
      expect(c.state.available, isFalse);
      expect(await c.open(), PhotoLibraryAuthorization.notDetermined);
      expect(c.state.items, isEmpty);
      c.dispose();
    });

    test('access is asked only when the system view opens, then the first page loads', () async {
      final lib = FakePhotoLibrary(_library(450));
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.refreshAuthorization();
      expect(lib.requests, 0, reason: 'reading the status never prompts');
      expect(c.state.authorization, PhotoLibraryAuthorization.notDetermined);
      expect(await c.open(), PhotoLibraryAuthorization.authorized);
      expect(lib.requests, 1);
      expect(lib.startCalls, 1);
      expect(c.state.items, hasLength(200));
      expect(c.state.totalCount, 450);
      expect(c.state.complete, isFalse);
      expect(c.state.items.first.id, PhotoKitId.of('A450/L0/001'), reason: 'newest first');
      expect(c.state.videos, isNotEmpty);
      expect(c.state.photos, isNotEmpty);
      await c.loadMore();
      await c.loadMore();
      expect(c.state.items, hasLength(450));
      expect(c.state.complete, isTrue);
      expect(c.state.items.map((i) => i.id).toSet(), hasLength(450), reason: 'no asset twice');
      final calls = lib.pageCalls;
      await c.loadMore();
      expect(lib.pageCalls, calls, reason: 'nothing left to load');
      await c.open();
      expect(lib.requests, 1, reason: 'asked once');
      c.dispose();
      expect(lib.stopCalls, 1);
    });

    test('denied access shows no items and never pages; settings can be opened', () async {
      final lib = FakePhotoLibrary(_library(10), grant: PhotoLibraryAuthorization.denied);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      expect(await c.open(), PhotoLibraryAuthorization.denied);
      expect(c.state.items, isEmpty);
      expect(lib.pageCalls, 0);
      expect(lib.startCalls, 0, reason: 'no observer without access');
      expect(await c.openSettings(), isTrue);
      c.dispose();
    });

    test('limited access lists the selection and can manage it', () async {
      final lib = FakePhotoLibrary(_library(3), status: PhotoLibraryAuthorization.limited);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      expect(await c.open(), PhotoLibraryAuthorization.limited);
      expect(c.state.limited, isTrue);
      expect(c.state.items, hasLength(3));
      lib.mutate(_library(5));
      await c.manageLimitedSelection();
      expect(lib.pickerCalls, 1);
      expect(c.state.items, hasLength(5));
      c.dispose();
    });

    test('an insert or delete event reloads the loaded window from the new snapshot', () async {
      final lib = FakePhotoLibrary(_library(300), status: PhotoLibraryAuthorization.authorized);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.open();
      await c.loadMore();
      expect(c.state.items, hasLength(300));
      final before = c.state.changeToken;

      lib.mutate([_asset('NEW/L0/001', t: 999), ...lib.assets]);
      lib.changeEvents.add(SystemPhotoChange(changeToken: lib.token, incremental: true, inserted: const ['NEW/L0/001']));
      await pumpEventQueue();
      expect(c.state.items.first.id, PhotoKitId.of('NEW/L0/001'));
      expect(c.state.items, hasLength(301));
      expect(c.state.totalCount, 301);
      expect(c.state.changeToken, isNot(before));

      final victim = lib.assets[10].localIdentifier;
      lib.mutate([for (final a in lib.assets) if (a.localIdentifier != victim) a]);
      lib.changeEvents.add(SystemPhotoChange(changeToken: lib.token, incremental: true, removed: [victim]));
      await pumpEventQueue();
      expect(c.state.items.any((i) => i.id == PhotoKitId.of(victim)), isFalse);
      expect(c.state.totalCount, 300);
      c.dispose();
    });

    test('a non-incremental change reloads; an in-place change refreshes cells and keeps paging', () async {
      final lib = FakePhotoLibrary(_library(5), status: PhotoLibraryAuthorization.authorized);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.open();
      final calls = lib.pageCalls;
      final id = lib.assets[2].localIdentifier;
      lib.assets = [for (final a in lib.assets) a.localIdentifier == id ? _asset(id, t: 3, favorite: true).withName('EDITED.HEIC') : a];
      lib.changeEvents.add(SystemPhotoChange(changeToken: lib.token, incremental: true, changed: [id]));
      await pumpEventQueue();
      expect(lib.pageCalls, calls, reason: 'same token: no reload');
      expect(c.state.items[2].name, 'EDITED.HEIC');

      lib.mutate(_library(2));
      lib.changeEvents.add(SystemPhotoChange(changeToken: lib.token, incremental: false));
      await pumpEventQueue();
      expect(c.state.items, hasLength(2));
      c.dispose();
    });

    test('a stale token while paging restarts from the new snapshot', () async {
      final lib = FakePhotoLibrary(_library(450), status: PhotoLibraryAuthorization.authorized);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.open();
      lib.mutate(_library(451));
      await c.loadMore();
      await pumpEventQueue();
      expect(c.state.changeToken, lib.token);
      expect(c.state.totalCount, 451);
      expect(c.state.items.first.id, PhotoKitId.of('A451/L0/001'));
      expect(c.state.items.map((i) => i.id).toSet().length, c.state.items.length);
      c.dispose();
    });

    test('revoked access clears the items; regained access reloads', () async {
      final lib = FakePhotoLibrary(_library(4), status: PhotoLibraryAuthorization.authorized);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.open();
      lib.status = PhotoLibraryAuthorization.denied;
      lib.authEvents.add(PhotoLibraryAuthorization.denied);
      await pumpEventQueue();
      expect(c.state.items, isEmpty);
      lib.status = PhotoLibraryAuthorization.limited;
      lib.authEvents.add(PhotoLibraryAuthorization.limited);
      await pumpEventQueue();
      expect(c.state.items, hasLength(4));
      c.dispose();
    });

    test('filters list photos or videos only', () async {
      final lib = FakePhotoLibrary(_library(20), status: PhotoLibraryAuthorization.authorized);
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.photoKit);
      await c.open();
      await c.setFilter(SystemPhotoFilter.videos);
      expect(c.state.items, everyElement(isA<VideoMediaItem>()));
      expect(c.state.items, hasLength(4));
      await c.setFilter(SystemPhotoFilter.photos);
      expect(c.state.items, everyElement(isA<PhotoMediaItem>()));
      c.dispose();
    });

    test('a missing native side marks the source unavailable', () async {
      final lib = FakePhotoLibrary(_library(1))..failWith = const LibraryNativeException(LibraryNativeErrorCode.notSupportedOnDevice, 'x');
      final c = SystemPhotosController(library: lib, platform: SystemPhotoPlatform.mediaStore);
      await c.open();
      expect(c.state.available, isFalse);
      expect(c.state.error, LibraryNativeErrorCode.notSupportedOnDevice);
      c.dispose();
    });
  });
}

extension on SystemPhotoAsset {
  SystemPhotoAsset withName(String name) => SystemPhotoAsset(
        localIdentifier: localIdentifier,
        kind: kind,
        width: width,
        height: height,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        duration: duration,
        isFavorite: isFavorite,
        originalFilename: name,
        mimeType: mimeType,
      );
}
