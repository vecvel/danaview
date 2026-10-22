// OWNER: HOM-02
//
// The system photo library source of the Photos tab (ARCH v1.2 V2-103, V2-111; HOM plan D-88,
// D-96): PhotoKit on iOS and macOS, MediaStore on Android (HOM-02A), through danaview_library_native's
// `SystemPhotoLibrary`. Assets become `PhotoMediaItem` / `VideoMediaItem` with `ph:` / `ms:` ids
// (V2-09); they are listed live and kept in memory only (never in library.db). Access is asked
// for the first time the Photos tab's system view opens (`open`), never at startup; limited and
// partial access are honoured (the platform lists only the selection). Paging follows the
// snapshot change token; change events refresh changed cells in place and reload the loaded
// window when assets were added, removed or moved. Nothing here logs names or ids (rule 30).
//
// PhotoKit pages larger than a screen carry cheap records (no RAW flag, filename or type: the
// native side skips the per-asset resource lookup on the page path); after each page the
// controller fills those cells through `fetchAssets` in small batches, off the page path, and
// keeps the filled items across reloads while the asset is unmodified. A missing type maps to
// `image/*` or `video/*`, a missing name to '' (the grid's labels leave an empty name out).

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which system library backs the Photos tab.
enum SystemPhotoPlatform {
  /// PhotoKit (iOS, macOS): `ph:` ids, `ph://` URIs.
  photoKit,

  /// MediaStore (Android): `ms:` ids, `content://media/external/…` URIs.
  mediaStore,
}

/// The system library of [platform], or null where there is none (Windows, Linux, web).
SystemPhotoPlatform? systemPhotoPlatformFor(TargetPlatform platform, {bool isWeb = kIsWeb}) {
  if (isWeb) return null;
  return switch (platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => SystemPhotoPlatform.photoKit,
    TargetPlatform.android => SystemPhotoPlatform.mediaStore,
    _ => null,
  };
}

/// The epoch, for assets without any time.
final DateTime _noTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// The V2-09 id of [asset] on [platform]; throws [MalformedIdException] for an invalid platform id.
ItemId systemItemId(SystemPhotoAsset asset, SystemPhotoPlatform platform) => switch (platform) {
      SystemPhotoPlatform.photoKit => PhotoKitId.of(asset.localIdentifier),
      SystemPhotoPlatform.mediaStore => MediaStoreId.parse('ms:${asset.localIdentifier}'),
    };

/// The URI the viewer, player and thumbnailer open [asset] with.
String systemItemUri(SystemPhotoAsset asset, SystemPhotoPlatform platform) => switch (platform) {
      SystemPhotoPlatform.photoKit => 'ph://${asset.localIdentifier}',
      SystemPhotoPlatform.mediaStore => asset.kind == SystemAssetKind.video
          ? 'content://media/external/video/media/${asset.localIdentifier}'
          : 'content://media/external/images/media/${asset.localIdentifier}',
    };

/// The MIME type of a photo whose exact type is not known yet.
const String unknownPhotoMimeType = 'image/*';

/// The MIME type of a video whose exact type is not known yet.
const String unknownVideoMimeType = 'video/*';

/// True when [asset] carries its resource facts (type, original name, RAW flag); a cheap PhotoKit
/// page record does not, and `SystemPhotoLibrary.fetchAssets` fills it.
bool systemAssetHasDetails(SystemPhotoAsset asset) => asset.mimeType != null || asset.uti != null || asset.originalFilename != null;

