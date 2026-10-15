// OWNER: UX-44
//
// RenderPreviewController (ARCH D-45(A), §17.5, §17.10; owner decision 2026-10-11, D-43(e) point 4):
// the editor side of the render-preview cache.
//
// What it does
// * After every applied preview plan ([planChanged]) it computes the range coverage with CORE-37
//   (`coverage`: rendered / heavyUnrendered / notNeeded per range), cancels a running render whose
//   range the edit touched (its hash is gone), drops queued ranges that no longer exist, and sends
//   `PreviewSession.setRenderedRanges` with only the ranges whose current hash has a file in the
//   index. The engine already dropped every rendered range the applied patch touched (INT-06
//   contract), so a stale render never plays; this resend restores the untouched ones (setPlan
//   drops them all) at their new positions (hashes ignore absolute time, so a ripple keeps them).
// * Automatic renders (Auto setting on the minimal and low tiers, `RenderPolicy.shouldAutoRender`):
//   only while the editor is idle (no playback, edit or other job for 5 s, its own timer) and the
//   device is charging (the engine's power signal, `background.powerState` /
//   `powerStateChanged`). One render at a time at `JobPriority.background`, heavy ranges in time
//   order; a range whose render failed is not retried automatically this session.
// * The manual "Render preview" action ([render]) works on every tier: one marker range, the
//   selection's span, the loop range or the whole timeline. An explicit span renders every
//   unrendered range in it; the whole timeline renders the ranges that need it (heavy ones).
//   Manual renders run at `JobPriority.normal`, ahead of automatic ones, and do not need idle or
//   charging.
// * A running render is cancelled when playback starts, an edit touches its range, an export
//   starts or memory runs low. Playback and export put a manual render back at the head of the
//   queue (it resumes when they end); memory pressure also trims the index and empties the queue.
// * Results go into the cache index (`put` moves `<hash>.partial.mp4` to `<hash>.mp4`), then the
//   coverage is recomputed and the rendered ranges are resent.
// * [clearRendered] cancels everything and empties `renders/` ("Clear rendered previews"; the
//   "Editor cache" contributor clears the same folder).
//
// Until IOS-19 and AND-18 fill the native side, the engine answers `notSupportedOnDevice`; the
// controller then stops rendering for the session ([RenderPreviewState.unsupported]) and preview
// stays live. Without a store ([renderPreviewStoreProvider] not overridden) nothing renders either.
//
// The pure part (`rangePlanOf`, cutting a preview plan to one range with times relative to its
// start, as `MediaJobs.renderPreview` expects) is public for tests.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_core/store.dart' show StoreFailure;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../app/editor_providers.dart';
import '../../app/editor_tier_defaults.dart';
import '../../app/strings/render_preview_strings.dart';
import '../flows/export/export_state.dart';

export '../../app/strings/render_preview_strings.dart' show RenderTargetKind;

// =============================================================================================
// Store port
// =============================================================================================

/// The render-preview cache as the controller sees it: CORE-37's `RenderCacheIndex` in the app
/// ([IndexRenderPreviewStore]).
///
/// See ARCH D-45(A), §17.10.
abstract interface class RenderPreviewStore implements RenderCacheLookup {
  /// Loads (or repairs) the index; safe to call again.
  Future<void> open();

  /// Final file of [hash] (`renders/<hash>.mp4`).
  String pathFor(String hash);

  /// Where the renderer writes [hash] (`renders/<hash>.partial.mp4`).
  String stagingPathFor(String hash);

  /// Records the rendered file of [hash] (moving it into place) and evicts to the LRU bound.
  Future<void> put(String hash, String renderedFile);

  /// Evicts under memory pressure or low disk.
  Future<void> trim(RenderCacheTrimLevel level);

  /// Removes every render-preview file.
  Future<void> clear();

  /// Bytes inside `renders/`.
  Future<int> bytes();
}

/// [RenderPreviewStore] over CORE-37's [RenderCacheIndex].
///
/// See ARCH D-45(A).
final class IndexRenderPreviewStore implements RenderPreviewStore {
  /// Wraps [index].
  IndexRenderPreviewStore(this.index);

  /// The index.
  final RenderCacheIndex index;

  @override
  bool contains(String hash) => index.isOpen && index.contains(hash);

  @override
  Future<void> open() => index.open();

  @override
  String pathFor(String hash) => index.pathFor(hash);

  @override
  String stagingPathFor(String hash) => index.stagingPathFor(hash);

