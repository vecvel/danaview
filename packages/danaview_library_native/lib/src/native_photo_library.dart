// OWNER: HOM-02
//
// The system photo library (ARCH v1.2 §3, §8, V2-103, V2-111): PhotoKit on iOS and macOS (HOM-02),
// MediaStore on Android (HOM-02A), behind one Dart interface. Also the shared error type of every
// danaview_library_native wrapper and the backup-flag wrapper HOM-17's `BackupFlagPort` adapts
// (the app root does the adapting; rule 21 keeps this package free of danaview_* imports).
// Nothing here logs names, ids or paths (rule 30) or touches the network (rule 21).

import 'dart:async';

import 'package:flutter/services.dart';

import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// Error codes of the library plugin (pigeons/library_api.dart, "Errors").
enum LibraryNativeErrorCode {
  /// The capability does not exist on this platform, or its native class has not landed yet.
  notSupportedOnDevice,

  /// The user (or a policy) denied access.
  permissionDenied,

  /// The asset, album or file is gone.
  notFound,

  /// The operation was cancelled.
  cancelled,

  /// The original is only in iCloud; Danaview never downloads it (ARCH §9.1).
  unavailableOffline,

  /// A file system error.
  ioError,

  /// The request was malformed.
  invalidArgument,

  /// A request with the same id is running.
  busy,

  /// Anything else.
  internal;

  /// The code of a platform error code string; Pigeon's `channel-error` (no native handler) is
  /// [notSupportedOnDevice], an unknown string [internal].
  static LibraryNativeErrorCode fromCode(String code) {
    if (code == 'channel-error') return notSupportedOnDevice;
    for (final value in values) {
      if (value.name == code) return value;
    }
    return internal;
  }
}

/// A failure of a danaview_library_native call. [message] is debug text without names or paths.
final class LibraryNativeException implements Exception {
  /// A failure with [code].
  const LibraryNativeException(this.code, this.message);

  /// What went wrong.
  final LibraryNativeErrorCode code;

  /// Debug text (never shown to users, never logged with names).
  final String message;

  @override
  String toString() => 'LibraryNativeException(${code.name}: $message)';
}

/// Photo library authorization (V2-103).
enum PhotoLibraryAuthorization {
  /// Never asked.
  notDetermined,

  /// Forbidden by a policy the user can't change.
  restricted,

  /// The user refused.
  denied,

  /// Full access.
  authorized,

  /// Limited (iOS) or partial (Android 14+) access: only the selected assets are listed.
  limited;

  /// True when assets can be listed.
  bool get canRead => this == authorized || this == limited;
}

/// Which system assets a fetch lists.
enum SystemPhotoFilter {
  /// Photos and videos.
  all,

  /// Photos only.
  photos,

  /// Videos only.
  videos,
}

/// Sort order of a system fetch.
enum SystemPhotoSort {
  /// Newest capture first (the Photos tab default).
  creationNewestFirst,

  /// Oldest capture first.
  creationOldestFirst,

  /// Most recently modified first.
  modificationNewestFirst,
}

/// The kind of a system asset.
enum SystemAssetKind {
  /// A still photo (including RAW, HDR and Live Photos).
  photo,

  /// A video.
  video,
}

/// The kind of a system album.
enum SystemAlbumKind {
  /// A smart album or an OS-defined bucket.
  smart,

  /// An album the user made, or an Android device folder.
  user,

  /// A shared album.
  shared,
}

/// One asset of the system library (cheap grid fields; EXIF is [SystemPhotoDetail]).
final class SystemPhotoAsset {
  /// An asset with the platform id [localIdentifier] (no `ph:`/`ms:` prefix).
  const SystemPhotoAsset({
    required this.localIdentifier,
    required this.kind,
    required this.width,
    required this.height,
    this.createdAt,
    this.modifiedAt,
    this.duration = Duration.zero,
    this.isFavorite = false,
    this.isRaw = false,
    this.isHdr = false,
    this.isLivePhoto = false,
    this.isScreenshot = false,
    this.originalFilename,
    this.uti,
    this.mimeType,
    this.sizeBytes,
  });

  /// PhotoKit `localIdentifier` or MediaStore `_ID`.
  final String localIdentifier;

  /// Photo or video.
  final SystemAssetKind kind;

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// Capture time, if known.
  final DateTime? createdAt;

  /// Last modification, if known.
  final DateTime? modifiedAt;

  /// Video length ([Duration.zero] for photos).
  final Duration duration;

  /// Marked favourite in the system library.
  final bool isFavorite;

  /// A RAW capture (V2-V2).
  final bool isRaw;

  /// An HDR capture.
  final bool isHdr;

  /// A Live Photo.
  final bool isLivePhoto;

