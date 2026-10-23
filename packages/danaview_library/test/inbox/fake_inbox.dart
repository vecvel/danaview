// OWNER: HOM-21
//
// A directory-backed InboxPort for the HOM-21 tests: `<root>/<batchId>/` holds the shared files and
// a batch is complete once it was "closed" (the manifest written last), as the extension does.
// Generated local files only.

import 'dart:io';

import 'package:danaview_library/testing.dart';

/// The App Group inbox of a test.
final class FakeInboxPort implements InboxPort {
  /// An inbox under [root].
  FakeInboxPort(this.root);

  /// The directory holding the batches.
  final Directory root;

  /// False to act as a platform without an inbox.
  bool available = true;

  /// The last folder snapshot written.
  List<int>? snapshot;

  /// Snapshot writes.
  int snapshotWrites = 0;

  /// Batch ids deleted.
  final List<String> deleted = [];

  /// Called before every take (a test may throw or block here).
  Future<void> Function(String batchId, String relativePath)? beforeTake;

  final Map<String, _Batch> _batches = {};

  /// Starts batch [id] created at [createdAt] with [files] (name → bytes); [complete] writes the
  /// manifest; [folder] is the folder picked in the extension.
  void addBatch(String id, Map<String, List<int>> files, {required DateTime createdAt, bool complete = true, FolderId? folder}) {
    final dir = Directory('${root.path}/$id')..createSync(recursive: true);
    final list = <InboxFile>[];
    var i = 0;
    for (final e in files.entries) {
      final rel = 'items/${i++}/${e.key}';
      File('${dir.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsBytesSync(e.value, flush: true);
      list.add(InboxFile(relativePath: rel, displayName: e.key, sizeBytes: e.value.length));
    }
    _batches[id] = _Batch(createdAt, complete, folder, list);
  }

  /// True while batch [id] exists.
  bool hasBatch(String id) => _batches.containsKey(id);

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<InboxBatch>> listBatches() async => [
        for (final e in _batches.entries)
          InboxBatch(
            batchId: e.key,
            createdAt: e.value.createdAt,
            complete: e.value.complete,
            targetFolder: e.value.folder,
            files: e.value.complete ? e.value.files : const [],
          ),
      ];

  @override
  Future<void> takeFile(String batchId, String relativePath, String destinationPath) async {
    await beforeTake?.call(batchId, relativePath);
    final f = File('${root.path}/$batchId/$relativePath');
    if (!f.existsSync()) throw const FileSystemException('missing');
    final dest = File(destinationPath);
    if (dest.existsSync()) dest.deleteSync();
    f.renameSync(destinationPath);
  }

  @override
  Future<void> deleteBatch(String batchId) async {
    _batches.remove(batchId);
    final dir = Directory('${root.path}/$batchId');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    deleted.add(batchId);
  }

  /// The clock [deleteStaleBatches] compares against.
  DateTime now = DateTime.utc(2026, 10, 23, 12);

  @override
  Future<int> deleteStaleBatches(Duration age) async {
    final stale = [for (final e in _batches.entries) if (!e.value.complete && now.difference(e.value.createdAt) > age) e.key];
    for (final id in stale) {
      await deleteBatch(id);
    }
    return stale.length;
  }

  @override
  Future<void> writeFolderSnapshot(List<int> json) async {
    snapshot = List.of(json);
    snapshotWrites++;
  }
}

final class _Batch {
  _Batch(this.createdAt, this.complete, this.folder, this.files);

  final DateTime createdAt;
  final bool complete;
  final FolderId? folder;
  final List<InboxFile> files;
}