  @override
  Future<void> put(String hash, String renderedFile) => index.put(hash, renderedFile);

  @override
  Future<void> trim(RenderCacheTrimLevel level) => index.trim(level);

  @override
  Future<void> clear() => index.clear();

  @override
  Future<int> bytes() => index.bytes();
}

final class _NoRenders implements RenderCacheLookup {
  const _NoRenders();

  @override
  bool contains(String hash) => false;
}

// =============================================================================================
// State
// =============================================================================================

/// The render running now.
///
/// See ARCH D-45(A).
@immutable
final class RenderJobInfo {
  /// Creates the info.
  const RenderJobInfo({required this.range, required this.hash, required this.manual, this.progress});

  /// Plan range being rendered.
  final PlanRange range;

  /// Its range hash.
  final String hash;

  /// Started by the "Render preview" action (else automatic).
  final bool manual;

  /// Progress 0..1, null before the first report.
  final double? progress;

  /// A copy with [progress].
  RenderJobInfo withProgress(double? progress) => RenderJobInfo(range: range, hash: hash, manual: manual, progress: progress);

  @override
  bool operator ==(Object other) =>
      other is RenderJobInfo && other.range == range && other.hash == hash && other.manual == manual && other.progress == progress;

  @override
  int get hashCode => Object.hash(range, hash, manual, progress);
}

/// What the render marker and the action show.
///
/// See ARCH D-45(A), §17.5.
@immutable
final class RenderPreviewState {
  /// Creates a state.
  const RenderPreviewState({
    this.ranges = const [],
    this.setting = RenderPreviewSetting.manual,
    this.active,
    this.queued = const [],
    this.available = false,
    this.unsupported = false,
    this.suspended = false,
  });

  /// One status per range of the current preview plan, in time order.
  final List<RangeStatus> ranges;

  /// The effective `editor.renderPreview` setting.
  final RenderPreviewSetting setting;

  /// The render running now.
  final RenderJobInfo? active;

  /// Hashes waiting for a manual render, in order.
  final List<String> queued;

  /// Whether a cache store exists (rendering is possible in principle).
  final bool available;

  /// The engine reported `notSupportedOnDevice`; preview stays live for this session.
  final bool unsupported;

  /// Playback or an export holds rendering back.
  final bool suspended;

  /// Whether anything renders or waits to render.
  bool get busy => active != null || queued.isNotEmpty;

  /// Ranges that are heavy and not rendered.
  Iterable<RangeStatus> get heavyUnrendered => ranges.where((r) => r.state == RangeState.heavyUnrendered);

  /// Whether [hash] is rendering or queued.
  bool isPending(String hash) => active?.hash == hash || queued.contains(hash);

  @override
  bool operator ==(Object other) =>
      other is RenderPreviewState &&
      listEquals(other.ranges, ranges) &&
      other.setting == setting &&
      other.active == active &&
      listEquals(other.queued, queued) &&
      other.available == available &&
      other.unsupported == unsupported &&
      other.suspended == suspended;

  @override
  int get hashCode => Object.hash(Object.hashAll(ranges), setting, active, Object.hashAll(queued), available, unsupported, suspended);
}

/// What the manual action asks for.
///
/// See ARCH §17.5.
@immutable
final class RenderTarget {
  const RenderTarget._(this.kind, this.span);

  /// One range of the render marker.
  const RenderTarget.range(TimeRange span) : this._(RenderTargetKind.range, span);

  /// The selected items' span.
  const RenderTarget.selection(TimeRange span) : this._(RenderTargetKind.selection, span);

  /// The loop range.
  const RenderTarget.loop(TimeRange span) : this._(RenderTargetKind.loop, span);

  /// The whole timeline (the ranges that need rendering).
  const RenderTarget.timeline() : this._(RenderTargetKind.timeline, null);

  /// What kind of target.
  final RenderTargetKind kind;

  /// Plan time span; null for the whole timeline.
  final TimeRange? span;

  @override
  bool operator ==(Object other) => other is RenderTarget && other.kind == kind && other.span == span;

  @override
  int get hashCode => Object.hash(kind, span);

  @override
  String toString() => 'RenderTarget(${kind.name}${span == null ? '' : ' ${span!.start}..${span!.end}'})';
}

/// Result of [RenderPreviewController.render].
///
/// See ARCH §17.5.
enum RenderRequestOutcome {
  /// Rendering started (or joined the queue behind a running render).
  started,

