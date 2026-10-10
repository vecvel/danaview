// OWNER: CORE-25
//
// Hashing and writing of project files off the UI isolate (ARCH §8.3, §18.1).
//
// * [ProjectWriter] is what the repository hands encoded bytes to. It builds the `.vwproj`
//   container (SHA-256 of the body, `VwprojFormat.build`) and writes it, atomically for main
//   documents (`AtomicFile`) and directly for journal slots (the a/b alternation keeps the other
//   slot intact, CORE-26). Small side files (`meta.json`, `refs.json`, `poster.jpg`) are written
//   atomically too.
// * [IsolateProjectWriter] runs that work in one long-lived isolate on the real file system
//   (`LocalStoreFs` + `OwnedFileDeleter`): the UI isolate only encodes (incrementally, ≤ 3 ms) and
//   sends the bytes as `TransferableTypedData` (no copy).
// * [InlineProjectWriter] does the same work on the calling isolate over any `StoreFs`. Tests use
//   it with `FaultInjectingFs` (crash at every step) and `InMemoryProjectRepository` with an
//   in-memory file system, which cannot cross an isolate boundary.
// * [LatestWinsQueue] serializes the writes of one project: one task runs at a time; a newer
//   request replaces a pending request of a kind it supersedes (an autosave is superseded by a
//   later autosave or by a main save; a main save by a later main save), and the replaced
//   request completes with the newer one's result.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../codec/schema_version.dart';
import 'atomic_file.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';
import 'vwproj_format.dart';

/// Header fields of a document write (the body hash and length are computed by the writer).
@immutable
final class DocumentStamp {
  /// Creates a stamp.
  const DocumentStamp({
    required this.app,
    required this.savedAt,
    required this.docRevision,
    required this.saveId,
    this.baseSaveId,
    this.schema = currentProjectSchema,
    this.minReader = currentProjectMinReader,
  });

  /// App version that writes (`"1.1.0+3"`).
  final String app;

  /// Write time (UTC).
  final DateTime savedAt;

  /// `EditProject.docRevision` written.
  final int docRevision;

  /// `sv_…` id of this write.
  final String saveId;

  /// For journal slots: the `saveId` of the main document the journal continues.
  final String? baseSaveId;

  /// Schema written.
  final int schema;

  /// Oldest reader schema that can read the document.
  final int minReader;
}

/// Hashes and writes project files (see the file header).
abstract interface class ProjectWriter {
  /// Builds the `.vwproj` document of [body] with [stamp] and writes it to [path]: through
  /// `AtomicFile` when [atomic] (main documents), else directly with one synced write (journal
  /// slots). Returns the document's header. Throws [StoreFailure].
  Future<ProjectHeader> writeDocument(String path, Uint8List body, DocumentStamp stamp, {bool atomic = true});

  /// Writes [bytes] to [path] atomically (`meta.json`, `refs.json`, `poster.jpg`).
  Future<void> writeFile(String path, Uint8List bytes);

  /// Releases the writer (an isolate writer stops its isolate after the pending requests).
  Future<void> close();
}

/// A [ProjectWriter] on the calling isolate over [fs] (tests, in-memory repositories).
final class InlineProjectWriter implements ProjectWriter {
  /// Creates the writer. [deleter] cleans stale temporaries and must share [fs].
  InlineProjectWriter({StoreFs fs = const LocalStoreFs(), OwnedFileDeleter? deleter})
      : _fs = fs,
        _atomic = AtomicFile(fs: fs, deleter: deleter);

  final StoreFs _fs;
  final AtomicFile _atomic;

  @override
  Future<ProjectHeader> writeDocument(String path, Uint8List body, DocumentStamp stamp, {bool atomic = true}) =>
      writeProjectDocument(_fs, _atomic, path, body, stamp, atomic: atomic);

  @override
  Future<void> writeFile(String path, Uint8List bytes) => _atomic.write(path, bytes);

  @override
  Future<void> close() async {}
}

/// The document write shared by both writers.
@visibleForTesting
Future<ProjectHeader> writeProjectDocument(
  StoreFs fs,
  AtomicFile atomicFile,
  String path,
  Uint8List body,
  DocumentStamp stamp, {
  required bool atomic,
}) async {
  final header = ProjectHeader.forBody(
    body,
    app: stamp.app,
    savedAt: stamp.savedAt,
    docRevision: stamp.docRevision,
    saveId: stamp.saveId,
    baseSaveId: stamp.baseSaveId,
    schema: stamp.schema,
    minReader: stamp.minReader,
  );
  final document = VwprojFormat.encode(header, body);
  if (atomic) {
    await atomicFile.write(path, document);
  } else {
    final dir = p.dirname(path);
    if (!(await fs.stat(dir)).exists) await fs.createDirectory(dir);
    await fs.writeBytesSynced(path, document);
  }
  return header;
}

// =============================================================================================
// Isolate writer
// =============================================================================================

/// A [ProjectWriter] backed by one long-lived isolate writing with `LocalStoreFs`.
final class IsolateProjectWriter implements ProjectWriter {
  IsolateProjectWriter._(this._isolate, this._commands, this._replies) {
    _replies.listen(_onReply);
  }

