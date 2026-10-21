// OWNER: HOM-20
//
// ImportService, the one import path of the library (ARCH v1.2 §5.6, V2-116, rule 27): pickers,
// Open with, the Share Extension inbox, linked folders and the player all enqueue an
// [ImportSource] here. One item at a time:
//
// 1. stat the source (opened read-only, never moved, renamed, deleted or written);
// 2. `beginImport` → an `import_jobs` row whose `source_desc` is the encoded source;
// 3. stream the bytes into `imports/<jobId>.part` (resumable from `bytes_done` after the app was
//    killed, while the source is still readable), progress rows for the sheet;
// 4. duplicates: a same-name file in the folder is suffixed `Name (2).ext` by the writer; a file
//    with the same size and SHA-256 anywhere in the library asks "keep both or skip" (or follows
//    the item's [DuplicatePolicy]);
// 5. fsync (the copier) → `commitImport` (rename into `files/<id>/` + one transaction);
// 6. the picker's staged copy (app-owned) is deleted, a security-scoped grant released, and the
//    import hooks run (thumbnail request HOM-04, index request AIS-50).
//
// Writes go through LibraryStore.write; the closures it ships to the writer isolate are built by
// top-level functions so they capture only sendable values. Nothing is logged (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../classify/classifier.dart';
import '../db/library_reader.dart';
import '../model/file_entry.dart';
import '../model/ids.dart';
import '../store/library_store.dart';
import '../store/library_writer.dart';
import 'import_copier.dart';
import 'import_source.dart';

/// Where an item of the import queue is.
enum ImportItemState {
  /// Waiting for the item before it.
  queued,

  /// Bytes are being copied.
  copying,

  /// Copied; hashing, classifying and committing.
  finishing,

  /// A file with the same content is already in the library; waiting for "keep both or skip".
  awaitingDuplicateDecision,

  /// In the library ([ImportItem.entry]).
  done,

  /// Skipped as a duplicate.
  skipped,

  /// Failed ([ImportItem.failure]).
  failed,

  /// Cancelled by the user.
  cancelled;

  /// True once the item will not change any more.
  bool get isFinal => this == done || this == skipped || this == failed || this == cancelled;
}

/// What to do with a file whose content is already in the library.
enum DuplicatePolicy {
  /// Ask ([ImportItemState.awaitingDuplicateDecision], answered by [ImportService.resolveDuplicate]).
  ask,

  /// Import it anyway.
  keepBoth,

  /// Don't import it.
  skip,
}

/// The answer to a duplicate question.
enum DuplicateDecision {
  /// Import it anyway.
  keepBoth,

  /// Don't import it.
  skip,
}

/// A snapshot of one item of the import queue.
@immutable
final class ImportItem {
  /// A snapshot.
  const ImportItem({
    required this.id,
    required this.displayName,
    required this.state,
    this.targetFolder,
    this.jobId,
    this.bytesDone = 0,
    this.bytesTotal = -1,
    this.entry,
    this.duplicateOf,
    this.failure,
    this.resumed = false,
  });

  /// The queue id (stable for the item's life).
  final String id;

  /// The name shown on the progress row.
  final String displayName;

  /// Where it is.
  final ImportItemState state;

  /// The folder asked for (null: `Imported`).
  final FolderId? targetFolder;

  /// The `import_jobs` id once the job started.
  final String? jobId;

  /// Bytes copied so far.
  final int bytesDone;

  /// The source size, or -1 while unknown.
  final int bytesTotal;

  /// The new entry ([ImportItemState.done]).
  final FileEntry? entry;

  /// The library entry with the same content ([ImportItemState.awaitingDuplicateDecision],
  /// [ImportItemState.skipped]).
  final FileEntry? duplicateOf;

  /// Why it failed ([ImportItemState.failed]).
  final ImportFailure? failure;

  /// True when this item continues a job an earlier run of the app started.
  final bool resumed;

