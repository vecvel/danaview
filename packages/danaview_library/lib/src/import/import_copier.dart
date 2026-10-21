// OWNER: HOM-20
//
// The byte copy of an import (ARCH v1.2 §5.6, rule 27): an [ImportCopier] streams one source into
// the job's `imports/<jobId>.part`, appending from an offset when an interrupted job resumes, and
// reports progress and durable checkpoints (the part is fsynced before a checkpoint, so
// `import_jobs.bytes_done` never runs ahead of the bytes on disk). [FileImportCopier] copies local
// files on a worker isolate with one fixed 1 MiB buffer (memory stays flat for a 2 GB video) and
// opens the source read-only; the native copier for content URIs and security-scoped URLs lives
// with the plugin wrapper in danaview_features (this package stays free of Flutter, rule 20).
// SHA-256 is streamed during the copy only when the library already holds a file of the same size
// (the only case a content duplicate is possible); the quick hash is read from the finished part.
// Nothing here logs a name or a path (rule 30).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'import_source.dart';

/// Bytes read from each end of a file for [computeQuickHash] (the v1.1 `quickHash`, CORE-04).
const int quickHashChunkBytes = 64 * 1024;

/// The copy buffer.
const int importCopyChunkBytes = 1024 * 1024;

/// Why an import item failed.
enum ImportFailure {
  /// The source can't be opened or read (gone, permission revoked after a relaunch).
  sourceUnreadable,

  /// The source changed size while it was copied.
  sourceChanged,

  /// No copier handles the source kind on this platform.
  unsupportedSource,

  /// The user cancelled.
  cancelled,

  /// The library refused the write (read-only library, invalid name, trashed folder).
  refused,

  /// A file system error while writing the part.
  ioError,
}

/// A failed copy or import step. The message never holds a name or a path (rule 30).
final class ImportException implements Exception {
  /// A failure of [failure].
  const ImportException(this.failure, [this.detail = '']);

  /// Why.
  final ImportFailure failure;

  /// Debug text without names or paths.
  final String detail;

  @override
  String toString() => 'ImportException(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// What a stat of the source found.
final class SourceStat {
  /// A stat.
  const SourceStat({required this.size, this.modifiedAt});

  /// Size in bytes, or -1 when the platform can't tell before the copy.
  final int size;

  /// Modification time, when known.
  final DateTime? modifiedAt;
}

/// What a finished copy produced.
final class CopyOutcome {
  /// An outcome.
  const CopyOutcome({required this.bytes, this.sha256});

  /// Bytes in the part file.
  final int bytes;

  /// The SHA-256 of the part (hex) when hashing was asked for, else null.
  final String? sha256;
}

/// A running copy.
abstract interface class ImportCopyRun {
  /// Completes with the outcome, or fails with an [ImportException].
  Future<CopyOutcome> get done;

  /// Stops the copy; [done] then fails with [ImportFailure.cancelled]. The part stays (the caller
  /// deletes it or keeps it to resume).
  Future<void> cancel();
}

/// Copies sources of the kinds it [handles] into part files.
abstract interface class ImportCopier {
  /// True when this copier can read [source].
  bool handles(ImportSource source);

  /// Size and time of [source]; throws [ImportException] ([ImportFailure.sourceUnreadable]).
  Future<SourceStat> stat(ImportSource source);

  /// Starts copying [source] into [partPath] from byte [resumeFrom] (the part is truncated to it
  /// first; 0 starts fresh). [onProgress] fires as bytes arrive, [onCheckpoint] after the part was
  /// flushed to disk up to that many bytes. [hash] streams a SHA-256 over the whole part.
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  });
}

/// `sha1(head + tail + utf8(':$size'))`, byte for byte the v1.1 quick hash (danaview_data
/// `MediaIdentityService.computeQuickHash`, editor core `computeQuickHash`): `head` is the first
/// `min(size, 64 KiB)` bytes, `tail` the last 64 KiB only when `size > 64 KiB`. Empty → `''`.
String computeQuickHash(Uint8List head, Uint8List tail, int size) {
  if (size == 0) return '';
  final b = BytesBuilder(copy: false)
    ..add(head)
    ..add(size > quickHashChunkBytes ? tail : Uint8List(0))
    ..add(utf8.encode(':$size'));
  return sha1.convert(b.takeBytes()).toString();
}

