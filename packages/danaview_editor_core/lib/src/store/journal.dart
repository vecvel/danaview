// OWNER: CORE-26
//
// The autosave journal of one project bundle (ARCH §8.1, §8.3):
//
//   projects/<id>/journal/a.dnproj   journal/b.dnproj   journal/recovered-<ts>.dnproj
//
// * Autosaves alternate between the two slots, so writing one never touches the other: a crash
//   in the middle of a slot write leaves a torn slot (its checksum fails) next to the previous
//   complete one. Slots are written directly (one synced write), not through `AtomicFile`.
// * Every slot is a complete `.dnproj` whose header carries `baseSaveId` = the `saveId` of the
//   main document it continues. A slot only counts for recovery when its `docRevision` is above
//   the main document's and its `baseSaveId` equals the main's `saveId` (recovery.dart).
// * A successful main save truncates the journal (both slots and any `recovered-*` file).
// * "Open last saved" (the user declines the recovery) keeps the newest slot as
//   `recovered-<ts>.dnproj` until the next successful main save, and empties the slots so new
//   autosaves cannot be confused with it.
//
// Every delete goes through `OwnedFileDeleter`.

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'dnproj_format.dart';

/// One of the two journal slots.
enum JournalSlot {
  /// `journal/a.dnproj`.
  a,

  /// `journal/b.dnproj`.
  b;

  /// The other slot.
  JournalSlot get other => this == a ? b : a;
}

/// A valid journal slot read from disk.
@immutable
final class JournalEntry {
  /// Creates an entry.
  const JournalEntry(this.slot, this.path, this.document);

  /// Which slot.
  final JournalSlot slot;

  /// Absolute path.
  final String path;

  /// The parsed, checksum-verified document.
  final DnprojDocument document;

  /// `docRevision` of the slot.
  int get docRevision => document.header.docRevision;

  /// `baseSaveId` of the slot (the main save it continues).
  String? get baseSaveId => document.header.baseSaveId;
}

/// The journal folder of one project bundle.
final class ProjectJournal {
  /// Creates the journal of the bundle at [projectDir]. [deleter] must share [fs].
  ProjectJournal(this.projectDir, {required StoreFs fs, required this.deleter}) : _fs = fs;

  /// The project bundle directory.
  final String projectDir;

  /// The deletion guard.
  final OwnedFileDeleter deleter;

  final StoreFs _fs;

  /// `<bundle>/journal`.
  String get dir => p.join(projectDir, 'journal');

  /// Absolute path of [slot].
  String pathOf(JournalSlot slot) => p.join(dir, '${slot.name}.dnproj');

  /// File name of a kept journal (`recovered-<UTC yyyyMMddTHHmmssZ>.dnproj`).
  static String recoveredName(DateTime at) {
    final u = at.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'recovered-${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z.dnproj';
  }

  /// Both slots that hold a valid document, newest `docRevision` first.
  Future<List<JournalEntry>> validSlots() async {
    final out = <JournalEntry>[];
    for (final slot in JournalSlot.values) {
      final path = pathOf(slot);
      final s = await _fs.stat(path);
      if (s.type != StoreEntityType.file) continue;
      try {
        final doc = DnprojFormat.tryParse(await _fs.readBytes(path));
        if (doc != null) out.add(JournalEntry(slot, path, doc));
      } on StoreFailure catch (e) {
        if (e.kind != StoreFailureKind.notFound) rethrow;
      }
    }
    out.sort((x, y) => y.docRevision.compareTo(x.docRevision));
    return out;
  }

  /// The newest valid slot, or null.
  Future<JournalEntry?> newest() async {
    final all = await validSlots();
    return all.isEmpty ? null : all.first;
  }

  /// The slot the next autosave writes: the one *not* holding the newest valid document of the
  /// current generation ([baseSaveId]); slot `a` when neither does.
  Future<JournalSlot> nextSlot({required String? baseSaveId}) async {
    for (final e in await validSlots()) {
      if (e.baseSaveId == baseSaveId) return e.slot.other;
    }
    return JournalSlot.a;
  }

  /// Whether a slot file (valid or not) exists.
  Future<bool> hasSlots() async {
    for (final slot in JournalSlot.values) {
      if ((await _fs.stat(pathOf(slot))).exists) return true;
    }
    return false;
  }

  /// `recovered-*.dnproj` files, oldest name first.
  Future<List<String>> recoveredFiles() async {
    if ((await _fs.stat(dir)).type != StoreEntityType.directory) return const [];
    final names = [
      for (final e in await _fs.list(dir))
        if (p.basename(e.path).startsWith('recovered-') && p.basename(e.path).endsWith('.dnproj')) e.path,
    ]..sort();
    return names;
  }

  /// Deletes both slots and their leftovers; with [keepRecovered] false also every
  /// `recovered-*` file (after a successful main save).
  Future<void> truncate({bool keepRecovered = false}) async {
    if ((await _fs.stat(dir)).type != StoreEntityType.directory) return;
    for (final e in await _fs.list(dir)) {
      final name = p.basename(e.path);
      final slotFile = name.startsWith('a.dnproj') || name.startsWith('b.dnproj');
      final recovered = name.startsWith('recovered-');
      if (slotFile || (recovered && !keepRecovered)) await deleter.delete(e.path);
    }
  }

  /// "Open last saved": moves the newest valid slot to `recovered-<ts>.dnproj` and empties the
  /// slots. Returns the kept file's path, or null when there was no valid slot.
  Future<String?> keepAsRecovered(DateTime at) async {
    final newest = await this.newest();
    String? kept;
    if (newest != null) {
      kept = p.join(dir, recoveredName(at));
      if ((await _fs.stat(kept)).exists) await deleter.delete(kept);
      await _fs.rename(newest.path, kept);
    }
    await truncate(keepRecovered: true);
    return kept;
  }
}
