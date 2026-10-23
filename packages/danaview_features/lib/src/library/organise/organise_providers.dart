// OWNER: HOM-19
//
// Riverpod side of Organise (HOM plan §8.1, D-98f / V2-119): the organiser over the open library
// store, the Favourites list, Recents, the recents hook every viewer calls, and the sort remembered
// per folder or list. With DANAVIEW_FILES_HOME off no store opens (HOM-17), so favourites and
// recents are empty and nothing here touches the 1.1 screens. Named sorts live in
// SharedPreferences through [PrefsSortPreferenceStore], which the app root installs (INT wiring);
// until then they are kept in memory.

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/library_store_providers.dart';

export 'package:danaview_library/danaview_library.dart'
    show
        EntryId,
        FavouriteEntry,
        FavouriteFolder,
        FavouriteItem,
        FileEntry,
        FolderId,
        FolderSortScope,
        InMemorySortPreferenceStore,
        ItemId,
        LibraryOrganiser,
        LibrarySort,
        LibrarySortMode,
        NamedSortScope,
        SortPreferenceStore,
        SortScope,
        compareNatural,
        recentsCap,
        sortEntries;

/// Named sorts in SharedPreferences (keys `organise.sort.<scope>`).
final class PrefsSortPreferenceStore implements SortPreferenceStore {
  /// A store over [prefs].
  PrefsSortPreferenceStore(this.prefs);

  /// The preferences.
  final SharedPreferences prefs;

  @override
  String? read(String key) {
    final value = prefs.get(key);
    return value is String ? value : null;
  }

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }
}

/// Where named sorts are kept. The app root overrides it with [PrefsSortPreferenceStore].
final sortPreferenceStoreProvider = Provider<SortPreferenceStore>((ref) => InMemorySortPreferenceStore());

/// The organiser of the open library, or null (flag off, or the store not open yet).
final libraryOrganiserProvider = Provider<LibraryOrganiser?>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return null;
  return LibraryOrganiser(store, sortPreferences: ref.watch(sortPreferenceStoreProvider));
});

/// Bumped after a named sort changes (Danaview folder sorts tick [libraryRevisionProvider]).
final _namedSortRevisionProvider = StateProvider<int>((ref) => 0);

/// The Favourites list: starred folders, then starred files (empty without a store).
final favouritesProvider = Provider<List<FavouriteItem>>((ref) {
  final organiser = ref.watch(libraryOrganiserProvider);
  if (organiser == null) return const [];
  ref.watch(libraryRevisionProvider);
  ref.watch(_namedSortRevisionProvider);
  return organiser.favourites();
});

/// Whether the Danaview item [id] is starred (false for anything else, or without a store).
final isFavouriteProvider = Provider.family<bool, ItemId>((ref, id) {
  final organiser = ref.watch(libraryOrganiserProvider);
  if (organiser == null) return false;
  ref.watch(libraryRevisionProvider);
  return organiser.isFavourite(id);
});

/// The last files opened in any viewer, newest first, at most 50 (empty without a store).
final recentFilesProvider = Provider<List<FileEntry>>((ref) {
  final organiser = ref.watch(libraryOrganiserProvider);
  if (organiser == null) return const [];
  ref.watch(libraryRevisionProvider);
  return organiser.recents();
});

/// The recents hook: every viewer (photo, PDF, Quick Look, text, the player for a library video)
/// calls `ref.read(recordLibraryOpenProvider)(entryId)` when it opens a Danaview file. A no-op
/// without a store; a failed write (a file trashed meanwhile) is ignored.
final recordLibraryOpenProvider = Provider<Future<void> Function(EntryId id)>((ref) {
  final organiser = ref.watch(libraryOrganiserProvider);
  return (id) async {
    if (organiser == null) return;
    try {
      await organiser.markOpened(id);
    } on LibraryWriteException {
      // The file left the library between opening and recording: nothing to remember.
    }
  };
});

/// The default sort of [scope]: folders by name A to Z, the library-wide tabs and Favourites
/// newest first.
LibrarySort defaultSortFor(SortScope scope) => switch (scope) {
      FolderSortScope() => LibrarySort.folderDefault,
      NamedSortScope(:final key) when key.startsWith('linked:') => LibrarySort.folderDefault,
      NamedSortScope() => LibrarySort.recentFirst,
    };

/// The remembered sort of [scope] (or its default).
final librarySortProvider = Provider.family<LibrarySort, SortScope>((ref, scope) {
  final fallback = defaultSortFor(scope);
  switch (scope) {
    case FolderSortScope():
      final organiser = ref.watch(libraryOrganiserProvider);
      if (organiser == null) return fallback;
      ref.watch(libraryRevisionProvider);
      return organiser.sortOf(scope, fallback: fallback);
    case NamedSortScope():
      ref.watch(_namedSortRevisionProvider);
      return LibrarySort.tryDecode(ref.watch(sortPreferenceStoreProvider).read(scope.preferenceKey)) ?? fallback;
  }
});

/// Remembers sorts.
final class LibrarySortMemory {
  LibrarySortMemory._(this._ref);

  final Ref _ref;

  /// Remembers [sort] for [scope]. A Danaview folder's sort needs the store (ignored without one).
  Future<void> remember(SortScope scope, LibrarySort sort) async {
    switch (scope) {
      case FolderSortScope():
        await _ref.read(libraryOrganiserProvider)?.setSort(scope, sort);
      case NamedSortScope():
        await _ref.read(sortPreferenceStoreProvider).write(scope.preferenceKey, sort.encode());
        _ref.read(_namedSortRevisionProvider.notifier).state++;
    }
  }
}

/// The sort memory.
final librarySortMemoryProvider = Provider<LibrarySortMemory>(LibrarySortMemory._);
