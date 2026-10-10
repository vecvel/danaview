// OWNER: CORE-24
//
// The store filesystem abstraction (ARCH §8.3): every filesystem call of the editor's persistence
// layer goes through [StoreFs]. [LocalStoreFs] is the `dart:io` implementation; [FaultInjectingFs]
// wraps any [StoreFs] to crash the process model after step N (leaving a torn write), or to fail a
// step with a disk-full or permission error, so tests can prove that a valid document survives
// every crash point (AtomicFile, CORE-24).
//
// V-D1 (does `RandomAccessFile.flush()` fsync?). [LocalStoreFs.writeBytesSynced] ends with
// `RandomAccessFile.flush()`. The public contract (dart-sdk/lib/io/file.dart in the Flutter 3.44
// SDK) is "Flushes the contents of the file to disk". The VM implements it in the native
// `File::Flush` (runtime/bin/file_posix.cc, not shipped with the SDK distribution, so it could not
// be re-read in this repository) as `fsync(2)` on the descriptor on every POSIX platform the editor
// ships on (iOS, Android/Linux, macOS). Treat that as confirmed by documentation and by the VM
// source from memory, to be confirmed on a device by QA-10 (kill -9 and battery-pull during
// autosave). Two caveats are designed around, not relied upon: (1) on Apple platforms `fsync`
// hands the data to the drive but does not force the drive's write cache (that needs
// `fcntl(F_FULLFSYNC)`, which Dart does not expose); (2) Dart cannot fsync the containing
// directory, so a `rename` can be lost on power failure even though the file data is durable (the
// reader then finds the previous document or the complete `tmp-*` file). The checksummed
// two-line format plus the `tmp-*`/`.bak` fallbacks make both harmless.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Kinds of persistence failure (ARCH §19).
enum StoreFailureKind {
  /// Not enough free space.
  diskFull,

  /// The OS refused access.
  permissionDenied,

  /// The file or project does not exist.
  notFound,

  /// No valid copy could be read (checksum mismatch everywhere).
  corrupt,

  /// Written by a newer app whose `minReader` is above this app's schema (D-12).
  newerSchema,

  /// The project is already open in this process.
  busy,

  /// Any other I/O error.
  io,
}

/// A typed persistence failure. [debugDetail] never contains paths or user content.
@immutable
final class StoreFailure implements Exception {
  /// Creates a failure.
  const StoreFailure(this.kind, [this.debugDetail = '']);

  /// Kind.
  final StoreFailureKind kind;

  /// Diagnostic text without paths.
  final String debugDetail;

  @override
  bool operator ==(Object other) => other is StoreFailure && other.kind == kind && other.debugDetail == debugDetail;

  @override
  int get hashCode => Object.hash(kind, debugDetail);

  @override
  String toString() => 'StoreFailure(${kind.name}${debugDetail.isEmpty ? '' : ': $debugDetail'})';
}

/// What a path is (without following a final symbolic link).
enum StoreEntityType {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link (target not followed).
  link,

  /// Nothing exists at the path.
  notFound,
}

/// `lstat` result.
@immutable
final class StoreStat {
  /// Creates a stat.
  const StoreStat(this.type, {this.size = 0, this.modified});

  /// Nothing there.
  static const StoreStat missing = StoreStat(StoreEntityType.notFound);

  /// Entity type.
  final StoreEntityType type;

  /// Size in bytes (files).
  final int size;

  /// Last modification time, when known.
  final DateTime? modified;

  /// Whether anything exists.
  bool get exists => type != StoreEntityType.notFound;
}

/// One child of a directory listing.
@immutable
final class StoreEntry {
  /// Creates an entry.
  const StoreEntry(this.path, this.type);

  /// Absolute path of the child.
  final String path;

  /// Its type (links are reported as [StoreEntityType.link]).
  final StoreEntityType type;
}

/// Every filesystem operation the persistence layer performs. Paths are absolute. Failures are
/// reported as [StoreFailure]; a missing source is `notFound`.
///
/// There is deliberately no public "delete anything" convenience for callers: [delete] is the
/// primitive behind `OwnedFileDeleter`, which is the only code allowed to call it with a path that
/// did not originate in the same store operation (ARCH §9.6).
abstract interface class StoreFs {
  /// Reads a whole file.
  Future<Uint8List> readBytes(String path);

  /// Reads at most [maxBytes] from the start of a file (header-only reads).
  Future<Uint8List> readPrefix(String path, int maxBytes);

  /// Creates or truncates [path], writes [bytes] and flushes them to disk (fsync, V-D1). The
  /// parent directory must exist.
  Future<void> writeBytesSynced(String path, Uint8List bytes);

  /// Copies [from] to [to] (created or truncated), flushing at the end. Used for managed copies
  /// written under a temporary name before an atomic rename.
  Future<void> copyFile(String from, String to);