  /// Copied fraction 0…1, or null while the size is unknown.
  double? get fraction {
    if (state == ImportItemState.done) return 1;
    if (bytesTotal <= 0) return bytesTotal == 0 ? 1 : null;
    final f = bytesDone / bytesTotal;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  /// A copy with the given fields replaced.
  ImportItem copyWith({
    ImportItemState? state,
    String? jobId,
    int? bytesDone,
    int? bytesTotal,
    FileEntry? entry,
    FileEntry? duplicateOf,
    ImportFailure? failure,
    FolderId? targetFolder,
  }) =>
      ImportItem(
        id: id,
        displayName: displayName,
        state: state ?? this.state,
        targetFolder: targetFolder ?? this.targetFolder,
        jobId: jobId ?? this.jobId,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        entry: entry ?? this.entry,
        duplicateOf: duplicateOf ?? this.duplicateOf,
        failure: failure ?? this.failure,
        resumed: resumed,
      );

  // Never prints the name (rule 30).
  @override
  String toString() => 'ImportItem($id, ${state.name}, $bytesDone/$bytesTotal)';
}

/// Runs after an entry was imported (thumbnail and index requests).
typedef ImportHook = void Function(FileEntry entry);

/// Gives up the platform grant of a URI ([ImportSource.releaseUri]).
typedef ImportReleaser = Future<void> Function(String uri);

final class _Work {
  _Work(this.item, this.source, this.policy, {this.job});

  ImportItem item;
  final ImportSource source;
  final DuplicatePolicy policy;
  ImportJob? job;
  ImportCopyRun? run;
  bool cancelRequested = false;
  Completer<DuplicateDecision>? decision;
  final Completer<ImportItem> result = Completer<ImportItem>();
}

/// The import queue over one [LibraryStore].
final class ImportService {
  /// A service over [store]. [copiers] are asked in order which one reads a source (local files
  /// by default; the app adds the native copier for platform URIs). [onImported] runs for every
  /// new entry; [release] gives up security-scoped grants.
  ImportService({
    required this.store,
    List<ImportCopier> copiers = const [FileImportCopier()],
    List<ImportHook> onImported = const [],
    ImportReleaser? release,
  })  : _copiers = List.unmodifiable(copiers),
        _hooks = List.of(onImported),
        _release = release;

  /// The library.
  final LibraryStore store;

  final List<ImportCopier> _copiers;
  final List<ImportHook> _hooks;
  final ImportReleaser? _release;
  final List<_Work> _queue = [];
  final StreamController<List<ImportItem>> _updates = StreamController<List<ImportItem>>.broadcast(sync: true);
  int _next = 0;
  bool _pumping = false;
  bool _disposed = false;

  /// Every item of this session, in enqueue order (finished ones until [clearFinished]).
  List<ImportItem> get items => List.unmodifiable([for (final w in _queue) w.item]);

  /// The items after every change.
  Stream<List<ImportItem>> get updates => _updates.stream;

  /// True while an item is queued or running.
  bool get busy => _queue.any((w) => !w.item.state.isFinal);

  /// Adds an import hook (thumbnails, index).
  void addHook(ImportHook hook) => _hooks.add(hook);

  /// Queues [source] for [target] (`Imported` when null); returns the item id.
  String enqueue(ImportSource source, {FolderId? target, DuplicatePolicy duplicates = DuplicatePolicy.ask}) {
    if (_disposed) throw StateError('import service is disposed');
    final id = 'imp_${++_next}';
    _queue.add(_Work(ImportItem(id: id, displayName: source.displayName, state: ImportItemState.queued, targetFolder: target), source, duplicates));
    _emit();
    unawaited(_pump());
    return id;
  }

  /// Queues every source of [sources]; returns their item ids in order.
  List<String> enqueueAll(Iterable<ImportSource> sources, {FolderId? target, DuplicatePolicy duplicates = DuplicatePolicy.ask}) => [
        for (final s in sources) enqueue(s, target: target, duplicates: duplicates),
      ];

  /// Completes with item [id] once it is final.
  Future<ImportItem> result(String id) => _work(id).result.future;

  /// Imports [sources] and waits for all of them.
  Future<List<ImportItem>> importAll(Iterable<ImportSource> sources, {FolderId? target, DuplicatePolicy duplicates = DuplicatePolicy.ask}) =>
      Future.wait([for (final id in enqueueAll(sources, target: target, duplicates: duplicates)) result(id)]);

