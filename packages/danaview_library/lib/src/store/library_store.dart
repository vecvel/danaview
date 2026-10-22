// OWNER: HOM-17
//
// LibraryStore, the library's front door (ARCH v1.2 V2-06, V2-08, §5.2–§5.4). Opening it:
//
// 1. creates the root layout (`library.db`, `files/`, `imports/`);
// 2. opens the writer connection (WAL) and migrates; a database that SQLite can't read or whose
//    quick check fails is moved aside as `library.db.corrupt-<stamp>` and rebuilt from `files/`
//    into `Recovered`; a newer schema opens read-only (D-12);
// 3. reconciles crash leftovers and repairs the invariants (library_reconcile.dart);
// 4. sweeps Recently deleted (`expires_at ≤ now`);
// 5. marks `imports/` excluded from backups through [BackupFlagPort] (everything else included).
//
// The writer runs on a background isolate (one writer); the store keeps a read-only connection on
// the calling isolate for paged queries and emits [LibraryStore.changes] after every write. The
// sweep runs again daily while [startDailySweep] is on (the app root pauses it in background).

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../db/library_connection.dart';
import '../db/library_reader.dart';
import '../db/migrations.dart';
import '../model/ids.dart';
import 'backup_flags.dart';
import 'library_faults.dart';
import 'library_fs.dart';
import 'library_invariants.dart';
import 'library_paths.dart';
import 'library_reconcile.dart';
import 'library_writer.dart';

/// The wall clock the store stamps writes with (a fake in tests).
typedef LibraryClock = DateTime Function();

DateTime _systemClock() => DateTime.now().toUtc();

/// One write: runs on the writer isolate with the writer and the caller's `now`.
typedef LibraryWrite<R> = R Function(LibraryWriter writer, DateTime now);

/// What opening the store found and did.
final class LibraryOpenReport {
  /// A report.
  const LibraryOpenReport({
    required this.outcome,
    required this.quarantinedAs,
    required this.reconcile,
    required this.sweep,
    required this.violations,
  });

  /// The migration outcome (after a rebuild: [MigrationOutcome.created]).
  final MigrationOutcome outcome;

  /// Where a corrupt database was moved, or null.
  final String? quarantinedAs;

  /// What the reconcile did (null when read-only).
  final ReconcileReport? reconcile;

  /// What the launch sweep removed.
  final PurgeResult sweep;

  /// Invariants still broken after the reconcile (empty normally).
  final List<String> violations;

  /// True when the library is newer than this build (writes are refused, a banner shows).
  bool get readOnly => outcome == MigrationOutcome.newerReadOnly;

  /// True when the database was rebuilt from files.
  bool get rebuilt => quarantinedAs != null;
}

/// Opens the writer side at [root]: everything of steps 1–4 above. Runs on the writer isolate.
(LibraryWriter, LibraryOpenReport) openLibraryWriter(String root, {required DateTime now, LibraryFaults faults = LibraryFaults.none, Random? random}) {
  final fs = LibraryFs(LibraryPaths(root), faults: faults);
  fs.ensureLayout();
  final path = fs.paths.databasePath;
  Database? db;
  String? quarantined;
  MigrationOutcome outcome;
  try {
    db = openLibraryWriteConnection(path);
    if (!libraryQuickCheck(db)) throw const FormatException('library.db failed its quick check');
    outcome = migrateLibrary(db);
  } on Object catch (e) {
    if (e is! SqliteException && e is! FormatException) rethrow;
    db?.dispose();
    quarantined = fs.quarantineDatabase(now);
    db = openLibraryWriteConnection(path);
    outcome = migrateLibrary(db);
  }
  final readOnly = outcome == MigrationOutcome.newerReadOnly;
  final writer = LibraryWriter(db, fs, random: random, readOnly: readOnly);
  ReconcileReport? reconcile;
  var sweep = const PurgeResult(entries: 0, folders: 0);
  if (!readOnly) {
    reconcile = reconcileLibrary(writer, now: now);
    sweep = writer.purgeExpired(now: now);
  }
  return (
    writer,
    LibraryOpenReport(
      outcome: outcome,
      quarantinedAs: quarantined,
      reconcile: reconcile,
      sweep: sweep,
      violations: readOnly ? const [] : checkLibraryInvariants(writer.reader, fs, unavailable: reconcile?.unavailable ?? const {}),
    ),
  );
}