  /// Copies [from] to [to] only if nothing exists at [to] (`O_CREAT | O_EXCL` semantics: a symbolic
  /// link at [to], even a dangling one, counts as existing). Returns false, without touching
  /// anything, when [to] exists. A partially written target is removed when the copy fails.
  Future<bool> copyExclusive(String from, String to);

  /// Atomically renames a file or directory, replacing an existing file at [to].
  Future<void> rename(String from, String to);

  /// Deletes a file, a link (never its target) or, with [recursive], a directory tree (links inside
  /// the tree are removed, not followed). A missing path is not an error.
  Future<void> delete(String path, {bool recursive = false});

  /// Creates [path] and any missing parents.
  Future<void> createDirectory(String path);

  /// `lstat`: never throws for a missing path.
  Future<StoreStat> stat(String path);

  /// The children of [directory] (not recursive, not sorted). Throws `notFound` when missing.
  Future<List<StoreEntry>> list(String directory);

  /// Normalizes [path] and resolves every symbolic link in its longest existing prefix; the
  /// components after that prefix (which do not exist yet) are appended unchanged. Lets the guards
  /// compare paths that may not exist.
  Future<String> canonicalize(String path);
}

/// The `dart:io` implementation of [StoreFs].
final class LocalStoreFs implements StoreFs {
  /// Creates the filesystem.
  const LocalStoreFs();

  @override
  Future<Uint8List> readBytes(String path) => _guard(() => File(path).readAsBytes());

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) => _guard(() async {
        final file = await File(path).open();
        try {
          final length = await file.length();
          return await file.read(math.min(length, maxBytes));
        } finally {
          await file.close();
        }
      });

  @override
  Future<void> writeBytesSynced(String path, Uint8List bytes) => _guard(() async {
        final file = await File(path).open(mode: FileMode.write);
        try {
          await file.writeFrom(bytes);
          await file.flush();
        } finally {
          await file.close();
        }
      });

  @override
  Future<void> copyFile(String from, String to) => _guard(() async {
        final out = await File(to).open(mode: FileMode.write);
        try {
          await _pump(from, out);
          await out.flush();
        } finally {
          await out.close();
        }
      });

  @override
  Future<bool> copyExclusive(String from, String to) async {
    try {
      await File(to).create(exclusive: true);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == _eexist) return false;
      throw storeFailureOf(e);
    }
    try {
      final out = await File(to).open(mode: FileMode.write);
      try {
        await _pump(from, out);
        await out.flush();
      } finally {
        await out.close();
      }
      return true;
    } on Object catch (e) {
      // The partial file is ours: it was created exclusively a moment ago by this call.
      try {
        await File(to).delete();
      } on Object {
        // Best effort.
      }
      throw storeFailureOf(e);
    }
  }

  @override
  Future<void> rename(String from, String to) => _guard(() async {
        final type = await FileSystemEntity.type(from, followLinks: false);
        switch (type) {
          case FileSystemEntityType.directory:
            await Directory(from).rename(to);
          case FileSystemEntityType.link:
            await Link(from).rename(to);
          case FileSystemEntityType.notFound:
            throw const StoreFailure(StoreFailureKind.notFound, 'rename source');
          default:
            await File(from).rename(to);
        }
      });

  @override
  Future<void> delete(String path, {bool recursive = false}) => _guard(() async {
        switch (await FileSystemEntity.type(path, followLinks: false)) {
          case FileSystemEntityType.notFound:
            return;
          case FileSystemEntityType.link:
            await Link(path).delete();
          case FileSystemEntityType.directory:
            await Directory(path).delete(recursive: recursive);
          default:
            await File(path).delete();
        }
      });

  @override
  Future<void> createDirectory(String path) => _guard(() async {
        await Directory(path).create(recursive: true);
      });

  @override
  Future<StoreStat> stat(String path) => _guard(() async {
        final s = await FileStat.stat(path);
        // FileStat follows links; ask for the unfollowed type first.
        final type = switch (await FileSystemEntity.type(path, followLinks: false)) {
          FileSystemEntityType.file => StoreEntityType.file,
          FileSystemEntityType.directory => StoreEntityType.directory,
          FileSystemEntityType.link => StoreEntityType.link,
          FileSystemEntityType.pipe || FileSystemEntityType.unixDomainSock => StoreEntityType.file,
          _ => StoreEntityType.notFound,
        };
        if (type == StoreEntityType.notFound) return StoreStat.missing;
        return StoreStat(type, size: s.size < 0 ? 0 : s.size, modified: s.modified);
      });

  @override
  Future<List<StoreEntry>> list(String directory) => _guard(() async {
        final out = <StoreEntry>[];
        await for (final e in Directory(directory).list(followLinks: false)) {
          out.add(StoreEntry(
            e.path,
            e is Link
                ? StoreEntityType.link
                : e is Directory
                    ? StoreEntityType.directory
                    : StoreEntityType.file,
          ));
        }
        return out;
      });

  @override
  Future<String> canonicalize(String path) async {
    var pending = p.normalize(p.absolute(path));
    for (var hops = 0; hops < _maxLinkHops; hops++) {
      var current = pending;
      final rest = <String>[];
      while (true) {
        try {
          final resolved = await Directory(current).resolveSymbolicLinks();
          return rest.isEmpty ? resolved : p.joinAll([resolved, ...rest.reversed]);
        } on FileSystemException {
          if (await FileSystemEntity.type(current, followLinks: false) == FileSystemEntityType.link) {
            // A dangling (or looping) link: follow it by hand so the result says where it points.
            final target = await Link(current).target();
            final base = p.isAbsolute(target) ? target : p.join(p.dirname(current), target);
            pending = p.normalize(p.joinAll([base, ...rest.reversed]));
            break;
          }
          final parent = p.dirname(current);
          if (parent == current) return rest.isEmpty ? current : p.joinAll([current, ...rest.reversed]);
          rest.add(p.basename(current));
          current = parent;
        }
      }
    }
    throw const StoreFailure(StoreFailureKind.io, 'too many symbolic links');
  }

  static const int _maxLinkHops = 40;

  static const int _bufferBytes = 1 << 20;

  Future<void> _pump(String from, RandomAccessFile out) async {
    final input = await File(from).open();
    try {
      while (true) {
        final chunk = await input.read(_bufferBytes);
        if (chunk.isEmpty) break;
        await out.writeFrom(chunk);
      }
    } finally {
      await input.close();
    }
  }

  static const int _eexist = 17;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (e) {
      throw storeFailureOf(e);
    }
  }
}

