// OWNER: HOM-17
//
// The library invariants (ARCH v1.2 §5.3), checked on open (after the reconcile) and by the
// property and crash tests:
//
// 1. no cycles in `folders`;
// 2. a live folder's parent is a live folder (or the top level);
// 3. a live entry's folder exists and is live; a trashed row has both `trashed_at` and `expires_at`;
// 4. `files/<id>/<display_name>` exists for every entry (missing → the entry is unavailable);
// 5. no stray directories under `files/` (no row, purge-staged) and no part file without a job;
// 6. no import job is left half-committed;
// 7. exactly one live `Imported` system folder;
// 8. Recents holds at most 50 rows, each an existing entry;
// 9. live names are unique (case-insensitively) among the live entries of a folder and among the
//    live subfolders of a parent.
//
// Violations name ids and rule numbers only, never names or paths (rule 30).

import '../db/library_folder.dart';
import '../db/library_reader.dart';
import '../db/library_schema.dart';
import '../model/ids.dart';
import 'library_fs.dart';
import 'library_paths.dart';

/// The invariants [reader] and [fs] break; empty when the library is consistent. Entries in
/// [unavailable] (already known to have lost their file) are not reported under rule 4.
List<String> checkLibraryInvariants(LibraryReader reader, LibraryFs fs, {Set<EntryId> unavailable = const {}}) {
  final out = <String>[];
  final folders = {for (final f in reader.allFolders(includeTrashed: true)) f.id: f};
  final entries = reader.allEntries(includeTrashed: true);

  // 1 and 2.
  for (final f in folders.values) {
    final seen = <FolderId>{f.id};
    var next = f.parentId;
    while (next != null) {
      if (!seen.add(next)) {
        out.add('1: folder ${f.id.value} is in a cycle');
        break;
      }
      next = folders[next]?.parentId;
    }
    if (!f.isTrashed && f.parentId != null) {
      final parent = folders[f.parentId];
      if (parent == null || parent.isTrashed) out.add('2: live folder ${f.id.value} has no live parent');
    }
    if ((f.trashedAt == null) != (f.expiresAt == null)) out.add('3: folder ${f.id.value} has half a trash state');
  }

  // 3 and 4.
  for (final e in entries) {
    if (!e.isTrashed) {
      final folder = folders[e.folderId];
      if (folder == null || folder.isTrashed) out.add('3: live entry ${e.id.value} has no live folder');
    }
    if (!unavailable.contains(e.id) && !fs.entryFileExists(e.id, e.displayName)) out.add('4: entry ${e.id.value} has no file');
  }

  // 5 and 6.
  final entryIds = {for (final e in entries) e.id.value};
  final jobs = reader.importJobs();
  for (final dir in fs.listEntryDirs()) {
    if (dir.startsWith(LibraryPaths.purgePrefix)) {
      out.add('5: purge-staged directory ${dir.substring(LibraryPaths.purgePrefix.length)} left');
    } else if (!entryIds.contains(dir)) {
      out.add('5: directory $dir has no entry');
    }
  }
  final jobParts = {for (final j in jobs) j.partPath.split('/').last};
  for (final part in fs.listParts()) {
    if (!jobParts.contains(part)) out.add('5: part file without a job');
  }
  for (final j in jobs) {
    if (j.state == ImportJobState.committing) out.add('6: import job ${j.id} is half-committed');
  }

  // 7.
  final imported = folders.values.where((f) => f.systemRole == FolderSystemRole.imported && !f.isTrashed).length;
  if (imported != 1) out.add('7: $imported live Imported folders');

  // 8.
  final recents = reader.db.select('SELECT entry_id FROM recents');
  if (recents.length > recentsCap) out.add('8: ${recents.length} recents');
  for (final r in recents) {
    if (!entryIds.contains(r['entry_id'])) out.add('8: recent ${r['entry_id']} has no entry');
  }

  // 9.
  final entryNames = <String, Set<String>>{};
  for (final e in entries.where((e) => !e.isTrashed)) {
    if (!(entryNames[e.folderId.value] ??= {}).add(e.displayName.toLowerCase())) {
      out.add('9: duplicate entry name in folder ${e.folderId.value}');
    }
  }
  final folderNames = <String, Set<String>>{};
  for (final f in folders.values.where((f) => !f.isTrashed)) {
    if (!(folderNames[f.parentId?.value ?? ''] ??= {}).add(f.name.toLowerCase())) {
      out.add('9: duplicate folder name under ${f.parentId?.value ?? 'the top level'}');
    }
  }
  return out;
}