/// Where the writer runs.
abstract interface class _WriterHost {
  LibraryOpenReport get report;

  Future<R> run<R>(LibraryWrite<R> op, DateTime now);

  Future<void> close();

  void abandon();
}

final class _InProcessHost implements _WriterHost {
  _InProcessHost(this.writer, this.report);

  final LibraryWriter writer;

  @override
  final LibraryOpenReport report;

  bool _closed = false;

  @override
  Future<R> run<R>(LibraryWrite<R> op, DateTime now) => Future.sync(() {
        if (_closed) throw StateError('library store is closed');
        return op(writer, now);
      });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    writer.db.dispose();
  }

  @override
  void abandon() {
    if (_closed) return;
    _closed = true;
    writer.db.dispose();
  }
}

final class _IsolateHost implements _WriterHost {
  _IsolateHost._(this._isolate, this._commands, this._replies, this._exited, this.report);

  /// How long [close] waits for the writer isolate to dispose library.db and exit before it kills it.
  static const Duration closeTimeout = Duration(seconds: 10);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;

  /// Completes when the writer isolate has exited (and so let go of library.db).
  final Future<void> _exited;

  @override
  final LibraryOpenReport report;

  final Map<int, Completer<Object?>> _pending = {};
  int _next = 0;
  bool _closed = false;

