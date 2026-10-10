// OWNER: CORE-24
//
// Crash-safe document writes (ARCH §8.3).
//
// `AtomicFile.write(path, bytes)`:
//   1. write `path.tmp-<rand>` and fsync it (`StoreFs.writeBytesSynced`);
//   2. rename `path` -> `path.bak` (when a main file exists);
//   3. rename `path.tmp-<rand>` -> `path`;
//   4. best effort: remove stale `path.tmp-*` leftovers of earlier crashes (through the
//      `OwnedFileDeleter`, the only delete path).
//
// Every state a crash can leave behind keeps at least one complete document, because the
// temporary file is complete and synced before anything is renamed:
//
//   crash during 1  -> `path` (old) is untouched; the torn tmp fails its checksum;
//   crash after 1   -> `path` (old) is untouched; a complete newer tmp exists;
//   crash after 2   -> `path` is missing; `.bak` is the old document; the tmp is the new one;
//   crash after 3   -> `path` is the new document; `.bak` the old one.
//
// `AtomicFile.read(path, isValid:)` returns `path` when `isValid` accepts it, else the newest valid
// of the `tmp-*` files and `.bak` (by modification time; on a tie the tmp wins because it is the
// later write), else throws `StoreFailure(corrupt)` (or `notFound` when no candidate exists). It
// never writes: promoting a recovered copy is the caller's decision (the repository, CORE-25).
// What "valid" means is the caller's: for `.vwproj` it is `VwprojFormat.isValid` (length and
// SHA-256 of the body).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'owned_file_deleter.dart';
import 'store_fs.dart';

/// Which copy of a document [AtomicFile.read] returned.
enum AtomicSource {
  /// `path` itself.
  main,

  /// A complete `path.tmp-*` file (a write whose last rename did not happen).
  temp,

  /// `path.bak` (the previous document).
  backup,
}

/// A valid copy returned by [AtomicFile.read].
@immutable
final class AtomicRead {
  /// Creates a read result.
  const AtomicRead(this.bytes, this.source, this.path);

  /// The document bytes.
  final Uint8List bytes;

  /// Which copy this is.
  final AtomicSource source;

  /// The file the bytes were read from.
  final String path;
}

/// Atomic, checksum-aware reads and writes of one document path (see the file header).
final class AtomicFile {
  /// Creates the helper. Pass [deleter] in production so stale temporary files are removed; without
  /// one nothing is ever deleted (leftovers are harmless: reads prefer valid copies by age).
  AtomicFile({StoreFs fs = const LocalStoreFs(), this.deleter, math.Random? random})
      : _fs = fs,
        _random = random ?? math.Random();

  final StoreFs _fs;
  final math.Random _random;

  /// Removes temporary files; null disables cleanup.
  final OwnedFileDeleter? deleter;

  /// `<path>.bak`.
  static String backupPath(String path) => '$path.bak';

  /// The common prefix of temporary files of [path]: `<path>.tmp-`.
  static String tempPrefix(String path) => '$path.tmp-';

  /// Atomically replaces the document at [path] with [bytes].
  ///
  /// Throws [StoreFailure] (disk full, permission, I/O). A failed write leaves the previous document
  /// readable: the new bytes are never written over it.
  Future<void> write(String path, Uint8List bytes) async {
    final dir = p.dirname(path);
    if (!(await _fs.stat(dir)).exists) await _fs.createDirectory(dir);
    final tmp = '${tempPrefix(path)}${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
    try {
      await _fs.writeBytesSynced(tmp, bytes);
    } on SimulatedCrash {
      rethrow; // a dead process cleans nothing up
    } on Object {
      await _discard(tmp);
      rethrow;
    }
    final hadMain = (await _fs.stat(path)).type == StoreEntityType.file;
    if (hadMain) {
      try {
        await _fs.rename(path, backupPath(path));
      } on SimulatedCrash {
        rethrow;
      } on Object {
        await _discard(tmp);
        rethrow;
      }
    }
    try {
      await _fs.rename(tmp, path);
    } on SimulatedCrash {
      rethrow;
    } on Object {
      // Put the old document back (best effort; after a crash nothing can run, and the reader finds
      // the complete tmp or the .bak).
      if (hadMain) await _quietly(() => _fs.rename(backupPath(path), path));
      await _discard(tmp);
      rethrow;
    }
    await removeStaleTemps(path);
  }