  /// Queued; it starts when playback stops.
  waitingForPause,

  /// Everything in the target is already rendered.
  alreadyRendered,

  /// The timeline (or the target) has nothing to render.
  nothingToRender,

  /// No cache on this device, or the preview is not ready.
  unavailable,

  /// The engine cannot render previews on this device yet.
  unsupported,

  /// An export is running.
  exportRunning,
}

/// Things the UI tells the user about (toasts).
///
/// See ARCH §17.5.
enum RenderPreviewNotice {
  /// Every manual render of a request finished.
  done,

  /// A manual render failed.
  failed,

  /// The engine cannot render previews on this device.
  unsupported,

  /// Rendered previews were cleared.
  cleared,
}

// =============================================================================================
// Controller
// =============================================================================================

final class _Task {
  _Task(this.range, this.hash, {required this.manual});

  PlanRange range;
  final String hash;
  final bool manual;
}

/// The render-preview controller (file header).
///
/// See ARCH D-45(A), §17.5.
class RenderPreviewController extends ValueNotifier<RenderPreviewState> {
  /// Creates the controller. [store] null means no cache (nothing renders). [setting] returns
  /// the effective `editor.renderPreview` value ([EditorTierDefaults.effectiveRenderPreview]).
  /// [previewSize] is the preview render size the hashes include (null: the canvas size).
  RenderPreviewController({
    required MediaJobs jobs,
    required BackgroundWorkGuard power,
    required RenderPreviewStore? store,
    required RenderTier tier,
    required RenderBudget budget,
    required RenderPreviewSetting Function() setting,
    this.previewSize,
    Duration idleAfter = RenderPolicy.idleAfter,
  })  : _jobs = jobs,
        _power = power,
        _store = store,
        _tier = tier,
        _budget = budget,
        _setting = setting,
        _idleAfter = idleAfter,
        super(RenderPreviewState(setting: setting(), available: store != null)) {
    _powerSub = _power.powerStateChanged.listen(_onPower, onError: (Object _) {});
    unawaited(_readPower());
    _markActivity();
  }

  final MediaJobs _jobs;
  final BackgroundWorkGuard _power;
  final RenderPreviewStore? _store;
  RenderTier _tier;
  RenderBudget _budget;
  final RenderPreviewSetting Function() _setting;
  final Duration _idleAfter;

  /// Preview render size included in the hashes (null: canvas size).
  final RenderSize? previewSize;

  final StreamController<RenderPreviewNotice> _notices = StreamController<RenderPreviewNotice>.broadcast();
  StreamSubscription<PowerState>? _powerSub;

  PreviewSession? _session;
  RenderPlan? _plan;
  List<RangeStatus> _ranges = const [];
  final List<_Task> _queue = [];
  _Task? _activeTask;
  MediaJob<GeneratedAsset>? _activeJob;
  double? _activeProgress;
  final Set<String> _failed = {};
  bool _manualBatch = false;
  bool _manualBatchFailed = false;

  bool _playing = false;
  bool _exporting = false;
  bool _idle = false;
  bool _charging = false;
  bool _unsupported = false;
  Timer? _idleTimer;
  Future<bool>? _opened;
  bool _disposed = false;
  Future<void> _sendTail = Future<void>.value();

  /// Toast-worthy events.
  Stream<RenderPreviewNotice> get notices => _notices.stream;

  /// The current preview plan (null before the first).
  RenderPlan? get plan => _plan;

  /// Device tier.
  RenderTier get tier => _tier;

  /// The live budget.
  RenderBudget get budget => _budget;

  /// Whether the editor counts as idle now (no playback, edit or job for 5 s).
  bool get isIdle => _idle;

  /// Whether the device reported charging.
  bool get isCharging => _charging;

  /// The store (null: no cache).
  RenderPreviewStore? get store => _store;

  // ---- Inputs -----------------------------------------------------------------------------

  /// The preview session that plays rendered ranges (null while the preview is closed).
  void attach(PreviewSession? session) {
    if (identical(session, _session)) return;
    _session = session;
    if (session != null) unawaited(_send());
  }

  /// Device tier or budget changed (capabilities arrived).
  void configure({required RenderTier tier, required RenderBudget budget}) {
    if (tier == _tier && budget == _budget) return;
    _tier = tier;
    _budget = budget;
    if (_plan != null) _recompute();
    _pump();
  }

