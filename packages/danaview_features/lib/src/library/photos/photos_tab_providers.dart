// OWNER: HOM-10
//
// Riverpod side of the Photos tab (ARCH v1.2 V2-102, V2-103, V2-108; Q-N8; BUILD_PLAN HOM-10):
//   * the Danaview photos of library.db (every Danaview folder) as grid items;
//   * the "Show my photo library" opt-in (Q-N8: off by default; the system library, and on
//     desktop the Pictures folders, appear only after the user turns it on);
//   * the album chips: All photos, Favourites, each Danaview folder holding photos, and the system
//     albums once the system library is shown (V2-108: they coexist);
//   * the tab's memory (density, chosen album, scroll offset), kept for the app's lifetime so a
//     tab switch comes back to the same place (the tab host may dispose the tab);
//   * the grid model: the photos of the chosen album, newest first, their date groups and aspect
//     buckets, computed once per change rather than per frame.
// With DANAVIEW_FILES_HOME off no store opens and the Photos tab is never shown (HOM-05).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../badges/media_badges.dart';
import '../files/library_store_providers.dart';
import '../organise/organise_providers.dart';
import '../sources/desktop_photos_source.dart';
import '../sources/system_photos_source.dart';
import 'photo_date_groups.dart';
import 'photo_grid_item.dart';
import 'photo_masonry_layout.dart';

/// The clock of the date groups (tests pin it).
final photosTabClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Every Danaview photo (all Danaview folders), newest first (empty without a store).
///
/// Re-run on every library write, but cheaply: one joined, already sorted query (no per-entry
/// meta reads, no Dart sort), and the photos that didn't change keep their instances, so a write
/// that touched no photo hands back the very same list and nothing downstream rebuilds, and a
/// favourite toggle replaces one item.
final danaviewPhotoItemsProvider = Provider<List<PhotoGridItem>>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return const [];
  ref.watch(libraryRevisionProvider);
  final next = readDanaviewPhotos(store, previous: _lastDanaviewPhotos[store]);
  _lastDanaviewPhotos[store] = next;
  return next;
});

/// The last read of each store, for [readDanaviewPhotos]'s instance reuse.
final Expando<List<PhotoGridItem>> _lastDanaviewPhotos = Expando('danaview photos');

// One query: the live photo entries with their size, capture time and badge flags, newest capture
// (or, without one, modification) first. `id` breaks ties so the order is stable.
final String _danaviewPhotosSql = 'SELECT e.id, e.folder_id, e.display_name, e.modified_at, e.is_favourite, '
    'm.width, m.height, m.taken_at, m.flags, m.entry_id AS meta_id '
    'FROM entries e LEFT JOIN entry_meta m ON m.entry_id = e.id '
    "WHERE e.trashed_at IS NULL AND e.kind = '${FileKind.photo.code}' "
    'ORDER BY COALESCE(m.taken_at, e.modified_at) DESC, e.id DESC';

/// Reads the live photo entries of [store] as grid items, newest first, in one query. Items equal
/// to one of [previous] (an earlier read) reuse that instance; when every item is unchanged,
/// [previous] itself is returned.
List<PhotoGridItem> readDanaviewPhotos(LibraryStore store, {List<PhotoGridItem>? previous}) {
  final rows = store.reader.db.select(_danaviewPhotosSql);
  final old = previous == null || previous.isEmpty ? null : {for (final p in previous) p.id: p};
  var unchanged = previous != null && previous.length == rows.length;
  final out = List<PhotoGridItem?>.filled(rows.length, null);
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final id = EntryId.parse(row['id'] as String);
    final name = row['display_name'] as String;
    final modifiedAt = timeOrNull(row['modified_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final hasMeta = row['meta_id'] != null;
    final meta = hasMeta ? EntryMeta(flags: row['flags'] as int? ?? 0) : null;
    final item = PhotoGridItem(
      id: id,
      origin: PhotoOrigin.danaview,
      name: name,
      date: timeOrNull(row['taken_at']) ?? modifiedAt,
      modifiedAt: modifiedAt,
      thumbSource: store.paths.entryFile(id, name),
      width: row['width'] as int? ?? 0,
      height: row['height'] as int? ?? 0,
      folderId: FolderId.parse(row['folder_id'] as String),
      isFavourite: row['is_favourite'] == 1,
      badges: MediaBadges.ofMeta(FileKind.photo, meta),
    );
    final before = old?[id];
    final kept = before != null && before == item ? before : item;
    out[i] = kept;
    if (unchanged && !identical(previous![i], kept)) unchanged = false;
  }
  if (unchanged) return previous!;
  return List.unmodifiable(out.cast<PhotoGridItem>());
}

/// The Danaview folders that hold at least one photo, by name (empty without a store).
final danaviewPhotoFoldersProvider = Provider<List<LibraryFolder>>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return const [];
  final ids = {for (final p in ref.watch(danaviewPhotoItemsProvider)) p.folderId};
  final folders = [
    for (final f in store.reader.allFolders())
      if (ids.contains(f.id)) f,
  ]..sort((a, b) => compareNatural(a.name, b.name));
  return List.unmodifiable(folders);
});

