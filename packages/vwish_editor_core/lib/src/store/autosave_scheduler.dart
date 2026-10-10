// OWNER: CORE-26
//
// Autosave timing (ARCH §8.3): every commit, pool change and view change calls [request]; the
// scheduler writes the journal after 2 s without further requests, and at the latest 10 s after
// the first unsaved request while requests keep coming. While a gesture's transaction is open
// ([AutosaveScheduler.isPaused]) a due autosave is skipped and retried one idle period later (the
// commit that closes the transaction is itself a request). One save runs at a time; requests made
// during a save schedule the next one. A failed save reports [AutosavePhase.failed] with the
// [StoreFailure] (edits stay in memory) and is retried on the next trigger.
//
// Time is injected ([StoreTimerFactory], clock) so tests run on a fake clock.

import 'dart:async';

import 'package:meta/meta.dart';

import 'store_fs.dart';

/// Creates a one-shot timer (default: `Timer.new`).
typedef StoreTimerFactory = Timer Function(Duration duration, void Function() callback);

/// Autosave timing constants.
@immutable
final class AutosavePolicy {
  /// Creates a policy (defaults: 2 s idle, forced at 10 s).
  const AutosavePolicy({this.idle = const Duration(seconds: 2), this.cap = const Duration(seconds: 10)});

  /// Quiet time after the last request.
  final Duration idle;

  /// Longest delay after the first unsaved request.
  final Duration cap;
}

/// What the scheduler is doing.
enum AutosavePhase {
  /// Nothing to save.
  idle,

  /// A save is scheduled.
  pending,

  /// A save is running.
  saving,

  /// The last save succeeded and nothing new is pending.
  saved,

  /// The last save failed; the next request retries.
  failed,
}

/// The scheduler's state (the UI maps it to its `SaveStatus`).
@immutable
final class AutosaveStatus {
  /// Creates a status.
  const AutosaveStatus(this.phase, {this.failure, this.lastSavedAt});

  /// Phase.
  final AutosavePhase phase;

  /// Why the last save failed (phase `failed`).
  final StoreFailure? failure;

  /// When the last successful save finished.
  final DateTime? lastSavedAt;

  @override
  bool operator ==(Object other) =>
      other is AutosaveStatus && other.phase == phase && other.failure == failure && other.lastSavedAt == lastSavedAt;

  @override
  int get hashCode => Object.hash(phase, failure, lastSavedAt);

  @override
  String toString() => 'AutosaveStatus(${phase.name}${failure == null ? '' : ', $failure'})';
}

/// Debounces autosaves of one open project (see the file header).
final class AutosaveScheduler {
  /// Creates a scheduler that calls [save] when an autosave is due. [isPaused] reports an open
  /// transaction. [timer] and [now] default to real time.
  AutosaveScheduler({
    required this.save,
    bool Function()? isPaused,
    this.policy = const AutosavePolicy(),
    StoreTimerFactory? timer,
    DateTime Function()? now,
  })  : _isPaused = isPaused ?? _never,
        _timer = timer ?? Timer.new,
        _now = now ?? DateTime.now;

  static bool _never() => false;

  /// Writes the journal.
  final Future<void> Function() save;

  /// Timing.
  final AutosavePolicy policy;

  final bool Function() _isPaused;
  final StoreTimerFactory _timer;
  final DateTime Function() _now;
  final StreamController<AutosaveStatus> _statuses = StreamController<AutosaveStatus>.broadcast(sync: true);

  Timer? _pending;
  DateTime? _firstUnsaved;
  Future<void>? _saving;
  bool _dirtyDuringSave = false;
  bool _disposed = false;
  AutosaveStatus _status = const AutosaveStatus(AutosavePhase.idle);

  /// Number of saves started (tests, diagnostics).
  int savesStarted = 0;

  /// Current status.
  AutosaveStatus get status => _status;

  /// Status changes.
  Stream<AutosaveStatus> get statuses => _statuses.stream;

  /// Whether an autosave is scheduled or running.
  bool get hasPendingWork => _pending != null || _saving != null || _dirtyDuringSave;

  /// Notes an unsaved change.
  void request() {
    if (_disposed) return;
    if (_saving != null) {
      _dirtyDuringSave = true;
      return;
    }
    final now = _now();
    _firstUnsaved ??= now;
    _schedule(now);
  }

  void _schedule(DateTime now) {
    _pending?.cancel();
    final sinceFirst = now.difference(_firstUnsaved!);
    var delay = policy.cap - sinceFirst;
    if (delay > policy.idle) delay = policy.idle;
    if (delay.isNegative) delay = Duration.zero;
    _pending = _timer(delay, _due);
    _set(AutosaveStatus(AutosavePhase.pending, lastSavedAt: _status.lastSavedAt));
  }

  void _due() {
    _pending = null;
    if (_disposed) return;
    if (_isPaused()) {
      // Skipped while a transaction is open: look again one idle period later.
      _pending = _timer(policy.idle, _due);
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() {
    final running = _saving;
    if (running != null) return running;
    _pending?.cancel();
    _pending = null;
    _firstUnsaved = null;
    _dirtyDuringSave = false;
    savesStarted++;
    _set(AutosaveStatus(AutosavePhase.saving, lastSavedAt: _status.lastSavedAt));
    final f = _saving = () async {
      try {
        await save();
        _set(AutosaveStatus(AutosavePhase.saved, lastSavedAt: _now()));
      } on Object catch (e) {
        _set(AutosaveStatus(AutosavePhase.failed, failure: storeFailureOf(e), lastSavedAt: _status.lastSavedAt));
      } finally {
        _saving = null;
      }
      if (_dirtyDuringSave && !_disposed) {
        _dirtyDuringSave = false;
        request();
      }
    }();
    return f;
  }

  /// Runs a scheduled autosave now (ignoring the pause) and waits for any running save.
  Future<void> flush() async {
    if (_saving != null) await _saving;
    if (_pending != null || _dirtyDuringSave) await _run();
  }

  /// Drops a scheduled autosave (a main save made it unnecessary).
  void cancel() {
    _pending?.cancel();
    _pending = null;
    _firstUnsaved = null;
    _dirtyDuringSave = false;
    if (_saving == null && _status.phase == AutosavePhase.pending) {
      _set(AutosaveStatus(AutosavePhase.idle, lastSavedAt: _status.lastSavedAt));
    }
  }

  /// Stops the scheduler (waits for a running save; a scheduled one is dropped).
  Future<void> dispose() async {
    _disposed = true;
    _pending?.cancel();
    _pending = null;
    if (_saving != null) await _saving;
    await _statuses.close();
  }

  void _set(AutosaveStatus s) {
    if (s == _status) return;
    _status = s;
    if (!_statuses.isClosed) _statuses.add(s);
  }
}
