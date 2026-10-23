// OWNER: HOM-21
//
// InboxImporter (ARCH v1.2 §5.6, owner 2026-10-16): on launch and on every foreground the app
// imports each complete Share Extension batch through the normal import path
// (`sourceHint = shareExtension`) and deletes the batch; incomplete batches (no `manifest.json`:
// the extension was killed or the share cancelled mid-copy) are never imported and are deleted once
// they are older than 24 h. It also refreshes the folder-list snapshot the extension's picker reads.
//
// Each file is moved out of the App Group (InboxPort.takeFile; rule 26: only the native Inbox class
// touches the App Group) into an app-owned staging directory and enqueued as a staged copy, which
// the import deletes after its commit. Kill-safety:
//
// * killed after a move but before its import started: the batch still exists and the staged file
//   is found again at the same path on the next run;
// * killed mid-copy: the import job resumes (ImportService.resumePending) from the staged file, and
//   the next run doesn't enqueue it twice;
// * a batch is deleted only after every one of its imports finished, so a half-imported share
//   never leaves an entry behind (the import commits in one transaction).
//
// Nothing here logs a name or a path (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../import/import_service.dart';
import '../import/import_source.dart';
import '../model/file_entry.dart';
import '../model/source_hint.dart';
import 'folder_snapshot.dart';
import 'inbox_port.dart';

/// Incomplete batches older than this are deleted.
const Duration inboxStaleAge = Duration(hours: 24);

/// What one [InboxImporter.run] did.
@immutable
final class InboxRunResult {
  /// A result.
  const InboxRunResult({
    this.available = true,
    this.batches = 0,
    this.imported = const [],
    this.skipped = 0,
    this.failed = 0,
    this.staleDeleted = 0,
  });

  /// No inbox on this platform (nothing ran).
  static const InboxRunResult unavailable = InboxRunResult(available: false);

  /// False when the platform has no inbox.
  final bool available;

  /// Complete batches handled (and deleted).
  final int batches;

  /// The entries imported, in share order.
  final List<FileEntry> imported;

  /// Files not imported because the same content is already in the library (when the policy skips).
  final int skipped;

  /// Files that could not be imported.
  final int failed;

  /// Incomplete batches deleted for being older than [inboxStaleAge].
  final int staleDeleted;

  @override
  String toString() => 'InboxRunResult(batches: $batches, imported: ${imported.length}, skipped: $skipped, failed: $failed, stale: $staleDeleted)';
}