/// The preference key of the opt-in.
const photosShowSystemLibraryKey = 'photos.showSystemLibrary';

/// "Show my photo library" (Q-N8): false until the user turns it on. Kept in the app's key-value
/// preferences (the store the app root installs for named sorts).
class PhotosLibraryOptIn extends StateNotifier<bool> {
  /// The opt-in read from [store].
  PhotosLibraryOptIn(this.store) : super(store.read(photosShowSystemLibraryKey) == 'true');

  /// Where it is kept.
  final SortPreferenceStore store;

  /// Turns it on or off.
  Future<void> set(bool on) async {
    state = on;
    await store.write(photosShowSystemLibraryKey, on ? 'true' : null);
  }
}

/// The opt-in.
final photosLibraryOptInProvider = StateNotifierProvider<PhotosLibraryOptIn, bool>(
  (ref) => PhotosLibraryOptIn(ref.watch(sortPreferenceStoreProvider)),
);

/// True where there is a library to opt in to: a system photo library or desktop Pictures folders.
final photosSystemLibraryAvailableProvider = Provider<bool>((ref) {
  final system = ref.watch(systemPhotosControllerProvider.select((s) => s.available));
  return system || ref.watch(desktopRootResolverProvider) != null;
});

/// Which photos the grid shows.
@immutable
sealed class PhotoAlbumSelection {
  const PhotoAlbumSelection();

  /// Every photo: Danaview, and the system library once shown.
  static const PhotoAlbumSelection all = AllPhotosSelection();

  /// Starred Danaview photos.
  static const PhotoAlbumSelection favourites = FavouritePhotosSelection();
}

/// Every photo.
final class AllPhotosSelection extends PhotoAlbumSelection {
  /// The selection.
  const AllPhotosSelection();

  @override
  bool operator ==(Object other) => other is AllPhotosSelection;

  @override
  int get hashCode => 1;
}

/// Starred Danaview photos.
final class FavouritePhotosSelection extends PhotoAlbumSelection {
  /// The selection.
  const FavouritePhotosSelection();

  @override
  bool operator ==(Object other) => other is FavouritePhotosSelection;

  @override
  int get hashCode => 2;
}

/// The photos of one Danaview folder.
final class DanaviewFolderSelection extends PhotoAlbumSelection {
  /// The folder [id].
  const DanaviewFolderSelection(this.id);

  /// The folder.
  final FolderId id;

  @override
  bool operator ==(Object other) => other is DanaviewFolderSelection && other.id == id;

  @override
  int get hashCode => Object.hash(3, id);
}

/// The photos of one system album.
final class SystemAlbumSelection extends PhotoAlbumSelection {
  /// The album [albumId].
  const SystemAlbumSelection(this.albumId);

  /// The platform album id.
  final String albumId;

  @override
  bool operator ==(Object other) => other is SystemAlbumSelection && other.albumId == albumId;

  @override
  int get hashCode => Object.hash(4, albumId);
}

/// What the tab remembers between visits.
@immutable
final class PhotosTabView {
  /// A view.
  const PhotosTabView({this.density = photoGridDefaultDensity, this.album = PhotoAlbumSelection.all});

  /// Index into [photoGridDensityTargets].
  final int density;

  /// The chosen album.
  final PhotoAlbumSelection album;

  /// A copy.
  PhotosTabView copyWith({int? density, PhotoAlbumSelection? album}) =>
      PhotosTabView(density: density ?? this.density, album: album ?? this.album);
}

/// The Photos tab's memory: density and album (which rebuild the grid) and the scroll offset
/// (which doesn't).
class PhotosTabMemory extends StateNotifier<PhotosTabView> {
  /// Fresh memory.
  PhotosTabMemory() : super(const PhotosTabView());

  /// The last scroll offset of the grid.
  double scrollOffset = 0;

  /// Sets the density level (clamped).
  void setDensity(int level) {
    final clamped = level.clamp(0, photoGridDensityTargets.length - 1);
    if (clamped != state.density) state = state.copyWith(density: clamped);
  }

  /// Chooses an album; the grid starts at the top.
  void setAlbum(PhotoAlbumSelection album) {
    if (album == state.album) return;
    scrollOffset = 0;
    state = state.copyWith(album: album);
  }
}