  /// A new preview plan was applied to the session (after every edit and on open).
  Future<void> planChanged(RenderPlan plan) async {
    if (_disposed) return;
    final first = _plan == null;
    _plan = plan;
    if (!first) _markActivity();
    await _ensureOpen();
    if (_disposed || !identical(_plan, plan)) return;
    _recompute();
    final current = {for (final r in _ranges) r.hash: r.range};
    final active = _activeTask;
    if (active != null && !current.containsKey(active.hash)) _cancelActive(requeue: false);
    _queue.removeWhere((t) => !current.containsKey(t.hash));
    for (final t in _queue) {
      t.range = current[t.hash]!;
    }
    final running = _activeTask;
    if (running != null) running.range = current[running.hash]!;
    _emit();
    await _send();
    _pump();
  }

  /// Playback started or stopped.
  void playingChanged(bool playing) {
    if (_disposed || playing == _playing) return;
    _playing = playing;
    if (playing) {
      _idle = false;
      _idleTimer?.cancel();
      _cancelActive(requeue: true);
      _emit();
    } else {
      _markActivity();
      _emit();
      _pump();
    }
  }

  /// An export started or ended.
  void exportChanged(bool running) {
    if (_disposed || running == _exporting) return;
    _exporting = running;
    if (running) {
      _cancelActive(requeue: true);
      _emit();
    } else {
      _markActivity();
      _emit();
      _pump();
    }
  }

  /// Memory is low: cancel, forget the queue and trim the cache.
  Future<void> memoryPressure() async {
    if (_disposed) return;
    _cancelActive(requeue: false);
    _queue.clear();
    _endBatch();
    _emit();
    final store = _store;
    if (store != null && await _ensureOpen()) {
      try {
        await store.trim(RenderCacheTrimLevel.memoryPressure);
      } on Object catch (e) {
        debugPrint('[RenderPreview] trim failed: ${e.runtimeType}');
      }
    }
    if (_disposed) return;
    _recompute();
    _emit();
    await _send();
  }

  /// Another job ran (proxies, thumbnails, reverse…): the editor is not idle.
  void jobActivity() {
    if (_disposed) return;
    _markActivity();
  }

  /// The `editor.renderPreview` preference changed.
  void settingChanged() {
    if (_disposed) return;
    final setting = _setting();
    final task = _activeTask;
    if (task != null && !task.manual && !RenderPolicy.shouldAutoRender(_tier, setting, idle: true, charging: true)) {
      _cancelActive(requeue: false);
    }
    _emit();
    _pump();
  }

  // ---- Manual action ----------------------------------------------------------------------

  /// Whether the manual action can run now (and why not).
  RenderRequestOutcome? get blockedReason {
    if (_store == null) return RenderRequestOutcome.unavailable;
    if (_unsupported) return RenderRequestOutcome.unsupported;
    if (_plan == null) return RenderRequestOutcome.unavailable;
    if (_ranges.isEmpty) return RenderRequestOutcome.nothingToRender;
    if (_exporting) return RenderRequestOutcome.exportRunning;
    return null;
  }

  /// Renders [target] ("Render preview"; every tier, `RenderPolicy.manualRenderAllowed`).
  Future<RenderRequestOutcome> render(RenderTarget target) async {
    if (_disposed) return RenderRequestOutcome.unavailable;
    if (_store == null) return RenderRequestOutcome.unavailable;
    if (_unsupported) return RenderRequestOutcome.unsupported;
    if (_plan == null || !RenderPolicy.manualRenderAllowed(_tier)) return RenderRequestOutcome.unavailable;
    if (!await _ensureOpen()) return RenderRequestOutcome.unavailable;
    if (_disposed) return RenderRequestOutcome.unavailable;
    if (_ranges.isEmpty) return RenderRequestOutcome.nothingToRender;
    if (_exporting) return RenderRequestOutcome.exportRunning;
    final span = target.span;
    final inSpan = [
      for (final r in _ranges)
        if (span == null || r.range.overlapsSpan(span.start, span.end)) r,
    ];
    if (inSpan.isEmpty) return RenderRequestOutcome.nothingToRender;
    final wanted = [
      for (final r in inSpan)
        if (r.state != RangeState.rendered && (span != null || r.state == RangeState.heavyUnrendered)) r,
    ];
    final fresh = [for (final r in wanted) if (!_isPending(r.hash)) r];
    if (wanted.isEmpty) {
      return span == null && inSpan.every((r) => r.state == RangeState.notNeeded)
          ? RenderRequestOutcome.nothingToRender
          : RenderRequestOutcome.alreadyRendered;
    }
    // Heavy ranges first, then the rest, each in time order.
    fresh.sort((a, b) {
      final h = (b.isHeavy ? 1 : 0).compareTo(a.isHeavy ? 1 : 0);
      return h != 0 ? h : a.range.start.compareTo(b.range.start);
    });
    for (final r in fresh) {
      _failed.remove(r.hash);
      _queue.add(_Task(r.range, r.hash, manual: true));
    }
    // An automatic render gives way to the user's request.
    final active = _activeTask;
    if (active != null && !active.manual) _cancelActive(requeue: false);
    _manualBatch = true;
    _emit();
    if (_playing) return RenderRequestOutcome.waitingForPause;
    _pump();
    return RenderRequestOutcome.started;
  }