/// Imports the Share Extension inbox through an [ImportService].
final class InboxImporter {
  /// An importer moving files from [port] into [stagingDirectory] (app-owned, used by nothing
  /// else: it is swept after each run) and importing them with [imports]. A shared file whose
  /// content is already in the library follows [duplicates] (default: keep both, as nobody may be
  /// looking at the import sheet when the app comes to the foreground).
  InboxImporter({
    required this.port,
    required this.imports,
    required this.stagingDirectory,
    this.duplicates = DuplicatePolicy.keepBoth,
    this.staleAge = inboxStaleAge,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The App Group inbox.
  final InboxPort port;

  /// The import queue.
  final ImportService imports;

  /// Where files moved out of the inbox wait for their import.
  final String stagingDirectory;

  /// What to do with a shared file whose content is already in the library.
  final DuplicatePolicy duplicates;

  /// Incomplete batches older than this are deleted.
  final Duration staleAge;

  final DateTime Function() _clock;
  Future<InboxRunResult>? _running;
  bool _again = false;

  /// Imports every complete batch and deletes it, deletes stale incomplete batches and refreshes
  /// the folder snapshot. A call while a run is in flight runs once more after it (a batch the
  /// extension finished meanwhile is picked up) and completes with that later run.
  Future<InboxRunResult> run() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _runLoop();
  }

  Future<InboxRunResult> _runLoop() async {
    try {
      InboxRunResult result;
      do {
        _again = false;
        result = await _runOnce();
      } while (_again);
      return result;
    } finally {
      _running = null;
    }
  }

  /// Writes the folder snapshot of the library now (after folder changes).
  Future<void> refreshFolderSnapshot() async {
    if (!await _available()) return;
    await _writeSnapshot();
  }

  Future<bool> _available() async {
    try {
      return await port.isAvailable();
    } on Object {
      return false;
    }
  }

  Future<void> _writeSnapshot() async {
    try {
      await port.writeFolderSnapshot(buildFolderSnapshot(imports.store.reader, now: _clock()));
    } on Object {
      // The extension keeps the previous snapshot (or offers Imported only).
    }
  }

  Future<InboxRunResult> _runOnce() async {
    if (!await _available()) return InboxRunResult.unavailable;
    await _writeSnapshot();

    var stale = 0;
    try {
      stale = await port.deleteStaleBatches(staleAge);
    } on Object {
      // Retried on the next run.
    }

    List<InboxBatch> batches;
    try {
      batches = await port.listBatches();
    } on Object {
      return InboxRunResult(staleDeleted: stale);
    }
    final complete = [for (final b in batches) if (b.complete) b]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final imported = <FileEntry>[];
    var skipped = 0, failed = 0, handled = 0;
    for (final batch in complete) {
      final outcome = await _importBatch(batch);
      if (outcome == null) continue;
      imported.addAll(outcome.imported);
      skipped += outcome.skipped;
      failed += outcome.failed;
      try {
        await port.deleteBatch(batch.batchId);
        handled++;
      } on Object {
        // Deleted on the next run (its files are gone, so nothing is imported twice).
      }
    }

    try {
      await imports.sweepStaging(stagingDirectory);
    } on Object {
      // Swept on the next run.
    }
    return InboxRunResult(batches: handled, imported: imported, skipped: skipped, failed: failed, staleDeleted: stale);
  }

  /// Imports [batch]; null when a disposed import service stopped it (the batch stays).
  Future<_BatchOutcome?> _importBatch(InboxBatch batch) async {
    // Flat names in the staging directory (the native take creates it): `<batch>_<n>_<name>`.
    final prefix = '${_safe(batch.batchId)}_';
    final pending = _pendingLocations();
    final ids = <String>[];
    var failed = 0;
    for (var i = 0; i < batch.files.length; i++) {
      final file = batch.files[i];
      final dest = p.join(stagingDirectory, '$prefix${i.toString().padLeft(4, '0')}_${_safe(file.displayName)}');
      // Copying already (an earlier run was killed mid-copy): the resumed job finishes it.
      if (pending.contains(p.canonicalize(dest))) continue;
      if (!File(dest).existsSync()) {
        try {
          await port.takeFile(batch.batchId, file.relativePath, dest);
        } on Object {
          // Gone: an earlier run moved and imported it and was killed before deleting the batch
          // (a missing file can't be told from that case, so it is not counted as a failure).
          if (!File(dest).existsSync()) continue;
        }
      }
      try {
        ids.add(imports.enqueue(
          ImportSource.file(
            dest,
            displayName: file.displayName,
            uti: file.uti,
            mime: file.mimeType,
            sizeBytes: file.sizeBytes,
            sourceHint: SourceHint.shareExtension,
            stagedCopy: true,
          ),
          target: batch.targetFolder,
          duplicates: duplicates,
        ));
      } on StateError {
        return null; // the import service is disposed (the app is going away)
      }
    }

    final imported = <FileEntry>[];
    var skipped = 0;
    for (final id in ids) {
      final ImportItem item;
      try {
        item = await imports.result(id);
      } on Object {
        failed++;
        continue;
      }
      switch (item.state) {
        case ImportItemState.done:
          imported.add(item.entry!);
        case ImportItemState.skipped:
          skipped++;
        case _:
          failed++;
      }
    }
    return _BatchOutcome(imported, skipped, failed);
  }

  Set<String> _pendingLocations() => {
        for (final job in imports.store.reader.importJobs())
          if (ImportSource.tryDecode(job.sourceDescription) case final s?) p.canonicalize(s.location),
      };

}

final class _BatchOutcome {
  _BatchOutcome(this.imported, this.skipped, this.failed);

  final List<FileEntry> imported;
  final int skipped;
  final int failed;
}

final RegExp _unsafe = RegExp(r'[^A-Za-z0-9._-]');

// A file-system-safe spelling of a name for the staging path only (the entry keeps the real name).
String _safe(String name) {
  var s = name.replaceAll(_unsafe, '_');
  if (s.length > 80) s = s.substring(s.length - 80);
  return s.isEmpty || s == '.' || s == '..' ? 'file' : s;
}
