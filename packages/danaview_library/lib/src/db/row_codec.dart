// OWNER: HOM-17
//
// Row mapping between `library.db` rows and the model (ARCH v1.2 §5.3). Times are UTC milliseconds;
// kinds and source hints keep their raw strings (FileEntry.kindCode), so a row written by a later
// version reads and writes back unchanged.

import 'package:sqlite3/sqlite3.dart';

import '../model/file_entry.dart';
import '../model/ids.dart';
import '../model/source_hint.dart';
import 'library_folder.dart';

/// [time] as stored (UTC milliseconds).
int msOf(DateTime time) => time.toUtc().millisecondsSinceEpoch;

/// [time] as stored, or null.
int? msOrNull(DateTime? time) => time == null ? null : msOf(time);

/// The stored [ms] as a UTC time, or null.
DateTime? timeOrNull(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;

DateTime _time(Object? ms) => timeOrNull(ms) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// The folder of a `folders` row.
LibraryFolder folderFromRow(Row row) => LibraryFolder(
      id: FolderId.parse(row['id'] as String),
      parentId: switch (row['parent_id']) { final String p => FolderId.parse(p), _ => null },
      name: row['name'] as String,
      createdAt: _time(row['created_at']),
      modifiedAt: _time(row['modified_at']),
      isFavourite: row['is_favourite'] == 1,
      sortMode: row['sort_mode'] as String?,
      sortDescending: row['sort_desc'] == 1,
      systemRole: FolderSystemRole.tryDecode(row['system_role'] as String?),
      trashedAt: timeOrNull(row['trashed_at']),
      expiresAt: timeOrNull(row['expires_at']),
    );

/// The entry of an `entries` row.
FileEntry entryFromRow(Row row) => FileEntry.stored(
      id: EntryId.parse(row['id'] as String),
      folderId: FolderId.parse(row['folder_id'] as String),
      displayName: row['display_name'] as String,
      kindCode: row['kind'] as String,
      subKind: row['sub_kind'] as String?,
      sizeBytes: row['size_bytes'] as int,
      addedAt: _time(row['added_at']),
      modifiedAt: _time(row['modified_at']),
      lastOpenedAt: timeOrNull(row['last_opened_at']),
      isFavourite: row['is_favourite'] == 1,
      sourceHint: SourceHint.decode(row['source_hint'] as String),
      quickHash: row['quick_hash'] as String?,
      trashedAt: timeOrNull(row['trashed_at']),
      expiresAt: timeOrNull(row['expires_at']),
    );

/// The facts of an `entry_meta` row.
EntryMeta metaFromRow(Row row) => EntryMeta(
      width: row['width'] as int?,
      height: row['height'] as int?,
      duration: switch (row['duration_us']) { final int us => Duration(microseconds: us), _ => null },
      fps: (row['fps'] as num?)?.toDouble(),
      codec: row['codec'] as String?,
      pageCount: row['page_count'] as int?,
      takenAt: timeOrNull(row['taken_at']),
      camera: row['camera'] as String?,
      flags: row['flags'] as int? ?? 0,
    );
