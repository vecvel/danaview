// OWNER: CORE-25
//
// Test support barrel (not part of the production surface): an in-memory `StoreFs` and
// `InMemoryProjectRepository`, the real `FileProjectRepository` running inline over
// `FaultInjectingFs(MemoryStoreFs())` with fake roots, for widget tests (danaview_editor's
// `FakeProjectRepository`) and for crash/fault tests that need no disk. Pure Dart (no dart:io).

library;

import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'ops.dart';
import 'store.dart';

/// A file system held in memory (no symbolic links). Modification times strictly increase with
/// every write so "newest copy" decisions are deterministic.
final class MemoryStoreFs implements StoreFs {
  /// Creates an empty file system (only `/` exists).
  MemoryStoreFs({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, _MemFile> _files = {};
  final Map<String, DateTime> _dirs = {'/': DateTime.utc(2026)};
  DateTime _last = DateTime.utc(2026);

  DateTime _tick() {
    var t = _clock().toUtc();
    if (!t.isAfter(_last)) t = _last.add(const Duration(microseconds: 1));
    return _last = t;
  }

  static String _n(String path) => p.posix.normalize(path);

  /// Every file path (sorted), for assertions.
  List<String> get filePaths => _files.keys.toList()..sort();

  /// Every directory path (sorted).
  List<String> get directoryPaths => _dirs.keys.toList()..sort();

  /// Writes [bytes] at [path] directly, creating parents (test setup).
  void putFile(String path, List<int> bytes, {DateTime? modified}) {
    final n = _n(path);
    _mkdirs(p.posix.dirname(n));
    _files[n] = _MemFile(Uint8List.fromList(bytes), modified ?? _tick());
  }

  /// Sets the modification time of a file or directory (grace-period tests).
  void touch(String path, DateTime modified) {
    final n = _n(path);
    final f = _files[n];
    if (f != null) {
      f.modified = modified;
    } else if (_dirs.containsKey(n)) {
      _dirs[n] = modified;
    }
  }

  /// Creates [path] and its parents (test setup).
  void mkdirs(String path) => _mkdirs(path);

  /// The bytes of [path], or null.
  Uint8List? peek(String path) => _files[_n(path)]?.bytes;

  void _mkdirs(String dir) {
    var d = _n(dir);
    final made = <String>[];
    while (!_dirs.containsKey(d)) {
      if (_files.containsKey(d)) throw const StoreFailure(StoreFailureKind.io, 'not a directory');
      made.add(d);
      final parent = p.posix.dirname(d);
      if (parent == d) break;
      d = parent;
    }
    for (final m in made) {
      _dirs[m] = _tick();
    }
  }

  void _requireParent(String path) {
    if (!_dirs.containsKey(p.posix.dirname(path))) throw const StoreFailure(StoreFailureKind.notFound, 'parent');
  }

  _MemFile _file(String path) {
    final f = _files[_n(path)];
    if (f == null) {
      throw StoreFailure(_dirs.containsKey(_n(path)) ? StoreFailureKind.io : StoreFailureKind.notFound, 'file');
    }
    return f;
  }

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List.fromList(_file(path).bytes);

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    final b = _file(path).bytes;
    return Uint8List.fromList(b.sublist(0, b.length < maxBytes ? b.length : maxBytes));
  }

  @override
  Future<void> writeBytesSynced(String path, Uint8List bytes) async {
    final n = _n(path);
    _requireParent(n);
    if (_dirs.containsKey(n)) throw const StoreFailure(StoreFailureKind.io, 'is a directory');
    _files[n] = _MemFile(Uint8List.fromList(bytes), _tick());
  }

  @override
  Future<void> copyFile(String from, String to) async {
    final src = _file(from);
    await writeBytesSynced(to, src.bytes);
  }

  @override
  Future<bool> copyExclusive(String from, String to) async {
    final n = _n(to);
    if (_files.containsKey(n) || _dirs.containsKey(n)) return false;
    await copyFile(from, n);
    return true;
  }

  @override
  Future<void> rename(String from, String to) async {
    final a = _n(from), b = _n(to);
    _requireParent(b);
    final f = _files.remove(a);
    if (f != null) {
      if (_dirs.containsKey(b)) {
        _files[a] = f;
        throw const StoreFailure(StoreFailureKind.io, 'target is a directory');
      }
      _files[b] = f;
      return;
    }
    if (!_dirs.containsKey(a)) throw const StoreFailure(StoreFailureKind.notFound, 'rename source');
    if (_dirs.containsKey(b) || _files.containsKey(b)) throw const StoreFailure(StoreFailureKind.io, 'target exists');
    final prefix = '$a/';
    for (final k in _files.keys.where((k) => k.startsWith(prefix)).toList()) {
      _files['$b/${k.substring(prefix.length)}'] = _files.remove(k)!;
    }
    for (final k in _dirs.keys.where((k) => k == a || k.startsWith(prefix)).toList()) {
      _dirs[k == a ? b : '$b/${k.substring(prefix.length)}'] = _dirs.remove(k)!;
    }
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final n = _n(path);
    if (_files.remove(n) != null) return;
    if (!_dirs.containsKey(n)) return;
    final prefix = '$n/';
    final children = _files.keys.any((k) => k.startsWith(prefix)) || _dirs.keys.any((k) => k.startsWith(prefix));
    if (children && !recursive) throw const StoreFailure(StoreFailureKind.io, 'directory not empty');
    _files.removeWhere((k, _) => k.startsWith(prefix));
    _dirs.removeWhere((k, _) => k == n || k.startsWith(prefix));
  }

  @override
  Future<void> createDirectory(String path) async => _mkdirs(path);

  @override
  Future<StoreStat> stat(String path) async {
    final n = _n(path);
    final f = _files[n];
    if (f != null) return StoreStat(StoreEntityType.file, size: f.bytes.length, modified: f.modified);
    final d = _dirs[n];
    if (d != null) return StoreStat(StoreEntityType.directory, modified: d);
    return StoreStat.missing;
  }

  @override
  Future<List<StoreEntry>> list(String directory) async {
    final n = _n(directory);
    if (!_dirs.containsKey(n)) throw const StoreFailure(StoreFailureKind.notFound, 'directory');
    final prefix = n == '/' ? '/' : '$n/';
    bool direct(String k) => k != n && k.startsWith(prefix) && !k.substring(prefix.length).contains('/');
    return [
      for (final k in _dirs.keys)
        if (direct(k)) StoreEntry(k, StoreEntityType.directory),
      for (final k in _files.keys)
        if (direct(k)) StoreEntry(k, StoreEntityType.file),
    ];
  }

  @override
  Future<String> canonicalize(String path) async => _n(p.posix.isAbsolute(path) ? path : '/$path');
}

final class _MemFile {
  _MemFile(this.bytes, this.modified);

