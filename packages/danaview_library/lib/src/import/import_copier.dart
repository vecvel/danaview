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
// A cancel is cooperative: the worker checks for it between chunks, closes its files and only then
// answers, because a killed isolate keeps its files open on Windows (the part could then be neither
// renamed nor deleted). Nothing here logs a name or a path (rule 30).

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
  /// deletes it or keeps it to resume), and it is closed by the time the returned future completes,
  /// so the caller may rename or delete it at once (Windows refuses both on an open file).
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
  /// A copier that checkpoints every [checkpointBytes] (fsync, then `bytes_done`). A cancel waits
  /// up to [cancelGrace] for the worker to close its files before the worker is killed.
  const FileImportCopier({this.checkpointBytes = 16 * 1024 * 1024, this.cancelGrace = const Duration(seconds: 5)});

  /// Bytes between checkpoints.
  final int checkpointBytes;

  /// How long a cancel waits for the copy to stop on its own.
  final Duration cancelGrace;

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
        cancelGrace,
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

// The worker protocol. Worker → parent: `('ctl', SendPort)` first (where a cancel goes), then
// `('p', bytes)` / `('c', bytes)`, and one final `('done', bytes, sha)` or `('err', code, detail)`
// sent only after the worker closed both of its files. Parent → worker: `'cancel'`, read between
// chunks. The parent kills the isolate only when a cancel isn't answered within the grace period.

final class _IsolateCopyRun implements ImportCopyRun {
  _IsolateCopyRun._(this._port, this._cancelGrace);

  final ReceivePort _port;
  final Duration _cancelGrace;
  final Completer<CopyOutcome> _done = Completer<CopyOutcome>();
  Isolate? _isolate;
  SendPort? _control;
  bool _cancelled = false;

  static _IsolateCopyRun spawn(_CopyArgs args, Duration cancelGrace, void Function(int) onProgress, void Function(int) onCheckpoint) {
    final run = _IsolateCopyRun._(ReceivePort(), cancelGrace);
    run._port.listen((Object? message) {
      switch (message) {
        case ('ctl', final SendPort control):
          run._control = control;
          if (run._cancelled) control.send('cancel');
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
          run._fail(const ImportException(ImportFailure.ioError, 'copy worker exited'));
      }
    });
    Isolate.spawn(_copyMain, (run._port.sendPort, args), onExit: run._port.sendPort, onError: run._port.sendPort, debugName: 'library-import-copy')
        .then((isolate) => run._isolate = isolate, onError: (Object _) => run._fail(const ImportException(ImportFailure.ioError, 'copy worker did not start')));
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

  /// Asks the worker to stop and waits until it closed the part (its final message). Killing an
  /// isolate doesn't close its files promptly on Windows, so the part would stay locked against
  /// the rename or delete that follows; the kill is only the fallback after [_cancelGrace].
  @override
  Future<void> cancel() async {
    if (_done.isCompleted) return;
    _cancelled = true;
    _control?.send('cancel'); // else sent when the worker's control port arrives
    final settled = _done.future.then<void>((_) {}, onError: (Object _) {});
    try {
      await settled.timeout(_cancelGrace);
    } on TimeoutException {
      // Stuck in a read (a slow or gone volume): the kill releases what the OS lets go.
      _isolate?.kill(priority: Isolate.immediate);
      _fail(const ImportException(ImportFailure.cancelled));
    }
  }
}

Future<void> _copyMain((SendPort, _CopyArgs) message) async {
  final (reply, args) = message;
  final copy = _Copy(args, reply);
  final control = ReceivePort();
  control.listen((Object? m) {
    if (m == 'cancel') copy.cancelled = true;
  });
  reply.send(('ctl', control.sendPort));
  Object last;
  try {
    last = await copy.run();
  } on FileSystemException catch (e) {
    last = ('err', ImportFailure.ioError.name, 'errno ${e.osError?.errorCode ?? -1}');
  } finally {
    copy.close();
    control.close();
  }
  // Only now, with both files closed, may the parent rename or delete the part.
  reply.send(last);
}

/// One copy on the worker isolate. Reads and writes are synchronous; the loop yields to the event
/// loop after every chunk so a cancel message is seen.
final class _Copy {
  _Copy(this.args, this.reply);

  final _CopyArgs args;
  final SendPort reply;
  bool cancelled = false;
  RandomAccessFile? _src;
  RandomAccessFile? _part;
  RandomAccessFile? _prefix;

  static const Object _cancelledMessage = ('err', 'cancelled', 'cancelled');

  /// Lets a pending cancel message in; true when the copy should stop.
  Future<bool> _stop() async {
    await Future<void>.delayed(Duration.zero);
    return cancelled;
  }

  Future<Object> run() async {
    if (await _stop()) return _cancelledMessage;
    final RandomAccessFile src;
    try {
      src = _src = File(args.source).openSync(mode: FileMode.read);
    } on FileSystemException {
      return ('err', ImportFailure.sourceUnreadable.name, 'open failed');
    }
    final size = src.lengthSync();
    final partFile = File(args.part);
    var offset = args.resumeFrom;
    if (offset > 0) {
      final have = partFile.existsSync() ? partFile.lengthSync() : 0;
      if (have < offset) offset = have;
      if (offset > size) offset = 0;
    }
    final part = _part = partFile.openSync(mode: offset > 0 ? FileMode.append : FileMode.write);
    if (offset > 0) {
      part.truncateSync(offset);
      part.setPositionSync(offset);
    }
    final digestOut = _DigestSink();
    final hashSink = args.hash ? sha256.startChunkedConversion(digestOut) : null;
    final buffer = Uint8List(importCopyChunkBytes);
    if (hashSink != null && offset > 0) {
      // Re-hash the prefix an earlier run copied (read-only, from the part).
      final prefix = _prefix = partFile.openSync();
      var left = offset;
      while (left > 0) {
        final n = prefix.readIntoSync(buffer, 0, left < buffer.length ? left : buffer.length);
        if (n <= 0) break;
        hashSink.add(Uint8List.sublistView(buffer, 0, n));
        left -= n;
        if (await _stop()) return _cancelledMessage;
      }
      _prefix = null;
      prefix.closeSync();
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
      if (await _stop()) {
        // Stopped where it is: what was written stays for a resume (bytes_done never runs ahead
        // of the last checkpoint).
        return _cancelledMessage;
      }
    }
    part.flushSync();
    if (src.lengthSync() != size || done != size) {
      return ('err', ImportFailure.sourceChanged.name, 'size changed during copy');
    }
    hashSink?.close();
    reply.send(('c', done));
    return ('done', done, hashSink == null ? null : digestOut.value.toString());
  }

  /// Closes every file the copy opened (each at most once).
  void close() {
    for (final f in [_prefix, _src, _part]) {
      try {
        f?.closeSync();
      } on FileSystemException {
        // A read-only handle can't lose data; the part is resumed or deleted by the service.
      }
    }
    _prefix = _src = _part = null;
  }
}
