// OWNER: API-02
//
// PlanSync keeps one PreviewSession's plan in step with the edited project (ARCH §11.8, §13.1):
//
//   schedule(project) ─► compile (≤ 1 in flight, latest wins) ─► diffPlans(acked, new)
//                     ─► session.applyPatch ─► planOutOfSync? ─► session.setPlan(full) once
//                                                               └► fails again ─► PreviewFailed
//
// Rules (normative for UX-08 / ENG-02 / QA-04):
// * **Latest wins.** `schedule` only records the newest project; one compile runs at a time and
//   picks up the newest project when it finishes. A compiled plan whose project was superseded
//   while it compiled is discarded (at most once in a row, so a stream of edits still reaches the
//   screen). 100 schedules during one compile cost at most 2 compiles.
// * **Diff base** is the last plan the engine acknowledged. The first plan, a plan after a
//   failure and a target change are sent whole with `setPlan`. Empty diffs are not sent (the
//   engine keeps its revision; the next patch still starts from it).
// * **Revisions never regress.** Plans carry the project's session-monotonic stamp
//   (`Timeline.revision`; undo/redo take fresh stamps, ARCH §7.3). If a compiled plan's `rev`
//   is not above every revision already sent (a stale project, or two sessions' stamps), PlanSync
//   re-stamps it `maxSentRev + 1`, so `patch.from < patch.to` and acks increase strictly.
// * **Failures.** `planOutOfSync` from `applyPatch` → `setPlan(full)` once; if that fails too (or
//   any other engine failure occurs) the status becomes `failed`, [PlanSync.events] emits
//   `PreviewFailedEvent` and the engine state is treated as unknown: the next `schedule` (or
//   [PlanSync.resync], the "Restart preview" action) sends the full plan again. A compile that
//   throws is reported the same way with `EngineErrorCode.internal`.
// * **Transients** (`sendTransient`, ARCH §11.2 Transient): coalesced to at most one flush per
//   [PlanSync.transientInterval] (60 Hz), last write per item wins. A transient is dropped while
//   the item's last committed change is structural and not yet applied by the engine (from the
//   moment its patch is computed until the engine acks it): the engine is rebuilding that item's
//   layers and the patch drops their transients anyway, so a late transient would override the
//   committed state with gesture state. `dropTransientsFor(item)` (a commit landed) discards the
//   pending transient at once and clears the engine's transient after the commit's plan is
//   applied, so the item never flashes back to its pre-gesture state.

import 'dart:async';
import 'dart:isolate';

import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import 'failures.dart';
import 'preview.dart';

/// What [PlanSync] is doing (ARCH §13.1).
enum PlanSyncStatus {
  /// Nothing scheduled.
  idle,

  /// A compile is running.
  compiling,

  /// A patch or full plan is being applied.
  applying,

  /// The last apply failed twice (the preview shows the last good frame).
  failed,
}

/// Project → preview plan (ARCH §13.1).
typedef PlanCompile = Future<RenderPlan> Function(EditProject project);

/// Time and timers used by [PlanSync]'s transient coalescing (ARCH §11.8, §18.1; injectable for tests).
abstract interface class PlanSyncClock {
  /// Monotonic time since an arbitrary origin.
  Duration now();

  /// A one-shot timer running [callback] after [delay].
  Timer timer(Duration delay, void Function() callback);
}

/// The wall clock: a [Stopwatch] and [Timer] (ARCH §18.1).
final class SystemPlanSyncClock implements PlanSyncClock {
  /// Creates the clock.
  SystemPlanSyncClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  Duration now() => _watch.elapsed;

  @override
  Timer timer(Duration delay, void Function() callback) => Timer(delay, callback);
}

/// Counters for QA timing and tests (ARCH §18.2 "commit → preview").
final class PlanSyncStats {
  /// Compiles started.
  int compiles = 0;

  /// Compiled plans discarded because a newer project was scheduled meanwhile.
  int discarded = 0;

  /// Patches sent with `applyPatch`.
  int patches = 0;

  /// Full plans sent with `setPlan`.
  int fullPlans = 0;

  /// Empty diffs that were not sent.
  int emptyDiffs = 0;

  /// `planOutOfSync` failures recovered with a full plan.
  int outOfSyncRecoveries = 0;

  /// Plans whose `rev` was raised to keep revisions increasing.
  int restamped = 0;

  /// Transients handed to the session.
  int transientsSent = 0;