/// The quick hash of the file at [path] (read-only).
Future<String> quickHashOfFile(String path) async {
  final raf = await File(path).open();
  try {
    final size = await raf.length();
    final head = await raf.read(size < quickHashChunkBytes ? size : quickHashChunkBytes);
    var tail = Uint8List(0);
    if (size > quickHashChunkBytes) {
      await raf.setPosition(size - quickHashChunkBytes);
      tail = await raf.read(quickHashChunkBytes);
    }
    return computeQuickHash(head, tail, size);
  } finally {
    await raf.close();
  }
}

/// The SHA-256 (hex) of the file at [path], read read-only on a worker isolate.
Future<String> sha256OfFile(String path) => Isolate.run(() {
      final raf = File(path).openSync();
      try {
        final out = _DigestSink();
        final sink = sha256.startChunkedConversion(out);
        final buffer = Uint8List(importCopyChunkBytes);
        while (true) {
          final n = raf.readIntoSync(buffer);
          if (n <= 0) break;
          sink.add(Uint8List.sublistView(buffer, 0, n));
        }
        sink.close();
        return out.value.toString();
      } finally {
        raf.closeSync();
      }
    });

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Copies local files ([ImportSourceKind.file]) on a worker isolate: the source is
/// opened read-only, the part is appended to with one reused buffer, fsynced at every checkpoint
/// and at the end.
final class FileImportCopier implements ImportCopier {
  /// A copier that checkpoints every [checkpointBytes] (fsync, then `bytes_done`).
  const FileImportCopier({this.checkpointBytes = 16 * 1024 * 1024});

  /// Bytes between checkpoints.
  final int checkpointBytes;

  @override
  bool handles(ImportSource source) => source.kind == ImportSourceKind.file;

  @override
  Future<SourceStat> stat(ImportSource source) async {
    final file = File(source.location);
    final FileStat s;
    try {
      s = await file.stat();
    } on FileSystemException {
      throw const ImportException(ImportFailure.sourceUnreadable, 'stat failed');
    }
    if (s.type != FileSystemEntityType.file) throw const ImportException(ImportFailure.sourceUnreadable, 'not a file');
    // Readability: open read-only and close at once (never for writing, rule 27).
    try {
      (await file.open()).closeSync();
    } on FileSystemException {
      throw const ImportException(ImportFailure.sourceUnreadable, 'open failed');
    }
    return SourceStat(size: s.size, modifiedAt: s.modified.toUtc());
  }

  @override
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  }) =>
      _IsolateCopyRun.spawn(
        _CopyArgs(source.location, partPath, resumeFrom < 0 ? 0 : resumeFrom, hash, checkpointBytes),
        onProgress,
        onCheckpoint,
      );
}

final class _CopyArgs {
  const _CopyArgs(this.source, this.part, this.resumeFrom, this.hash, this.checkpointBytes);

  final String source;
  final String part;
  final int resumeFrom;
  final bool hash;
  final int checkpointBytes;
}

final class _IsolateCopyRun implements ImportCopyRun {
  _IsolateCopyRun._(this._port);

  final ReceivePort _port;
  final Completer<CopyOutcome> _done = Completer<CopyOutcome>();
  Isolate? _isolate;
  bool _cancelled = false;

  static _IsolateCopyRun spawn(_CopyArgs args, void Function(int) onProgress, void Function(int) onCheckpoint) {
    final run = _IsolateCopyRun._(ReceivePort());
    run._port.listen((Object? message) {
      switch (message) {
        case ('p', final int bytes):
          onProgress(bytes);
        case ('c', final int bytes):
          onCheckpoint(bytes);
        case ('done', final int bytes, final String? sha):
          run._finish(CopyOutcome(bytes: bytes, sha256: sha));
        case ('err', final String code, final String detail):
          run._fail(ImportException(ImportFailure.values.byName(code), detail));
        case null:
          // The isolate exited (or was killed) without an answer.
          run._fail(ImportException(run._cancelled ? ImportFailure.cancelled : ImportFailure.ioError, 'copy worker exited'));
      }
    });
    Isolate.spawn(_copyMain, (run._port.sendPort, args), onExit: run._port.sendPort, onError: run._port.sendPort, debugName: 'library-import-copy')
        .then((isolate) {
      run._isolate = isolate;
      if (run._cancelled) isolate.kill(priority: Isolate.immediate);
    }, onError: (Object _) => run._fail(const ImportException(ImportFailure.ioError, 'copy worker did not start')));
    return run;
  }

