// OWNER: HOM-17
// EXTENDED: HOM-28 ([LibraryWriter.replaceEntryFile]: the PDF tools' Replace, part copy then one
// rename over the entry's file.)
//
// The one writer of `library.db` (ARCH v1.2 V2-06, V2-08, §5.3, §5.4). It owns the read-write
// connection and LibraryFs; the store runs it on a background isolate. Every multi-row change is
// one transaction; moves, nesting, favourites, Recently deleted and restore are database-only
// (folder membership is a column, files stay at `files/<id>/` until purge). File steps are single
// atomic renames ordered so the open-time reconcile (library_reconcile.dart) can finish or undo
// them after a crash:
//
// * import commit: `mkdir files/<id>` → insert the entry and mark the job `committing` (one
//   transaction) → rename the part file into place → delete the job row;
// * rename: rename the file in its directory → update the row;
// * purge: rename `files/<id>` to `files/.purge-<id>` → delete the rows (one transaction) → delete
//   the staged directory.
//
// Times come from the caller (`now`), so a fake clock drives every test and a clock moved
// backwards never changes an `expires_at` already written (V2-08).

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../db/library_folder.dart';
import '../db/library_reader.dart';
import '../db/row_codec.dart';
import '../model/file_entry.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import '../model/source_hint.dart';
import '../refs/ref_holder.dart';
import 'library_faults.dart';
import 'library_fs.dart';

/// How long Recently deleted keeps an item (owner decision 2026-10-16, V2-08).
const Duration recentlyDeletedRetention = Duration(days: 30);

/// Why a write was refused.
enum LibraryWriteError {
  /// The row doesn't exist.
  notFound,

  /// The row (or the target folder) is in Recently deleted.
  trashed,

  /// The row is not in Recently deleted (restore of a live row).
  notTrashed,

  /// `Imported` and `Recovered` can't be renamed, moved or deleted.
  systemFolder,

  /// The move would put a folder inside itself.
  cycle,

  /// The name is empty, too long or has characters a file name can't hold.
  invalidName,

  /// The import job's part file is missing.
  missingPart,

  /// The library is newer than this build and opened read-only.
  readOnly,
}

/// A refused write. [error] says why; the message never holds a name or path (rule 30).
final class LibraryWriteException implements Exception {
  /// A refusal.
  const LibraryWriteException(this.error);

  /// Why.
  final LibraryWriteError error;

  @override
  String toString() => 'LibraryWriteException(${error.name})';
}

/// What an import commit writes into the entry (the import pipeline, HOM-20, fills it).
final class ImportedFileInfo {
  /// The facts of a copied-in file. The size is read from the part file.
  const ImportedFileInfo({
    required this.displayName,
    required this.kind,
    this.subKind,
    this.mime,
    this.uti,
    this.quickHash,
    this.contentSha256,
    this.sourceHint = SourceHint.files,
    this.modifiedAt,
    this.meta,
  });

  /// The file name (deduplicated in the target folder as `Name (2).ext`).
  final String displayName;

  /// The classified kind.
  final FileKind kind;

  /// The sub-kind (a document sub-filter code).
  final String? subKind;

  /// MIME type.
  final String? mime;

  /// Apple UTType.
  final String? uti;

  /// Quick-hash fingerprint.
  final String? quickHash;

  /// Full SHA-256, when computed for duplicate detection.
  final String? contentSha256;

  /// Where it came from.
  final SourceHint sourceHint;

  /// The source's modification time (defaults to the commit time).
  final DateTime? modifiedAt;

  /// Photo, video or document facts.
  final EntryMeta? meta;
}

/// What a purge removed.
final class PurgeResult {
  /// Counts.
  const PurgeResult({required this.entries, required this.folders});

  /// Entries removed for good.
  final int entries;

  /// Folders removed for good.
  final int folders;

  /// True when nothing was removed.
  bool get isEmpty => entries == 0 && folders == 0;
}