/// [asset] as a library item: a [PhotoMediaItem] or a [VideoMediaItem] (ARCH v1.2 §5.1). A
/// missing type maps to [unknownPhotoMimeType] / [unknownVideoMimeType], a missing name to ''.
MediaItem systemMediaItem(SystemPhotoAsset asset, SystemPhotoPlatform platform) {
  final id = systemItemId(asset, platform);
  final uri = systemItemUri(asset, platform);
  final modified = asset.modifiedAt ?? asset.createdAt ?? _noTime;
  final name = asset.originalFilename ?? '';
  final size = asset.sizeBytes;
  switch (asset.kind) {
    case SystemAssetKind.photo:
      return PhotoMediaItem(
        id: id,
        uri: uri,
        name: name,
        modifiedAt: modified,
        mimeType: asset.mimeType ?? unknownPhotoMimeType,
        sizeBytes: size != null && size >= 0 ? size : null,
        width: asset.width < 0 ? 0 : asset.width,
        height: asset.height < 0 ? 0 : asset.height,
        isRaw: asset.isRaw,
        isHdr: asset.isHdr,
        isLivePhoto: asset.isLivePhoto,
        takenAt: asset.createdAt,
      );
    case SystemAssetKind.video:
      return VideoMediaItem(
        id: id,
        uri: uri,
        name: name,
        modifiedAt: modified,
        mimeType: asset.mimeType ?? unknownVideoMimeType,
        sizeBytes: size != null && size >= 0 ? size : null,
        duration: asset.duration.isNegative ? Duration.zero : asset.duration,
        width: asset.width > 0 ? asset.width : null,
        height: asset.height > 0 ? asset.height : null,
      );
  }
}

/// The state of [SystemPhotosController].
@immutable
class SystemPhotosState {
  /// A state.
  const SystemPhotosState({
    this.platform,
    this.authorization = PhotoLibraryAuthorization.notDetermined,
    this.items = const [],
    this.totalCount = 0,
    this.loading = false,
    this.opened = false,
    this.filter = SystemPhotoFilter.all,
    this.albumId,
    this.changeToken,
    this.error,
  });

  /// The system library of this platform, or null where there is none.
  final SystemPhotoPlatform? platform;

  /// The current access.
  final PhotoLibraryAuthorization authorization;

  /// The loaded items, newest first (a prefix of the fetch).
  final List<MediaItem> items;

  /// Assets in the whole fetch.
  final int totalCount;

  /// True while a page or a reload runs.
  final bool loading;

  /// True once the Photos tab's system view was opened (access asked).
  final bool opened;

  /// What the fetch lists.
  final SystemPhotoFilter filter;

  /// The album listed, or null for the whole library.
  final String? albumId;

  /// Token of the snapshot [items] came from.
  final String? changeToken;

  /// The last failure, if any.
  final LibraryNativeErrorCode? error;

  /// False where the platform has no system library (or its native side is missing): the Photos
  /// tab hides the system section.
  bool get available => platform != null && error != LibraryNativeErrorCode.notSupportedOnDevice;

  /// True when every asset of the fetch is loaded.
  bool get complete => items.length >= totalCount;

  /// True when access is limited (offer "Manage selection").
  bool get limited => authorization == PhotoLibraryAuthorization.limited;

  /// The loaded photos.
  Iterable<PhotoMediaItem> get photos => items.whereType<PhotoMediaItem>();

  /// The loaded videos.
  Iterable<VideoMediaItem> get videos => items.whereType<VideoMediaItem>();

