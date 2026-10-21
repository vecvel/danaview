// OWNER: HOM-17
//
// Read-only queries of `library.db` (ARCH v1.2 §5.3): paged entry lists for the Home tabs and
// folders, the folder tree, recents, the Recently deleted view, storage use, import jobs and
// reference counts. Trashed rows are excluded from every list except the Recently deleted view and
// the `include…Trashed` dumps (V2-08); they still count toward storage. The store opens a read-only
// connection for this on the UI isolate (≤ 2 ms per 200-row page, §10).

import 'package:sqlite3/sqlite3.dart';

import '../model/file_entry.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import '../refs/ref_holder.dart';
import 'library_folder.dart';
import 'row_codec.dart';

/// The sort keys of a paged entry query.
enum EntrySortKey {
  /// Display name, case-insensitive (HOM-19 adds natural order on top).
  name('display_name COLLATE NOCASE'),

  /// Date added.
  addedAt('added_at'),

  /// Date modified.
  modifiedAt('modified_at'),

  /// File size.
  size('size_bytes'),

  /// Kind, then sub-kind.
  kind('kind, sub_kind');

  const EntrySortKey(this._sql);

  final String _sql;
}

/// Which live entries a page holds.
final class EntryQuery {
  /// A query. [folderId] null means the whole library; [kinds] null means every kind.
  const EntryQuery({
    this.folderId,
    this.kinds,
    this.subKind,
    this.favouritesOnly = false,
    this.sort = EntrySortKey.addedAt,
    this.descending = true,
  });

  /// Only entries of this folder (not its subfolders).
  final FolderId? folderId;

  /// Only these kinds; [FileKind.other] also matches kinds this build doesn't know.
  final Set<FileKind>? kinds;

  /// Only this `sub_kind` (a Documents sub-filter code).
  final String? subKind;

  /// Only starred entries.
  final bool favouritesOnly;

  /// The order.
  final EntrySortKey sort;

  /// Descending order.
  final bool descending;
}

/// The state of an import job (`import_jobs.state`).
enum ImportJobState {
  /// Bytes are being copied into `imports/<id>.part`.
  copying('copying'),

  /// The entry row exists and the part file is being moved into place.
  committing('committing');

  const ImportJobState(this.code);

  /// The stored string.
  final String code;

  /// The state stored as [code] (unknown → [copying], which only resumes or abandons).
  static ImportJobState decode(String? code) => code == committing.code ? committing : copying;
}

/// One `import_jobs` row. Its entry, once committed, is `fe_<id>`.
final class ImportJob {
  /// An import job.
  const ImportJob({
    required this.id,
    required this.sourceDescription,
    required this.targetFolder,
    required this.bytesTotal,
    required this.bytesDone,
    required this.state,
    required this.partPath,
    required this.createdAt,
  });

  /// The job id (the token of its future entry id).
  final String id;

  /// A description of the source the import pipeline can resume from (never logged).
  final String? sourceDescription;

  /// The target folder.
  final FolderId targetFolder;

  /// Expected bytes (0 when unknown).
  final int bytesTotal;

  /// Bytes copied so far.
  final int bytesDone;

  /// Where the job is.
  final ImportJobState state;

  /// The part file, relative to the library root (`imports/<id>.part`).
  final String partPath;

  /// When it started.
  final DateTime createdAt;

  /// The entry id this job commits to.
  EntryId get entryId => EntryId.parse('fe_$id');
}

/// One top-level row of the Recently deleted view: an entry or a folder (with the subtree trashed
/// with it).
final class TrashedItem {
  /// A trashed row.
  const TrashedItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.sizeBytes,
    required this.itemCount,
    required this.trashedAt,
    required this.expiresAt,
  });

  /// The entry or folder id.
  final ItemId id;

  /// Its name.
  final String name;

  /// The entry kind, or null for a folder.
  final FileKind? kind;

  /// Bytes it holds (a folder: every entry trashed with it).
  final int sizeBytes;

  /// Files it holds (1 for an entry).
  final int itemCount;

  /// When it was deleted.
  final DateTime trashedAt;

  /// When it is removed for good.
  final DateTime expiresAt;

  /// True for a folder.
  bool get isFolder => kind == null;

  /// Whole days left before removal at [now] (rounded up, never negative): 30 right after a delete.
  int daysLeft(DateTime now) => daysLeftUntil(expiresAt, now);
}

