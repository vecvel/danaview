// OWNER: HOM-17
//
// The open-time reconcile (ARCH v1.2 §5.3): finishes or undoes whatever a crash interrupted and
// repairs what the invariants forbid, without ever dropping a file silently.
//
// * a half-committed import is finished (its entry row is already there; the part file is moved
//   into place);
// * a purge-staged directory goes back when its row survived, else it is deleted;
// * an interrupted rename is rolled back (the one file in `files/<id>/` gets the stored name back);
// * a part file without a job, and an empty `files/<id>/` without a row, are deleted;
// * a directory with files but no row is adopted into `Recovered` (the rebuild-from-files path uses
//   the same step on an empty database, keeping each entry's id so editor references survive);
// * cycles are broken, live folders without a live parent move to the top level, live entries
//   without a live folder move to `Imported`, and `Imported` is recreated when missing;
// * an entry whose file is gone stays, marked unavailable.

import '../classify/classifier.dart';
import '../db/library_folder.dart';
import '../db/library_reader.dart';
import '../db/row_codec.dart';
import '../model/ids.dart';
import '../model/source_hint.dart';
import 'library_paths.dart';
import 'library_writer.dart';

/// What the reconcile did.
final class ReconcileReport {
  /// A report.
  const ReconcileReport({
    required this.unavailable,
    required this.recovered,
    required this.importsFinished,
    required this.purgesRolledBack,
    required this.renamesRolledBack,
    required this.repaired,
  });

  /// Entries whose file is missing (shown as unavailable, never dropped).
  final Set<EntryId> unavailable;

  /// Files adopted into `Recovered`.
  final int recovered;

  /// Half-committed imports finished.
  final int importsFinished;

  /// Purges undone because their rows survived.
  final int purgesRolledBack;

  /// Renames undone.
  final int renamesRolledBack;

  /// Folder and entry rows moved to restore the tree invariants.
  final int repaired;
}