  /// A copy with the given fields replaced ([clearError] drops [error], [clearAlbum] lists the
  /// whole library).
  SystemPhotosState copyWith({
    PhotoLibraryAuthorization? authorization,
    List<MediaItem>? items,
    int? totalCount,
    bool? loading,
    bool? opened,
    SystemPhotoFilter? filter,
    String? albumId,
    bool clearAlbum = false,
    String? changeToken,
    LibraryNativeErrorCode? error,
    bool clearError = false,
  }) =>
      SystemPhotosState(
        platform: platform,
        authorization: authorization ?? this.authorization,
        items: items ?? this.items,
        totalCount: totalCount ?? this.totalCount,
        loading: loading ?? this.loading,
        opened: opened ?? this.opened,
        filter: filter ?? this.filter,
        albumId: clearAlbum ? null : (albumId ?? this.albumId),
        changeToken: changeToken ?? this.changeToken,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Lists the system photo library for the Photos tab.
class SystemPhotosController extends StateNotifier<SystemPhotosState> {
  /// A controller over [library] on [platform]; a null [library] or [platform] keeps it empty
  /// and unavailable.
  SystemPhotosController({
    required this.library,
    required SystemPhotoPlatform? platform,
    this.pageSize = 200,
    this.detailBatchSize = 48,
  })  : assert(pageSize > 0 && pageSize <= 500),
        assert(detailBatchSize > 0),
        super(SystemPhotosState(platform: library == null ? null : platform));

  /// The native library, or null where there is none.
  final SystemPhotoLibrary? library;

  /// Assets per page (the platform caps it at 500).
  final int pageSize;

  /// Assets per `fetchAssets` call when filling cheap page records.
  final int detailBatchSize;

  /// Filled items by id, with the modification time they were filled at (reused by reloads
  /// while the asset is unmodified).
  final Map<ItemId, MediaItem> _filled = {};

  /// Platform ids of loaded cells still waiting for their details, oldest page first.
  final List<String> _pendingDetails = [];
  Future<void>? _filling;

  StreamSubscription<SystemPhotoChange>? _changes;
  StreamSubscription<PhotoLibraryAuthorization>? _authorizations;
  bool _observing = false;
  int _epoch = 0;
  Future<void>? _paging;

  SystemPhotoPlatform? get _platform => state.platform;

  /// Reads the access without prompting (the tab shows the right empty state before [open]).
  Future<void> refreshAuthorization() async {
    final lib = library;
    if (lib == null || _platform == null) return;
    try {
      final status = await lib.authorizationStatus();
      if (mounted) state = state.copyWith(authorization: status, clearError: true);
    } on LibraryNativeException catch (e) {
      if (mounted) state = state.copyWith(error: e.code);
    }
  }

  /// The Photos tab's system view opened: asks for access the first time (V2-103), then starts
  /// observing and loads the first page. Returns the access.
  Future<PhotoLibraryAuthorization> open() async {
    final lib = library;
    if (lib == null || _platform == null) return state.authorization;
    try {
      var status = await lib.authorizationStatus();
      if (status == PhotoLibraryAuthorization.notDetermined) status = await lib.requestAuthorization();
      if (!mounted) return status;
      state = state.copyWith(authorization: status, opened: true, clearError: true);
      if (!status.canRead) {
        state = state.copyWith(items: const [], totalCount: 0);
        return status;
      }
      await _startObserving();
      await reload();
      return status;
    } on LibraryNativeException catch (e) {
      if (mounted) state = state.copyWith(error: e.code, opened: true);
      return state.authorization;
    }
  }

  Future<void> _startObserving() async {
    final lib = library!;
    _changes ??= lib.changes.listen(_onChange);
    _authorizations ??= lib.authorizationChanges.listen(_onAuthorization);
    if (!_observing) {
      _observing = true;
      await lib.startObserving();
    }
  }

  /// Lists [filter] of the library or of [albumId] from the start.
  Future<void> setFilter(SystemPhotoFilter filter, {String? albumId}) async {
    if (filter == state.filter && albumId == state.albumId) return;
    state = state.copyWith(filter: filter, albumId: albumId, clearAlbum: albumId == null, items: const [], totalCount: 0);
    if (state.authorization.canRead && state.opened) await reload();
  }

  /// Loads the next page (no-op while one is loading or when complete).
  Future<void> loadMore() {
    if (_paging != null) return _paging!;
    if (!state.opened || !state.authorization.canRead || (state.complete && state.changeToken != null)) return Future.value();
    final run = _loadMore(_epoch);
    _paging = run;
    return run.whenComplete(() => _paging = null);
  }

  Future<void> _loadMore(int epoch) async {
    final lib = library;
    final platform = _platform;
    if (lib == null || platform == null) return;
    state = state.copyWith(loading: true);
    try {
      final page = await lib.fetchPage(
        filter: state.filter,
        albumId: state.albumId,
        offset: state.items.length,
        limit: pageSize,
        changeToken: state.changeToken,
      );
      if (!mounted || epoch != _epoch) return;
      if (page.tokenStale) {
        state = state.copyWith(loading: false);
        unawaited(reload());
        return;
      }
      state = state.copyWith(
        items: [...state.items, ..._items(page.assets, platform)],
        totalCount: page.totalCount,
        changeToken: page.changeToken,
        loading: false,
        clearError: true,
      );
      _queueDetails(page.assets, platform);
    } on LibraryNativeException catch (e) {
      if (mounted && epoch == _epoch) state = state.copyWith(loading: false, error: e.code);
    }
  }

  /// Reloads the loaded window (at least one page) from a fresh snapshot.
  Future<void> reload() async {
    final lib = library;
    final platform = _platform;
    if (lib == null || platform == null || !state.authorization.canRead) return;
    final epoch = ++_epoch;
    final want = state.items.length < pageSize ? pageSize : state.items.length;
    state = state.copyWith(loading: true);
    try {
      final items = <MediaItem>[];
      final assets = <SystemPhotoAsset>[];
      String? token;
      var total = 0;
      var offset = 0;
      for (var attempt = 0; attempt < 3; attempt++) {
        items.clear();
        assets.clear();
        token = null;
        offset = 0;
        var stale = false;
        while (offset < want) {
          final page = await lib.fetchPage(
            filter: state.filter,
            albumId: state.albumId,
            offset: offset,
            limit: pageSize,
            changeToken: token,
          );
          if (!mounted || epoch != _epoch) return;
          if (page.tokenStale) {
            stale = true;
            break;
          }
          token = page.changeToken;
          total = page.totalCount;
          items.addAll(_items(page.assets, platform));
          assets.addAll(page.assets);
          offset += page.assets.length;
          if (page.nextOffset == null) break;
        }
        if (!stale) break;
      }
      _pendingDetails.clear();
      final loaded = {for (final i in items) i.id};
      _filled.removeWhere((id, _) => !loaded.contains(id));
      state = state.copyWith(items: items, totalCount: total, changeToken: token, loading: false, clearError: true);
      _queueDetails(assets, platform);
    } on LibraryNativeException catch (e) {
      if (mounted && epoch == _epoch) state = state.copyWith(loading: false, error: e.code);
    }
  }

  void _onChange(SystemPhotoChange change) {
    if (!mounted || !state.opened) return;
    final shifts = !change.incremental || change.inserted.isNotEmpty || change.removed.isNotEmpty || change.changeToken != state.changeToken;
    if (shifts) {
      unawaited(reload());
    } else if (change.changed.isNotEmpty) {
      unawaited(_refreshInPlace(change.changed));
    }
  }

  Future<void> _refreshInPlace(List<String> ids) async {
    final lib = library;
    final platform = _platform;
    if (lib == null || platform == null) return;
    final epoch = _epoch;
    try {
      final fresh = {for (final item in _items(await lib.fetchAssets(ids), platform)) item.id: item};
      if (!mounted || epoch != _epoch || fresh.isEmpty) return;
      _filled.addAll(fresh);
      state = state.copyWith(items: [for (final item in state.items) fresh[item.id] ?? item]);
    } on LibraryNativeException catch (e) {
      if (mounted) state = state.copyWith(error: e.code);
    }
  }

  void _onAuthorization(PhotoLibraryAuthorization status) {
    if (!mounted) return;
    state = state.copyWith(authorization: status);
    if (status.canRead) {
      unawaited(reload());
    } else {
      _epoch++;
      _pendingDetails.clear();
      _filled.clear();
      state = state.copyWith(items: const [], totalCount: 0);
    }
  }

  /// Limited access: lets the user change the selection, then reloads.
  Future<void> manageLimitedSelection() async {
    final lib = library;
    if (lib == null || !state.limited) return;
    try {
      await lib.presentLimitedLibraryPicker();
      await reload();
    } on LibraryNativeException catch (e) {
      if (mounted && e.code != LibraryNativeErrorCode.cancelled) state = state.copyWith(error: e.code);
    }
  }

  /// Denied access: opens the app's system settings page.
  Future<bool> openSettings() async {
    final lib = library;
    if (lib == null) return false;
    try {
      return await lib.openAppSettings();
    } on LibraryNativeException {
      return false;
    }
  }

  /// [assets] as items; a cheap record whose asset was filled earlier and is unmodified since
  /// comes back filled.
  List<MediaItem> _items(List<SystemPhotoAsset> assets, SystemPhotoPlatform platform) {
    final out = <MediaItem>[];
    for (final a in assets) {
      try {
        final item = systemMediaItem(a, platform);
        final filled = systemAssetHasDetails(a) ? null : _filled[item.id];
        out.add(filled != null && filled.modifiedAt == item.modifiedAt ? filled : item);
      } on FormatException {
        // A platform id outside the V2-09 rules is skipped rather than shown with a broken id.
      }
    }
    return out;
  }

  /// Queues the cheap records of [assets] that were not filled yet and starts filling them.
  void _queueDetails(List<SystemPhotoAsset> assets, SystemPhotoPlatform platform) {
    for (final a in assets) {
      if (systemAssetHasDetails(a)) continue;
      try {
        final item = systemMediaItem(a, platform);
        final filled = _filled[item.id];
        if (filled != null && filled.modifiedAt == item.modifiedAt) continue;
        _pendingDetails.add(a.localIdentifier);
      } on FormatException {
        // Skipped, as in _items.
      }
    }
    if (_pendingDetails.isNotEmpty) _filling ??= _fillDetails().whenComplete(() => _filling = null);
  }

  /// Fills queued cells in batches of [detailBatchSize] (one native call, one state update each).
  Future<void> _fillDetails() async {
    final lib = library;
    final platform = _platform;
    if (lib == null || platform == null) return;
    while (mounted && _pendingDetails.isNotEmpty) {
      final epoch = _epoch;
      final take = _pendingDetails.length < detailBatchSize ? _pendingDetails.length : detailBatchSize;
      final ids = _pendingDetails.sublist(0, take);
      _pendingDetails.removeRange(0, take);
      List<SystemPhotoAsset> assets;
      try {
        assets = await lib.fetchAssets(ids);
      } on LibraryNativeException {
        // The cells keep their cheap records; a later reload queues them again.
        continue;
      }
      if (!mounted) return;
      if (epoch != _epoch) continue;
      final fresh = <ItemId, MediaItem>{};
      for (final a in assets) {
        try {
          fresh[systemItemId(a, platform)] = systemMediaItem(a, platform);
        } on FormatException {
          // Skipped, as in _items.
        }
      }
      if (fresh.isEmpty) continue;
      _filled.addAll(fresh);
      state = state.copyWith(items: [for (final item in state.items) fresh[item.id] ?? item]);
    }
  }

  @override
  void dispose() {
    _epoch++;
    _pendingDetails.clear();
    unawaited(_changes?.cancel());
    unawaited(_authorizations?.cancel());
    if (_observing) unawaited(library?.stopObserving().catchError((Object _) {}));
    super.dispose();
  }
}

/// The system photo library of this platform (PhotoKit, MediaStore), or null where there is none.
final systemPhotoLibraryProvider = Provider<SystemPhotoLibrary?>((ref) {
  if (systemPhotoPlatformFor(defaultTargetPlatform) == null) return null;
  return NativePhotoLibrary();
});

/// The system photos of the Photos tab. Call `SystemPhotosController.open` when the tab's system
/// view first shows, `loadMore` near the end of the grid.
final systemPhotosControllerProvider = StateNotifierProvider<SystemPhotosController, SystemPhotosState>(
  (ref) => SystemPhotosController(
    library: ref.watch(systemPhotoLibraryProvider),
    platform: systemPhotoPlatformFor(defaultTargetPlatform),
  ),
);
