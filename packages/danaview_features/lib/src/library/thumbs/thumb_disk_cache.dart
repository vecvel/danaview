// OWNER: HOM-04
//
// The encoded-thumbnail disk tier (ARCH v1.2 V2-28, V2-104) under
// `<cache>/danaview/library/thumbs/` (the platform cache directory: excluded from iCloud and
// device backups on Apple and from Auto Backup on Android; the root is additionally flagged
// excluded through the plugin's backup flag where the app passes it). Files are written through a
// part file renamed into place, so a crash never leaves a half thumbnail under a key; a write
// removes the item's older versions (invalidation by modification time); a size trim drops the
// least recently written files. [ThumbDiskCache] is the port the service uses; [IoThumbDiskCache]
// is the `dart:io` implementation. Nothing is logged (rule 30).

import 'dart:async';
import 'dart:io';

import 'thumb_key.dart';

/// The disk tier the thumbnail service reads and writes.
abstract interface class ThumbDiskCache {
  /// The file of [key] when it exists, else null.
  Future<String?> lookup(ThumbKey key);

  /// A fresh part-file path for writing [key] (its directory exists).
  Future<String> partPathFor(ThumbKey key);

  /// Moves the finished [partPath] into place as [key]'s file and deletes the item's other
  /// versions at the same class. Returns the final path.
  Future<String> commit(ThumbKey key, String partPath);

  /// Deletes a part file that will not be committed (failure, cancel). Never throws.
  Future<void> discard(String partPath);

  /// Deletes the file of [key] (it would not decode). Never throws.
  Future<void> evict(ThumbKey key);
}

/// Path of the thumbnail cache root under the platform cache directory [cacheDir].
String thumbsRootIn(String cacheDir) {
  final sep = Platform.pathSeparator;
  final base = cacheDir.endsWith(sep) ? cacheDir.substring(0, cacheDir.length - 1) : cacheDir;
  return [base, 'danaview', 'library', 'thumbs'].join(sep);
}

/// The `dart:io` disk tier rooted at [root].
final class IoThumbDiskCache implements ThumbDiskCache {
  /// A cache at [root] (see [thumbsRootIn]); call [open] before use.
  IoThumbDiskCache(this.root);

  /// The cache root.
  final String root;

  int _parts = 0;

  String _abs(String relative) => [root, ...relative.split('/')].join(Platform.pathSeparator);

  /// Creates the root and removes part files a previous run left behind. [excludeFromBackup] (the
  /// plugin's backup flag) marks the root excluded; its failure is ignored (the platform cache
  /// directory is not backed up anyway).
  Future<void> open({Future<void> Function(String path)? excludeFromBackup}) async {
    await Directory(root).create(recursive: true);
    if (excludeFromBackup != null) {
      try {
        await excludeFromBackup(root);
      } on Object {
        // The cache directory is outside backups on every platform; the flag is belt and braces.
      }
    }
    await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.part')) {
        await _delete(e);
      }
    }
  }

  @override
  Future<String?> lookup(ThumbKey key) async {
    final f = File(_abs(key.relativePath));
    return await f.exists() ? f.path : null;
  }

  @override
  Future<String> partPathFor(ThumbKey key) async {
    final dir = Directory(_abs(key.relativeItemDir));
    await dir.create(recursive: true);
    return '${dir.path}${Platform.pathSeparator}${key.modifiedMs}-${++_parts}-$pid.part';
  }

  @override
  Future<String> commit(ThumbKey key, String partPath) async {
    final target = _abs(key.relativePath);
    await File(partPath).rename(target);
    final dir = Directory(_abs(key.relativeItemDir));
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path != target && e.path.endsWith('.thumb')) await _delete(e);
    }
    return target;
  }

  @override
  Future<void> discard(String partPath) => _delete(File(partPath));

  @override
  Future<void> evict(ThumbKey key) => _delete(File(_abs(key.relativePath)));

  /// Bytes and files on disk (Settings › storage, the trim).
  Future<({int bytes, int files})> usage() async {
    var bytes = 0, files = 0;
    if (!await Directory(root).exists()) return (bytes: 0, files: 0);
    await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.thumb')) {
        bytes += await e.length();
        files++;
      }
    }
    return (bytes: bytes, files: files);
  }

  /// Deletes the least recently written thumbnails until at most [maxBytes] remain.
  Future<void> trim(int maxBytes) async {
    if (!await Directory(root).exists()) return;
    final all = <(File, FileStat)>[];
    var total = 0;
    await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.thumb')) {
        final st = await e.stat();
        all.add((e, st));
        total += st.size;
      }
    }
    if (total <= maxBytes) return;
    all.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (f, st) in all) {
      if (total <= maxBytes) break;
      await _delete(f);
      total -= st.size;
    }
  }

  /// Deletes every thumbnail (Settings › clear cache).
  Future<void> clear() async {
    final d = Directory(root);
    if (await d.exists()) await d.delete(recursive: true);
    await d.create(recursive: true);
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
