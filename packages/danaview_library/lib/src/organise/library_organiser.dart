// OWNER: HOM-19
//
// LibraryOrganiser: favourites, recents and remembered sorts over a [LibraryStore] (HOM plan §8.1,
// D-98f / V2-119). Writes go through the store's one writer (HOM-17: `setEntryFavourite`,
// `setFolderFavourite`, `markOpened`, `clearRecents`, `setFolderSort`); reads use its read-only
// connection. Trashed rows never appear in favourites or recents (V2-08). Recents keep the last 50
// files opened in any viewer (the library.db trigger) and are never synced: they live only in
// library.db, which no sync path reads.

import '../db/library_folder.dart';
import '../db/library_reader.dart';
import '../db/row_codec.dart';
import '../model/file_entry.dart';
import '../model/ids.dart';
import '../store/library_store.dart';
import 'library_sort.dart';
import 'sort_memory.dart';

/// One row of the Favourites list: a Danaview folder or a file.
sealed class FavouriteItem {
  const FavouriteItem();

  /// The item id.
  ItemId get id;

  /// The name shown.
  String get name;
}

/// A starred folder.
final class FavouriteFolder extends FavouriteItem {
  /// A starred folder.
  const FavouriteFolder(this.folder);

  /// The folder.
  final LibraryFolder folder;

  @override
  ItemId get id => folder.id;

  @override
  String get name => folder.name;
}

/// A starred file.
final class FavouriteEntry extends FavouriteItem {
  /// A starred file.
  const FavouriteEntry(this.entry);

  /// The file.
  final FileEntry entry;

  @override
  ItemId get id => entry.id;

  @override
  String get name => entry.displayName;
}

/// Favourites, recents and sorts of one library.
final class LibraryOrganiser {
  /// The organiser of [store]; named sorts are kept in [sortPreferences].
  LibraryOrganiser(this.store, {SortPreferenceStore? sortPreferences})
      : sortPreferences = sortPreferences ?? InMemorySortPreferenceStore();

  /// The library.
  final LibraryStore store;

  /// Where named sorts are kept.
  final SortPreferenceStore sortPreferences;

  LibraryReader get _reader => store.reader;

  // ---- favourites ---------------------------------------------------------------------------

  /// Stars or unstars the Danaview entry or folder [id]. Throws [ArgumentError] for any other id
  /// (linked and system items are read-only, HOM plan §8.1) and the store's
  /// `LibraryWriteException` for a missing or trashed row.
  Future<void> setFavourite(ItemId id, bool favourite) {
    if (EntryId.tryParse(id.value) case final entry?) {
      return store.write((w, _) => w.setEntryFavourite(entry, favourite));
    }
    if (FolderId.tryParse(id.value) case final folder?) {
      return store.write((w, _) => w.setFolderFavourite(folder, favourite));
    }
    throw ArgumentError.value(id.value, 'id', 'only Danaview files and folders can be favourites');
  }

  /// Flips the star of [id]; returns the new state.
  Future<bool> toggleFavourite(ItemId id) async {
    final next = !isFavourite(id);
    await setFavourite(id, next);
    return next;
  }

  /// True when [id] is a live, starred Danaview entry or folder.
  bool isFavourite(ItemId id) {
    if (EntryId.tryParse(id.value) case final entry?) {
      final e = _reader.entry(entry);
      return e != null && !e.isTrashed && e.isFavourite;
    }
    if (FolderId.tryParse(id.value) case final folder?) {
      final f = _reader.folder(folder);
      return f != null && !f.isTrashed && f.isFavourite;
    }
    return false;
  }

  /// Starred live folders.
  List<LibraryFolder> favouriteFolders() => [
        for (final row in _reader.db.select('SELECT * FROM folders WHERE is_favourite = 1 AND trashed_at IS NULL'))
          folderFromRow(row),
      ];

  /// Starred live files, in [sort] order.
  List<FileEntry> favouriteEntries({LibrarySort sort = LibrarySort.recentFirst}) => sortEntries(
        _reader.entriesPage(const EntryQuery(favouritesOnly: true), limit: -1),
        sort,
      );

  /// The Favourites list (the Overview row and the chip): folders first, by natural name, then
  /// files in the remembered Favourites sort.
  List<FavouriteItem> favourites() => [
        for (final f in sortFolders(favouriteFolders(), LibrarySort.folderDefault)) FavouriteFolder(f),
        for (final e in favouriteEntries(sort: sortOf(NamedSortScope.favourites, fallback: LibrarySort.recentFirst)))
          FavouriteEntry(e),
      ];

  // ---- recents ------------------------------------------------------------------------------

  /// Records that a viewer opened [id] (every viewer calls this; the list keeps the last 50).
  Future<void> markOpened(EntryId id) => store.write((w, now) => w.markOpened(id, now: now));

  /// The live files opened most recently, newest first (at most 50).
  List<FileEntry> recents() => _reader.recents();

  /// Clears Recents.
  Future<void> clearRecents() => store.write((w, _) => w.clearRecents());

  // ---- sort ---------------------------------------------------------------------------------

  /// The remembered sort of [scope], or [fallback] (folders: name A to Z; named scopes: as given).
  LibrarySort sortOf(SortScope scope, {LibrarySort fallback = LibrarySort.folderDefault}) => switch (scope) {
        FolderSortScope(:final id) => switch (_reader.folder(id)) {
            final folder? => LibrarySort.ofFolder(folder, fallback: fallback),
            null => fallback,
          },
        NamedSortScope() => LibrarySort.tryDecode(sortPreferences.read(scope.preferenceKey)) ?? fallback,
      };

  /// Remembers [sort] for [scope].
  Future<void> setSort(SortScope scope, LibrarySort sort) => switch (scope) {
        FolderSortScope(:final id) => store.write((w, _) => w.setFolderSort(id, sort.mode.code, descending: sort.descending)),
        NamedSortScope() => sortPreferences.write(scope.preferenceKey, sort.encode()),
      };

  /// The live subfolders and files of Danaview folder [id] in its remembered sort (or [sort]).
  /// Folders come before files, as in the 1.1 browser.
  ({List<LibraryFolder> folders, List<FileEntry> entries}) folderContents(FolderId id, {LibrarySort? sort}) {
    final s = sort ?? sortOf(SortScope.folder(id));
    return (
      folders: sortFolders(_reader.childFolders(id), s),
      entries: sortEntries(_reader.entriesPage(EntryQuery(folderId: id, sort: EntrySortKey.addedAt, descending: false), limit: -1), s),
    );
  }
}
