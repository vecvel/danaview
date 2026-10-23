// OWNER: HOM-21
//
// The App Group Share Extension inbox reader (ARCH v1.2 §5.6, rule 26: the plugin's Inbox class is
// the only App Group reader): lists the batches the iOS extension wrote (`Inbox/<batchId>/`,
// complete once `manifest.json` exists), moves a shared file out to an app path, deletes batches
// (stale incomplete ones after 24 h), writes the folder-list snapshot the extension's picker reads,
// and reports `inboxChanged` when the extension finishes a batch while the app runs. iOS only:
// macOS, Android, Windows and Linux answer notSupportedOnDevice (Android uses incoming intents,
// HOM-21A). Nothing here logs a name or a path (rule 30).

import 'package:flutter/services.dart';

import 'native_photo_library.dart';
import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// One file of a [NativeInboxBatch].
final class NativeInboxFile {
  /// A file.
  const NativeInboxFile({required this.relativePath, required this.displayName, required this.sizeBytes, this.uti, this.mimeType});

  /// The path inside the batch directory.
  final String relativePath;

  /// The name to import it as.
  final String displayName;

  /// Apple UTType, when recorded.
  final String? uti;

  /// MIME type, when recorded.
  final String? mimeType;

  /// Size in bytes.
  final int sizeBytes;

  // Never prints the name or the path (rule 30).
  @override
  String toString() => 'NativeInboxFile($sizeBytes bytes)';
}

/// One Share Extension batch.
final class NativeInboxBatch {
  /// A batch.
  const NativeInboxBatch({required this.batchId, required this.createdAt, required this.complete, required this.files, this.targetFolderId});

  /// The batch directory name.
  final String batchId;

  /// When the extension started it.
  final DateTime createdAt;

  /// True once `manifest.json` exists.
  final bool complete;

  /// The Danaview folder (`fd_…`) picked in the extension, or null for Imported.
  final String? targetFolderId;

  /// The files in share order (empty while incomplete).
  final List<NativeInboxFile> files;

  @override
  String toString() => 'NativeInboxBatch($batchId, ${complete ? 'complete' : 'incomplete'}, ${files.length} files)';
}

/// [NativeInboxBatch] of a Pigeon message (tests and the wrapper).
NativeInboxBatch inboxBatchFromMessage(InboxBatchMsg m) => NativeInboxBatch(
      batchId: m.batchId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m.createdAtMs, isUtc: true),
      complete: m.complete,
      targetFolderId: (m.targetFolderId?.isEmpty ?? true) ? null : m.targetFolderId,
      files: [
        for (final f in m.files)
          NativeInboxFile(relativePath: f.relativePath, displayName: f.displayName, sizeBytes: f.sizeBytes, uti: f.uti, mimeType: f.mimeType),
      ],
    );

/// The Share Extension inbox over the plugin's Pigeon surface. Every call throws
/// [LibraryNativeException]; `notSupportedOnDevice` outside iOS.
final class NativeInbox {
  /// The inbox of the default engine; tests pass a mock [binaryMessenger] and an [events] hub.
  NativeInbox({BinaryMessenger? binaryMessenger, String messageChannelSuffix = '', LibraryEventHub? events})
      : _api = InboxHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        _events = events ?? LibraryEventHub.forInstance(messageChannelSuffix);

  final InboxHostApi _api;
  final LibraryEventHub _events;

  /// False when there is no inbox here (not iOS, or the App Group entitlement is missing). Never
  /// throws.
  Future<bool> isAvailable() async {
    try {
      return await guardNative(_api.isAvailable);
    } on LibraryNativeException {
      return false;
    }
  }

  /// Every batch directory, oldest first.
  Future<List<NativeInboxBatch>> listBatches() => guardNative(() async => [for (final m in await _api.listBatches()) inboxBatchFromMessage(m)]);

  /// Moves [relativePath] of batch [batchId] to the absolute app path [destinationPath].
  Future<void> takeFile(String batchId, String relativePath, String destinationPath) {
    if (batchId.isEmpty) throw ArgumentError.value(batchId, 'batchId', 'empty');
    if (relativePath.isEmpty) throw ArgumentError.value('', 'relativePath', 'empty');
    if (destinationPath.isEmpty) throw ArgumentError.value('', 'destinationPath', 'empty');
    return guardNative(() => _api.takeFile(batchId, relativePath, destinationPath));
  }

  /// Deletes batch [batchId] (a missing batch is fine).
  Future<void> deleteBatch(String batchId) {
    if (batchId.isEmpty) throw ArgumentError.value(batchId, 'batchId', 'empty');
    return guardNative(() => _api.deleteBatch(batchId));
  }

  /// Deletes incomplete batches older than [age]; returns how many.
  Future<int> deleteStaleBatches(Duration age) {
    if (age.isNegative) throw ArgumentError.value(age, 'age', 'negative');
    return guardNative(() => _api.deleteStaleBatches(age.inMilliseconds));
  }

  /// Replaces the folder snapshot the extension's picker reads (UTF-8 JSON).
  Future<void> writeFolderSnapshot(List<int> json) => guardNative(() => _api.writeFolderSnapshot(Uint8List.fromList(json)));

  /// Fires when the extension finished a batch while the app runs (no payload).
  Stream<void> get changes => _events.of(LibraryEventKindMsg.inboxChanged).map((_) {});
}