  final Uint8List bytes;
  DateTime modified;
}

/// A [ProjectRepository] in memory: the production [FileProjectRepository] running inline over
/// `FaultInjectingFs(MemoryStoreFs())` under fake roots (`/mem/{support,cache,documents}`).
///
/// [fs] exposes fault injection (`crashAtStep`, `failWhere`, `restart`) and [memory] the stored
/// bytes. [seed] stores a ready-made project. Autosave runs on [timer] (real timers by default).
final class InMemoryProjectRepository implements ProjectRepository {
  /// Creates the repository.
  factory InMemoryProjectRepository({
    MediaPoolService? media,
    MediaAccessPort? access,
    IdGenerator? ids,
    DateTime Function()? clock,
    StoreRoots roots = defaultRoots,
    AutosavePolicy autosavePolicy = const AutosavePolicy(),
    StoreTimerFactory? timer,
    PosterProvider? poster,
    ProjectDeletedHook? onProjectDeleted,
    bool allow2160 = false,
  }) {
    final memory = MemoryStoreFs(clock: clock);
    final fs = FaultInjectingFs(memory);
    final deleter = OwnedFileDeleter(roots, fs: fs, assertOnViolation: false);
    [roots.support, roots.cache, roots.documents].forEach(memory.mkdirs);
    final inner = FileProjectRepository(
      roots: roots,
      fs: fs,
      deleter: deleter,
      useIsolates: false,
      media: media,
      access: access,
      ids: ids,
      clock: clock,
      autosavePolicy: autosavePolicy,
      timer: timer,
      poster: poster,
      onProjectDeleted: onProjectDeleted,
      allow2160: allow2160,
    );
    return InMemoryProjectRepository._(inner, fs, memory);
  }

  InMemoryProjectRepository._(this.inner, this.fs, this.memory);

  /// Fake roots used by default.
  static const StoreRoots defaultRoots = StoreRoots(support: '/mem/support', cache: '/mem/cache', documents: '/mem/documents');

  /// The production repository doing the work.
  final FileProjectRepository inner;

  /// The fault-injecting file system every operation goes through.
  final FaultInjectingFs fs;

  /// The in-memory file system under [fs].
  final MemoryStoreFs memory;

  /// Stores [project] as a closed project (replacing one with the same id).
  Future<ProjectId> seed(EditProject project) => inner.writeNewProject(project);

  /// Current summaries.
  Future<List<ProjectSummary>> summaries() => inner.summaries();

  @override
  Stream<List<ProjectSummary>> watchSummaries() => inner.watchSummaries();

  @override
  Future<ProjectId> create(NewProjectSpec spec) => inner.create(spec);

  @override
  Future<LoadedProject> open(ProjectId id) => inner.open(id);

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) => inner.save(session, reason: reason);

  @override
  void requestAutosave(EditSession session) => inner.requestAutosave(session);

  @override
  Future<void> flush(ProjectId id) => inner.flush(id);

  @override
  Future<void> close(ProjectId id) => inner.close(id);

  @override
  Future<void> rename(ProjectId id, String name) => inner.rename(id, name);

  @override
  Future<ProjectId> duplicate(ProjectId id, {String? name}) => inner.duplicate(id, name: name);

  @override
  Future<void> delete(ProjectId id) => inner.delete(id);

  @override
  Future<List<RecoverableSession>> recoverable() => inner.recoverable();

  @override
  Future<LoadedProject> restore(RecoverableSession session) => inner.restore(session);

  @override
  Future<void> discard(RecoverableSession session) => inner.discard(session);

  @override
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri) => inner.findUntouchedProjectFor(pathOrUri);

  @override
  Future<ProjectStorageReport> storageReport() => inner.storageReport();

  /// Closes everything.
  Future<void> dispose() => inner.dispose();
}
