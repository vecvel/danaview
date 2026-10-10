// OWNER: CORE-26
//
// Crash recovery (ARCH §8.3): which journal can be restored, and restore / discard / keep.
//
// A project is recoverable when its newest valid journal slot has
// `docRevision > main.docRevision` and `baseSaveId == main.saveId` (the journal continues exactly
// the main document on disk; it only exists after a crash, a kill or a failed background save,
// because every successful main save truncates the journal). When no valid main document can be
// read at all (every copy corrupt), the newest valid slot is offered regardless of its
// `baseSaveId` ("Restore last good version").
//
// * `restore` promotes the slot's document to `project.vwproj` with `AtomicFile` (a crash leaves
//   either the old or the promoted main) and then truncates the journal.
// * `discard` deletes the slots.
// * `keepLastSaved` ("Open last saved") keeps the slot as `recovered-<ts>.vwproj` until the next
//   successful main save (journal.dart).
//
// Nothing here runs on open: opening never writes. The repository (CORE-25) calls these.

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../codec/schema_version.dart';
import '../ids/ids.dart';
import 'atomic_file.dart';
import 'journal.dart';
import 'owned_file_deleter.dart';
import 'project_repository.dart';
import 'store_fs.dart';
import 'vwproj_format.dart';

/// A journal slot that can be restored, with the main document it is compared with.
@immutable
final class RecoveryCandidate {
  /// Creates a candidate.
  const RecoveryCandidate({required this.entry, required this.mainHeader});

  /// The newest valid journal slot.
  final JournalEntry entry;

  /// Header of the main document (null when no valid main copy exists).
  final ProjectHeader? mainHeader;

  /// The [RecoverableSession] shown to the user for project [id].
  RecoverableSession toSession(ProjectId id) => RecoverableSession(
        projectId: id,
        projectName: projectNameOf(entry.document.body) ?? '',
        journalRevision: entry.docRevision,
        mainRevision: mainHeader?.docRevision ?? 0,
        journalSavedAt: entry.document.header.savedAt,
      );
}

/// Whether a journal slot with [journal] header continues [main] and is ahead of it.
bool isRecoverableOver(ProjectHeader journal, ProjectHeader? main) {
  if (main == null) return true;
  return journal.docRevision > main.docRevision && journal.baseSaveId == main.saveId;
}

/// `meta.name` of a body, or null when it cannot be read (cheap: no model decode).
String? projectNameOf(List<int> body) {
  try {
    final j = jsonDecode(utf8.decode(body));
    if (j is Map<String, Object?>) {
      final meta = j['meta'];
      if (meta is Map<String, Object?> && meta['name'] is String) return meta['name']! as String;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Recovery operations on one project bundle.
final class ProjectRecovery {
  /// Creates the recovery helper of the bundle at [projectDir]. [deleter] must share [fs].
  ProjectRecovery(this.projectDir, {required StoreFs fs, required OwnedFileDeleter deleter})
      : _atomic = AtomicFile(fs: fs, deleter: deleter),
        journal = ProjectJournal(projectDir, fs: fs, deleter: deleter);

  /// The bundle directory.
  final String projectDir;

  /// Its journal.
  final ProjectJournal journal;

  final AtomicFile _atomic;

  /// `<bundle>/project.vwproj`.
  String get mainPath => p.join(projectDir, 'project.vwproj');

  /// The header of the best readable main document (main, else newest valid tmp/bak), or null
  /// when none is valid.
  Future<ProjectHeader?> mainHeader() async {
    try {
      final r = await _atomic.read(mainPath, isValid: VwprojFormat.isValid);
      return VwprojFormat.parse(r.bytes).header;
    } on StoreFailure catch (e) {
      if (e.kind == StoreFailureKind.notFound || e.kind == StoreFailureKind.corrupt) return null;
      rethrow;
    }
  }

  /// The restorable journal, or null. [main] may be passed when already read.
  Future<RecoveryCandidate?> inspect({ProjectHeader? main, bool mainKnown = false}) async {
    if (!await journal.hasSlots()) return null;
    final m = mainKnown ? main : await mainHeader();
    final newest = await journal.newest();
    if (newest == null) return null;
    return isRecoverableOver(newest.document.header, m) ? RecoveryCandidate(entry: newest, mainHeader: m) : null;
  }

  /// Promotes the restorable journal to the main document and truncates the journal. Throws
  /// [StoreFailure] `notFound` when nothing is restorable any more.
  Future<ProjectHeader> restore() async {
    final c = await inspect();
    if (c == null) throw const StoreFailure(StoreFailureKind.notFound, 'no recoverable journal');
    final bytes = VwprojFormat.encode(c.entry.document.header, c.entry.document.body);
    await _atomic.write(mainPath, bytes);
    await journal.truncate(keepRecovered: true);
    return c.entry.document.header;
  }

  /// Deletes the journal slots (keeps `recovered-*` files until the next main save).
  Future<void> discard() => journal.truncate(keepRecovered: true);

  /// "Open last saved": keeps the newest slot as `recovered-<ts>.vwproj`.
  Future<String?> keepLastSaved(DateTime at) => journal.keepAsRecovered(at);
}
