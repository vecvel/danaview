// OWNER: HOM-19
//
// The Danaview folders' snapshot for the name index: every live entry (with its folder's name)
// and every live folder (with its parent's name). Trashed rows are left out by the query itself
// (V2-08: "excluded from every filter, search, recents and index query"). One read of four
// columns per row on the read-only connection; the FEAT controller re-reads it after each write.

import 'package:sqlite3/sqlite3.dart';

import '../db/library_reader.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import 'name_search.dart';

/// The source id of the Danaview folders in a [NameIndex].
const String danaviewSearchSourceId = 'danaview';

/// Every live entry and folder of the library behind [reader], as search items.
List<SearchItem> danaviewSearchItems(LibraryReader reader) {
  final Database db = reader.db;
  final folderNames = <String, String>{
    for (final row in db.select('SELECT id, name FROM folders WHERE trashed_at IS NULL')) row['id'] as String: row['name'] as String,
  };
  final items = <SearchItem>[];
  for (final row in db.select('SELECT id, parent_id, name FROM folders WHERE trashed_at IS NULL')) {
    items.add(SearchItem(
      id: FolderId.parse(row['id'] as String),
      name: row['name'] as String,
      origin: SearchOrigin.danaview,
      folderName: folderNames[row['parent_id'] as String?],
    ));
  }
  for (final row in db.select('SELECT id, folder_id, display_name, kind, sub_kind FROM entries WHERE trashed_at IS NULL')) {
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

/// Refreshes the Danaview source of [index] from [reader].
void refreshDanaviewSearchSource(NameIndex index, LibraryReader reader) =>
    index.replaceSource(danaviewSearchSourceId, danaviewSearchItems(reader));
