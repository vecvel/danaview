// OWNER: HOM-19
//
// Sort (HOM plan §8.1, D-98f / V2-119): name (natural order), date added, date modified, size and
// type, ascending or descending, remembered per folder. Sorting is stable: rows with equal keys
// keep the order they came in (the merge sort of package:collection), and descending reverses the
// key comparison only, so ties never flip. Type sorts by kind, then sub-kind, then extension, then
// name, so files of one type stay in name order.
//
// The stored form is the `folders.sort_mode` / `sort_desc` pair of library.db for Danaview folders
// (ARCH §5.3) and `<code>:<asc|desc>` for every other scope (sort_memory.dart).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../db/library_folder.dart';
import '../model/file_entry.dart';
import 'natural_order.dart';

/// What a list is sorted by.
enum LibrarySortMode {
  /// Name, natural order.
  name('name', 'Name'),

  /// Date added.
  dateAdded('added', 'Date added'),

  /// Date modified.
  dateModified('modified', 'Date modified'),

  /// File size.
  size('size', 'Size'),

  /// File type.
  type('type', 'Type');

  const LibrarySortMode(this.code, this.label);

  /// The stored code (`folders.sort_mode`).
  final String code;

  /// The label of the sort menu.
  final String label;

  /// The mode stored as [code], or null.
  static LibrarySortMode? tryDecode(String? code) {
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return null;
  }

  /// The direction a user expects first when picking this mode: A to Z for name and type, newest
  /// and largest first otherwise.
  bool get defaultDescending => switch (this) {
        name || type => false,
        dateAdded || dateModified || size => true,
      };
}

/// A sort: a mode and a direction.
@immutable
final class LibrarySort {
  /// A sort.
  const LibrarySort(this.mode, {this.descending = false});

  /// [mode] in its usual direction ([LibrarySortMode.defaultDescending]).
  LibrarySort.natural(this.mode) : descending = mode.defaultDescending;

  /// The default of a Danaview or linked folder: name, A to Z (the 1.1 folder order).
  static const LibrarySort folderDefault = LibrarySort(LibrarySortMode.name);

  /// The default of the library-wide tabs (All, Videos, Photos, Documents): newest first.
  static const LibrarySort recentFirst = LibrarySort(LibrarySortMode.dateAdded, descending: true);

  /// What the list is sorted by.
  final LibrarySortMode mode;

  /// Descending order.
  final bool descending;

  /// This sort with [mode] (keeping the direction when the mode is unchanged).
  LibrarySort withMode(LibrarySortMode mode) => mode == this.mode ? this : LibrarySort.natural(mode);

  /// This sort the other way round.
  LibrarySort get reversed => LibrarySort(mode, descending: !descending);

  /// The `<code>:<asc|desc>` form.
  String encode() => '${mode.code}:${descending ? 'desc' : 'asc'}';

  /// The sort encoded by [encode], or null when [value] is unreadable.
  static LibrarySort? tryDecode(String? value) {
    if (value == null) return null;
    final i = value.indexOf(':');
    if (i < 0) return null;
    final mode = LibrarySortMode.tryDecode(value.substring(0, i));
    final dir = value.substring(i + 1);
    if (mode == null || (dir != 'asc' && dir != 'desc')) return null;
    return LibrarySort(mode, descending: dir == 'desc');
  }

  /// The remembered sort of [folder], or [fallback] when none is stored (or the code is unknown).
  static LibrarySort ofFolder(LibraryFolder folder, {LibrarySort fallback = folderDefault}) {
    final mode = LibrarySortMode.tryDecode(folder.sortMode);
    return mode == null ? fallback : LibrarySort(mode, descending: folder.sortDescending);
  }

  @override
  bool operator ==(Object other) => other is LibrarySort && other.mode == mode && other.descending == descending;

  @override
  int get hashCode => Object.hash(mode, descending);

  @override
  String toString() => 'LibrarySort(${encode()})';
}