  /// Queues every job an earlier run left in `import_jobs` (the app was killed mid-copy). A job
  /// whose source can no longer be decoded is abandoned at once; one whose source can't be read is
  /// abandoned when its turn comes (reported as [ImportFailure.sourceUnreadable]). Returns the ids.
  Future<List<String>> resumePending({DuplicatePolicy duplicates = DuplicatePolicy.ask}) async {
    if (_disposed) throw StateError('import service is disposed');
    final known = {for (final w in _queue) w.job?.id};
    final ids = <String>[];
    for (final job in store.reader.importJobs()) {
      if (job.state != ImportJobState.copying || known.contains(job.id)) continue;
      final source = ImportSource.tryDecode(job.sourceDescription);
      if (source == null) {
        await store.write(_abandonOp(job.id));
        continue;
      }
      final id = 'imp_${++_next}';
      _queue.add(_Work(
        ImportItem(
          id: id,
          displayName: source.displayName,
          state: ImportItemState.queued,
          targetFolder: job.targetFolder,
          jobId: job.id,
          bytesDone: job.bytesDone,
          bytesTotal: job.bytesTotal,
          resumed: true,
        ),
        source,
        duplicates,
        job: job,
      ));
      ids.add(id);
    }
    if (ids.isNotEmpty) {
      _emit();
      unawaited(_pump());
    }
    return ids;
  }