/// Reconciles the database and files of [w] at [now].
ReconcileReport reconcileLibrary(LibraryWriter w, {required DateTime now}) {
  final db = w.db;
  final fs = w.fs;
  final reader = w.reader;
  var importsFinished = 0, purgesRolledBack = 0, renamesRolledBack = 0, recovered = 0, repaired = 0;

  // Import jobs.
  final committingEntries = <String>{};
  for (final job in reader.importJobs()) {
    if (job.state != ImportJobState.committing) {
      fs.removeEmptyEntryDir(job.entryId.value);
      continue;
    }
    final entry = reader.entry(job.entryId);
    if (entry == null) {
      db.execute('UPDATE import_jobs SET state = ? WHERE id = ?', [ImportJobState.copying.code, job.id]);
      fs.removeEmptyEntryDir(job.entryId.value);
      continue;
    }
    committingEntries.add(job.entryId.value);
    if (!fs.entryFileExists(entry.id, entry.displayName) && fs.partExists(job.partPath)) {
      if (!fs.entryDirExists(entry.id)) fs.createEntryDir(entry.id);
      fs.movePartIntoEntry(job.partPath, entry.id, entry.displayName);
    }
    db.execute('DELETE FROM import_jobs WHERE id = ?', [job.id]);
    importsFinished++;
  }

  // Stray part files.
  final jobParts = {for (final j in reader.importJobs()) j.partPath.split('/').last};
  for (final part in fs.listParts()) {
    if (!jobParts.contains(part)) fs.deletePart('imports/$part');
  }

  // Purge-staged directories.
  for (final dir in fs.listEntryDirs()) {
    if (!dir.startsWith(LibraryPaths.purgePrefix)) continue;
    final id = EntryId.tryParse(dir.substring(LibraryPaths.purgePrefix.length));
    if (id != null && reader.entry(id) != null) {
      fs.unstagePurge(id);
      purgesRolledBack++;
    } else {
      fs.removeEntryDirNamed(dir);
    }
  }

  // Entry files: roll back interrupted renames, note missing files.
  final unavailable = <EntryId>{};
  final entries = reader.allEntries(includeTrashed: true);
  for (final e in entries) {
    if (fs.entryFileExists(e.id, e.displayName)) continue;
    final files = fs.filesIn(e.id);
    if (files.length == 1) {
      fs.renameEntryFile(e.id, files.single, e.displayName);
      renamesRolledBack++;
    } else {
      unavailable.add(e.id);
    }
  }

  // Orphan directories.
  final known = {for (final e in entries) e.id.value, ...committingEntries};
  for (final dir in fs.listEntryDirs()) {
    if (dir.startsWith(LibraryPaths.purgePrefix) || known.contains(dir)) continue;
    final id = EntryId.tryParse(dir);
    if (id == null) continue;
    final files = fs.filesIn(id);
    if (files.isEmpty) {
      fs.removeEmptyEntryDir(dir);
      continue;
    }
    final name = files.first;
    final folder = w.systemFolder(FolderSystemRole.recovered, now);
    final taken = {
      for (final r in db.select('SELECT display_name FROM entries WHERE folder_id = ? AND trashed_at IS NULL', [folder.value]))
        (r['display_name'] as String).toLowerCase(),
    };
    final unique = uniqueName(name, taken);
    if (unique != name) fs.renameEntryFile(id, name, unique);
    final kind = classify(fileName: unique);
    db.execute(
      'INSERT INTO entries(id, folder_id, display_name, kind, sub_kind, size_bytes, added_at, modified_at, is_favourite, source_hint) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
      [id.value, folder.value, unique, kind.kind.code, kind.subKind, fs.entryFileSize(id, unique) ?? 0, msOf(now), msOf(now), SourceHint.unknown.code],
    );
    recovered++;
  }

  // Tree repair.
  w.transaction(() {
    void toTopLevel(LibraryFolder f) {
      final taken = {for (final t in reader.childFolders(null)) if (t.id != f.id) t.name.toLowerCase()};
      db.execute('UPDATE folders SET parent_id = NULL, name = ? WHERE id = ?', [uniqueName(f.name, taken, splitExtension: false), f.id.value]);
      repaired++;
    }

    final folders = {for (final f in reader.allFolders(includeTrashed: true)) f.id: f};
    for (final f in folders.values) {
      final seen = <FolderId>{f.id};
      var next = f.parentId;
      while (next != null && seen.add(next)) {
        next = folders[next]?.parentId;
      }
      if (next != null) {
        toTopLevel(f);
        folders[f.id] = reader.folder(f.id)!;
      }
    }
    for (final f in reader.allFolders()) {
      if (f.parentId == null) continue;
      final parent = reader.folder(f.parentId!);
      if (parent == null || parent.isTrashed) toTopLevel(f);
    }
    final imported = w.importedFolder(now);
    final taken = {for (final e in reader.entriesPage(EntryQuery(folderId: imported), limit: -1)) e.displayName.toLowerCase()};
    for (final e in reader.allEntries()) {
      final folder = reader.folder(e.folderId);
      if (folder == null || folder.isTrashed) {
        final unique = uniqueName(e.displayName, taken);
        taken.add(unique.toLowerCase());
        if (unique != e.displayName && fs.entryFileExists(e.id, e.displayName)) fs.renameEntryFile(e.id, e.displayName, unique);
        db.execute('UPDATE entries SET folder_id = ?, display_name = ? WHERE id = ?', [imported.value, unique, e.id.value]);
        repaired++;
      }
    }
    db.execute('DELETE FROM recents WHERE entry_id NOT IN (SELECT id FROM entries)');
  });

  return ReconcileReport(
    unavailable: unavailable,
    recovered: recovered,
    importsFinished: importsFinished,
    purgesRolledBack: purgesRolledBack,
    renamesRolledBack: renamesRolledBack,
    repaired: repaired,
  );
}
