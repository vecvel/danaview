// OWNER: HOM-18
//
// Riverpod providers behind the filter tabs and the Folders tab (ARCH v1.2 V2-114, §5.3; HOM plan
// §5.2). Every list is a lazy pager over HOM-17's paged read-only queries: the count is read once
// per library revision and rows are read a page at a time as the list builds them, so a
// 50,000-entry library costs one COUNT and the visible pages (HOM-14). Each provider watches
// [libraryRevisionProvider], so a write (create, rename, move, delete, restore) re-reads in the
// frame after it lands. Without a store (DANAVIEW_FILES_HOME off, or not opened yet) every
// provider yields null or empty.

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import 'library_filters.dart';

/// Rows read per page.
const int libraryEntryPageSize = 100;

/// A lazily paged, read-only list of the live entries matching one [EntryQuery].
final class LibraryEntryPages {
  /// Pages of [query] over [reader]; the count is read now, rows on first access.
  LibraryEntryPages(LibraryReader reader, this.query, {this.pageSize = libraryEntryPageSize})
      : _reader = reader,
        length = reader.countEntries(query);

  /// No rows (no store).
  LibraryEntryPages.empty()
      : _reader = null,
        query = const EntryQuery(),
        pageSize = libraryEntryPageSize,
        length = 0;

  final LibraryReader? _reader;

  /// The query.
  final EntryQuery query;

  /// Rows per page.
  final int pageSize;

  /// How many rows the list has.
  final int length;

  final Map<int, List<FileEntry>> _pages = {};

  /// True without rows.
  bool get isEmpty => length == 0;

  /// The row at [index] (reads its page on first access), or null when it vanished between the
  /// count and the page read (the next revision rebuilds the pager).
  FileEntry? at(int index) {
    final reader = _reader;
    if (reader == null || index < 0 || index >= length) return null;
    final page = index ~/ pageSize;
    final rows = _pages[page] ??= reader.entriesPage(query, offset: page * pageSize, limit: pageSize);
    final offset = index - page * pageSize;
    return offset < rows.length ? rows[offset] : null;
  }

  /// Every row (tests and small lists only).
  List<FileEntry> toList() => [for (var i = 0; i < length; i++) if (at(i) case final entry?) entry];
}

/// Which filter list: the filter and, for Documents, the optional sub-filter.
typedef LibraryFilterKey = ({LibraryFilter filter, DocumentKind? subFilter});

/// The query of a filter list: newest first (the `All` timeline is chronological, D-98a).
EntryQuery libraryFilterQuery(LibraryFilterKey key) => EntryQuery(
      kinds: key.filter.kinds,
      subKind: key.filter == LibraryFilter.documents ? key.subFilter?.code : null,
      sort: EntrySortKey.addedAt,
      descending: true,
    );

/// The Danaview entries of a filter (empty without a store).
final libraryFilterEntriesProvider = Provider.family<LibraryEntryPages, LibraryFilterKey>((ref, key) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return LibraryEntryPages.empty();
  ref.watch(libraryRevisionProvider);
  return LibraryEntryPages(store.reader, libraryFilterQuery(key));
});

/// The entries directly in Danaview folder [folder], by name (empty without a store).
final libraryFolderEntriesProvider = Provider.family<LibraryEntryPages, FolderId>((ref, folder) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return LibraryEntryPages.empty();
  ref.watch(libraryRevisionProvider);
  return LibraryEntryPages(store.reader, EntryQuery(folderId: folder, sort: EntrySortKey.name, descending: false));
});

/// The live subfolders of [parent] (the top level when null), by name.
final libraryChildFoldersProvider = Provider.family<List<LibraryFolder>, FolderId?>((ref, parent) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return const [];
  ref.watch(libraryRevisionProvider);
  return store.reader.childFolders(parent);
});

/// The live folder [id] with its path from the top level (empty when it isn't live).
final libraryFolderPathProvider = Provider.family<List<LibraryFolder>, FolderId>((ref, id) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return const [];
  ref.watch(libraryRevisionProvider);
  return store.reader.pathOf(id);
});

/// The facts of entry [id] (null without a store or facts).
final libraryEntryMetaProvider = Provider.family<EntryMeta?, EntryId>((ref, id) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return null;
  ref.watch(libraryRevisionProvider);
  return store.reader.meta(id);
});

/// Documents in the user's linked folders (HOM plan §8.1: shown under Documents, read-only).
///
/// Empty by default: the linked-folder document scan arrives with the Documents tab in slice S3;
/// the app root overrides this provider then.
final linkedDocumentsProvider = Provider<List<DocumentItem>>((ref) => const []);