  /// "Clear rendered previews": cancels everything and empties `renders/`.
  Future<void> clearRendered() async {
    if (_disposed) return;
    _cancelActive(requeue: false);
    _queue.clear();
    _endBatch();
    _failed.clear();
    final store = _store;
    if (store != null) {
      await _ensureOpen();
      await store.clear();
    }
    if (_disposed) return;
    _recompute();
    _emit();
    await _send();
    _notify(RenderPreviewNotice.cleared);
  }

  /// Bytes of rendered previews (0 without a store).
  Future<int> renderedBytes() async {
    final store = _store;
    if (store == null) return 0;
    try {
      return await store.bytes();
    } on Object {
      return 0;
    }
  }

  // ---- Internals --------------------------------------------------------------------------

  bool _isPending(String hash) => _activeTask?.hash == hash || _queue.any((t) => t.hash == hash);

  Future<bool> _ensureOpen() {
    final store = _store;
    if (store == null) return Future.value(false);
    return _opened ??= store.open().then((_) => true, onError: (Object e) {
      debugPrint('[RenderPreview] cache index could not open: ${e.runtimeType}');
      return false;
    });
  }

  void _recompute() {
    final plan = _plan;
    if (plan == null) {
      _ranges = const [];
      return;
    }
    final store = _store;
    _ranges = coverage(plan, store ?? const _NoRenders(), _budget, previewSize: previewSize);
  }

  Future<void> _readPower() async {
    try {
      final state = await _power.powerState();
      _onPower(state);
    } on Object {
      // No power signal (unsupported device): treat as not charging.
    }
  }

  void _onPower(PowerState state) {
    if (_disposed) return;
    _charging = state.charging;
    _pump();
  }

  void _markActivity() {
    _idle = false;
    _idleTimer?.cancel();
    if (_disposed || _playing) return;
    _idleTimer = Timer(_idleAfter, () {
      if (_disposed || _playing) return;
      _idle = true;
      _pump();
    });
  }

  void _cancelActive({required bool requeue}) {
    final task = _activeTask;
    final job = _activeJob;
    if (task == null || job == null) return;
    _activeTask = null;
    _activeJob = null;
    _activeProgress = null;
    if (requeue && task.manual) _queue.insert(0, task);
    job.cancel();
  }

  void _endBatch() {
    _manualBatch = false;
    _manualBatchFailed = false;
  }

  void _pump() {
    if (_disposed || _activeTask != null || _plan == null || _store == null || _unsupported) return;
    if (_playing || _exporting) return;
    final opened = _opened;
    if (opened == null) {
      unawaited(_ensureOpen().then((_) => _pump()));
      return;
    }
    _Task? next;
    if (_queue.isNotEmpty) {
      next = _queue.removeAt(0);
    } else {
      if (_manualBatch) {
        final failed = _manualBatchFailed;
        _endBatch();
        _notify(failed ? RenderPreviewNotice.failed : RenderPreviewNotice.done);
      }
      if (RenderPolicy.shouldAutoRender(_tier, _setting(), idle: _idle, charging: _charging)) {
        for (final r in _ranges) {
          if (r.state == RangeState.heavyUnrendered && !_failed.contains(r.hash)) {
            next = _Task(r.range, r.hash, manual: false);
            break;
          }
        }
      }
    }
    if (next == null) {
      _emit();
      return;
    }
    _start(next);
  }