/// Whole days from [now] to [expiresAt], rounded up, never negative (the "N days left" label).
int daysLeftUntil(DateTime expiresAt, DateTime now) {
  final ms = expiresAt.millisecondsSinceEpoch - now.millisecondsSinceEpoch;
  if (ms <= 0) return 0;
  const day = Duration.millisecondsPerDay;
  return (ms + day - 1) ~/ day;
}

/// Library sizes for Settings (V2-V1) and the folder headers.
final class LibraryStorageUsage {
  /// Sizes and counts.
  const LibraryStorageUsage({
    required this.liveBytes,
    required this.liveCount,
    required this.trashedBytes,
    required this.trashedCount,
  });

  /// Nothing stored.
  static const LibraryStorageUsage empty = LibraryStorageUsage(liveBytes: 0, liveCount: 0, trashedBytes: 0, trashedCount: 0);

  /// Bytes of files outside Recently deleted.
  final int liveBytes;

  /// Files outside Recently deleted.
  final int liveCount;

  /// Bytes in Recently deleted.
  final int trashedBytes;

  /// Files in Recently deleted.
  final int trashedCount;

  /// Everything the library holds on disk (trashed files still count, V2-08).
  int get totalBytes => liveBytes + trashedBytes;
}

const String _entryColumns = 'id, folder_id, display_name, kind, sub_kind, size_bytes, added_at, modified_at, '
    'last_opened_at, is_favourite, source_hint, quick_hash, trashed_at, expires_at';

/// Read-only queries over a `library.db` connection.
final class LibraryReader {
  /// A reader over [db] (a read-only connection, or the writer's own).
  LibraryReader(this.db);

  /// The connection.
  final Database db;

  /// The folder [id], trashed or not, or null.
  LibraryFolder? folder(FolderId id) {
    final rows = db.select('SELECT * FROM folders WHERE id = ?', [id.value]);
    return rows.isEmpty ? null : folderFromRow(rows.first);
  }

  /// The live system folder of [role], or null.
  LibraryFolder? systemFolder(FolderSystemRole role) {
    final rows = db.select('SELECT * FROM folders WHERE system_role = ? AND trashed_at IS NULL ORDER BY created_at, id LIMIT 1', [role.code]);
    return rows.isEmpty ? null : folderFromRow(rows.first);
  }

  /// Live subfolders of [parent] (the top level when null), by name.
  List<LibraryFolder> childFolders(FolderId? parent) => [
        for (final row in parent == null
            ? db.select('SELECT * FROM folders WHERE parent_id IS NULL AND trashed_at IS NULL ORDER BY name COLLATE NOCASE, id')
            : db.select('SELECT * FROM folders WHERE parent_id = ? AND trashed_at IS NULL ORDER BY name COLLATE NOCASE, id', [parent.value]))
          folderFromRow(row),
      ];

  /// Every folder, by id; trashed ones too when [includeTrashed].
  List<LibraryFolder> allFolders({bool includeTrashed = false}) => [
        for (final row in db.select('SELECT * FROM folders ${includeTrashed ? '' : 'WHERE trashed_at IS NULL '}ORDER BY id'))
          folderFromRow(row),
      ];

  /// The live folders from the top level down to [id] (inclusive), or empty when [id] is not live.
  List<LibraryFolder> pathOf(FolderId id) {
    final path = <LibraryFolder>[];
    final seen = <FolderId>{};
    FolderId? next = id;
    while (next != null && seen.add(next)) {
      final f = folder(next);
      if (f == null || f.isTrashed) return const [];
      path.insert(0, f);
      next = f.parentId;
    }
    return path;
  }

  /// The entry [id], trashed or not, or null.
  FileEntry? entry(EntryId id) {
    final rows = db.select('SELECT $_entryColumns FROM entries WHERE id = ?', [id.value]);
    return rows.isEmpty ? null : entryFromRow(rows.first);
  }

  /// The facts of entry [id], or null.
  EntryMeta? meta(EntryId id) {
    final rows = db.select('SELECT * FROM entry_meta WHERE entry_id = ?', [id.value]);
    return rows.isEmpty ? null : metaFromRow(rows.first);
  }

