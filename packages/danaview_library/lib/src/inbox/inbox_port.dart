// OWNER: HOM-21
//
// InboxPort, what the library needs from the iOS Share Extension inbox (ARCH v1.2 §5.6, rule 26):
// the App Group `Inbox/<batchId>/` directories the extension writes (streamed copies, then
// `manifest.json` last). The library is pure Dart and never reads the App Group itself; the app
// adapts `danaview_library_native`'s `NativeInbox` (the only App Group reader) to this port.
// Nothing here prints a name or a path (rule 30).

import 'package:meta/meta.dart';

import '../model/ids.dart';

/// One shared file of an inbox batch.
@immutable
final class InboxFile {
  /// A file of a batch.
  const InboxFile({required this.relativePath, required this.displayName, required this.sizeBytes, this.uti, this.mimeType});

  /// The path inside the batch directory (what [InboxPort.takeFile] takes).
  final String relativePath;

  /// The name the entry gets.
  final String displayName;

  /// Apple UTType, when the extension recorded one.
  final String? uti;

  /// MIME type, when known.
  final String? mimeType;

  /// Size in bytes.
  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is InboxFile &&
      other.relativePath == relativePath &&
      other.displayName == displayName &&
      other.uti == uti &&
      other.mimeType == mimeType &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(relativePath, displayName, uti, mimeType, sizeBytes);

  // Never prints the name or the path (rule 30).
  @override
  String toString() => 'InboxFile($sizeBytes bytes)';
}

/// One Share Extension batch (`Inbox/<batchId>/`).
@immutable
final class InboxBatch {
  /// A batch.
  const InboxBatch({required this.batchId, required this.createdAt, required this.complete, this.targetFolder, this.files = const []});

  /// The directory name.
  final String batchId;

  /// When the extension started it (the manifest's `createdAt`, else the directory's date).
  final DateTime createdAt;

  /// True once `manifest.json` exists: every file of [files] was copied completely.
  final bool complete;

  /// The Danaview folder picked in the extension, or null for `Imported`.
  final FolderId? targetFolder;

  /// The files, in share order (empty while incomplete).
  final List<InboxFile> files;

  // Never prints names (rule 30).
  @override
  String toString() => 'InboxBatch($batchId, ${complete ? 'complete' : 'incomplete'}, ${files.length} files)';
}

/// The App Group inbox as the library sees it. Every method may throw; [InboxImporter] treats a
/// failure as "try again on the next launch or foreground".
abstract interface class InboxPort {
  /// False when the platform has no inbox (not iOS, or the App Group entitlement is missing).
  Future<bool> isAvailable();

  /// Every batch directory, complete or not.
  Future<List<InboxBatch>> listBatches();

  /// Moves [relativePath] of batch [batchId] to [destinationPath] (an app-owned path; replaced if
  /// it exists).
  Future<void> takeFile(String batchId, String relativePath, String destinationPath);

  /// Deletes batch [batchId] and everything left in it.
  Future<void> deleteBatch(String batchId);

  /// Deletes incomplete batches older than [age]; returns how many.
  Future<int> deleteStaleBatches(Duration age);

  /// Replaces the folder-list snapshot the extension's folder picker reads (UTF-8 JSON).
  Future<void> writeFolderSnapshot(List<int> json);
}