  void _start(_Task task) {
    final plan = _plan!;
    final store = _store!;
    RenderPlan rangePlan;
    try {
      rangePlan = rangePlanOf(plan, task.range);
    } on Object catch (e) {
      debugPrint('[RenderPreview] could not cut the range plan: ${e.runtimeType}');
      _failed.add(task.hash);
      if (task.manual) _manualBatchFailed = true;
      scheduleMicrotask(_pump);
      return;
    }
    final MediaJob<GeneratedAsset> job;
    try {
      job = _jobs.renderPreview(rangePlan, outputPath: store.stagingPathFor(task.hash));
    } on Object catch (e) {
      _onFailure(task, e);
      scheduleMicrotask(_pump);
      return;
    }
    job.setPriority(task.manual ? JobPriority.normal : JobPriority.background);
    _activeTask = task;
    _activeJob = job;
    _activeProgress = null;
    _emit();
    unawaited(_run(task, job));
  }

  Future<void> _run(_Task task, MediaJob<GeneratedAsset> job) async {
    final sub = job.progress.listen((p) {
      if (!identical(_activeJob, job) || _disposed) return;
      _activeProgress = p;
      _emit();
    }, onError: (Object _) {});
    var stored = false;
    try {
      final asset = await job.result;
      if (_disposed) return;
      await _store!.put(task.hash, asset.path);
      stored = true;
    } on EngineCancelled {
      // Cancelled by playback, an edit, an export, memory pressure or the user.
    } on Object catch (e) {
      if (!_disposed) _onFailure(task, e);
    } finally {
      unawaited(sub.cancel());
    }
    if (_disposed) return;
    if (identical(_activeJob, job)) {
      _activeTask = null;
      _activeJob = null;
      _activeProgress = null;
    }
    if (stored) {
      _recompute();
      _emit();
      await _send();
    }
    _pump();
  }

  void _onFailure(_Task task, Object error) {
    if (error is EngineFailure && error.code == EngineErrorCode.notSupportedOnDevice) {
      final first = !_unsupported;
      _unsupported = true;
      _queue.clear();
      _endBatch();
      if (first && task.manual) _notify(RenderPreviewNotice.unsupported);
      _emit();
      return;
    }
    if (error is! EngineFailure && error is! StoreFailure) {
      debugPrint('[RenderPreview] render failed: ${error.runtimeType}');
    }
    _failed.add(task.hash);
    if (task.manual) _manualBatchFailed = true;
  }

  /// Sends the rendered ranges of the current plan (serialized; the last call wins).
  Future<void> _send() {
    final run = _sendTail.then((_) => _sendNow());
    _sendTail = run.catchError((Object _) {});
    return _sendTail;
  }

  Future<void> _sendNow() async {
    final session = _session;
    final store = _store;
    if (_disposed || session == null || store == null || _plan == null) return;
    final ranges = [
      for (final r in _ranges)
        if (r.state == RangeState.rendered) RenderedRange(range: r.range.range, uri: Uri.file(store.pathFor(r.hash)).toString(), hash: r.hash),
    ];
    try {
      await session.setRenderedRanges(ranges);
    } on EngineFailure catch (e) {
      if (e.code == EngineErrorCode.notSupportedOnDevice) {
        _unsupported = true;
        _emit();
      } else {
        debugPrint('[RenderPreview] setRenderedRanges refused: ${e.code.name}');
      }
    }
  }

  void _notify(RenderPreviewNotice notice) {
    if (!_disposed) _notices.add(notice);
  }

