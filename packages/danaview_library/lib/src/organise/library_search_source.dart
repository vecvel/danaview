// OWNER: HOM-19
//
// The Danaview folders' snapshot for the name index: every live entry (with its folder's name)
// and every live folder (with its parent's name). Trashed rows are left out by the query itself
// (V2-08: "excluded from every filter, search, recents and index query"). One read of five
// columns per row.
//
// The FEAT controller re-reads it after library writes, off the UI isolate:
// [loadDanaviewSearchSnapshot] hands [readDanaviewSearchSnapshotAt] to the caller's background
// runner (`Isolate.run` in the app). This file never imports dart:isolate itself (ARCH rule 20:
// dart:io and dart:isolate only under lib/src/{store,import,inbox,actions,db,desktop}/). There it
// opens its own read-only connection, reads the rows, and fingerprints them (FNV-1a over every searchable column). When the fingerprint
// matches the one the index already holds, the write changed no searchable row (an import progress
// checkpoint, a favourite, a sort, a last-opened stamp) and nothing is built or swapped. Otherwise
// it builds and sorts the items there ([prepareSearchSource]) and hands back a source the UI
// isolate swaps in with [NameIndex.replacePreparedSource] in O(1).

import 'dart:async';

import 'package:sqlite3/sqlite3.dart';

import '../db/library_connection.dart';
import '../db/library_reader.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import 'name_search.dart';

/// The source id of the Danaview folders in a [NameIndex].
const String danaviewSearchSourceId = 'danaview';

/// A read of the Danaview folders for the name index.
final class DanaviewSearchSnapshot {
  /// A snapshot; [source] is null when the rows matched the fingerprint asked about.
  const DanaviewSearchSnapshot(this.fingerprint, this.source);

  /// The fingerprint of every searchable column of every live row.
  final int fingerprint;

  /// The prepared items, or null when unchanged (nothing to swap in).
  final PreparedSearchSource? source;

  /// True when the rows changed since the fingerprint asked about.
  bool get changed => source != null;
}

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;

int _fnv(int h, String? s) {
  if (s == null) return (h ^ 0x1ff) * _fnvPrime;
  for (var i = 0; i < s.length; i++) {
    h = (h ^ s.codeUnitAt(i)) * _fnvPrime;
  }
  // A separator outside UTF-16 so ('ab', 'c') and ('a', 'bc') differ.
  return (h ^ 0x1fe) * _fnvPrime;
}

typedef _Rows = ({ResultSet folders, ResultSet entries, int fingerprint});

_Rows _readRows(Database db) {
  final folders = db.select('SELECT id, parent_id, name FROM folders WHERE trashed_at IS NULL ORDER BY id');
  final entries = db.select('SELECT id, folder_id, display_name, kind, sub_kind FROM entries WHERE trashed_at IS NULL ORDER BY id');
  var h = _fnvOffset;
  for (final row in folders.rows) {
    for (final v in row) {
      h = _fnv(h, v as String?);
    }
  }
  h = (h ^ 0x1fd) * _fnvPrime;
  for (final row in entries.rows) {
    for (final v in row) {
      h = _fnv(h, v as String?);
    }
  }
  return (folders: folders, entries: entries, fingerprint: h);
}

List<SearchItem> _items(_Rows rows) {
  final folderNames = <String, String>{for (final row in rows.folders) row['id'] as String: row['name'] as String};
  final items = <SearchItem>[];
  for (final row in rows.folders) {
    items.add(SearchItem(
      id: FolderId.parse(row['id'] as String),
      name: row['name'] as String,
      origin: SearchOrigin.danaview,
      folderName: folderNames[row['parent_id'] as String?],
    ));
  }
  for (final row in rows.entries) {
    items.add(SearchItem(
      id: EntryId.parse(row['id'] as String),
      name: row['display_name'] as String,
      origin: SearchOrigin.danaview,
      kind: FileKind.decode(row['kind'] as String),
      subKind: row['sub_kind'] as String?,
      folderName: folderNames[row['folder_id'] as String],
    ));
  }
  return items;
}

/// Every live entry and folder of the library behind [reader], as search items.
List<SearchItem> danaviewSearchItems(LibraryReader reader) => _items(_readRows(reader.db));

/// Reads the Danaview folders from [db] on the calling isolate; the items are built and sorted only
/// when the fingerprint differs from [unlessFingerprint].
DanaviewSearchSnapshot readDanaviewSearchSnapshot(Database db, {int? unlessFingerprint}) {
  final rows = _readRows(db);
  if (rows.fingerprint == unlessFingerprint) return DanaviewSearchSnapshot(rows.fingerprint, null);
  return DanaviewSearchSnapshot(rows.fingerprint, prepareSearchSource(_items(rows)));
}

/// [readDanaviewSearchSnapshot] over its own read-only connection to the library database at
/// [databasePath] (`LibraryStore.paths.databasePath`), closed before it returns. Meant to run in a
/// background isolate (see [loadDanaviewSearchSnapshot]).
DanaviewSearchSnapshot readDanaviewSearchSnapshotAt(String databasePath, {int? unlessFingerprint}) {
  final db = openLibraryReadConnection(databasePath);
  try {
    return readDanaviewSearchSnapshot(db, unlessFingerprint: unlessFingerprint);
  } finally {
    db.dispose();
  }
}

/// Runs [computation] off the calling isolate and returns its result: `Isolate.run` in the app
/// and in tests. Injected so lib/src/organise/ stays free of dart:isolate (ARCH rule 20).
typedef BackgroundRunner = Future<R> Function<R>(FutureOr<R> Function() computation);

/// [readDanaviewSearchSnapshotAt] through [run] (a background isolate), so neither the read nor the
/// build and sort of the items lands on the UI isolate.
Future<DanaviewSearchSnapshot> loadDanaviewSearchSnapshot(String databasePath, {required BackgroundRunner run, int? unlessFingerprint}) =>
    run(() => readDanaviewSearchSnapshotAt(databasePath, unlessFingerprint: unlessFingerprint));

/// Refreshes the Danaview source of [index] from [reader] on the calling isolate (tests and small
/// libraries; the app loads it with [loadDanaviewSearchSnapshot]).
void refreshDanaviewSearchSource(NameIndex index, LibraryReader reader) =>
    index.replaceSource(danaviewSearchSourceId, danaviewSearchItems(reader));