  void _finish(CopyOutcome outcome) {
    if (_done.isCompleted) return;
    _done.complete(_cancelled ? Future<CopyOutcome>.error(const ImportException(ImportFailure.cancelled)) : outcome);
    _port.close();
  }

  void _fail(ImportException e) {
    if (_done.isCompleted) return;
    _done.completeError(_cancelled ? const ImportException(ImportFailure.cancelled) : e);
    _port.close();
  }

  @override
  Future<CopyOutcome> get done => _done.future;

  @override
  Future<void> cancel() async {
    if (_done.isCompleted) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    if (_isolate == null) return;
    await _done.future.then<void>((_) {}, onError: (Object _) {});
  }
}

void _copyMain((SendPort, _CopyArgs) message) {
  final (reply, args) = message;
  RandomAccessFile? src;
  RandomAccessFile? part;
  try {
    try {
      src = File(args.source).openSync(mode: FileMode.read);
    } on FileSystemException {
      reply.send(('err', ImportFailure.sourceUnreadable.name, 'open failed'));
      return;
    }
    final size = src.lengthSync();
    final partFile = File(args.part);
    var offset = args.resumeFrom;
    if (offset > 0) {
      final have = partFile.existsSync() ? partFile.lengthSync() : 0;
      if (have < offset) offset = have;
      if (offset > size) offset = 0;
    }
    part = partFile.openSync(mode: offset > 0 ? FileMode.append : FileMode.write);
    if (offset > 0) {
      part.truncateSync(offset);
      part.setPositionSync(offset);
    }
    final digestOut = _DigestSink();
    final hashSink = args.hash ? sha256.startChunkedConversion(digestOut) : null;
    final buffer = Uint8List(importCopyChunkBytes);
    if (hashSink != null && offset > 0) {
      // Re-hash the prefix an earlier run copied (read-only, from the part).
      final prefix = partFile.openSync();
      try {
        var left = offset;
        while (left > 0) {
          final n = prefix.readIntoSync(buffer, 0, left < buffer.length ? left : buffer.length);
          if (n <= 0) break;
          hashSink.add(Uint8List.sublistView(buffer, 0, n));
          left -= n;
        }
      } finally {
        prefix.closeSync();
      }
    }
    src.setPositionSync(offset);
    var done = offset;
    var sinceCheckpoint = 0;
    while (true) {
      final n = src.readIntoSync(buffer);
      if (n <= 0) break;
      part.writeFromSync(buffer, 0, n);
      hashSink?.add(Uint8List.sublistView(buffer, 0, n));
      done += n;
      sinceCheckpoint += n;
      reply.send(('p', done));
      if (sinceCheckpoint >= args.checkpointBytes) {
        part.flushSync();
        sinceCheckpoint = 0;
        reply.send(('c', done));
      }
    }
    part.flushSync();
    if (src.lengthSync() != size || done != size) {
      reply.send(('err', ImportFailure.sourceChanged.name, 'size changed during copy'));
      return;
    }
    hashSink?.close();
    reply.send(('c', done));
    reply.send(('done', done, hashSink == null ? null : digestOut.value.toString()));
  } on FileSystemException catch (e) {
    reply.send(('err', ImportFailure.ioError.name, 'errno ${e.osError?.errorCode ?? -1}'));
  } finally {
    try {
      src?.closeSync();
    } on FileSystemException {
      // Closing a read-only handle can't lose data.
    }
    try {
      part?.closeSync();
    } on FileSystemException {
      // The part is resumed or deleted by the service.
    }
  }
}