/// The sortable facts of one row of any source (a Danaview entry or folder, a linked file, a
/// system asset). Unknown facts sort first ascending (last descending).
@immutable
final class SortFacts {
  /// Facts of one row. [kindRank] orders types (folders before files: pass -1 for a folder).
  const SortFacts({
    required this.name,
    this.addedAt,
    this.modifiedAt,
    this.sizeBytes,
    this.kindRank = 0,
    this.typeCode = '',
  });

  /// The name shown.
  final String name;

  /// When it was added.
  final DateTime? addedAt;

  /// When it was last modified.
  final DateTime? modifiedAt;

  /// Its size in bytes.
  final int? sizeBytes;

  /// The rank of its kind in type order.
  final int kindRank;

  /// Sub-kind and extension, compared after [kindRank] in type order.
  final String typeCode;
}

int _compareNullable(int? a, int? b) {
  if (a == null) return b == null ? 0 : -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

/// Sorts [items] by [sort] into a new list, stably. [facts] reads each item's facts once.
List<T> sortByFacts<T>(Iterable<T> items, LibrarySort sort, SortFacts Function(T item) facts) {
  final rows = [for (final item in items) (item, facts(item))];
  // Name keys are split once per row, and only when the comparison needs them.
  final keys = <int, NaturalSortKey>{};
  NaturalSortKey key(int i) => keys[i] ??= NaturalSortKey(rows[i].$2.name);
  final indexed = List<int>.generate(rows.length, (i) => i);
  int byKey(int i, int j) {
    final a = rows[i].$2;
    final b = rows[j].$2;
    return switch (sort.mode) {
      LibrarySortMode.name => key(i).compareTo(key(j)),
      LibrarySortMode.dateAdded => _compareNullable(a.addedAt?.millisecondsSinceEpoch, b.addedAt?.millisecondsSinceEpoch),
      LibrarySortMode.dateModified => _compareNullable(a.modifiedAt?.millisecondsSinceEpoch, b.modifiedAt?.millisecondsSinceEpoch),
      LibrarySortMode.size => _compareNullable(a.sizeBytes, b.sizeBytes),
      LibrarySortMode.type => _typeOrder(a, b, () => key(i).compareTo(key(j))),
    };
  }

  mergeSort<int>(indexed, compare: sort.descending ? (i, j) => byKey(j, i) : byKey);
  return [for (final i in indexed) rows[i].$1];
}

int _typeOrder(SortFacts a, SortFacts b, int Function() byName) {
  final rank = a.kindRank.compareTo(b.kindRank);
  if (rank != 0) return rank;
  final code = a.typeCode.compareTo(b.typeCode);
  return code != 0 ? code : byName();
}

/// The sort facts of a Danaview entry.
SortFacts entrySortFacts(FileEntry e) => SortFacts(
      name: e.displayName,
      addedAt: e.addedAt,
      modifiedAt: e.modifiedAt,
      sizeBytes: e.sizeBytes,
      kindRank: e.kind.index,
      typeCode: '${e.subKind ?? ''}\u0000${p.extension(e.displayName).toLowerCase()}',
    );

/// The sort facts of a Danaview folder (size unknown: folders sort by name among themselves).
SortFacts folderSortFacts(LibraryFolder f) => SortFacts(
      name: f.name,
      addedAt: f.createdAt,
      modifiedAt: f.modifiedAt,
      kindRank: -1,
    );

/// Sorts Danaview entries by [sort], stably.
List<FileEntry> sortEntries(Iterable<FileEntry> entries, LibrarySort sort) => sortByFacts(entries, sort, entrySortFacts);

/// Sorts Danaview folders by [sort], stably. Size sorts folders by name (they carry no size).
List<LibraryFolder> sortFolders(Iterable<LibraryFolder> folders, LibrarySort sort) =>
    sortByFacts(folders, sort.mode == LibrarySortMode.size ? LibrarySort(LibrarySortMode.name, descending: sort.descending) : sort, folderSortFacts);