  /// Transients replaced by a newer one for the same item before a flush.
  int transientsCoalesced = 0;

  /// Transients dropped (structural change pending, or dropped by a commit).
  int transientsDropped = 0;

  /// Transient flushes (each sends the newest transient of every pending item).
  int transientFlushes = 0;
}

/// Keeps a [PreviewSession]'s plan in step with the project (file header; ARCH §13.1, API-02).
class PlanSync {
  /// Creates the sync for [session]; [compile] turns a project into a preview plan (for example a
  /// [PreviewPlanCompiler]). [transientInterval] is the minimum time between transient flushes.
  PlanSync(
    this.session, {
    required this.compile,
    this.transientInterval = const Duration(microseconds: 16667),
    PlanSyncClock? clock,
  }) : _clock = clock ?? SystemPlanSyncClock();

  /// The session being driven.
  final PreviewSession session;

  /// Project → plan (a [PreviewPlanCompiler] runs it in an isolate above 300 items).
  final PlanCompile compile;

  /// Minimum time between two transient flushes (default 1/60 s).
  final Duration transientInterval;

  final PlanSyncClock _clock;
  final StreamController<PlanSyncStatus> _status = StreamController<PlanSyncStatus>.broadcast(sync: true);
  final StreamController<PreviewEvent> _events = StreamController<PreviewEvent>.broadcast(sync: true);

  /// Counters (QA timing, tests).
  final PlanSyncStats stats = PlanSyncStats();

  PlanSyncStatus _current = PlanSyncStatus.idle;
  EditProject? _pending;
  EditProject? _latest;
  bool _running = false;
  bool _disposed = false;
  bool _forceFull = false;
  bool _discardedLast = false;
  RenderPlan? _acked;
  PlanAck? _lastAck;
  EngineFailure? _lastFailure;
  int _maxSentRev = -1;
  final List<Completer<void>> _idleWaiters = [];

  final Map<String, PlanTransient> _pendingTransients = {};
  final Set<String> _structuralPending = {};
  final Set<String> _clearAfterApply = {};
  Timer? _transientTimer;
  Duration? _lastFlush;

  /// Status changes (synchronous broadcast; the current value is [currentStatus]).
  Stream<PlanSyncStatus> get status => _status.stream;

  /// The current status.
  PlanSyncStatus get currentStatus => _current;

  /// `PreviewFailedEvent` when a plan could not be applied after the full-plan retry.
  Stream<PreviewEvent> get events => _events.stream;

  /// The last acknowledged plan revision, structural flag and apply time (UI, QA timing).
  PlanAck? get lastAck => _lastAck;

  /// The plan the engine acknowledged last (the diff base), or null when unknown.
  RenderPlan? get appliedPlan => _acked;

  /// The failure behind the last `failed` status, or null.
  EngineFailure? get lastFailure => _lastFailure;

  /// Whether a compile or apply is running or a project is waiting.
  bool get busy => _running || _pending != null;

  /// Item ids whose structural change is committed but not yet acknowledged (transients for them
  /// are dropped).
  Set<String> get structuralPendingItems => Set.unmodifiable(_structuralPending);

  /// Schedules a compile and apply of [project]; the latest call wins.
  void schedule(EditProject project) {
    if (_disposed) return;
    _pending = project;
    _latest = project;
    if (_running) return;
    _running = true;
    scheduleMicrotask(_pump);
  }

  /// Forgets the engine's state and sends the latest project's full plan ("Restart preview").
  void resync() {
    if (_disposed) return;
    _forceFull = true;
    final p = _latest;
    if (p != null) schedule(p);
  }