  /// A screenshot.
  final bool isScreenshot;

  /// Original file name, if known (never logged).
  final String? originalFilename;

  /// Uniform type identifier (Apple), if known.
  final String? uti;

  /// MIME type, if known.
  final String? mimeType;

  /// Size, when the platform reports it cheaply.
  final int? sizeBytes;
}

/// One page of a system fetch.
final class SystemPhotoPage {
  /// A page.
  const SystemPhotoPage({
    required this.assets,
    required this.offset,
    required this.totalCount,
    required this.changeToken,
    required this.tokenStale,
  });

  /// The assets of this page, in fetch order.
  final List<SystemPhotoAsset> assets;

  /// Index of the first asset.
  final int offset;

  /// Assets in the whole fetch.
  final int totalCount;

  /// The snapshot token; pass it with the next page.
  final String changeToken;

  /// True when the token passed in named an older snapshot: restart paging from 0.
  final bool tokenStale;

  /// The offset of the next page, or null when this one reaches the end.
  int? get nextOffset {
    final next = offset + assets.length;
    return assets.isEmpty || next >= totalCount ? null : next;
  }
}

/// One system album or device folder.
final class SystemPhotoAlbum {
  /// An album.
  const SystemPhotoAlbum({required this.albumId, required this.title, required this.kind, required this.estimatedCount});

  /// The platform album id.
  final String albumId;

  /// Localized title (never logged).
  final String title;

  /// Smart, user or shared.
  final SystemAlbumKind kind;

  /// Asset count, -1 when unknown.
  final int estimatedCount;
}

/// EXIF basics of one asset (the viewer's info panel).
final class SystemPhotoDetail {
  /// A detail record.
  const SystemPhotoDetail({
    required this.localIdentifier,
    required this.locallyAvailable,
    this.iso,
    this.aperture,
    this.exposureSeconds,
    this.focalLengthMm,
    this.cameraMake,
    this.cameraModel,
    this.lensModel,
    this.takenAt,
    this.latitude,
    this.longitude,
    this.colorProfile,
    this.bitDepth,
    this.isRaw = false,
    this.isHdr = false,
    this.isLivePhoto = false,
    this.uti,
    this.mimeType,
    this.originalFilename,
    this.sizeBytes,
  });

  /// The asset.
  final String localIdentifier;

  /// False when the original is only in iCloud (EXIF fields are then null).
  final bool locallyAvailable;

  /// ISO speed.
  final int? iso;

  /// f-number.
  final double? aperture;

  /// Exposure time in seconds.
  final double? exposureSeconds;

  /// Focal length in millimetres.
  final double? focalLengthMm;

  /// Camera make.
  final String? cameraMake;

  /// Camera model.
  final String? cameraModel;

  /// Lens model.
  final String? lensModel;

  /// EXIF capture time.
  final DateTime? takenAt;

  /// Latitude (degrees, south negative).
  final double? latitude;

  /// Longitude (degrees, west negative).
  final double? longitude;

  /// Colour profile name.
  final String? colorProfile;

  /// Bits per component.
  final int? bitDepth;

  /// A RAW capture.
  final bool isRaw;

  /// An HDR capture.
  final bool isHdr;

  /// A Live Photo.
  final bool isLivePhoto;

  /// Uniform type identifier.
  final String? uti;

  /// MIME type.
  final String? mimeType;

  /// Original file name (never logged).
  final String? originalFilename;

  /// Size of the original in bytes.
  final int? sizeBytes;
}

/// A file [SystemPhotoLibrary.copyAsset] created.
final class SystemPhotoCopy {
  /// A copy at [path].
  const SystemPhotoCopy({required this.path, required this.sizeBytes, this.uti, this.mimeType});

  /// The new file.
  final String path;

  /// Its size.
  final int sizeBytes;

  /// Its uniform type identifier, if known.
  final String? uti;

  /// Its MIME type, if known.
  final String? mimeType;
}

/// What changed in the system library (V2-111).
final class SystemPhotoChange {
  /// A change.
  const SystemPhotoChange({
    required this.changeToken,
    required this.incremental,
    this.inserted = const [],
    this.removed = const [],
    this.changed = const [],
  });

  /// The token pages carry from now on.
  final String changeToken;

  /// False when the platform couldn't say what changed: reload everything.
  final bool incremental;

  /// Ids of new assets.
  final List<String> inserted;

  /// Ids of removed assets.
  final List<String> removed;

  /// Ids of assets changed in place (favourite, edit).
  final List<String> changed;
}

/// The system photo library as the Photos tab, the viewer and the editor import see it.
abstract interface class SystemPhotoLibrary {
  /// Current authorization, without prompting.
  Future<PhotoLibraryAuthorization> authorizationStatus();