  /// Reads the best valid copy of [path] (see the file header). Throws [StoreFailure] `notFound`
  /// when there is no candidate file at all and `corrupt` when candidates exist but none is valid.
  Future<AtomicRead> read(String path, {required bool Function(Uint8List bytes) isValid}) async {
    var sawAny = false;

    Future<AtomicRead?> tryFile(String candidate, AtomicSource source) async {
      final Uint8List bytes;
      try {
        bytes = await _fs.readBytes(candidate);
      } on StoreFailure catch (e) {
        if (e.kind == StoreFailureKind.notFound) return null;
        rethrow;
      }
      sawAny = true;
      return isValid(bytes) ? AtomicRead(bytes, source, candidate) : null;
    }

    final main = await tryFile(path, AtomicSource.main);
    if (main != null) return main;

    final fallbacks = <({String path, AtomicSource source, DateTime modified, int order})>[];
    for (final tmp in await tempFiles(path)) {
      final s = await _fs.stat(tmp);
      if (s.type == StoreEntityType.file) {
        fallbacks.add((path: tmp, source: AtomicSource.temp, modified: s.modified ?? DateTime.fromMillisecondsSinceEpoch(0), order: 0));
      }
    }
    final bak = await _fs.stat(backupPath(path));
    if (bak.type == StoreEntityType.file) {
      fallbacks.add((path: backupPath(path), source: AtomicSource.backup, modified: bak.modified ?? DateTime.fromMillisecondsSinceEpoch(0), order: 1));
    }
    fallbacks.sort((a, b) {
      final byTime = b.modified.compareTo(a.modified);
      if (byTime != 0) return byTime;
      final byKind = a.order.compareTo(b.order);
      return byKind != 0 ? byKind : a.path.compareTo(b.path);
    });
    for (final c in fallbacks) {
      final r = await tryFile(c.path, c.source);
      if (r != null) return r;
    }
    if (!sawAny && (await _fs.stat(path)).type == StoreEntityType.notFound && fallbacks.isEmpty) {
      throw const StoreFailure(StoreFailureKind.notFound, 'document');
    }
    throw const StoreFailure(StoreFailureKind.corrupt, 'no valid copy');
  }

  /// The `path.tmp-*` files next to [path] (absolute paths, unsorted).
  Future<List<String>> tempFiles(String path) async {
    final dir = p.dirname(path);
    final prefix = '${p.basename(path)}.tmp-';
    final StoreStat s = await _fs.stat(dir);
    if (s.type != StoreEntityType.directory) return const [];
    final entries = await _fs.list(dir);
    return [
      for (final e in entries)
        if (p.basename(e.path).startsWith(prefix)) e.path,
    ];
  }

  /// Removes `path.tmp-*` leftovers (through the [deleter]; a no-op without one). Call only when
  /// [path] holds a valid document.
  Future<void> removeStaleTemps(String path) async {
    final d = deleter;
    if (d == null) return;
    try {
      for (final tmp in await tempFiles(path)) {
        await _quietly(() => d.delete(tmp));
      }
    } on SimulatedCrash {
      rethrow;
    } on Object {
      // Cleanup never fails a completed save.
    }
  }

  Future<void> _discard(String tmp) async {
    final d = deleter;
    if (d != null) await _quietly(() => d.delete(tmp));
  }

  Future<void> _quietly(Future<void> Function() body) async {
    try {
      await body();
    } on SimulatedCrash {
      rethrow;
    } on Object {
      // Best effort.
    }
  }
}