/// Maps an I/O error to a [StoreFailure] (already-typed failures pass through). Platform error
/// numbers: ENOENT 2, EPERM 1, EACCES 13, EROFS 30, ENOSPC 28, EDQUOT 122 (Linux/Android) or 69
/// (Darwin), EFBIG 27.
StoreFailure storeFailureOf(Object error) {
  if (error is StoreFailure) return error;
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    final kind = switch (code) {
      2 => StoreFailureKind.notFound,
      1 || 13 || 30 => StoreFailureKind.permissionDenied,
      28 || 27 || 69 || 122 => StoreFailureKind.diskFull,
      _ => StoreFailureKind.io,
    };
    final message = error.message.toLowerCase();
    if (kind == StoreFailureKind.io && message.contains('no space')) return const StoreFailure(StoreFailureKind.diskFull);
    if (kind == StoreFailureKind.io && message.contains('not found')) return const StoreFailure(StoreFailureKind.notFound);
    return StoreFailure(kind, code == null ? 'io' : 'errno $code');
  }
  return StoreFailure(StoreFailureKind.io, error.runtimeType.toString());
}

/// What a [FaultInjectingFs] step is.
enum FsOpKind {
  /// [StoreFs.writeBytesSynced].
  write,

  /// [StoreFs.copyFile].
  copy,

  /// [StoreFs.copyExclusive].
  copyExclusive,

  /// [StoreFs.rename].
  rename,

  /// [StoreFs.delete].
  delete,

  /// [StoreFs.createDirectory].
  createDirectory,
}

/// One mutating step seen by a [FaultInjectingFs].
@immutable
final class FsOp {
  /// Creates a step record.
  const FsOp(this.index, this.kind, this.path, [this.path2]);

  /// 1-based position among the mutating steps since the last [FaultInjectingFs.reset].
  final int index;

  /// Kind.
  final FsOpKind kind;

  /// First path (target of writes and deletes, source of renames and copies).
  final String path;

  /// Second path (destination of renames and copies).
  final String? path2;

  @override
  String toString() => '#$index ${kind.name} ${p.basename(path)}${path2 == null ? '' : ' -> ${p.basename(path2!)}'}';
}

/// What the step that crashes leaves behind when it is a write or copy.
enum TornWrite {
  /// Nothing: the step did not happen.
  none,

  /// An empty file (created but no data reached the disk).
  empty,

  /// The first half of the data.
  half,

  /// All the data but without the follow-up (the step happened, the process died right after it).
  complete,
}

/// The process died; thrown by the crashing step and by every call until [FaultInjectingFs.restart].
final class SimulatedCrash implements Exception {
  /// Creates the crash.
  const SimulatedCrash(this.step);

  /// The step that crashed (0 when raised by a later call).
  final int step;

  @override
  String toString() => 'SimulatedCrash(step $step)';
}