  /// Asks for access (first time only; later calls return the state). Call only when the Photos
  /// tab's system view opens (V2-103).
  Future<PhotoLibraryAuthorization> requestAuthorization();

  /// Lets a limited-access user change the selection; returns the selected ids.
  Future<List<String>> presentLimitedLibraryPicker();

  /// Opens the app's system settings page; false when it couldn't.
  Future<bool> openAppSettings();

  /// Starts [changes] and [authorizationChanges] (after access was granted).
  Future<void> startObserving();

  /// Stops them.
  Future<void> stopObserving();

  /// One page of the library or of [albumId].
  Future<SystemPhotoPage> fetchPage({
    SystemPhotoFilter filter = SystemPhotoFilter.all,
    SystemPhotoSort sort = SystemPhotoSort.creationNewestFirst,
    String? albumId,
    int offset = 0,
    int limit = 200,
    String? changeToken,
  });

  /// Assets by id, in order; unknown ids are left out.
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> localIdentifiers);

  /// Albums and device folders with photos or videos.
  Future<List<SystemPhotoAlbum>> fetchAlbums();

  /// EXIF basics of one asset.
  Future<SystemPhotoDetail> assetDetail(String localIdentifier);

  /// Copies the original into [destinationDirectory] (create-new, no network).
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId});

  /// Cancels a running [copyAsset].
  Future<void> cancelCopy(String requestId);

  /// Library changes (after [startObserving]).
  Stream<SystemPhotoChange> get changes;

  /// Authorization changes seen while observing.
  Stream<PhotoLibraryAuthorization> get authorizationChanges;
}

PhotoLibraryAuthorization _authorization(PhotoAuthorizationMsg m) => switch (m) {
      PhotoAuthorizationMsg.notDetermined => PhotoLibraryAuthorization.notDetermined,
      PhotoAuthorizationMsg.restricted => PhotoLibraryAuthorization.restricted,
      PhotoAuthorizationMsg.denied => PhotoLibraryAuthorization.denied,
      PhotoAuthorizationMsg.authorized => PhotoLibraryAuthorization.authorized,
      PhotoAuthorizationMsg.limited => PhotoLibraryAuthorization.limited,
    };