  static Future<_IsolateHost> spawn(String root, DateTime now, Random? random) async {
    final replies = ReceivePort();
    final exit = ReceivePort();
    final exited = exit.first;
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(_writerMain, (replies.sendPort, root, now, random), debugName: 'library-writer', onExit: exit.sendPort);
    } catch (_) {
      replies.close();
      exit.close();
      rethrow;
    }
    final ready = Completer<(SendPort, LibraryOpenReport)>();
    late final _IsolateHost host;
    replies.listen((Object? message) {
      if (!ready.isCompleted) {
        if (message case (final SendPort port, final LibraryOpenReport report)) {
          ready.complete((port, report));
        } else if (message case (final Object error, final String stack)) {
          ready.completeError(error, StackTrace.fromString(stack));
        }
        return;
      }
      if (message case (final int id, final bool ok, final Object? value, final String? stack)) {
        final completer = host._pending.remove(id);
        if (completer == null) return;
        ok ? completer.complete(value) : completer.completeError(value!, stack == null ? null : StackTrace.fromString(stack));
      }
    });
    try {
      final (port, report) = await ready.future;
      return host = _IsolateHost._(isolate, port, replies, exited, report);
    } catch (_) {
      replies.close();
      isolate.kill();
      rethrow;
    }
  }

  static void _writerMain((SendPort, String, DateTime, Random?) args) {
    final (reply, root, now, random) = args;
    final LibraryWriter writer;
    try {
      final (w, report) = openLibraryWriter(root, now: now, random: random);
      writer = w;
      final commands = ReceivePort();
      reply.send((commands.sendPort, report));
      commands.listen((Object? message) {
        if (message == null) {
          writer.db.dispose();
          commands.close();
          return;
        }
        final (id, op, at) = message as (int, Object? Function(LibraryWriter, DateTime), DateTime);
        try {
          reply.send((id, true, op(writer, at), null));
        } catch (e, s) {
          reply.send((id, false, e is LibraryWriteException ? e : StateError('$e'), s.toString()));
        }
      });
    } catch (e, s) {
      reply.send((e is LibraryWriteException ? e : StateError('$e'), s.toString()));
    }
  }

  @override
  Future<R> run<R>(LibraryWrite<R> op, DateTime now) async {
    if (_closed) throw StateError('library store is closed');
    final id = _next++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    Object? erased(LibraryWriter w, DateTime t) => op(w, t);
    _commands.send((id, erased, now));
    return await completer.future as R;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _commands.send(null);
    await Future<void>.delayed(Duration.zero);
    _replies.close();
    for (final c in _pending.values) {
      c.completeError(StateError('library store is closed'));
    }
    _pending.clear();
    // The writer disposes library.db, closes its port and exits. Wait for that, so a closed store
    // no longer holds the file: Windows refuses to delete or move an open file (FIX-S1Q-A5).
    await _exited.timeout(closeTimeout, onTimeout: () => _isolate.kill(priority: Isolate.immediate));
  }

  @override
  void abandon() {
    _closed = true;
    _replies.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// The Danaview folder store: one writer, a read-only reader, change events and the sweep.
final class LibraryStore {
  LibraryStore._(this.paths, this._host, this._readDb, this._clock, this._backup)
      : reader = LibraryReader(_readDb),
        unavailable = Set.of(_host.report.reconcile?.unavailable ?? const <EntryId>{});

  /// Opens the library at [root] (see the file header). [background] runs the writer on its own
  /// isolate (the app); tests pass false, with [faults] to inject crashes and [random] for ids.
  static Future<LibraryStore> open({
    required String root,
    LibraryClock clock = _systemClock,
    BackupFlagPort backup = const NoBackupFlagPort(),
    bool background = true,
    LibraryFaults faults = LibraryFaults.none,
    Random? random,
  }) async {
    final now = clock();
    final _WriterHost host;
    if (background) {
      host = await _IsolateHost.spawn(root, now, random);
    } else {
      final (writer, report) = openLibraryWriter(root, now: now, faults: faults, random: random);
      host = _InProcessHost(writer, report);
    }
    final paths = LibraryPaths(root);
    final Database readDb;
    try {
      readDb = openLibraryReadConnection(paths.databasePath);
    } catch (_) {
      await host.close();
      rethrow;
    }
    final store = LibraryStore._(paths, host, readDb, clock, backup);
    await store.applyBackupClasses();
    return store;
  }

  /// The root layout.
  final LibraryPaths paths;

  final _WriterHost _host;
  final Database _readDb;
  final LibraryClock _clock;
  final BackupFlagPort _backup;
  final StreamController<void> _changes = StreamController<void>.broadcast(sync: true);
  Timer? _sweepTimer;
  bool _closed = false;

  /// Paged read-only queries on the calling isolate.
  final LibraryReader reader;

  /// Entries whose file was missing at open (shown as unavailable, never dropped).
  final Set<EntryId> unavailable;

  /// What opening found and did.
  LibraryOpenReport get openReport => _host.report;

  /// True when the library is newer than this build (writes are refused).
  bool get readOnly => _host.report.readOnly;

  /// Fires after every write (folder screens and filters re-query in the same frame).
  Stream<void> get changes => _changes.stream;

  /// The current time of the store's clock.
  DateTime now() => _clock();

  /// Runs [op] on the writer, stamped with the clock's `now`, then emits [changes].
  Future<R> write<R>(LibraryWrite<R> op) async {
    if (_closed) throw StateError('library store is closed');
    try {
      return await _host.run(op, _clock());
    } finally {
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  /// Sweeps Recently deleted now (`expires_at ≤ now`).
  Future<PurgeResult> sweepNow() => write((w, now) => w.purgeExpired(now: now));

  /// Runs [sweepNow] every [interval] until [stopDailySweep] (on while the app is in foreground).
  void startDailySweep({Duration interval = const Duration(days: 1)}) {
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(interval, (_) => unawaited(sweepNow().then<void>((_) {}, onError: (Object _) {})));
  }

  /// Stops the daily sweep (app in background).
  void stopDailySweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  /// True while the daily sweep timer runs.
  bool get dailySweepRunning => _sweepTimer?.isActive ?? false;

  /// Marks `imports/` excluded from backups; the database and `files/` stay included (§5.2).
  Future<void> applyBackupClasses() async {
    await _backup.setExcludedFromBackup(paths.importsDir, excluded: true);
  }

  /// The backup class of [path] under the root (§5.2).
  LibraryBackupClass backupClassOf(String path) =>
      path == paths.importsDir || path.startsWith('${paths.importsDir}/') || path.startsWith('${paths.importsDir}\\')
          ? LibraryBackupClass.excluded
          : LibraryBackupClass.included;

  /// The invariants currently broken (tests and diagnostics; reads files, so not for the UI isolate
  /// on a large library).
  Future<List<String>> checkInvariants() {
    // The op crosses to the writer isolate: capture a sendable copy of the set, never `this`
    // (the store holds the host's ReceivePort, which is unsendable).
    final known = Set<EntryId>.of(unavailable);
    return write((w, _) => checkLibraryInvariants(w.reader, w.fs, unavailable: known));
  }

  /// Closes the store.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopDailySweep();
    _readDb.dispose();
    await _host.close();
    await _changes.close();
  }

  /// Drops every connection without finishing anything (tests: the process died).
  void abandon() {
    if (_closed) return;
    _closed = true;
    stopDailySweep();
    _readDb.dispose();
    _host.abandon();
    unawaited(_changes.close());
  }
}