/// A [StoreFs] decorator for tests: counts the mutating steps and
/// - crashes at step N ([crashAtStep]): the step is applied as [TornWrite] says, then this and every
///   later call throws [SimulatedCrash] until [restart] (the process "restarted"; on-disk state is
///   whatever was left behind);
/// - fails a step with a [StoreFailure] ([failStep] / [failWhere]) without applying it, for disk
///   full (ENOSPC) and permission (EACCES) scenarios.
final class FaultInjectingFs implements StoreFs {
  /// Wraps [inner].
  FaultInjectingFs(this.inner);

  /// The real (or in-memory) filesystem underneath.
  final StoreFs inner;

  /// Every mutating step since the last [reset], including the crashed or failed one.
  final List<FsOp> log = [];

  int? _crashAt;
  TornWrite _torn = TornWrite.none;
  bool _crashed = false;
  final List<_Failure> _failures = [];

  /// Number of mutating steps taken so far.
  int get steps => log.length;

  /// Whether the simulated process is currently dead.
  bool get crashed => _crashed;

  /// Crash at the [step]-th mutating step from now on (1-based, counted from the last [reset]).
  void crashAtStep(int step, {TornWrite torn = TornWrite.none}) {
    _crashAt = step;
    _torn = torn;
  }

  /// Makes the [step]-th mutating step fail once with [kind] (not applied).
  void failStep(int step, StoreFailureKind kind) => _failures.add(_Failure((op) => op.index == step, kind, 1));

  /// Makes every mutating step matching [test] fail with [kind], at most [times] times.
  void failWhere(bool Function(FsOp op) test, StoreFailureKind kind, {int times = 1 << 30}) =>
      _failures.add(_Failure(test, kind, times));

  /// The process "restarts": calls work again; the on-disk state is kept; pending crash and
  /// failure plans are cleared.
  void restart() {
    _crashed = false;
    _crashAt = null;
    _failures.clear();
  }

  /// [restart] plus a fresh step counter and log.
  void reset() {
    restart();
    log.clear();
  }

  Future<T> _step<T>(
    FsOpKind kind,
    String path,
    String? path2,
    Future<T> Function() apply, {
    Future<void> Function(TornWrite torn)? tear,
  }) async {
    if (_crashed) throw const SimulatedCrash(0);
    final op = FsOp(log.length + 1, kind, path, path2);
    log.add(op);
    for (final f in _failures) {
      if (f.times > 0 && f.test(op)) {
        f.times--;
        throw StoreFailure(f.kind, 'injected');
      }
    }
    if (_crashAt == op.index) {
      _crashed = true;
      if (_torn == TornWrite.complete) {
        await apply();
      } else if (tear != null && _torn != TornWrite.none) {
        await tear(_torn);
      }
      throw SimulatedCrash(op.index);
    }
    return apply();
  }

  void _alive() {
    if (_crashed) throw const SimulatedCrash(0);
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    _alive();
    return inner.readBytes(path);
  }

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    _alive();
    return inner.readPrefix(path, maxBytes);
  }

  @override
  Future<StoreStat> stat(String path) async {
    _alive();
    return inner.stat(path);
  }

  @override
  Future<List<StoreEntry>> list(String directory) async {
    _alive();
    return inner.list(directory);
  }

  @override
  Future<String> canonicalize(String path) async {
    _alive();
    return inner.canonicalize(path);
  }

  @override
  Future<void> writeBytesSynced(String path, Uint8List bytes) => _step(
        FsOpKind.write,
        path,
        null,
        () => inner.writeBytesSynced(path, bytes),
        tear: (torn) => inner.writeBytesSynced(
          path,
          torn == TornWrite.half ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2) : Uint8List(0),
        ),
      );

  @override
  Future<void> copyFile(String from, String to) => _step(
        FsOpKind.copy,
        from,
        to,
        () => inner.copyFile(from, to),
        tear: (torn) async {
          final bytes = await inner.readBytes(from);
          await inner.writeBytesSynced(to, torn == TornWrite.half ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2) : Uint8List(0));
        },
      );

  @override
  Future<bool> copyExclusive(String from, String to) => _step(FsOpKind.copyExclusive, from, to, () => inner.copyExclusive(from, to));

  @override
  Future<void> rename(String from, String to) => _step(FsOpKind.rename, from, to, () => inner.rename(from, to));

  @override
  Future<void> delete(String path, {bool recursive = false}) =>
      _step(FsOpKind.delete, path, null, () => inner.delete(path, recursive: recursive));

  @override
  Future<void> createDirectory(String path) => _step(FsOpKind.createDirectory, path, null, () => inner.createDirectory(path));
}

final class _Failure {
  _Failure(this.test, this.kind, this.times);
  final bool Function(FsOp op) test;
  final StoreFailureKind kind;
  int times;
}