/// The tab's memory, alive as long as the app.
final photosTabMemoryProvider = StateNotifierProvider<PhotosTabMemory, PhotosTabView>((ref) => PhotosTabMemory());

/// The loaded system photos as grid items (empty until opted in and readable).
final systemPhotoItemsProvider = Provider<List<PhotoGridItem>>((ref) {
  if (!ref.watch(photosLibraryOptInProvider)) return const [];
  final items = ref.watch(systemPhotosControllerProvider.select((s) => s.authorization.canRead ? s.items : const <MediaItem>[]));
  return List.unmodifiable([
    for (final item in items)
      if (item is PhotoMediaItem) photoGridItemOf(item, PhotoOrigin.system),
  ]);
});

/// The desktop Pictures photos as grid items (empty until opted in, and off desktop).
final desktopPhotoItemsProvider = Provider<List<PhotoGridItem>>((ref) {
  if (!ref.watch(photosLibraryOptInProvider)) return const [];
  if (ref.watch(desktopRootResolverProvider) == null) return const [];
  final photos = ref.watch(desktopPhotosControllerProvider).photos;
  return List.unmodifiable([for (final p in photos) photoGridItemOf(p, PhotoOrigin.desktop)]);
});

/// The system albums (empty until the system library is shown and readable).
final systemPhotoAlbumsProvider = FutureProvider<List<SystemPhotoAlbum>>((ref) async {
  if (!ref.watch(photosLibraryOptInProvider)) return const [];
  final library = ref.watch(systemPhotoLibraryProvider);
  final readable = ref.watch(systemPhotosControllerProvider.select((s) => s.opened && s.authorization.canRead));
  if (library == null || !readable) return const [];
  try {
    return List.unmodifiable([
      for (final album in await library.fetchAlbums())
        if (album.estimatedCount != 0) album,
    ]);
  } on LibraryNativeException {
    return const [];
  }
});

/// The album the grid really shows: the remembered one, or All when it is gone (a deleted folder,
/// the library turned off).
final effectivePhotoAlbumProvider = Provider<PhotoAlbumSelection>((ref) {
  final album = ref.watch(photosTabMemoryProvider.select((v) => v.album));
  switch (album) {
    case AllPhotosSelection() || FavouritePhotosSelection():
      return album;
    case DanaviewFolderSelection(:final id):
      return ref.watch(danaviewPhotoFoldersProvider).any((f) => f.id == id) ? album : PhotoAlbumSelection.all;
    case SystemAlbumSelection():
      return ref.watch(photosLibraryOptInProvider) ? album : PhotoAlbumSelection.all;
  }
});

/// The grid's input: photos newest first, their date groups and their aspect buckets.
@immutable
final class PhotosGridModel {
  /// A model of [photos] in [groups].
  PhotosGridModel(this.photos, this.groups)
      : buckets = Uint8List.fromList([for (final p in photos) p.bucket.index]);

  /// The empty model.
  static final PhotosGridModel empty = PhotosGridModel(const [], const []);

  /// The photos, newest first.
  final List<PhotoGridItem> photos;

  /// Their date groups (contiguous, covering every photo).
  final List<PhotoDateGroup> groups;

  /// One [PhotoAspectBucket.index] per photo.
  final Uint8List buckets;

  /// True without photos.
  bool get isEmpty => photos.isEmpty;
}

/// Builds the model of [photos] (newest first) relative to [now].
PhotosGridModel photosGridModelOf(List<PhotoGridItem> photos, DateTime now) =>
    photos.isEmpty ? PhotosGridModel.empty : PhotosGridModel(photos, groupPhotosByDate(photos, now));

/// The photos of the effective album, newest first.
final photosTabItemsProvider = Provider<List<PhotoGridItem>>((ref) {
  final album = ref.watch(effectivePhotoAlbumProvider);
  final danaview = ref.watch(danaviewPhotoItemsProvider);
  return switch (album) {
    AllPhotosSelection() => mergeNewestFirst(
        mergeNewestFirst(danaview, ref.watch(systemPhotoItemsProvider)),
        ref.watch(desktopPhotoItemsProvider),
      ),
    FavouritePhotosSelection() => List.unmodifiable(danaview.where((p) => p.isFavourite)),
    DanaviewFolderSelection(:final id) => List.unmodifiable(danaview.where((p) => p.folderId == id)),
    // The system controller lists the chosen album (the tab sets its filter).
    SystemAlbumSelection() => ref.watch(systemPhotoItemsProvider),
  };
});

/// The grid model of the Photos tab.
final photosGridModelProvider = Provider<PhotosGridModel>((ref) {
  final photos = ref.watch(photosTabItemsProvider);
  return photosGridModelOf(photos, ref.watch(photosTabClockProvider)());
});