  void _emit() {
    if (_disposed) return;
    final task = _activeTask;
    value = RenderPreviewState(
      ranges: List.unmodifiable(_ranges),
      setting: _setting(),
      active: task == null ? null : RenderJobInfo(range: task.range, hash: task.hash, manual: task.manual, progress: _activeProgress),
      queued: List.unmodifiable([for (final t in _queue) t.hash]),
      available: _store != null,
      unsupported: _unsupported,
      suspended: _playing || _exporting,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _cancelActive(requeue: false);
    _disposed = true;
    _idleTimer?.cancel();
    unawaited(_powerSub?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}

// =============================================================================================
// Range plans (pure)
// =============================================================================================

/// [plan] cut to [range] with times relative to its start, as `MediaJobs.renderPreview` expects
/// (ARCH D-45, §12.3): the layers overlapping the range clipped to it (maps, keyframes and canvas
/// masks included), the assets they use, no audio (renders are video only; audio plays live) and
/// `durUs` = the range length. Edges are re-timed on the plan's frame grid (frame k of the plan
/// becomes frame k − k0), so the result is a valid preview plan.
RenderPlan rangePlanOf(RenderPlan plan, PlanRange range) {
  final grid = plan.canvas.gridRate;
  final a = range.start;
  final b = math.min(range.end, plan.durUs);
  if (b <= a) throw ArgumentError.value(range, 'range', 'outside the plan');
  final k0 = grid.frameIndexOf(a);
  TimeUs rel(TimeUs t) => grid.timeOfFrame(grid.frameIndexOf(t) - k0);
  final layers = <PlanLayer>[];
  final assetIds = <String>{};
  for (final l in plan.layers) {
    if (!(l.t0 < b && a < l.t1)) continue;
    final t0 = math.max(l.t0, a);
    final t1 = math.min(l.t1, b);
    final rt0 = rel(t0);
    final rt1 = rel(t1);
    if (rt1 <= rt0) continue;
    List<MapSegment> map = const [];
    if (l.kind == PlanLayerKind.media && l.map.isNotEmpty) {
      map = l.hold ? _holdMap(l.map.first.s0, rt0, rt1) : _clipMap(l.map, t0, t1, rel);
    }
    if (l.asset case final id?) assetIds.add(id);
    if (l.fx.lut case final lut?) assetIds.add(lut.asset);
    layers.add(PlanLayer(
      id: l.id,
      z: l.z,
      seq: l.seq,
      t0: rt0,
      t1: rt1,
      kind: l.kind,
      asset: l.asset,
      map: map,
      hold: l.hold,
      color: l.color,
      base: l.base,
      crop: l.crop,
      xf: l.xf,
      fx: l.fx,
      anim: _clipAnim(l.anim, t0, t1, a, rt0, rt1),
      cmasks: [
        for (final m in l.cmasks)
          CanvasMask(cx: m.cx, cy: m.cy, w: m.w, h: m.h, r: m.r, feather: m.feather, inv: m.inv, anim: _clipAnim(m.anim, t0, t1, a, rt0, rt1)),
      ],
    ));
  }
  layers.sort((x, y) {
    final z = x.z.compareTo(y.z);
    if (z != 0) return z;
    final t = x.t0.compareTo(y.t0);
    return t != 0 ? t : x.id.compareTo(y.id);
  });
  return RenderPlan(
    v: plan.v,
    rev: plan.rev,
    target: PlanTarget.preview,
    canvas: plan.canvas,
    durUs: rel(b),
    assets: {
      for (final id in assetIds)
        if (plan.assets[id] case final asset?) id: asset,
    },
    layers: layers,
  );
}

List<MapSegment> _holdMap(TimeUs s0, TimeUs rt0, TimeUs rt1) => [MapSegment(rt0, rt1, s0, s0 + (rt1 - rt0))];

List<MapSegment> _clipMap(List<MapSegment> map, TimeUs t0, TimeUs t1, TimeUs Function(TimeUs) rel) {
  final out = <MapSegment>[];
  for (final s in map) {
    if (!(s.t0 < t1 && t0 < s.t1)) continue;
    final c0 = math.max(s.t0, t0);
    final c1 = math.min(s.t1, t1);
    final r0 = rel(c0);
    final r1 = rel(c1);
    if (r1 <= r0) continue;
    TimeUs src(TimeUs t) => s.s0 + ((t - s.t0) * (s.s1 - s.s0) / (s.t1 - s.t0)).round();
    final a = src(c0);
    final z = math.max(a, src(c1));
    out.add(MapSegment(r0, r1, a, z));
  }
  return out;
}

Map<String, List<AnimKey>> _clipAnim(Map<String, List<AnimKey>> anim, TimeUs t0, TimeUs t1, TimeUs a, TimeUs rt0, TimeUs rt1) {
  if (anim.isEmpty) return const {};
  final out = <String, List<AnimKey>>{};
  for (final e in anim.entries) {
    final keys = e.value;
    if (keys.isEmpty) continue;
    final clipped = <AnimKey>[AnimKey(rt0, evaluateAnimKeys(keys, t0))];
    for (final k in keys) {
      final t = k.tUs - a;
      if (k.tUs > t0 && k.tUs < t1 && t > rt0 && t < rt1) clipped.add(AnimKey(t, k.v));
    }
    clipped.add(AnimKey(rt1, evaluateAnimKeys(keys, t1)));
    out[e.key] = clipped;
  }
  return out;
}

// =============================================================================================
// Providers
// =============================================================================================

/// The render-preview cache of this device: `IndexRenderPreviewStore(RenderCacheIndex(...))`
/// over the editor roots, overridden by the app's editor bootstrap. Null (the default) means no
/// cache: nothing renders and preview stays live.
///
/// See ARCH D-45(A), §17.3.
final renderPreviewStoreProvider = Provider<RenderPreviewStore?>((ref) => null, name: 'renderPreviewStoreProvider');

/// The live budget of this device (from `EditorCapabilities`; mid-tier defaults until known).
RenderBudget renderBudgetOf(EditorCapabilities? caps, {TargetPlatform? platform}) {
  final tier = caps == null ? RenderTier.mid : EditorTierDefaults.renderTierOf(caps.tier);
  if (caps == null) return RenderBudget.forTier(tier);
  final android = (platform ?? defaultTargetPlatform) == TargetPlatform.android;
  return RenderBudget.forTier(
    tier,
    maxConcurrentVideoLayers: caps.maxConcurrentVideoLayers > 0 ? caps.maxConcurrentVideoLayers : null,
    maxVisualSequences: android && caps.maxVisualSequences > 0 ? caps.maxVisualSequences : null,
  );
}

/// The render-preview controller of a project, wired to the session's plan sync, the transport,
/// the export flow, engine signals and the `editor.renderPreview` preference.
///
/// See ARCH D-45(A), §17.3.
final renderPreviewControllerProvider = Provider.autoDispose.family<RenderPreviewController, ProjectId>((ref, id) {
  final engine = ref.watch(editorEngineProvider);
  final prefs = ref.watch(editorPrefsProvider);
  final store = ref.watch(renderPreviewStoreProvider);
  final session = ref.watch(editorSessionProvider(id));
  final defaults = ref.read(editorTierDefaultsProvider);
  final controller = RenderPreviewController(
    jobs: engine.jobs,
    power: engine.background,
    store: store,
    tier: defaults.renderTier,
    budget: renderBudgetOf(ref.read(editorCapabilitiesProvider).valueOrNull),
    setting: () => ref.read(editorTierDefaultsProvider).effectiveRenderPreview(prefs),
  );

  // Capabilities (tier and budget) may arrive after the controller.
  ref.listen<EditorTierDefaults>(editorTierDefaultsProvider, (_, next) {
    controller
      ..configure(tier: next.renderTier, budget: renderBudgetOf(ref.read(editorCapabilitiesProvider).valueOrNull))
      ..settingChanged();
  });

  void onPrefs() => controller.settingChanged();
  prefs.addListener(onPrefs);

  // Plans: every applied plan of the session's PlanSync.
  StreamSubscription<PlanSyncStatus>? statusSub;
  PlanSync? wired;
  RenderPlan? lastPlan;
  void offerPlan() {
    final plan = wired?.appliedPlan;
    if (plan == null || identical(plan, lastPlan)) return;
    lastPlan = plan;
    unawaited(controller.planChanged(plan));
  }

  void wire() {
    final sync = session.isOpen ? session.planSync : null;
    controller.attach(session.isOpen ? session.preview : null);
    if (identical(sync, wired)) return;
    unawaited(statusSub?.cancel());
    statusSub = null;
    wired = sync;
    lastPlan = null;
    if (sync == null) return;
    statusSub = sync.status.listen((status) {
      if (status == PlanSyncStatus.idle) {
        controller.attach(session.preview);
        offerPlan();
      }
    });
    offerPlan();
  }

  session.attached.addListener(wire);
  wire();

  // Playback.
  final transport = ref.watch(transportProvider(id));
  void onPlaying() => controller.playingChanged(transport.playing.value);
  transport.playing.addListener(onPlaying);
  onPlaying();

  // Export.
  ref.listen<ExportUiState>(exportControllerProvider(id), (_, next) {
    controller.exportChanged(next is ExportUiPreparing || next is ExportUiRunning || next is ExportUiCancelling);
  });

  // Other jobs keep the editor busy.
  ref.listen(editorControllerProvider(id).select((s) => s.tasks), (_, next) {
    if (next.isNotEmpty) controller.jobActivity();
  });

  // Memory pressure.
  final signals = engine.signals.listen((signal) {
    if (signal is MemoryWarningSignal) unawaited(controller.memoryPressure());
  }, onError: (Object _) {});

  ref.onDispose(() {
    prefs.removeListener(onPrefs);
    session.attached.removeListener(wire);
    transport.playing.removeListener(onPlaying);
    unawaited(statusSub?.cancel());
    unawaited(signals.cancel());
    controller.dispose();
  });
  return controller;
}, name: 'renderPreviewControllerProvider');