  /// Spawns the writer isolate. Stale temporaries are removed through an `OwnedFileDeleter`
  /// over [roots] inside the isolate.
  static Future<IsolateProjectWriter> spawn(StoreRoots roots) async {
    final replies = ReceivePort('vwish.editor.writer.replies');
    final ready = Completer<SendPort>();
    final stream = replies.asBroadcastStream();
    final first = stream.first.then((m) => ready.complete(m as SendPort));
    final isolate = await Isolate.spawn(
      _writerMain,
      (replies.sendPort, roots),
      debugName: 'vwish.editor.writer',
      onExit: replies.sendPort,
      onError: replies.sendPort,
    );
    await first;
    return IsolateProjectWriter._(isolate, await ready.future, stream);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final Stream<Object?> _replies;
  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;
  bool _closed = false;

  void _onReply(Object? message) {
    if (message == null || (message is List<Object?> && message.length == 2 && message[0] is String)) {
      // The isolate exited (null) or reported an uncaught error: fail everything still waiting.
      _closed = true;
      final waiting = [..._pending.values];
      _pending.clear();
      for (final c in waiting) {
        c.completeError(const StoreFailure(StoreFailureKind.io, 'writer isolate stopped'));
      }
      return;
    }
    if (message is! List<Object?> || message.length < 2) return;
    final id = message[0]! as int;
    final c = _pending.remove(id);
    if (c == null) return;
    final payload = message[1];
    if (payload is List<Object?> && payload.isNotEmpty && payload[0] == 'error') {
      final kind = StoreFailureKind.values.byName(payload[1]! as String);
      c.completeError(StoreFailure(kind, payload[2]! as String));
    } else {
      c.complete(payload);
    }
  }

  Future<Object?> _call(List<Object?> request) {
    if (_closed) return Future.error(const StoreFailure(StoreFailureKind.io, 'writer closed'));
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _commands.send([id, ...request]);
    return c.future;
  }

  @override
  Future<ProjectHeader> writeDocument(String path, Uint8List body, DocumentStamp stamp, {bool atomic = true}) async {
    final line = await _call([
      'doc',
      path,
      TransferableTypedData.fromList([body]),
      stamp.app,
      stamp.savedAt.toUtc().microsecondsSinceEpoch,
      stamp.docRevision,
      stamp.saveId,
      stamp.baseSaveId,
      stamp.schema,
      stamp.minReader,
      atomic,
    ]);
    return ProjectHeader.parseLine(line! as String);
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    await _call(['file', path, TransferableTypedData.fromList([bytes])]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await Future.wait([for (final c in _pending.values) c.future.catchError((Object _) => null)]);
    _closed = true;
    _commands.send(null);
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<void> _writerMain((SendPort, StoreRoots) args) async {
  final (replies, roots) = args;
  const fs = LocalStoreFs();
  final atomic = AtomicFile(fs: fs, deleter: OwnedFileDeleter(roots, fs: fs, assertOnViolation: false));
  final commands = ReceivePort('vwish.editor.writer.commands');
  replies.send(commands.sendPort);
  // Requests are handled one at a time, in arrival order.
  await for (final message in commands) {
    if (message == null) break;
    final m = message as List<Object?>;
    final id = m[0]! as int;
    try {
      switch (m[1]) {
        case 'doc':
          final body = (m[3]! as TransferableTypedData).materialize().asUint8List();
          final header = await writeProjectDocument(
            fs,
            atomic,
            m[2]! as String,
            body,
            DocumentStamp(
              app: m[4]! as String,
              savedAt: DateTime.fromMicrosecondsSinceEpoch(m[5]! as int, isUtc: true),
              docRevision: m[6]! as int,
              saveId: m[7]! as String,
              baseSaveId: m[8] as String?,
              schema: m[9]! as int,
              minReader: m[10]! as int,
            ),
            atomic: m[11]! as bool,
          );
          replies.send([id, header.encodeLine()]);
        case 'file':
          final bytes = (m[3]! as TransferableTypedData).materialize().asUint8List();
          await atomic.write(m[2]! as String, bytes);
          replies.send([id, null]);
      }
    } on Object catch (e) {
      final f = storeFailureOf(e);
      replies.send([
        id,
        ['error', f.kind.name, f.debugDetail],
      ]);
    }
  }
  commands.close();
}

// =============================================================================================
// Per-project serial queue
// =============================================================================================

/// Runs tasks one at a time; a newer task replaces pending tasks it supersedes (see the header).
final class LatestWinsQueue<T> {
  final List<_Job<T>> _pending = [];
  Future<void>? _running;

  /// Whether nothing runs or waits.
  bool get isIdle => _running == null && _pending.isEmpty;

  /// Queues [task] of [kind]. Pending (not yet started) tasks whose kind is in [supersedes]
  /// are dropped and complete with this task's result (or error).
  Future<T> enqueue(String kind, Future<T> Function() task, {Set<String> supersedes = const {}}) {
    final job = _Job<T>(kind, task);
    _pending.removeWhere((j) {
      if (!supersedes.contains(j.kind)) return false;
      job.followers
        ..add(j.completer)
        ..addAll(j.followers);
      return true;
    });
    _pending.add(job);
    _pump();
    return job.completer.future;
  }

  /// Completes when nothing runs or waits.
  Future<void> idle() async {
    while (_running != null) {
      await _running;
    }
  }

  void _pump() {
    if (_running != null || _pending.isEmpty) return;
    final job = _pending.removeAt(0);
    _running = _run(job).whenComplete(() {
      _running = null;
      _pump();
    });
  }

  Future<void> _run(_Job<T> job) async {
    try {
      final r = await job.task();
      job.completer.complete(r);
      for (final f in job.followers) {
        f.complete(r);
      }
    } on Object catch (e, s) {
      job.completer.completeError(e, s);
      for (final f in job.followers) {
        f.completeError(e, s);
      }
    }
  }
}

final class _Job<T> {
  _Job(this.kind, this.task);

  final String kind;
  final Future<T> Function() task;
  final Completer<T> completer = Completer<T>();
  final List<Completer<T>> followers = [];
}