  (String, List<Object?>) _where(EntryQuery q) {
    final clauses = <String>['trashed_at IS NULL'];
    final args = <Object?>[];
    if (q.folderId case final folder?) {
      clauses.add('folder_id = ?');
      args.add(folder.value);
    }
    if (q.kinds case final kinds?) {
      final codes = [for (final k in kinds) k.code];
      final parts = <String>['kind IN (${List.filled(codes.length, '?').join(', ')})'];
      args.addAll(codes);
      if (kinds.contains(FileKind.other)) {
        final known = [for (final k in FileKind.values) k.code];
        parts.add('kind NOT IN (${List.filled(known.length, '?').join(', ')})');
        args.addAll(known);
      }
      clauses.add(codes.isEmpty ? '0' : '(${parts.join(' OR ')})');
    }
    if (q.subKind case final sub?) {
      clauses.add('sub_kind = ?');
      args.add(sub);
    }
    if (q.favouritesOnly) clauses.add('is_favourite = 1');
    return (clauses.join(' AND '), args);
  }

  /// One page of live entries matching [query] ([limit] rows from [offset]).
  List<FileEntry> entriesPage(EntryQuery query, {int offset = 0, int limit = 200}) {
    final (where, args) = _where(query);
    final dir = query.descending ? 'DESC' : 'ASC';
    final order = query.sort._sql.split(', ').map((c) => '$c $dir').join(', ');
    return [
      for (final row in db.select(
        'SELECT $_entryColumns FROM entries WHERE $where ORDER BY $order, id $dir LIMIT ? OFFSET ?',
        [...args, limit, offset],
      ))
        entryFromRow(row),
    ];
  }

  /// How many live entries match [query].
  int countEntries(EntryQuery query) {
    final (where, args) = _where(query);
    return db.select('SELECT COUNT(*) AS n FROM entries WHERE $where', args).first['n'] as int;
  }

  /// Every entry, by id; trashed ones too when [includeTrashed].
  List<FileEntry> allEntries({bool includeTrashed = false}) => [
        for (final row in db.select('SELECT $_entryColumns FROM entries ${includeTrashed ? '' : 'WHERE trashed_at IS NULL '}ORDER BY id'))
          entryFromRow(row),
      ];

  /// The live entries opened most recently (at most 50), newest first.
  List<FileEntry> recents() => [
        for (final row in db.select(
          'SELECT ${_entryColumns.split(', ').map((c) => 'e.$c').join(', ')} FROM recents r JOIN entries e ON e.id = r.entry_id '
          'WHERE e.trashed_at IS NULL ORDER BY r.opened_at DESC, r.entry_id',
        ))
          entryFromRow(row),
      ];

  /// The top-level rows of Recently deleted, newest deletion first: trashed folders whose parent
  /// wasn't trashed with them, and trashed entries whose folder wasn't.
  List<TrashedItem> recentlyDeleted() {
    final items = <TrashedItem>[];
    final folders = db.select(
      'SELECT f.* FROM folders f LEFT JOIN folders p ON p.id = f.parent_id '
      'WHERE f.trashed_at IS NOT NULL AND (p.id IS NULL OR p.trashed_at IS NULL OR p.trashed_at != f.trashed_at)',
    );
    for (final row in folders) {
      final f = folderFromRow(row);
      final ids = subtreeFolderIds(f.id, trashedAt: f.trashedAt);
      final placeholders = List.filled(ids.length, '?').join(', ');
      final sums = db.select(
        'SELECT COUNT(*) AS n, COALESCE(SUM(size_bytes), 0) AS bytes FROM entries '
        'WHERE folder_id IN ($placeholders) AND trashed_at = ?',
        [for (final id in ids) id.value, msOf(f.trashedAt!)],
      ).first;
      items.add(TrashedItem(
        id: f.id,
        name: f.name,
        kind: null,
        sizeBytes: sums['bytes'] as int,
        itemCount: sums['n'] as int,
        trashedAt: f.trashedAt!,
        expiresAt: f.expiresAt!,
      ));
    }
    final entries = db.select(
      'SELECT ${_entryColumns.split(', ').map((c) => 'e.$c').join(', ')} FROM entries e LEFT JOIN folders f ON f.id = e.folder_id '
      'WHERE e.trashed_at IS NOT NULL AND (f.id IS NULL OR f.trashed_at IS NULL OR f.trashed_at != e.trashed_at)',
    );
    for (final row in entries) {
      final e = entryFromRow(row);
      items.add(TrashedItem(
        id: e.id,
        name: e.displayName,
        kind: e.kind,
        sizeBytes: e.sizeBytes,
        itemCount: 1,
        trashedAt: e.trashedAt!,
        expiresAt: e.expiresAt!,
      ));
    }
    items.sort((a, b) {
      final byTime = b.trashedAt.compareTo(a.trashedAt);
      return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
    });
    return items;
  }

