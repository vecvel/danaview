// OWNER: HOM-02
//
// NativePhotoLibrary and NativeBackupFlags over a mock binary messenger (BUILD_PLAN HOM-02):
// every field of the Pigeon messages reaches the Dart types, errors map to LibraryNativeException
// (an unregistered host API is notSupportedOnDevice), events fan out through one subscription,
// and the backup flag is a no-op where unsupported.

import 'dart:async';

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:danaview_library_native/src/pigeon/library_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = PhotoLibraryHostApi.pigeonChannelCodec;

  /// Answers [method] of [api] with [reply] (a value, or a PlatformException to fail with).
  void answer(String api, String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$api.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final api in ['PhotoLibraryHostApi', 'BackupFlagHostApi']) {
      for (final m in [
        'authorizationStatus', 'requestAuthorization', 'presentLimitedLibraryPicker', 'openAppSettings', 'startObserving',
        'stopObserving', 'fetchPage', 'fetchAssets', 'fetchAlbums', 'assetDetail', 'copyAsset', 'cancelCopy',
        'setExcludedFromBackup', 'isExcludedFromBackup',
      ]) {
        messenger.setMockMessageHandler('$_prefix.$api.$m', null);
      }
    }
  });

  PhotoAssetMsg assetMsg(String id, {PhotoAssetKindMsg kind = PhotoAssetKindMsg.photo}) => PhotoAssetMsg(
        localIdentifier: id,
        kind: kind,
        widthPx: 4032,
        heightPx: 3024,
        creationTimeMs: 1700000000000,
        modificationTimeMs: 1700000001000,
        durationMs: kind == PhotoAssetKindMsg.video ? 12500 : 0,
        isFavorite: true,
        isRaw: true,
        isHdr: true,
        isLivePhoto: true,
        isScreenshot: false,
        originalFilename: 'IMG_0001.DNG',
        uti: 'com.adobe.raw-image',
        mimeType: 'image/x-adobe-dng',
        sizeBytes: 123,
      );

  test('fetchPage sends the request and maps every field', () async {
    PhotoFetchRequestMsg? sent;
    answer('PhotoLibraryHostApi', 'fetchPage', (args) {
      sent = args.single! as PhotoFetchRequestMsg;
      return PhotoPageMsg(
        assets: [assetMsg('A/L0/001'), assetMsg('B/L0/001', kind: PhotoAssetKindMsg.video)],
        offset: 200,
        totalCount: 202,
        changeToken: 'g3',
        tokenStale: true,
      );
    });
    final lib = NativePhotoLibrary(events: LibraryEventHub.over(() => const Stream.empty()));
    final page = await lib.fetchPage(filter: SystemPhotoFilter.videos, sort: SystemPhotoSort.modificationNewestFirst, albumId: 'alb', offset: 200, limit: 50, changeToken: 'g2');
    expect(sent!.filter, PhotoMediaFilterMsg.videos);
    expect(sent!.sort, PhotoSortMsg.modificationNewestFirst);
    expect(sent!.albumId, 'alb');
    expect(sent!.offset, 200);
    expect(sent!.limit, 50);
    expect(sent!.changeToken, 'g2');
    expect(page.totalCount, 202);
    expect(page.changeToken, 'g3');
    expect(page.tokenStale, isTrue);
    expect(page.nextOffset, isNull, reason: '200 + 2 reaches the end');
    final photo = page.assets.first;
    expect(photo.localIdentifier, 'A/L0/001');
    expect(photo.kind, SystemAssetKind.photo);
    expect((photo.width, photo.height), (4032, 3024));
    expect(photo.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
    expect(photo.modifiedAt, DateTime.fromMillisecondsSinceEpoch(1700000001000, isUtc: true));
    expect([photo.isFavorite, photo.isRaw, photo.isHdr, photo.isLivePhoto, photo.isScreenshot], [true, true, true, true, false]);
    expect(photo.originalFilename, 'IMG_0001.DNG');
    expect(photo.uti, 'com.adobe.raw-image');
    expect(photo.mimeType, 'image/x-adobe-dng');
    expect(photo.sizeBytes, 123);
    expect(page.assets.last.kind, SystemAssetKind.video);
    expect(page.assets.last.duration, const Duration(milliseconds: 12500));
  });

  test('nextOffset continues until the total', () {
    const a = SystemPhotoAsset(localIdentifier: 'x', kind: SystemAssetKind.photo, width: 1, height: 1);
    expect(const SystemPhotoPage(assets: [a, a], offset: 0, totalCount: 5, changeToken: 't', tokenStale: false).nextOffset, 2);
    expect(const SystemPhotoPage(assets: [], offset: 0, totalCount: 5, changeToken: 't', tokenStale: false).nextOffset, isNull);
  });

  test('page arguments are validated before the call', () {
    final lib = NativePhotoLibrary(events: LibraryEventHub.over(() => const Stream.empty()));
    expect(() => lib.fetchPage(offset: -1), throwsArgumentError);
    expect(() => lib.fetchPage(limit: 0), throwsArgumentError);
    expect(() => lib.fetchPage(limit: 501), throwsArgumentError);
  });

  test('authorization, albums, detail, copy and assets map their fields', () async {
    answer('PhotoLibraryHostApi', 'authorizationStatus', (_) => PhotoAuthorizationMsg.limited);
    answer('PhotoLibraryHostApi', 'requestAuthorization', (_) => PhotoAuthorizationMsg.authorized);
    answer('PhotoLibraryHostApi', 'fetchAlbums', (_) => [PhotoAlbumMsg(albumId: 'a1', title: 'Trip', kind: PhotoAlbumKindMsg.shared, estimatedCount: 7)]);
    answer('PhotoLibraryHostApi', 'fetchAssets', (args) => [for (final id in args.single! as List<Object?>) assetMsg(id! as String)]);
    answer('PhotoLibraryHostApi', 'assetDetail', (args) => PhotoAssetDetailMsg(
          localIdentifier: args.single! as String,
          iso: 400,
          aperture: 1.8,
          exposureSeconds: 0.01,
          focalLengthMm: 6.86,
          cameraMake: 'Apple',
          cameraModel: 'iPhone 12',
          lensModel: 'Wide',
          takenAtMs: 1700000000000,
          latitude: 1.5,
          longitude: -2.5,
          colorProfile: 'Display P3',
          bitDepth: 8,
          isRaw: false,
          isHdr: true,
          isLivePhoto: true,
          uti: 'public.heic',
          mimeType: 'image/heic',
          originalFilename: 'IMG.HEIC',
          sizeBytes: 2048,
          locallyAvailable: true,
        ));
    PhotoCopyRequestMsg? copyRequest;
    answer('PhotoLibraryHostApi', 'copyAsset', (args) {
      copyRequest = args.single! as PhotoCopyRequestMsg;
      return PhotoCopyResultMsg(path: '/tmp/IMG.HEIC', uti: 'public.heic', mimeType: 'image/heic', sizeBytes: 2048);
    });
    final lib = NativePhotoLibrary(events: LibraryEventHub.over(() => const Stream.empty()));
    expect(await lib.authorizationStatus(), PhotoLibraryAuthorization.limited);
    expect(PhotoLibraryAuthorization.limited.canRead, isTrue);
    expect(PhotoLibraryAuthorization.denied.canRead, isFalse);
    expect(await lib.requestAuthorization(), PhotoLibraryAuthorization.authorized);
    final albums = await lib.fetchAlbums();
    expect((albums.single.albumId, albums.single.title, albums.single.kind, albums.single.estimatedCount), ('a1', 'Trip', SystemAlbumKind.shared, 7));
    expect((await lib.fetchAssets(['x', 'y'])).map((a) => a.localIdentifier), ['x', 'y']);
    expect(await lib.fetchAssets(const []), isEmpty);
    final d = await lib.assetDetail('x');
    expect([d.iso, d.aperture, d.exposureSeconds, d.focalLengthMm], [400, 1.8, 0.01, 6.86]);
    expect([d.cameraMake, d.cameraModel, d.lensModel, d.colorProfile], ['Apple', 'iPhone 12', 'Wide', 'Display P3']);
    expect(d.takenAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
    expect((d.latitude, d.longitude, d.bitDepth, d.sizeBytes), (1.5, -2.5, 8, 2048));
    expect([d.isRaw, d.isHdr, d.isLivePhoto, d.locallyAvailable], [false, true, true, true]);
    expect([d.uti, d.mimeType, d.originalFilename], ['public.heic', 'image/heic', 'IMG.HEIC']);
    final copy = await lib.copyAsset('x', '/tmp', pairedVideo: true, requestId: 'r1');
    expect(copyRequest!.requestId, 'r1');
    expect(copyRequest!.pairedVideo, isTrue);
    expect(copyRequest!.destinationDirectory, '/tmp');
    expect((copy.path, copy.sizeBytes, copy.uti, copy.mimeType), ('/tmp/IMG.HEIC', 2048, 'public.heic', 'image/heic'));
  });

  test('platform errors map to LibraryNativeException codes', () async {
    answer('PhotoLibraryHostApi', 'fetchPage', (_) => PlatformException(code: 'permissionDenied', message: 'photo library access not granted'));
    answer('PhotoLibraryHostApi', 'assetDetail', (_) => PlatformException(code: 'unavailableOffline'));
    answer('PhotoLibraryHostApi', 'copyAsset', (_) => PlatformException(code: 'somethingNew'));
    final lib = NativePhotoLibrary(events: LibraryEventHub.over(() => const Stream.empty()));
    await expectLater(lib.fetchPage(), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.permissionDenied)));
    await expectLater(lib.assetDetail('x'), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.unavailableOffline)));
    await expectLater(lib.copyAsset('x', '/tmp'), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.internal)));
  });

  test('an unregistered host API is notSupportedOnDevice', () async {
    final lib = NativePhotoLibrary(events: LibraryEventHub.over(() => const Stream.empty()));
    await expectLater(lib.authorizationStatus(), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)));
    await expectLater(lib.presentLimitedLibraryPicker(), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)));
    for (final code in LibraryNativeErrorCode.values) {
      expect(LibraryNativeErrorCode.fromCode(code.name), code);
    }
    expect(LibraryNativeErrorCode.fromCode('channel-error'), LibraryNativeErrorCode.notSupportedOnDevice);
  });

  test('events fan out from one subscription and filter by kind', () async {
    var listens = 0;
    final source = StreamController<LibraryEventMsg>.broadcast(onListen: () => listens++);
    final hub = LibraryEventHub.over(() => source.stream);
    final lib = NativePhotoLibrary(events: hub);
    final changes = <SystemPhotoChange>[];
    final auths = <PhotoLibraryAuthorization>[];
    final s1 = lib.changes.listen(changes.add);
    final s2 = lib.authorizationChanges.listen(auths.add);
    final s3 = hub.of(LibraryEventKindMsg.copyProgress).listen((_) {});
    expect(listens, 1, reason: 'one native subscription for every listener');
    source
      ..add(LibraryEventMsg(
        kind: LibraryEventKindMsg.photoLibraryChanged,
        photoChange: PhotoLibraryChangeMsg(changeToken: 'g4', incremental: true, inserted: ['a'], removed: ['b'], changed: ['c']),
      ))
      ..add(LibraryEventMsg(kind: LibraryEventKindMsg.photoAuthorizationChanged, authorization: PhotoAuthorizationMsg.denied))
      ..add(LibraryEventMsg(kind: LibraryEventKindMsg.inboxChanged));
    await pumpEventQueue();
    expect(changes.single.changeToken, 'g4');
    expect(changes.single.incremental, isTrue);
    expect([changes.single.inserted, changes.single.removed, changes.single.changed], [['a'], ['b'], ['c']]);
    expect(auths, [PhotoLibraryAuthorization.denied]);
    await s1.cancel();
    await s2.cancel();
    await s3.cancel();
    await source.close();
  });

  test('backup flags call the host and are a no-op where unsupported', () async {
    final flags = NativeBackupFlags();
    // No handler: notSupportedOnDevice is swallowed (Android, or before the glue).
    await flags.setExcludedFromBackup('/x/imports', excluded: true);
    expect(await flags.isExcludedFromBackup('/x/imports'), isFalse);
    final calls = <List<Object?>>[];
    answer('BackupFlagHostApi', 'setExcludedFromBackup', (args) {
      calls.add(args);
      return null;
    });
    answer('BackupFlagHostApi', 'isExcludedFromBackup', (_) => true);
    await flags.setExcludedFromBackup('/x/imports', excluded: true);
    expect(calls.single, ['/x/imports', true]);
    expect(await flags.isExcludedFromBackup('/x/imports'), isTrue);
    answer('BackupFlagHostApi', 'setExcludedFromBackup', (_) => PlatformException(code: 'notFound'));
    await expectLater(flags.setExcludedFromBackup('/gone', excluded: true), throwsA(isA<LibraryNativeException>()));
  });
}