  /// Deletes files in the picker staging directory [stagingDir] that no queued item or stored job
  /// still reads (left by a run that ended before their import started).
  Future<int> sweepStaging(String stagingDir) async {
    final dir = Directory(stagingDir);
    if (!dir.existsSync()) return 0;
    final keep = <String>{
      for (final w in _queue)
        if (!w.item.state.isFinal) _norm(w.source.location),
      for (final job in store.reader.importJobs())
        if (ImportSource.tryDecode(job.sourceDescription) case final s?) _norm(s.location),
    };
    var removed = 0;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File || keep.contains(_norm(e.path))) continue;
      try {
        e.deleteSync();
        removed++;
      } on FileSystemException {
        // Gone already or in use; the next sweep retries.
      }
    }
    return removed;
  }

  /// Answers the duplicate question of item [id].
  void resolveDuplicate(String id, DuplicateDecision decision) {
    final c = _work(id).decision;
    if (c != null && !c.isCompleted) c.complete(decision);
  }

  /// Cancels item [id]: a queued item never starts, a running copy stops and its part is deleted.
  Future<void> cancel(String id) async {
    final w = _work(id);
    if (w.item.state.isFinal) return;
    w.cancelRequested = true;
    if (w.item.state == ImportItemState.queued) {
      if (w.job != null) await store.write(_abandonOp(w.job!.id));
      _finish(w, w.item.copyWith(state: ImportItemState.cancelled));
      return;
    }
    final d = w.decision;
    if (d != null && !d.isCompleted) d.complete(DuplicateDecision.skip);
    await w.run?.cancel();
  }

  /// Removes finished items from [items].
  void clearFinished() {
    _queue.removeWhere((w) => w.item.state.isFinal);
    _emit();
  }

  /// Stops the service as the app going away would: the running copy stops where it is and its
  /// job stays in `import_jobs` for [resumePending]; queued items are dropped.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final w in _queue) {
      w.decision?.completeError(StateError('import service is disposed'));
      w.decision = null;
    }
    final running = _queue.where((w) => w.run != null && !w.item.state.isFinal).toList();
    for (final w in running) {
      await w.run!.cancel();
    }
    await _updates.close();
  }

  // ---- the pump ----------------------------------------------------------------------------

  _Work _work(String id) => _queue.firstWhere((w) => w.item.id == id, orElse: () => throw ArgumentError.value(id, 'id', 'unknown import item'));

  void _emit() {
    if (!_updates.isClosed) _updates.add(items);
  }

  void _update(_Work w, ImportItem item) {
    w.item = item;
    _emit();
  }

  void _finish(_Work w, ImportItem item) {
    _update(w, item);
    if (!w.result.isCompleted) w.result.complete(item);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed) {
        final next = _queue.where((w) => w.item.state == ImportItemState.queued).firstOrNull;
        if (next == null) break;
        await _process(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _fail(_Work w, ImportFailure failure) async {
    final job = w.job;
    if (job != null) {
      try {
        await store.write(_abandonOp(job.id));
      } on Object {
        // The reconcile deletes a stray part on the next open.
      }
    }
    _finish(w, w.item.copyWith(state: failure == ImportFailure.cancelled ? ImportItemState.cancelled : ImportItemState.failed, failure: failure));
  }

  Future<void> _process(_Work w) async {
    final source = w.source;
    final copier = _copiers.where((c) => c.handles(source)).firstOrNull;
    if (copier == null) return _fail(w, ImportFailure.unsupportedSource);
    _update(w, w.item.copyWith(state: ImportItemState.copying));

    final SourceStat stat;
    try {
      stat = await copier.stat(source);
    } on ImportException catch (e) {
      return _fail(w, e.failure);
    }
    if (_disposed) return;

    // The job: a new one, or the one an earlier run left.
    var resumeFrom = 0;
    var job = w.job;
    try {
      if (job == null) {
        final desc = source.encode();
        try {
          job = await store.write(_beginOp(w.item.targetFolder, desc, stat.size));
        } on LibraryWriteException catch (e) {
          // A target trashed or deleted meanwhile: the default folder.
          if (w.item.targetFolder == null || (e.error != LibraryWriteError.trashed && e.error != LibraryWriteError.notFound)) rethrow;
          job = await store.write(_beginOp(null, desc, stat.size));
        }
        w.job = job;
      } else {
        final part = File(store.paths.resolve(job.partPath));
        final have = part.existsSync() ? part.lengthSync() : 0;
        final unchanged = job.bytesTotal == stat.size && (source.modifiedAt == null || stat.modifiedAt == null || source.modifiedAt == stat.modifiedAt);
        resumeFrom = unchanged ? (job.bytesDone < have ? job.bytesDone : have) : 0;
      }
    } on LibraryWriteException {
      return _fail(w, ImportFailure.refused);
    }
    if (job == null) return _fail(w, ImportFailure.refused);
    final jobId = job.id;
    _update(w, w.item.copyWith(jobId: jobId, bytesTotal: stat.size, bytesDone: resumeFrom, targetFolder: job.targetFolder));
    if (w.cancelRequested) return _fail(w, ImportFailure.cancelled);

    // Copy.
    final partPath = store.paths.resolve(job.partPath);
    final hash = stat.size >= 0 && _sizeInLibrary(stat.size);
    var checkpoints = Future<void>.value();
    final run = copier.start(
      source: source,
      partPath: partPath,
      resumeFrom: resumeFrom,
      hash: hash,
      onProgress: (bytes) {
        if (!w.item.state.isFinal) _update(w, w.item.copyWith(bytesDone: bytes));
      },
      onCheckpoint: (bytes) {
        checkpoints = checkpoints.then((_) => store.write(_progressOp(jobId, bytes))).then<void>((_) {}, onError: (Object _) {});
      },
    );
    w.run = run;
    final CopyOutcome outcome;
    try {
      outcome = await run.done;
    } on ImportException catch (e) {
      w.run = null;
      await checkpoints;
      // Disposed mid-copy: the app is going away; keep the job for resumePending.
      if (_disposed) return;
      return _fail(w, w.cancelRequested ? ImportFailure.cancelled : e.failure);
    }
    w.run = null;
    await checkpoints;
    if (_disposed) return;
    if (w.cancelRequested) return _fail(w, ImportFailure.cancelled);
    _update(w, w.item.copyWith(state: ImportItemState.finishing, bytesDone: outcome.bytes, bytesTotal: stat.size < 0 ? outcome.bytes : stat.size));

    // Duplicates by content.
    String? sha = outcome.sha256;
    if (sha == null && stat.size < 0 && _sizeInLibrary(outcome.bytes)) sha = await sha256OfFile(partPath);
    if (sha != null) {
      final dup = await _contentDuplicate(outcome.bytes, sha);
      if (dup != null) {
        var decision = switch (w.policy) {
          DuplicatePolicy.keepBoth => DuplicateDecision.keepBoth,
          DuplicatePolicy.skip => DuplicateDecision.skip,
          DuplicatePolicy.ask => null,
        };
        if (decision == null) {
          final c = w.decision = Completer<DuplicateDecision>();
          _update(w, w.item.copyWith(state: ImportItemState.awaitingDuplicateDecision, duplicateOf: dup));
          try {
            decision = await c.future;
          } on StateError {
            return; // disposed while asking: the job stays for resumePending
          } finally {
            w.decision = null;
          }
          if (w.cancelRequested) return _fail(w, ImportFailure.cancelled);
          _update(w, w.item.copyWith(state: ImportItemState.finishing));
        }
        if (decision == DuplicateDecision.skip) {
          await store.write(_abandonOp(jobId));
          await _afterSource(source);
          _finish(w, w.item.copyWith(state: ImportItemState.skipped, duplicateOf: dup));
          return;
        }
      }
    }

    // Commit.
    if (w.cancelRequested) return _fail(w, ImportFailure.cancelled);
    final quick = await quickHashOfFile(partPath);
    final name = importDisplayName(source.displayName);
    final kind = classify(uti: source.uti, mime: source.mime, fileName: name);
    final FileEntry entry;
    try {
      entry = await store.write(_commitOp(
        jobId,
        ImportedFileInfo(
          displayName: name,
          kind: kind.kind,
          subKind: kind.subKind,
          mime: source.mime,
          uti: source.uti,
          quickHash: quick,
          contentSha256: sha,
          sourceHint: source.sourceHint,
          modifiedAt: stat.modifiedAt ?? source.modifiedAt,
        ),
      ));
    } on LibraryWriteException {
      return _fail(w, ImportFailure.refused);
    }
    await _afterSource(source);
    _finish(w, w.item.copyWith(state: ImportItemState.done, entry: entry));
    for (final hook in List.of(_hooks)) {
      try {
        hook(entry);
      } on Object {
        // A failing thumbnail or index request never fails the import.
      }
    }
  }

  /// Deletes the picker's staged copy (app-owned, never the user's original) and releases the grant.
  Future<void> _afterSource(ImportSource source) async {
    if (source.stagedCopy && source.kind == ImportSourceKind.file) {
      try {
        await File(source.location).delete();
      } on FileSystemException {
        // Swept by sweepStaging later.
      }
    }
    final uri = source.releaseUri;
    if (uri != null && _release != null) {
      try {
        await _release(uri);
      } on Object {
        // The grant ends with the process anyway.
      }
    }
  }

  bool _sizeInLibrary(int size) =>
      store.reader.db.select('SELECT 1 FROM entries WHERE size_bytes = ? AND trashed_at IS NULL LIMIT 1', [size]).isNotEmpty;

  Future<FileEntry?> _contentDuplicate(int size, String sha) async {
    final rows = store.reader.db.select(
      'SELECT id, display_name, content_sha256 FROM entries WHERE size_bytes = ? AND trashed_at IS NULL ORDER BY added_at, id',
      [size],
    );
    for (final row in rows) {
      final id = EntryId.parse(row['id'] as String);
      var theirs = row['content_sha256'] as String?;
      if (theirs == null) {
        final path = store.paths.entryFile(id, row['display_name'] as String);
        if (!File(path).existsSync()) continue;
        theirs = await sha256OfFile(path);
      }
      if (theirs == sha) return store.reader.entry(id);
    }
    return null;
  }
}

String _norm(String path) => File(path).absolute.path;

final RegExp _badNameChars = RegExp(r'[/\\\x00-\x1F\x7F]');

/// [name] made a valid entry file name: separators and control characters become `_`, `.`/`..`
/// and empty names become `Imported file`, and the name is cut to 255 UTF-8 bytes keeping the
/// extension.
String importDisplayName(String name) {
  var n = name.replaceAll(_badNameChars, '_').trim();
  if (n.isEmpty || n == '.' || n == '..') n = 'Imported file';
  if (isValidEntryName(n)) return n;
  final dot = n.lastIndexOf('.');
  final ext = dot > 0 && n.length - dot <= 16 ? n.substring(dot) : '';
  var base = ext.isEmpty ? n : n.substring(0, dot);
  while (base.isNotEmpty && !isValidEntryName('$base$ext')) {
    base = String.fromCharCodes(base.runes.take(base.runes.length - 1));
  }
  return base.isEmpty ? 'Imported file$ext' : '$base$ext';
}

// Write closures built outside the service, so they capture only sendable values (the writer may
// run on its own isolate).

LibraryWrite<ImportJob> _beginOp(FolderId? target, String desc, int size) =>
    (w, now) => w.beginImport(target: target, sourceDescription: desc, bytesTotal: size < 0 ? 0 : size, now: now);

LibraryWrite<void> _progressOp(String jobId, int bytes) => (w, _) => w.recordImportProgress(jobId, bytes);

LibraryWrite<void> _abandonOp(String jobId) => (w, _) => w.abandonImport(jobId);

LibraryWrite<FileEntry> _commitOp(String jobId, ImportedFileInfo info) => (w, now) => w.commitImport(jobId, info, now: now);