DateTime? _time(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

SystemPhotoAsset _asset(PhotoAssetMsg m) => SystemPhotoAsset(
      localIdentifier: m.localIdentifier,
      kind: m.kind == PhotoAssetKindMsg.video ? SystemAssetKind.video : SystemAssetKind.photo,
      width: m.widthPx,
      height: m.heightPx,
      createdAt: _time(m.creationTimeMs),
      modifiedAt: _time(m.modificationTimeMs),
      duration: Duration(milliseconds: m.durationMs),
      isFavorite: m.isFavorite,
      isRaw: m.isRaw,
      isHdr: m.isHdr,
      isLivePhoto: m.isLivePhoto,
      isScreenshot: m.isScreenshot,
      originalFilename: m.originalFilename,
      uti: m.uti,
      mimeType: m.mimeType,
      sizeBytes: m.sizeBytes,
    );

/// [SystemPhotoLibrary] over the plugin's Pigeon surface.
final class NativePhotoLibrary implements SystemPhotoLibrary {
  /// The library of the default engine; tests pass a mock [binaryMessenger] and an [events] hub.
  NativePhotoLibrary({BinaryMessenger? binaryMessenger, String messageChannelSuffix = '', LibraryEventHub? events})
      : _api = PhotoLibraryHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        _events = events ?? LibraryEventHub.forInstance(messageChannelSuffix);

  final PhotoLibraryHostApi _api;
  final LibraryEventHub _events;
  int _copies = 0;

  @override
  Future<PhotoLibraryAuthorization> authorizationStatus() => guardNative(() async => _authorization(await _api.authorizationStatus()));

  @override
  Future<PhotoLibraryAuthorization> requestAuthorization() =>
      guardNative(() async => _authorization(await _api.requestAuthorization()));

  @override
  Future<List<String>> presentLimitedLibraryPicker() => guardNative(_api.presentLimitedLibraryPicker);

  @override
  Future<bool> openAppSettings() => guardNative(_api.openAppSettings);

  @override
  Future<void> startObserving() => guardNative(_api.startObserving);

  @override
  Future<void> stopObserving() => guardNative(_api.stopObserving);

  @override
  Future<SystemPhotoPage> fetchPage({
    SystemPhotoFilter filter = SystemPhotoFilter.all,
    SystemPhotoSort sort = SystemPhotoSort.creationNewestFirst,
    String? albumId,
    int offset = 0,
    int limit = 200,
    String? changeToken,
  }) {
    if (offset < 0) throw ArgumentError.value(offset, 'offset', 'negative');
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit', 'not in 1…500');
    return guardNative(() async {
      final page = await _api.fetchPage(PhotoFetchRequestMsg(
        filter: PhotoMediaFilterMsg.values[filter.index],
        sort: PhotoSortMsg.values[sort.index],
        albumId: albumId,
        offset: offset,
        limit: limit,
        changeToken: changeToken,
      ));
      return SystemPhotoPage(
        assets: [for (final a in page.assets) _asset(a)],
        offset: page.offset,
        totalCount: page.totalCount,
        changeToken: page.changeToken,
        tokenStale: page.tokenStale,
      );
    });
  }

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> localIdentifiers) async {
    if (localIdentifiers.isEmpty) return const [];
    return guardNative(() async => [for (final a in await _api.fetchAssets(localIdentifiers)) _asset(a)]);
  }

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() => guardNative(() async => [
        for (final a in await _api.fetchAlbums())
          SystemPhotoAlbum(
            albumId: a.albumId,
            title: a.title,
            kind: SystemAlbumKind.values[a.kind.index],
            estimatedCount: a.estimatedCount,
          ),
      ]);

  @override
  Future<SystemPhotoDetail> assetDetail(String localIdentifier) => guardNative(() async {
        final d = await _api.assetDetail(localIdentifier);
        return SystemPhotoDetail(
          localIdentifier: d.localIdentifier,
          locallyAvailable: d.locallyAvailable,
          iso: d.iso,
          aperture: d.aperture,
          exposureSeconds: d.exposureSeconds,
          focalLengthMm: d.focalLengthMm,
          cameraMake: d.cameraMake,
          cameraModel: d.cameraModel,
          lensModel: d.lensModel,
          takenAt: _time(d.takenAtMs),
          latitude: d.latitude,
          longitude: d.longitude,
          colorProfile: d.colorProfile,
          bitDepth: d.bitDepth,
          isRaw: d.isRaw,
          isHdr: d.isHdr,
          isLivePhoto: d.isLivePhoto,
          uti: d.uti,
          mimeType: d.mimeType,
          originalFilename: d.originalFilename,
          sizeBytes: d.sizeBytes,
        );
      });

  @override
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId}) =>
      guardNative(() async {
        final r = await _api.copyAsset(PhotoCopyRequestMsg(
          requestId: requestId ?? 'photo-copy-${++_copies}-${DateTime.now().microsecondsSinceEpoch}',
          localIdentifier: localIdentifier,
          destinationDirectory: destinationDirectory,
          pairedVideo: pairedVideo,
        ));
        return SystemPhotoCopy(path: r.path, sizeBytes: r.sizeBytes, uti: r.uti, mimeType: r.mimeType);
      });

  @override
  Future<void> cancelCopy(String requestId) => guardNative(() => _api.cancelCopy(requestId));

  @override
  Stream<SystemPhotoChange> get changes => _events.of(LibraryEventKindMsg.photoLibraryChanged).map((e) => e.photoChange).where((c) => c != null).map((c) => SystemPhotoChange(
        changeToken: c!.changeToken,
        incremental: c.incremental,
        inserted: c.inserted,
        removed: c.removed,
        changed: c.changed,
      ));

  @override
  Stream<PhotoLibraryAuthorization> get authorizationChanges => _events
      .of(LibraryEventKindMsg.photoAuthorizationChanged)
      .map((e) => e.authorization)
      .where((a) => a != null)
      .map((a) => _authorization(a!));
}

/// Backup exclusion of app paths (Apple `NSURLIsExcludedFromBackupKey`). The app root adapts it to
/// HOM-17's `BackupFlagPort`; it never throws for a platform without the flag (Android's rules are
/// backup XML, INT-104).
final class NativeBackupFlags {
  /// The flags of the default engine; tests pass a mock [binaryMessenger].
  NativeBackupFlags({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = BackupFlagHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final BackupFlagHostApi _api;

  /// Marks [path] excluded from (or included in) backups; a no-op where unsupported.
  Future<void> setExcludedFromBackup(String path, {required bool excluded}) async {
    try {
      await guardNative(() => _api.setExcludedFromBackup(path, excluded));
    } on LibraryNativeException catch (e) {
      if (e.code != LibraryNativeErrorCode.notSupportedOnDevice) rethrow;
    }
  }

  /// Whether [path] is excluded; false where unsupported.
  Future<bool> isExcludedFromBackup(String path) async {
    try {
      return await guardNative(() => _api.isExcludedFromBackup(path));
    } on LibraryNativeException catch (e) {
      if (e.code == LibraryNativeErrorCode.notSupportedOnDevice) return false;
      rethrow;
    }
  }
}