  /// [root] and its descendant folders. With [trashedAt], only descendants trashed at that moment
  /// (the subtree deleted together); otherwise every descendant.
  List<FolderId> subtreeFolderIds(FolderId root, {DateTime? trashedAt}) {
    final out = <FolderId>[root];
    final seen = <FolderId>{root};
    for (var i = 0; i < out.length; i++) {
      final rows = trashedAt == null
          ? db.select('SELECT id FROM folders WHERE parent_id = ?', [out[i].value])
          : db.select('SELECT id FROM folders WHERE parent_id = ? AND trashed_at = ?', [out[i].value, msOf(trashedAt)]);
      for (final row in rows) {
        final id = FolderId.parse(row['id'] as String);
        if (seen.add(id)) out.add(id);
      }
    }
    return out;
  }

  /// Sizes for Settings and the folder headers.
  LibraryStorageUsage storageUsage() {
    final row = db.select(
      'SELECT COALESCE(SUM(CASE WHEN trashed_at IS NULL THEN size_bytes END), 0) AS live_bytes, '
      'COALESCE(SUM(CASE WHEN trashed_at IS NULL THEN 1 END), 0) AS live_n, '
      'COALESCE(SUM(CASE WHEN trashed_at IS NOT NULL THEN size_bytes END), 0) AS trashed_bytes, '
      'COALESCE(SUM(CASE WHEN trashed_at IS NOT NULL THEN 1 END), 0) AS trashed_n FROM entries',
    ).first;
    return LibraryStorageUsage(
      liveBytes: row['live_bytes'] as int,
      liveCount: row['live_n'] as int,
      trashedBytes: row['trashed_bytes'] as int,
      trashedCount: row['trashed_n'] as int,
    );
  }

  /// The holders of entry [id].
  List<RefHolder> holdersOf(EntryId id) => [
        for (final row in db.select('SELECT holder FROM refs WHERE entry_id = ? ORDER BY holder', [id.value]))
          if (RefHolder.tryParse(row['holder'] as String) case final holder?) holder,
      ];

  /// Distinct holders of [entries] and of every entry under [folders] (the delete warning).
  RefUsage refUsage({Iterable<EntryId> entries = const [], Iterable<FolderId> folders = const []}) {
    final ids = <String>{for (final e in entries) e.value};
    for (final f in folders) {
      final tree = subtreeFolderIds(f);
      for (final row in db.select(
        'SELECT id FROM entries WHERE folder_id IN (${List.filled(tree.length, '?').join(', ')})',
        [for (final t in tree) t.value],
      )) {
        ids.add(row['id'] as String);
      }
    }
    if (ids.isEmpty) return RefUsage.none;
    final holders = <String>{
      for (final row in db.select(
        'SELECT DISTINCT holder FROM refs WHERE entry_id IN (${List.filled(ids.length, '?').join(', ')})',
        ids.toList(),
      ))
        row['holder'] as String,
    };
    return RefUsage(
      projects: holders.where((h) => h.startsWith('${RefHolderKind.project.prefix}:')).length,
      photos: holders.where((h) => h.startsWith('${RefHolderKind.photo.prefix}:')).length,
    );
  }

  /// Every import job, oldest first.
  List<ImportJob> importJobs() => [
        for (final row in db.select('SELECT * FROM import_jobs ORDER BY created_at, id'))
          ImportJob(
            id: row['id'] as String,
            sourceDescription: row['source_desc'] as String?,
            targetFolder: FolderId.parse(row['target_folder'] as String),
            bytesTotal: row['bytes_total'] as int? ?? 0,
            bytesDone: row['bytes_done'] as int? ?? 0,
            state: ImportJobState.decode(row['state'] as String?),
            partPath: row['part_path'] as String,
            createdAt: timeOrNull(row['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
      ];
}