  /// Completes when nothing is compiling, applying or scheduled.
  Future<void> flush() {
    if (!busy) return Future.value();
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  Future<void> _pump() async {
    try {
      while (!_disposed) {
        final project = _pending;
        if (project == null) break;
        _pending = null;
        _setStatus(PlanSyncStatus.compiling);
        stats.compiles++;
        RenderPlan plan;
        try {
          plan = await compile(project);
        } catch (e) {
          if (_disposed) break;
          _fail(EngineFailure.of(EngineErrorCode.internal, debugDetail: 'compile failed: ${e.runtimeType}'));
          continue;
        }
        if (_disposed) break;
        if (_pending != null && !_discardedLast) {
          // Superseded while compiling: the newer project wins.
          stats.discarded++;
          _discardedLast = true;
          continue;
        }
        _discardedLast = false;
        _setStatus(PlanSyncStatus.applying);
        await _apply(plan);
      }
    } finally {
      _running = false;
      if (!_disposed) {
        if (_current != PlanSyncStatus.failed) _setStatus(PlanSyncStatus.idle);
        // A schedule() that raced the loop's exit.
        if (_pending != null) {
          _running = true;
          scheduleMicrotask(_pump);
        }
      }
      if (!busy || _disposed) {
        final waiters = List.of(_idleWaiters);
        _idleWaiters.clear();
        for (final w in waiters) {
          w.complete();
        }
      }
    }
  }

  RenderPlan _stamp(RenderPlan plan) {
    if (plan.rev > _maxSentRev) return plan;
    stats.restamped++;
    return plan.copyWith(rev: _maxSentRev + 1);
  }

  Future<void> _apply(RenderPlan compiled) async {
    final base = _acked;
    try {
      if (base == null || _forceFull || base.target != compiled.target) {
        await _sendFull(_stamp(compiled));
        return;
      }
      final plan = _stamp(compiled);
      final patch = diffPlans(base, plan);
      if (isEmptyPatch(patch)) {
        stats.emptyDiffs++;
        if (_current == PlanSyncStatus.failed) _setStatus(PlanSyncStatus.applying);
        return;
      }
      final structuralItems = _structuralItemsOf(base, patch);
      _structuralPending.addAll(structuralItems);
      for (final item in structuralItems) {
        if (_pendingTransients.remove(item) != null) stats.transientsDropped++;
      }
      try {
        _maxSentRev = plan.rev > _maxSentRev ? plan.rev : _maxSentRev;
        stats.patches++;
        final ack = await session.applyPatch(patch);
        if (_disposed) return;
        _acked = plan;
        _ack(ack);
      } on EngineFailure catch (f) {
        if (_disposed) return;
        if (f.code != EngineErrorCode.planOutOfSync) {
          // Patches apply atomically: the engine still holds `base`.
          _fail(f);
          return;
        }
        stats.outOfSyncRecoveries++;
        // The patch was not applied, so its revision is still unused by the engine.
        await _sendFull(plan);
      } finally {
        _structuralPending.removeAll(structuralItems);
      }
    } finally {
      _drainClears();
    }
  }

  Future<void> _sendFull(RenderPlan plan) async {
    _maxSentRev = plan.rev > _maxSentRev ? plan.rev : _maxSentRev;
    stats.fullPlans++;
    try {
      final ack = await session.setPlan(plan);
      if (_disposed) return;
      _acked = plan;
      _forceFull = false;
      _ack(ack);
    } on EngineFailure catch (f) {
      if (_disposed) return;
      _acked = null;
      _fail(f);
    }
  }

  void _ack(PlanAck ack) {
    _lastAck = ack;
    _lastFailure = null;
    if (ack.rev > _maxSentRev) _maxSentRev = ack.rev;
    if (_current == PlanSyncStatus.failed) _setStatus(PlanSyncStatus.applying);
  }

  void _fail(EngineFailure f) {
    _lastFailure = f;
    _setStatus(PlanSyncStatus.failed);
    if (!_events.isClosed) _events.add(PreviewFailedEvent(f));
  }

  void _setStatus(PlanSyncStatus s) {
    if (_current == s) return;
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  /// Items with a structural change in [patch] over [base]: added or removed layers, or layers
  /// whose `kind`, `z`, `t`, `asset`, `map`, `hold` or `seq` changed (ARCH §11.2).
  static Set<String> _structuralItemsOf(RenderPlan base, RenderPlanPatch patch) {
    final out = <String>{};
    for (final id in patch.layers.remove) {
      out.add(PlanIds.itemOf(id));
    }
    if (patch.layers.upsert.isEmpty) return out;
    final old = {for (final l in base.layers) l.id: l};
    for (final l in patch.layers.upsert) {
      final o = old[l.id];
      if (o == null || layerTimingChanged(o, l)) out.add(PlanIds.itemOf(l.id));
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // Transients.

  /// Sends [transient] for [item], coalesced to at most one flush per [transientInterval]
  /// (newest per item wins). Dropped while the item has a structural change in flight.
  void sendTransient(ItemId item, PlanTransient transient) {
    if (_disposed) return;
    if (_structuralPending.contains(item)) {
      stats.transientsDropped++;
      return;
    }
    if (_pendingTransients.containsKey(item)) stats.transientsCoalesced++;
    _pendingTransients[item] = transient;
    if (_transientTimer != null) return;
    final now = _clock.now();
    final last = _lastFlush;
    final since = last == null ? transientInterval : now - last;
    if (since >= transientInterval) {
      _flushTransients();
    } else {
      _transientTimer = _clock.timer(transientInterval - since, _flushTransients);
    }
  }

  void _flushTransients() {
    _transientTimer = null;
    if (_disposed || _pendingTransients.isEmpty) return;
    _lastFlush = _clock.now();
    stats.transientFlushes++;
    final batch = Map.of(_pendingTransients);
    _pendingTransients.clear();
    for (final e in batch.entries) {
      stats.transientsSent++;
      session.setTransient(ItemId(e.key), e.value);
    }
  }

  /// A commit of [item] landed: discards its pending transient now and clears the engine's
  /// transient once the commit's plan is applied (at once when nothing is in flight).
  void dropTransientsFor(ItemId item) {
    if (_disposed) return;
    if (_pendingTransients.remove(item) != null) stats.transientsDropped++;
    if (busy) {
      _clearAfterApply.add(item);
    } else {
      session.clearTransient(item);
    }
  }

  void _drainClears() {
    if (_clearAfterApply.isEmpty || _disposed) return;
    final items = List.of(_clearAfterApply);
    _clearAfterApply.clear();
    for (final i in items) {
      session.clearTransient(ItemId(i));
    }
  }

  /// Stops scheduling and transients (the session itself is owned by the caller).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _transientTimer?.cancel();
    _transientTimer = null;
    _pendingTransients.clear();
    _pending = null;
    final waiters = List.of(_idleWaiters);
    _idleWaiters.clear();
    for (final w in waiters) {
      w.complete();
    }
    await _status.close();
    await _events.close();
  }
}

/// The standard preview compile for [PlanSync] (ARCH §11.1 rule 3, §18.1): memoized
/// [PlanMemo.compile] on the calling isolate, except that a **cold** compile (no memoized
/// compile yet, or after [reset]) of a project with more than [isolateThreshold] items runs a
/// plain standard-stage compile in `Isolate.run`. The memo warms on the next compile; if the
/// project or resolver cannot be sent to an isolate, the compile runs inline.
final class PreviewPlanCompiler {
  /// Creates the compiler. [resolver] resolves the assets of the project being compiled.
  PreviewPlanCompiler({
    required this.resolver,
    PlanMemo? memo,
    this.isolateThreshold = 300,
    this.holdFrame = true,
    this.maxAudioSpeed = defaultMaxAudioSpeed,
  }) : memo = memo ?? PlanMemo();

  /// Asset resolver for a project.
  final PlanAssetResolver Function(EditProject project) resolver;

  /// The session memo (one per session).
  final PlanMemo memo;

  /// Item count above which a cold compile runs in an isolate.
  final int isolateThreshold;

  /// `capabilities.holdFrame`.
  final bool holdFrame;

  /// Audio speed limit of the engine (`defaultMaxAudioSpeed`).
  final double maxAudioSpeed;

  bool _warm = false;

  /// Compiles run in an isolate so far.
  int isolateCompiles = 0;

  /// Item count of [project] (all lanes).
  static int itemCountOf(EditProject project) {
    var n = 0;
    for (final t in project.tracks) {
      n += t.items.length;
    }
    return n;
  }

  /// Drops the memo (cache trim); the next large compile runs in an isolate again.
  void reset() {
    memo.clear();
    _warm = false;
  }

  /// The preview plan of [project].
  Future<RenderPlan> call(EditProject project) async {
    final r = resolver(project);
    if (!_warm && itemCountOf(project) > isolateThreshold) {
      final hold = holdFrame;
      final speed = maxAudioSpeed;
      try {
        final plan = await Isolate.run(
          () => compilePlan(
            project,
            PlanTarget.preview,
            r,
            options: CompileOptions(holdFrame: hold, stages: standardLoweringStages(maxAudioSpeed: speed)),
          ).plan,
          debugName: 'vwish.plan.compile',
        );
        isolateCompiles++;
        _warm = true;
        return plan;
      } on ArgumentError {
        // Not sendable (a resolver holding a port or closure): compile inline.
      }
    }
    final plan = memo.compile(project, PlanTarget.preview, r, base: CompileOptions(holdFrame: holdFrame), maxAudioSpeed: maxAudioSpeed).plan;
    _warm = true;
    return plan;
  }
}