final RegExp _forbiddenInFileName = RegExp(r'[/\\\x00-\x1F\x7F]');
final RegExp _forbiddenInFolderName = RegExp(r'[\x00-\x1F\x7F]');

/// True when [name] can be an entry's file name (no separators or control characters, not `.` or
/// `..`, at most 255 UTF-8 bytes).
bool isValidEntryName(String name) =>
    name.trim().isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !_forbiddenInFileName.hasMatch(name) &&
    _utf8Length(name) <= 255;

/// True when [name] can be a folder name.
bool isValidFolderName(String name) => name.trim().isNotEmpty && !_forbiddenInFolderName.hasMatch(name) && name.length <= 255;

int _utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}

/// [name] made unique against [taken] (lower-cased names): `Name (2).ext`, `Name (3).ext`, … When
/// [splitExtension] is false (folders) the suffix goes at the end.
String uniqueName(String name, Set<String> taken, {bool splitExtension = true}) {
  if (!taken.contains(name.toLowerCase())) return name;
  final ext = splitExtension ? p.extension(name) : '';
  final base = splitExtension ? name.substring(0, name.length - ext.length) : name;
  for (var n = 2;; n++) {
    final candidate = '$base ($n)$ext';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
}

/// The one writer over a read-write connection and the file layer.
final class LibraryWriter {
  /// A writer. [readOnly] refuses every write (a newer library, D-12).
  LibraryWriter(this.db, this.fs, {Random? random, this.readOnly = false})
      : _random = random ?? Random.secure(),
        reader = LibraryReader(db);

  /// The read-write connection.
  final Database db;

  /// The file layer.
  final LibraryFs fs;

  /// Queries over the writer's own connection.
  final LibraryReader reader;

  /// True when the library is newer than this build.
  final bool readOnly;

  final Random _random;

  LibraryFaults get _faults => fs.faults;

  // ---- plumbing ----------------------------------------------------------------------------

  /// Runs [body] in one transaction. A [LibraryCrash] leaves it open, as a dying process would.
  T transaction<T>(T Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _faults.hit('tx.commit');
      db.execute('COMMIT');
      return result;
    } on LibraryCrash {
      rethrow;
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _writable() {
    if (readOnly) throw const LibraryWriteException(LibraryWriteError.readOnly);
  }

  LibraryFolder _folder(FolderId id) => reader.folder(id) ?? (throw const LibraryWriteException(LibraryWriteError.notFound));

  LibraryFolder _liveFolder(FolderId id) {
    final f = _folder(id);
    if (f.isTrashed) throw const LibraryWriteException(LibraryWriteError.trashed);
    return f;
  }

  FileEntry _entry(EntryId id) => reader.entry(id) ?? (throw const LibraryWriteException(LibraryWriteError.notFound));

  FileEntry _liveEntry(EntryId id) {
    final e = _entry(id);
    if (e.isTrashed) throw const LibraryWriteException(LibraryWriteError.trashed);
    return e;
  }

  Set<String> _liveEntryNames(FolderId folder, {EntryId? except}) => {
        for (final row in db.select(
          'SELECT display_name FROM entries WHERE folder_id = ? AND trashed_at IS NULL AND id != ?',
          [folder.value, except?.value ?? ''],
        ))
          (row['display_name'] as String).toLowerCase(),
      };

  Set<String> _liveFolderNames(FolderId? parent, {FolderId? except}) => {
        for (final row in parent == null
            ? db.select('SELECT name FROM folders WHERE parent_id IS NULL AND trashed_at IS NULL AND id != ?', [except?.value ?? ''])
            : db.select('SELECT name FROM folders WHERE parent_id = ? AND trashed_at IS NULL AND id != ?', [parent.value, except?.value ?? '']))
          (row['name'] as String).toLowerCase(),
      };

  /// The live `Imported` folder, created when missing.
  FolderId importedFolder(DateTime now) => systemFolder(FolderSystemRole.imported, now);

  /// The live system folder of [role], created at the top level when missing.
  FolderId systemFolder(FolderSystemRole role, DateTime now) {
    final existing = reader.systemFolder(role);
    if (existing != null) return existing.id;
    _writable();
    final id = FolderId.random(_random);
    final name = uniqueName(role.defaultName, _liveFolderNames(null), splitExtension: false);
    db.execute(
      'INSERT INTO folders(id, parent_id, name, created_at, modified_at, is_favourite, sort_desc, system_role) VALUES (?, NULL, ?, ?, ?, 0, 0, ?)',
      [id.value, name, msOf(now), msOf(now), role.code],
    );
    return id;
  }

  // ---- folders -----------------------------------------------------------------------------

  /// Creates a folder named [name] (deduplicated among its live siblings) under [parent] (the top
  /// level when null).
  FolderId createFolder(String name, {FolderId? parent, required DateTime now}) {
    _writable();
    if (!isValidFolderName(name)) throw const LibraryWriteException(LibraryWriteError.invalidName);
    return transaction(() {
      if (parent != null) _liveFolder(parent);
      final id = FolderId.random(_random);
      db.execute(
        'INSERT INTO folders(id, parent_id, name, created_at, modified_at, is_favourite, sort_desc) VALUES (?, ?, ?, ?, ?, 0, 0)',
        [id.value, parent?.value, uniqueName(name, _liveFolderNames(parent), splitExtension: false), msOf(now), msOf(now)],
      );
      return id;
    });
  }

  /// Renames folder [id]; returns the name given (deduplicated among siblings).
  String renameFolder(FolderId id, String name, {required DateTime now}) {
    _writable();
    if (!isValidFolderName(name)) throw const LibraryWriteException(LibraryWriteError.invalidName);
    return transaction(() {
      final f = _liveFolder(id);
      if (f.isSystem) throw const LibraryWriteException(LibraryWriteError.systemFolder);
      final unique = uniqueName(name, _liveFolderNames(f.parentId, except: id), splitExtension: false);
      db.execute('UPDATE folders SET name = ?, modified_at = ? WHERE id = ?', [unique, msOf(now), id.value]);
      return unique;
    });
  }

  /// Moves folder [id] under [parent] (the top level when null). Refuses a move into itself or a
  /// descendant (cycle check) and into a trashed folder.
  void moveFolder(FolderId id, FolderId? parent, {required DateTime now}) {
    _writable();
    transaction(() {
      final f = _liveFolder(id);
      if (f.isSystem) throw const LibraryWriteException(LibraryWriteError.systemFolder);
      if (parent != null) {
        _liveFolder(parent);
        if (reader.subtreeFolderIds(id).contains(parent)) throw const LibraryWriteException(LibraryWriteError.cycle);
      }
      if (f.parentId == parent) return;
      final unique = uniqueName(f.name, _liveFolderNames(parent, except: id), splitExtension: false);
      db.execute('UPDATE folders SET parent_id = ?, name = ?, modified_at = ? WHERE id = ?', [parent?.value, unique, msOf(now), id.value]);
    });
  }

  /// Stars or unstars folder [id].
  void setFolderFavourite(FolderId id, bool favourite) {
    _writable();
    _liveFolder(id);
    db.execute('UPDATE folders SET is_favourite = ? WHERE id = ?', [favourite ? 1 : 0, id.value]);
  }

  /// Remembers the sort of folder [id] (HOM-19's codes).
  void setFolderSort(FolderId id, String? sortMode, {bool descending = false}) {
    _writable();
    _folder(id);
    db.execute('UPDATE folders SET sort_mode = ?, sort_desc = ? WHERE id = ?', [sortMode, descending ? 1 : 0, id.value]);
  }

  // ---- entries -----------------------------------------------------------------------------

  /// Renames entry [id] (deduplicated in its folder) by renaming its one file; returns the name.
  String renameEntry(EntryId id, String name, {required DateTime now}) {
    _writable();
    if (!isValidEntryName(name)) throw const LibraryWriteException(LibraryWriteError.invalidName);
    final e = _liveEntry(id);
    final unique = uniqueName(name, _liveEntryNames(e.folderId, except: id));
    if (unique == e.displayName) return unique;
    if (fs.entryFileExists(id, e.displayName)) fs.renameEntryFile(id, e.displayName, unique);
    _faults.hit('rename.file');
    transaction(() {
      db.execute('UPDATE entries SET display_name = ?, modified_at = ? WHERE id = ?', [unique, msOf(now), id.value]);
    });
    return unique;
  }

  /// Moves [ids] into [target] in one transaction (database-only; names deduplicated there).
  void moveEntries(Iterable<EntryId> ids, FolderId target, {required DateTime now}) {
    _writable();
    transaction(() {
      _liveFolder(target);
      // Check every id and plan every name before touching a file: a refused id (trashed in the
      // meantime, missing) must leave the files exactly as they were.
      final taken = _liveEntryNames(target);
      final plan = <(EntryId, String, String)>[];
      final planned = <EntryId>{};
      for (final id in ids) {
        final e = _liveEntry(id);
        if (e.folderId == target || !planned.add(id)) continue;
        final unique = uniqueName(e.displayName, taken);
        taken.add(unique.toLowerCase());
        plan.add((id, e.displayName, unique));
      }
      // Renames done so far, undone when a later step throws so the rolled-back rows still name
      // their files. A LibraryCrash is a dying process: nothing runs after it, the next launch's
      // reconcile repairs the names.
      final renamed = <(EntryId, String, String)>[];
      try {
        for (final (id, from, to) in plan) {
          if (to != from && fs.entryFileExists(id, from)) {
            fs.renameEntryFile(id, from, to);
            renamed.add((id, from, to));
          }
          db.execute('UPDATE entries SET folder_id = ?, display_name = ? WHERE id = ?', [target.value, to, id.value]);
          _faults.hit('move.row');
        }
      } on LibraryCrash {
        rethrow;
      } catch (_) {
        for (final (id, from, to) in renamed.reversed) {
          try {
            if (fs.entryFileExists(id, to)) fs.renameEntryFile(id, to, from);
          } catch (_) {
            // Left for the next launch's reconcile, which renames the file back to its row's name.
          }
        }
        rethrow;
      }
    });
  }

  /// Stars or unstars entry [id].
  void setEntryFavourite(EntryId id, bool favourite) {
    _writable();
    _liveEntry(id);
    db.execute('UPDATE entries SET is_favourite = ? WHERE id = ?', [favourite ? 1 : 0, id.value]);
  }

  /// Records that a viewer opened entry [id] (Recents keeps the last 50 by trigger).
  void markOpened(EntryId id, {required DateTime now}) {
    _writable();
    transaction(() {
      _liveEntry(id);
      db.execute('UPDATE entries SET last_opened_at = ? WHERE id = ?', [msOf(now), id.value]);
      db.execute('INSERT OR REPLACE INTO recents(entry_id, opened_at) VALUES (?, ?)', [id.value, msOf(now)]);
    });
  }

  /// Clears Recents (the one clear button).
  void clearRecents() {
    _writable();
    db.execute('DELETE FROM recents');
  }

  /// Records [entryId]'s facts.
  void setMeta(EntryId entryId, EntryMeta meta) {
    _writable();
    _entry(entryId);
    _writeMeta(entryId, meta);
  }

  /// Records [entryId]'s page count, keeping its other facts (FIX-S3Q-4's backfill).
  void setPageCount(EntryId entryId, int pageCount) {
    _writable();
    _liveEntry(entryId);
    db.execute(
      'INSERT INTO entry_meta(entry_id, page_count, flags) VALUES (?, ?, 0) '
      'ON CONFLICT(entry_id) DO UPDATE SET page_count = excluded.page_count',
      [entryId.value, pageCount],
    );
  }

  void _writeMeta(EntryId id, EntryMeta meta) {
    db.execute(
      'INSERT OR REPLACE INTO entry_meta(entry_id, width, height, duration_us, fps, codec, page_count, taken_at, camera, flags) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id.value, meta.width, meta.height, meta.duration?.inMicroseconds, meta.fps, meta.codec, meta.pageCount, msOrNull(meta.takenAt), meta.camera, meta.flags],
    );
  }

  // ---- references --------------------------------------------------------------------------

  /// Records that [holder] uses entry [entryId].
  void addRef(EntryId entryId, RefHolder holder) {
    _writable();
    _entry(entryId);
    db.execute('INSERT OR IGNORE INTO refs(entry_id, holder) VALUES (?, ?)', [entryId.value, holder.value]);
  }

  /// Forgets that [holder] uses entry [entryId].
  void removeRef(EntryId entryId, RefHolder holder) {
    _writable();
    db.execute('DELETE FROM refs WHERE entry_id = ? AND holder = ?', [entryId.value, holder.value]);
  }

  /// Forgets every reference of [holder] (its project or recipe was deleted).
  void removeHolder(RefHolder holder) {
    _writable();
    db.execute('DELETE FROM refs WHERE holder = ?', [holder.value]);
  }

  // ---- Recently deleted --------------------------------------------------------------------

  /// Moves [ids] to Recently deleted (one transaction; files stay in place).
  void trashEntries(Iterable<EntryId> ids, {required DateTime now}) {
    _writable();
    final expires = now.add(recentlyDeletedRetention);
    transaction(() {
      for (final id in ids) {
        final e = _liveEntry(id);
        db.execute(
          'UPDATE entries SET trashed_at = ?, expires_at = ?, trashed_from_folder = ? WHERE id = ?',
          [msOf(now), msOf(expires), e.folderId.value, id.value],
        );
        _faults.hit('trash.row');
      }
    });
  }

  /// Moves folder [id] and its live subtree to Recently deleted in one transaction, all with the
  /// same `expires_at`.
  void trashFolder(FolderId id, {required DateTime now}) {
    _writable();
    final t = msOf(now);
    final expires = msOf(now.add(recentlyDeletedRetention));
    transaction(() {
      final f = _liveFolder(id);
      if (f.isSystem) throw const LibraryWriteException(LibraryWriteError.systemFolder);
      for (final folder in reader.subtreeFolderIds(id)) {
        db.execute('UPDATE folders SET trashed_at = ?, expires_at = ? WHERE id = ? AND trashed_at IS NULL', [t, expires, folder.value]);
        db.execute(
          'UPDATE entries SET trashed_at = ?, expires_at = ?, trashed_from_folder = folder_id WHERE folder_id = ? AND trashed_at IS NULL',
          [t, expires, folder.value],
        );
        _faults.hit('trash.row');
      }
    });
  }

  /// Where a trashed entry in [folderId] goes back to: that folder when live, else the nearest
  /// live ancestor, else `Imported` (V2-08, §5.4).
  FolderId _restoreFolderFor(FolderId folderId, DateTime now) {
    final seen = <FolderId>{};
    FolderId? next = folderId;
    while (next != null && seen.add(next)) {
      final f = reader.folder(next);
      if (f == null) break;
      if (!f.isTrashed) return f.id;
      next = f.parentId;
    }
    return importedFolder(now);
  }

  /// Where a trashed folder with parent [parentId] goes back to: the top level when it was there,
  /// else the nearest live ancestor (the top level counts), else `Imported` when the chain is gone.
  FolderId? _restoreParentFor(FolderId? parentId, DateTime now) {
    final seen = <FolderId>{};
    FolderId? next = parentId;
    while (next != null && seen.add(next)) {
      final f = reader.folder(next);
      if (f == null) return importedFolder(now);
      if (!f.isTrashed) return f.id;
      next = f.parentId;
    }
    return next == null ? null : importedFolder(now);
  }

  /// Restores trashed entry or folder [id] (a folder with the subtree trashed with it); returns
  /// the folder it now sits in (null: the top level).
  FolderId? restore(ItemId id, {required DateTime now}) {
    _writable();
    return transaction(() {
      if (id.asEntry case final entryId?) {
        final e = _entry(entryId);
        if (!e.isTrashed) throw const LibraryWriteException(LibraryWriteError.notTrashed);
        final dest = _restoreFolderFor(e.folderId, now);
        final unique = uniqueName(e.displayName, _liveEntryNames(dest));
        if (unique != e.displayName && fs.entryFileExists(entryId, e.displayName)) {
          fs.renameEntryFile(entryId, e.displayName, unique);
        }
        db.execute(
          'UPDATE entries SET folder_id = ?, display_name = ?, trashed_at = NULL, expires_at = NULL, trashed_from_folder = NULL WHERE id = ?',
          [dest.value, unique, entryId.value],
        );
        return dest;
      }
      final folderId = id.asFolder ?? (throw const LibraryWriteException(LibraryWriteError.notFound));
      final f = _folder(folderId);
      if (!f.isTrashed) throw const LibraryWriteException(LibraryWriteError.notTrashed);
      final parent = _restoreParentFor(f.parentId, now);
      final tree = reader.subtreeFolderIds(folderId, trashedAt: f.trashedAt);
      final t = msOf(f.trashedAt!);
      for (final sub in tree) {
        db.execute('UPDATE folders SET trashed_at = NULL, expires_at = NULL WHERE id = ? AND trashed_at = ?', [sub.value, t]);
        db.execute(
          'UPDATE entries SET trashed_at = NULL, expires_at = NULL, trashed_from_folder = NULL WHERE folder_id = ? AND trashed_at = ?',
          [sub.value, t],
        );
        _faults.hit('restore.row');
      }
      final unique = uniqueName(f.name, _liveFolderNames(parent, except: folderId), splitExtension: false);
      db.execute('UPDATE folders SET parent_id = ?, name = ? WHERE id = ?', [parent?.value, unique, folderId.value]);
      return parent;
    });
  }

  /// Removes for good every trashed row with `expires_at ≤ now` (the sweep on launch and daily).
  PurgeResult purgeExpired({required DateTime now}) {
    _writable();
    final t = msOf(now);
    return _purge(
      entries: [for (final r in db.select('SELECT id FROM entries WHERE expires_at IS NOT NULL AND expires_at <= ?', [t])) EntryId.parse(r['id'] as String)],
      folders: [for (final r in db.select('SELECT id FROM folders WHERE expires_at IS NOT NULL AND expires_at <= ?', [t])) FolderId.parse(r['id'] as String)],
    );
  }

  /// Removes everything in Recently deleted (Empty now).
  PurgeResult emptyTrash() {
    _writable();
    return _purge(
      entries: [for (final r in db.select('SELECT id FROM entries WHERE trashed_at IS NOT NULL')) EntryId.parse(r['id'] as String)],
      folders: [for (final r in db.select('SELECT id FROM folders WHERE trashed_at IS NOT NULL')) FolderId.parse(r['id'] as String)],
    );
  }

  PurgeResult _purge({required List<EntryId> entries, required List<FolderId> folders}) {
    if (entries.isEmpty && folders.isEmpty) return const PurgeResult(entries: 0, folders: 0);
    for (final id in entries) {
      fs.stagePurge(id);
      _faults.hit('purge.stage');
    }
    transaction(() {
      for (final id in entries) {
        for (final table in const ['entries WHERE id', 'entry_meta WHERE entry_id', 'recents WHERE entry_id', 'refs WHERE entry_id']) {
          db.execute('DELETE FROM $table = ?', [id.value]);
        }
      }
      for (final id in folders) {
        db.execute('DELETE FROM folders WHERE id = ?', [id.value]);
      }
      _faults.hit('purge.rows');
    });
    for (final id in entries) {
      fs.removeStaged(id);
      _faults.hit('purge.remove');
    }
    return PurgeResult(entries: entries.length, folders: folders.length);
  }

  // ---- import ------------------------------------------------------------------------------

  String _newJobId() => EntryId.random(_random).token;

  /// Starts an import job into [target] (`Imported` when null); the caller writes bytes to
  /// `LibraryFs.openPart(job.id)` and calls [recordImportProgress], then [commitImport].
  ImportJob beginImport({FolderId? target, String? sourceDescription, int bytesTotal = 0, required DateTime now}) {
    _writable();
    return transaction(() {
      final folder = target ?? importedFolder(now);
      _liveFolder(folder);
      final id = _newJobId();
      final part = fs.paths.relativePartPath(id);
      db.execute(
        'INSERT INTO import_jobs(id, source_desc, target_folder, bytes_total, bytes_done, state, part_path, created_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?)',
        [id, sourceDescription, folder.value, bytesTotal, ImportJobState.copying.code, part, msOf(now)],
      );
      return ImportJob(
        id: id,
        sourceDescription: sourceDescription,
        targetFolder: folder,
        bytesTotal: bytesTotal,
        bytesDone: 0,
        state: ImportJobState.copying,
        partPath: part,
        createdAt: now,
      );
    });
  }

  ImportJob _job(String jobId) =>
      reader.importJobs().where((j) => j.id == jobId).firstOrNull ?? (throw const LibraryWriteException(LibraryWriteError.notFound));

  /// Records [bytesDone] for job [jobId] (resume picks up from the part file's size).
  void recordImportProgress(String jobId, int bytesDone) {
    _writable();
    db.execute('UPDATE import_jobs SET bytes_done = ? WHERE id = ?', [bytesDone, jobId]);
  }

  /// Turns the finished part file of job [jobId] into an entry (crash-safe, see the file header).
  FileEntry commitImport(String jobId, ImportedFileInfo info, {required DateTime now}) {
    _writable();
    if (!isValidEntryName(info.displayName)) throw const LibraryWriteException(LibraryWriteError.invalidName);
    final job = _job(jobId);
    if (!fs.partExists(job.partPath)) throw const LibraryWriteException(LibraryWriteError.missingPart);
    final entryId = job.entryId;
    final size = fs.partSize(job.partPath);
    fs.createEntryDir(entryId);
    _faults.hit('import.mkdir');
    final name = transaction(() {
      final target = reader.folder(job.targetFolder);
      final folder = target == null || target.isTrashed ? importedFolder(now) : target.id;
      final unique = uniqueName(info.displayName, _liveEntryNames(folder));
      db.execute(
        'INSERT INTO entries(id, folder_id, display_name, kind, sub_kind, mime, uti, ext, size_bytes, quick_hash, content_sha256, '
        'added_at, modified_at, is_favourite, source_hint) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
        [
          entryId.value, folder.value, unique, info.kind.code, info.subKind, info.mime, info.uti, _ext(unique), size,
          info.quickHash, info.contentSha256, msOf(now), msOf(info.modifiedAt ?? now), info.sourceHint.code,
        ],
      );
      if (info.meta case final meta? when !meta.isEmpty) _writeMeta(entryId, meta);
      db.execute('UPDATE import_jobs SET state = ? WHERE id = ?', [ImportJobState.committing.code, jobId]);
      return unique;
    });
    _faults.hit('import.row');
    fs.movePartIntoEntry(job.partPath, entryId, name);
    _faults.hit('import.move');
    db.execute('DELETE FROM import_jobs WHERE id = ?', [jobId]);
    return reader.entry(entryId)!;
  }

  /// Gives up job [jobId]: deletes its part file and row.
  void abandonImport(String jobId) {
    _writable();
    final job = reader.importJobs().where((j) => j.id == jobId).firstOrNull;
    if (job == null) return;
    if (job.state == ImportJobState.committing) return; // the reconcile finishes it instead
    fs.deletePart(job.partPath);
    db.execute('DELETE FROM import_jobs WHERE id = ?', [jobId]);
  }

  /// Copies entry [id] into [target] as a new entry (Copy to…), through the import path.
  FileEntry copyEntry(EntryId id, FolderId target, {required DateTime now}) {
    _writable();
    final e = _liveEntry(id);
    _liveFolder(target);
    final job = beginImport(target: target, bytesTotal: e.sizeBytes, now: now);
    fs.copyEntryToPart(id, e.displayName, job.id);
    final row = db.select('SELECT mime, uti, content_sha256 FROM entries WHERE id = ?', [id.value]).first;
    return commitImport(
      job.id,
      ImportedFileInfo(
        displayName: e.displayName,
        kind: FileKind.decode(e.kindCode),
        subKind: e.subKind,
        mime: row['mime'] as String?,
        uti: row['uti'] as String?,
        quickHash: e.quickHash,
        contentSha256: row['content_sha256'] as String?,
        sourceHint: e.sourceHint,
        modifiedAt: e.modifiedAt,
        meta: reader.meta(id),
      ),
      now: now,
    );
  }

  /// Replaces the file of the live entry [id] with the finished file at [sourcePath] (the PDF
  /// tools' "Replace", only for Danaview folder files; ARCH v1.2 §9.3, D-98j): the bytes are first
  /// copied into a stray part `imports/rpl_<token>.part` on the library's volume, then one atomic
  /// rename puts them over `files/<id>/<name>`, then the row gets the new size, [quickHash] and
  /// modification time ([pageCount] goes into `entry_meta` when given). The entry keeps its id,
  /// name, folder, favourite and references. A crash before the rename leaves the old file and a
  /// stray part (the open-time reconcile deletes it); a crash after it, the new bytes with the old
  /// size until the next replace or rescan. [sourcePath] is only read.
  FileEntry replaceEntryFile(EntryId id, String sourcePath, {required String quickHash, int? pageCount, required DateTime now}) {
    _writable();
    final e = _liveEntry(id);
    if (!File(sourcePath).existsSync()) throw const LibraryWriteException(LibraryWriteError.notFound);
    if (!fs.entryFileExists(id, e.displayName)) throw const LibraryWriteException(LibraryWriteError.notFound);
    final part = 'imports/rpl_${_newJobId()}.part';
    try {
      fs.copyIntoPart(sourcePath, part);
      fs.movePartOverEntry(part, id, e.displayName);
    } catch (_) {
      fs.deletePart(part);
      rethrow;
    }
    final size = fs.entryFileSize(id, e.displayName) ?? 0;
    transaction(() {
      db.execute(
        'UPDATE entries SET size_bytes = ?, quick_hash = ?, content_sha256 = NULL, modified_at = ? WHERE id = ?',
        [size, quickHash, msOf(now), id.value],
      );
      if (pageCount != null) {
        final old = reader.meta(id);
        _writeMeta(
          id,
          EntryMeta(
            width: old?.width,
            height: old?.height,
            duration: old?.duration,
            fps: old?.fps,
            codec: old?.codec,
            pageCount: pageCount,
            takenAt: old?.takenAt,
            camera: old?.camera,
            flags: old?.flags ?? 0,
          ),
        );
      }
    });
    return reader.entry(id)!;
  }

  static String? _ext(String name) {
    final ext = p.extension(name);
    return ext.isEmpty ? null : ext.substring(1).toLowerCase();
  }
}
