// OWNER: UX-08
//
// EditorController: the editor's mutation and lifecycle API (ARCH §17.3, ux.md §16.3-16.5).
//
//   apply(cmd) ─► EditSession.apply ─► rejected? info toast + haptic (ARCH §19 rule 4)
//                                    └► committed: state (project, history, save: edited)
//                                                  PlanSync.schedule(project)   (one patch)
//                                                  repository.requestAutosave   (one request)
//                                                  events (EditorCommitted, notice toasts)
//
// * Transactions (gestures): `beginTransaction` wraps core `SessionTransaction`; updates emit
//   state at most once per frame (EditorFrameScheduler) and send param-only transients through
//   PlanSync (≤ 60 Hz); commit = one history entry + one patch + one autosave request; cancel
//   restores the base.
// * Undo/redo/jumpHistory move N entries as one step and schedule one plan patch; the selection
//   is restored to the affected items that still exist; the playhead does not move.
// * open(): repository.open (failures -> EditorFailure; read-only, migration, repairs, recovery
//   and D-14 limits surfaced as events) -> EditSession with the device's EditPolicy -> preview
//   session + PlanSync over the PlanCompilerPort -> first plan -> exact seek to the initial
//   playhead (quantized and clamped to the project).
// * close(): flush (≤ flushTimeout, tier-aware: FIX-M1) -> dispose PlanSync and preview -> repository.close -> release the
//   provider's keepAlive. Never throws. It never waits on background work (FIX-M15, QA-02 M-15):
//   the session is marked closing first (the Tasks controller drops its pending job resume), an
//   open that already attached is not awaited (its first plan and exact seek may wait on a media
//   resolve that never comes; disposing the preview ends them), an open that has not attached yet
//   is awaited at most `flushTimeout`, and each release step is bounded. Each step is logged
//   (`[EditorClose]`, debug and profile builds; no paths or user text). onAppHidden saves (lifecycle save; the repository renders
//   the poster through EditorPosterCapture), onAppInactive cancels the gesture and requests an
//   autosave.
// * Implements UX-07's EditorShellDelegate, so `editorShellProvider` drives the shell from it.
// * Background jobs (FIX-JOB-RESUME): once the session attaches, the provider factory starts
//   `tasksControllerProvider(id)`, which re-queues pending reverse, freeze and proxy jobs.
// * No editor action crashes the app: unexpected errors become UnknownFailure (ARCH §19).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' hide MediaUnavailable;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import '../../app/editor_messages.dart';
import '../../app/editor_prefs.dart';
import '../../app/editor_providers.dart';
import '../../app/editor_tier_defaults.dart' show editorTierDefaultsProvider;
import '../../debug/debug.dart';
import '../contracts/contracts.dart';
import '../editor_lifecycle.dart';
import 'edit_transaction.dart';
import 'editor_events.dart';
import 'editor_session.dart';
import 'editor_state.dart';
import 'plan_compiler_port.dart';
import 'tasks_controller.dart' show tasksControllerProvider;

export 'edit_transaction.dart';
export 'editor_events.dart';

/// Runs a callback once at the next frame (transaction state coalescing, ux.md §16.4).
abstract interface class EditorFrameScheduler {
  /// The scheduler binding's frame callbacks.
  static const EditorFrameScheduler binding = _BindingFrameScheduler();

  /// Runs [callback] at the next frame.
  void schedule(VoidCallback callback);
}

final class _BindingFrameScheduler implements EditorFrameScheduler {
  const _BindingFrameScheduler();

  @override
  void schedule(VoidCallback callback) => SchedulerBinding.instance.scheduleFrameCallback((_) => callback());
}

/// Builds the PlanSync of a preview session (tests inject a counting one).
typedef PlanSyncFactory = PlanSync Function(PreviewSession session, PlanCompile compile);

/// Result of [EditorController.saveNow].
@immutable
final class SaveOutcome {
  const SaveOutcome._({this.receipt, this.failure, this.skipped = false});

  /// Saved with [receipt].
  const SaveOutcome.saved(SaveReceipt receipt) : this._(receipt: receipt);

  /// Failed with [failure] (edits stay in memory; the journal keeps them recoverable).
  const SaveOutcome.failed(SaveFailed failure) : this._(failure: failure);

  /// Nothing was saved (not open, read-only).
  const SaveOutcome.skipped() : this._(skipped: true);

  /// The receipt, when saved.
  final SaveReceipt? receipt;

  /// The failure, when failed.
  final SaveFailed? failure;

  /// Whether nothing was attempted.
  final bool skipped;

  /// Whether the edits are on disk (or there was nothing to save).
  bool get ok => failure == null;

  @override
  String toString() => receipt != null
      ? 'SaveOutcome.saved(${receipt!.docRevision})'
      : (failure != null ? 'SaveOutcome.failed($failure)' : 'SaveOutcome.skipped()');
}

/// Result of [EditorController.close].
@immutable
final class CloseOutcome {
  /// Creates the outcome.
  const CloseOutcome({required this.saved, this.failure});

  /// Whether the latest edits were on disk when the editor closed.
  final bool saved;

  /// The save failure, when not saved.
  final SaveFailed? failure;

  @override
  String toString() => 'CloseOutcome(saved: $saved${failure == null ? '' : ', $failure'})';
}

/// The editor's mutation and lifecycle API (ARCH §17.3, ux.md §16.3).
class EditorController extends StateNotifier<EditorState> implements EditorShellDelegate {
  /// Creates the controller of project [id]; nothing happens until [open].
  EditorController({
    required this.id,
    required EditorSession session,
    required ProjectRepository repository,
    required EditorEngine engine,
    EditorPrefs? prefs,
    PlanCompilerPort? compilers,
    EditorFrameScheduler frames = EditorFrameScheduler.binding,
    PlanSyncFactory? planSyncFactory,
    IdGenerator? ids,
    DateTime Function()? clock,
    Duration flushTimeout = const Duration(seconds: 3),
    Duration Function()? flushTimeoutOf,
  })  : _flushTimeoutOf = flushTimeoutOf ?? (() => flushTimeout),
        _session = session,
        _repository = repository,
        _engine = engine,
        _prefs = prefs,
        _compilers = compilers ?? ResolvingPlanCompilerPort.offline,
        _frames = frames,
        _planSyncFactory = planSyncFactory ?? ((s, compile) => PlanSync(s, compile: compile)),
        _ids = ids,
        _clock = clock,
        super(const EditorState.opening()) {
    addListener(_syncShell, fireImmediately: false);
  }

  /// Project id.
  final ProjectId id;

  /// Longest flush on close (ux.md §4.7).
  ///
  /// FIX-M1: resolved each time a flush or close needs it, so building the controller does not
  /// read the device tier (that read starts the engine capabilities probe before the editor
  /// opens; UX-14/15 keeps engine calls empty until open), and the tier is never stale.
  Duration get flushTimeout => _flushTimeoutOf();
  final Duration Function() _flushTimeoutOf;

  final EditorSession _session;
  final ProjectRepository _repository;
  final EditorEngine _engine;
  final EditorPrefs? _prefs;
  final PlanCompilerPort _compilers;
  final EditorFrameScheduler _frames;
  final PlanSyncFactory _planSyncFactory;
  final IdGenerator? _ids;
  final DateTime Function()? _clock;

  final StreamController<EditorEvent> _events = StreamController<EditorEvent>.broadcast();
  final ValueNotifier<EditorShellStatus> _shell = ValueNotifier<EditorShellStatus>(EditorShellStatus.opening);
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Future<void>? _opening;
  Future<CloseOutcome>? _closing;
  bool _closeRequested = false;
  bool _readOnly = false;
  bool _saveFailureStreak = false;
  int _mainSavedRevision = 0;
  int _consecutiveHistory = 0;
  _ControllerTransaction? _tx;
  bool _txEmitScheduled = false;
  EditorPerfSpan? _openSpan;
  bool _released = false;
  int _openGen = 0;
  final List<VoidCallback> _viewFlushers = [];

  /// Called once when the controller no longer needs to be kept alive (after [close]); the
  /// provider factory closes its `keepAlive` link here.
  VoidCallback? onReleased;

  /// One-shot UI effects: toasts, haptics, announcements, commits, history moves.
  Stream<EditorEvent> get events => _events.stream;

  /// The session (core EditSession, preview, PlanSync).
  EditorSession get session => _session;

  /// Whether the project opened read-only (D-12).
  bool get readOnly => _readOnly;

  /// The open transaction, or null.
  EditTransaction? get transaction => _tx;

  /// Whether edits are accepted (ready and not closing).
  bool get canEdit => mounted && state.phase == EditorPhase.ready && _session.isOpen && _closing == null;

  // -----------------------------------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------------------------------

  /// Opens the project and the preview session, then seeks exactly to [initialPlayhead] (or the
  /// project's saved playhead), quantized to the frame grid and clamped to the project. Failures
  /// land in `state.failure` (phase `failed`); never throws.
  @override
  Future<void> open({TimeUs? initialPlayhead}) {
    final pending = _opening;
    // An open that a close left behind (it may still wait on its first plan) is not reused.
    if (pending != null && _closing == null) return pending;
    if (_session.isOpen && _closing == null) return Future.value();
    late final Future<void> opening;
    opening = _openAfterClose(initialPlayhead).whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
    return _opening = opening;
  }

  Future<void> _openAfterClose(TimeUs? initialPlayhead) async {
    final closing = _closing;
    if (closing != null) {
      await closing;
      if (!mounted) return;
      _closing = null;
      _released = false;
    }
    _closeRequested = false;
    final gen = ++_openGen;
    try {
      await _open(initialPlayhead, gen);
    } catch (e, s) {
      _report(e, s, 'opening the editor');
      _fail(EditorFailures.fromError(e, opening: true));
    }
  }

  /// Whether the open of generation [gen] must stop (a close was requested, or a newer open runs).
  bool _openStale(int gen) => !mounted || _closeRequested || gen != _openGen;

  Future<void> _open(TimeUs? initialPlayhead, int gen) async {
    _set(const EditorState.opening());
    _openSpan = EditorPerfHooks.begin(EditorPerfMarks.editorOpenToFirstFrame);
    final LoadedProject loaded;
    try {
      loaded = await _repository.open(id);
    } catch (e) {
      _fail(EditorFailures.fromError(e, opening: true));
      return;
    }
    if (_openStale(gen)) {
      await _quietly(() => _repository.close(id));
      return;
    }

    EditorCapabilities caps;
    try {
      caps = await _engine.capabilities();
    } catch (_) {
      caps = const EditorCapabilities(supported: true);
    }

    final edit = EditSession(
      loaded.project,
      ids: _ids,
      clock: _clock,
      editPolicy: EditPolicy(maxConcurrentVideoLayers: caps.maxConcurrentVideoLayers, maxVisualSequences: caps.maxVisualSequences),
    );
    _readOnly = loaded.readOnly;
    _mainSavedRevision = loaded.project.docRevision;
    _saveFailureStreak = false;
    _consecutiveHistory = 0;

    // Initial playhead: exact, on the frame grid, inside the project (ARCH §17.1).
    final opened = edit.committedProject;
    final rate = opened.settings.frameRate;
    var t = rate.quantize(initialPlayhead ?? opened.view.playhead);
    final duration = opened.duration;
    if (t > duration) t = rate.quantize(duration);
    if (t < 0) t = 0;
    if (t != opened.view.playhead) edit.updateView((v) => v.copyWith(playhead: t));
    // Moving the playhead on open is not an edit: nothing to save yet.
    _mainSavedRevision = edit.committedProject.docRevision;

    final compiler = _compilers.forSession(edit, caps);
    final prefs = _prefs;
    final quality = switch (prefs?.previewQuality) {
      PreviewQualityPreference.full => PreviewQuality.full,
      PreviewQualityPreference.half => PreviewQuality.half,
      _ => PreviewQuality.auto,
    };
    final useProxies = prefs?.proxyMedia != ProxyMediaMode.off;
    final canvas = opened.settings.canvas;
    PreviewSession? preview;
    PlanSync? sync;
    PreviewFailed? previewFailure;
    try {
      preview = await _engine.openPreview(PreviewConfig(
        canvasWidth: canvas.widthPx,
        canvasHeight: canvas.heightPx,
        fps: (rate.num / rate.den).round(),
        quality: quality,
        useProxies: useProxies,
      ));
      sync = _planSyncFactory(preview, _resolvingCompile(compiler));
    } catch (e) {
      previewFailure = _previewFailureOf(e);
    }
    if (_openStale(gen)) {
      await _quietly(() async => sync?.dispose());
      await _quietly(() async => preview?.dispose());
      await _quietly(() => _repository.close(id));
      return;
    }

    _session.attach(edit: edit, loaded: loaded, engine: _engine, capabilities: caps, compiler: compiler, preview: preview, planSync: sync);
    _listenPreview(preview, sync);
    // Without a preview nothing compiles, so warm the compiler's media snapshot once: background
    // jobs and posters resolve through it (FIX-QA05-D5).
    if (sync == null) unawaited(_quietly(() => _resolvingCompile(compiler)(edit.committedProject)));
    _listenAutosave();

    final view = edit.committedProject.view;
    _set(EditorState(
      phase: EditorPhase.ready,
      project: edit.project,
      history: edit.history,
      save: _readOnly ? SaveStatus.readOnly : SaveStatus.clean,
      modes: EditModes(
        ripple: view.rippleEnabled,
        snapping: view.snappingEnabled,
        centerPlayhead: prefs?.centerPlayheadOnTouch ?? true,
      ),
      preview: previewFailure == null
          ? PreviewStatus(PreviewPhase.starting, quality: quality, useProxies: useProxies)
          : PreviewStatus(PreviewPhase.failed, quality: quality, useProxies: useProxies, failure: previewFailure),
    ));

    // Open outcomes (ARCH §19: open never throws for content problems).
    if (_readOnly) _toast(EditorMessages.openedReadOnly);
    if (loaded.migratedFrom != null) _toast(EditorMessages.migrated);
    if (loaded.warnings.isNotEmpty) _toast(EditorMessages.repaired);
    final recovery = loaded.pendingRecovery;
    if (recovery != null) _emit(EditorRecoveryAvailable(recovery));
    final limits = edit.limits.countsOf(edit.committedProject).exceeded(edit.editPolicy);
    if (limits.isNotEmpty) _emit(EditorLimitsExceeded(limits));

    // First plan, then the exact seek.
    SeekAck? ack;
    if (preview != null && sync != null) {
      sync.schedule(edit.committedProject);
      try {
        await sync.flush();
        if (!_session.isOpen || !identical(_session.preview, preview)) return;
        ack = await preview.seek(t);
      } catch (e) {
        // A close (or a newer open) released this session meanwhile: nothing to report.
        if (!identical(_session.editOrNull, edit)) return;
        _setPreviewFailed(_previewFailureOf(e));
      }
    }
    if (!identical(_session.editOrNull, edit)) return;
    _session.markOpenedAt(t, ack);
  }

  /// [compiler]'s compile that records each finished pass on the session (FIX-QA05-D5): INT-02's
  /// compiler resolves the project's media before it compiles, and its synchronous `resolve`
  /// answers from that snapshot, so the Tasks controller resolves sources only after a pass.
  PlanCompile _resolvingCompile(SessionPlanCompiler compiler) =>
      (project) => compiler.compile(project).whenComplete(() => _session.markMediaResolved(compiler));

  void _fail(EditorFailure failure) {
    _openSpan = null;
    _set(state.copyWith(phase: EditorPhase.failed, failure: failure, project: null));
  }

  /// Flushes the latest edits before the editor closes; true when they are on disk (or there was
  /// nothing to save). Bounded by [flushTimeout]; never throws.
  ///
  /// FIX-M1 (QA-02 M-1): a timeout only stops the waiting. The save keeps going in the
  /// repository's write queue (the state stays `saving` until it lands), and a second call while
  /// it runs, with no newer edit, joins it instead of queueing another full save.
  @override
  Future<bool> flushBeforeClose() async {
    if (!_session.isOpen || _readOnly) return true;
    _closeTx(emit: true);
    _flushViews();
    final revision = _session.editOrNull?.committedProject.docRevision;
    var running = _closeFlush;
    if (running == null || _closeFlushRevision != revision) {
      final started = _flushQuietly(SaveReason.close);
      _closeFlush = running = started;
      _closeFlushRevision = revision;
      unawaited(started.whenComplete(() {
        if (identical(_closeFlush, started)) _closeFlush = null;
      }));
    }
    return running.timeout(flushTimeout, onTimeout: () => false);
  }

  Future<bool>? _closeFlush;
  int? _closeFlushRevision;

  Future<bool> _flushQuietly(SaveReason reason) async {
    try {
      return await _flush(reason);
    } catch (_) {
      return false;
    }
  }

  /// Saves (main document) when there are unsaved edits, otherwise completes pending writes.
  Future<bool> _flush(SaveReason reason) async {
    final edit = _session.editOrNull;
    if (edit == null || _readOnly) return true;
    if (edit.committedProject.docRevision > _mainSavedRevision) {
      final out = await _save(reason, manual: false);
      return out.ok;
    }
    try {
      await _repository.flush(id);
      return true;
    } catch (e) {
      final failure = _saveFailureOf(e);
      _onSaveFailed(failure);
      return false;
    }
  }

  /// Flushes (≤ [flushTimeout]), disposes the preview and PlanSync, closes the project in the
  /// repository and releases the provider. Safe in any phase; never throws.
  @override
  Future<CloseOutcome> close() => _closing ??= _close();

  Future<CloseOutcome> _close() async {
    _closeRequested = true;
    final opening = _opening;
    _closeLog('start (attached: ${_session.isOpen}, open pending: ${opening != null})');
    // First: background work stops resuming (the Tasks controller suspends; FIX-M15).
    _session.markClosing();
    if (opening != null) {
      if (_session.isOpen) {
        // The open attached and now waits for its first plan / exact seek, which may wait on a
        // media resolve: never await it. Releasing the preview below ends it.
        _closeLog('open still finishing (first plan / seek): not awaited');
      } else {
        // Not attached yet: the open sees the close and cleans up itself; wait for that, bounded.
        var finished = true;
        try {
          await opening.timeout(flushTimeout, onTimeout: () => finished = false);
        } catch (_) {}
        _closeLog(finished ? 'pending open finished' : 'pending open did not finish in ${flushTimeout.inMilliseconds} ms: not awaited');
      }
    }
    // Any open still running is stale from here on (it never attaches).
    _openGen++;
    var outcome = const CloseOutcome(saved: true);
    try {
      if (_session.isOpen) {
        _session.markClosing();
        if (mounted && state.phase == EditorPhase.ready) _set(state.copyWith(phase: EditorPhase.closing));
        _closeTx(emit: false);
        final saved = _readOnly ? true : await flushBeforeClose();
        _closeLog('flushBeforeClose: ${saved ? 'saved' : 'not saved'}');
        outcome = CloseOutcome(saved: saved, failure: saved ? null : state.save.failure);
        await _releaseSession();
        if (mounted && state.phase != EditorPhase.failed) _set(state.copyWith(phase: EditorPhase.closed));
      }
    } catch (e, s) {
      _report(e, s, 'closing the editor');
      await _releaseSession();
    }
    _release();
    _closeLog('done ($outcome)');
    return outcome;
  }

  Future<void> _releaseSession() async {
    _closeLog('release: start');
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    final sync = _session.planSync;
    final preview = _session.preview;
    final wasOpen = _session.isOpen;
    _session.detach();
    _closeLog('release: session detached (EditorSession closed)');
    // Each step is bounded: a release that never returns must not keep the close open.
    await _releaseStep('plan sync dispose', sync?.dispose);
    await _releaseStep('preview dispose', preview?.dispose);
    if (wasOpen) await _releaseStep('repository close', () => _repository.close(id));
    _closeLog('release: end');
  }

  Future<void> _releaseStep(String what, Future<void> Function()? body) async {
    if (body == null) return;
    _closeLog('release: $what');
    try {
      await Future<void>.sync(body).timeout(flushTimeout);
    } on TimeoutException {
      _closeLog('release: $what timed out after ${flushTimeout.inMilliseconds} ms');
    } catch (e) {
      _closeLog('release: $what failed (${e.runtimeType})');
    }
  }

  /// A close-step log line (FIX-M15, QA-02 M-15): debug and profile builds only; no paths or user
  /// text (ARCH §19 rule 3).
  void _closeLog(String step) {
    if (kReleaseMode) return;
    debugPrint('[EditorClose] ${id.value}: $step');
  }

  void _release() {
    if (_released) return;
    _released = true;
    final release = onReleased;
    if (release != null) {
      try {
        release();
      } catch (_) {}
    }
  }

  /// Saves now (main document). [manual] for ⌘S, Project › Save and "Couldn't save · Retry"
  /// ("Saved" toast). Never throws.
  @override
  Future<SaveOutcome> saveNow({bool manual = false}) {
    if (!_session.isOpen) return Future.value(const SaveOutcome.skipped());
    if (_readOnly) {
      if (manual) _toast(EditorMessages.openedReadOnly);
      return Future.value(const SaveOutcome.skipped());
    }
    return _save(manual ? SaveReason.manual : SaveReason.lifecycle, manual: manual);
  }

  Future<SaveOutcome> _save(SaveReason reason, {required bool manual}) async {
    final edit = _session.editOrNull;
    if (edit == null) return const SaveOutcome.skipped();
    _setSave(SaveStatus.saving);
    try {
      final receipt = await _repository.save(edit, reason: reason);
      if (receipt.docRevision > _mainSavedRevision) _mainSavedRevision = receipt.docRevision;
      _saveFailureStreak = false;
      final current = _session.editOrNull?.committedProject.docRevision ?? receipt.docRevision;
      _setSave(current > receipt.docRevision ? SaveStatus.edited : SaveStatus.saved(receipt.savedAt));
      if (manual) _toast(EditorMessages.saved, kind: EditorToastKind.success);
      return SaveOutcome.saved(receipt);
    } catch (e) {
      final failure = _saveFailureOf(e);
      _onSaveFailed(failure);
      return SaveOutcome.failed(failure);
    }
  }

  SaveFailed _saveFailureOf(Object e) => switch (e) {
        StoreFailure(:final kind) => SaveFailed(kind),
        _ => const SaveFailed(StoreFailureKind.io),
      };

  void _onSaveFailed(SaveFailed failure) {
    _setSave(SaveStatus.failed(failure));
    if (_saveFailureStreak) return;
    _saveFailureStreak = true;
    _toast(EditorMessages.forFailure(failure), kind: EditorToastKind.error);
  }

  void _setSave(SaveStatus save) {
    if (!mounted || state.save == save) return;
    if (_readOnly && save.phase != SavePhase.readOnly) return;
    _set(state.copyWith(save: save));
  }

  /// The app became inactive: cancel an interrupted gesture, pause playback, request an autosave.
  @override
  void onAppInactive() {
    if (!_session.isOpen) return;
    _closeTx(emit: true);
    final preview = _session.preview;
    if (preview != null) unawaited(_quietly(preview.pause));
    _requestAutosave();
  }

  /// The app was hidden or paused: save now (lifecycle save, with the poster); keep the preview.
  @override
  void onAppHidden() {
    if (!_session.isOpen || _readOnly) return;
    _closeTx(emit: true);
    _flushViews();
    unawaited(_quietly(() => _flush(SaveReason.lifecycle)));
  }

  /// The app came back: redraw the preview and resend the plan if it had failed. A preview that
  /// stopped while the app was away (a recoverable failure) restarts at once, as "Restart preview"
  /// would (FIX-QA05-D5 / QA-05 D6): with the plan in step, nothing else would ever leave `failed`.
  @override
  void onAppResumed() {
    final preview = _session.preview;
    if (preview == null) return;
    final status = state.preview;
    if (status.phase == PreviewPhase.failed && status.failure?.recoverable != false) {
      unawaited(_quietly(restartPreview));
      return;
    }
    unawaited(_quietly(preview.refresh));
    final sync = _session.planSync;
    if (sync != null && sync.currentStatus == PlanSyncStatus.failed) sync.resync();
  }

  /// The system is low on memory: drop the compiler memo and engine caches.
  @override
  void onMemoryPressure() {
    _session.compiler?.trim();
    unawaited(_quietly(() => _engine.trimCaches(CacheTrimLevel.memoryPressure)));
  }

  // -----------------------------------------------------------------------------------------------
  // Preview
  // -----------------------------------------------------------------------------------------------

  void _listenPreview(PreviewSession? preview, PlanSync? sync) {
    if (preview != null) {
      _subscriptions.add(preview.events.listen(_onPreviewEvent, onError: (Object _) {}));
    }
    if (sync != null) {
      _subscriptions.add(sync.events.listen(_onPreviewEvent, onError: (Object _) {}));
      _subscriptions.add(sync.status.listen((s) {
        // Only an applied plan (idle) brings a failed preview back: `compiling` or `applying` after
        // a failure has not reached the engine yet (QA-05 D6).
        if (s == PlanSyncStatus.idle && state.preview.phase == PreviewPhase.failed && identical(_session.planSync, sync)) {
          _setPreview(state.preview.copyWith(phase: PreviewPhase.ready));
        }
      }, onError: (Object _) {}));
    }
  }

  void _onPreviewEvent(PreviewEvent event) {
    switch (event) {
      case PreviewFirstFrame():
        _openSpan?.end();
        _openSpan = null;
        if (state.preview.phase == PreviewPhase.starting) _setPreview(state.preview.copyWith(phase: PreviewPhase.ready));
      case PreviewDegraded(:final quality):
        // A quality step never hides a stopped preview ("Restart preview" stays; QA-05 D6).
        if (state.preview.phase == PreviewPhase.failed) break;
        _setPreview(state.preview.copyWith(phase: PreviewPhase.degraded, quality: quality));
      case PreviewRecovered():
        if (state.preview.phase != PreviewPhase.failed) _setPreview(state.preview.copyWith(phase: PreviewPhase.ready));
      case PreviewStalled() || PreviewSurfaceLost():
        break;
      case PreviewFailedEvent(:final failure):
        _setPreviewFailed(_previewFailureOf(failure));
    }
  }

  PreviewFailed _previewFailureOf(Object error) {
    final mapped = EditorFailures.fromError(error);
    return mapped is PreviewFailed ? mapped : PreviewFailed(recoverable: true, engineCode: error is EngineFailure ? error.code : null);
  }

  void _setPreviewFailed(PreviewFailed failure) {
    if (!mounted) return;
    final already = state.preview.phase == PreviewPhase.failed;
    _setPreview(state.preview.copyWith(phase: PreviewPhase.failed, failure: failure));
    if (!already) _emit(const EditorAnnouncement('Preview stopped'));
  }

  void _setPreview(PreviewStatus preview) {
    if (!mounted || state.preview == preview) return;
    _set(state.copyWith(preview: preview));
  }

  /// "Restart preview": resends the full plan and redraws, or reopens the preview session when it
  /// never started.
  Future<void> restartPreview() async {
    final edit = _session.editOrNull;
    final compiler = _session.compiler;
    if (edit == null || compiler == null) return;
    final sync = _session.planSync;
    final preview = _session.preview;
    if (sync != null && preview != null) {
      // The phase leaves `failed` when PlanSync's next full plan is acknowledged.
      sync.resync();
      await _quietly(preview.refresh);
      return;
    }
    try {
      final canvas = edit.committedProject.settings.canvas;
      final rate = edit.committedProject.settings.frameRate;
      final s = await _engine.openPreview(PreviewConfig(
        canvasWidth: canvas.widthPx,
        canvasHeight: canvas.heightPx,
        fps: (rate.num / rate.den).round(),
        quality: state.preview.quality,
        useProxies: state.preview.useProxies,
      ));
      if (!_session.isOpen) {
        await _quietly(s.dispose);
        return;
      }
      final ps = _planSyncFactory(s, _resolvingCompile(compiler));
      _session.replacePreview(s, ps);
      _listenPreview(s, ps);
      _setPreview(state.preview.copyWith(phase: PreviewPhase.starting));
      ps.schedule(edit.committedProject);
      await ps.flush();
      await s.seek(edit.committedProject.view.playhead);
    } catch (e) {
      _setPreviewFailed(_previewFailureOf(e));
    }
  }

  /// Sets the session's preview quality (UX-18).
  Future<void> setPreviewQuality(PreviewQuality quality) async {
    _setPreview(state.preview.copyWith(quality: quality));
    final preview = _session.preview;
    if (preview != null) await _quietly(() => preview.setQuality(quality));
  }

  /// Turns proxies on or off for this session (UX-18).
  Future<void> setUseProxies(bool on) async {
    _setPreview(state.preview.copyWith(useProxies: on));
    final preview = _session.preview;
    if (preview != null) await _quietly(() => preview.setUseProxies(on));
  }

  // -----------------------------------------------------------------------------------------------
  // Autosave status
  // -----------------------------------------------------------------------------------------------

  void _listenAutosave() {
    final repo = _repository;
    if (repo is! FileProjectRepository) return;
    _subscriptions.add(repo.watchAutosave(id).listen(_onAutosave, onError: (Object _) {}));
  }

  void _onAutosave(AutosaveStatus status) {
    if (!mounted || _readOnly) return;
    switch (status.phase) {
      case AutosavePhase.idle:
        break;
      case AutosavePhase.pending:
        if (state.save.phase != SavePhase.failed) _setSave(SaveStatus.edited);
      case AutosavePhase.saving:
        _setSave(SaveStatus.saving);
      case AutosavePhase.saved:
        _saveFailureStreak = false;
        _setSave(SaveStatus.saved(status.lastSavedAt));
      case AutosavePhase.failed:
        final f = status.failure;
        _onSaveFailed(SaveFailed(f?.kind ?? StoreFailureKind.io));
    }
  }

  void _requestAutosave() {
    final edit = _session.editOrNull;
    if (edit == null || _readOnly) return;
    try {
      _repository.requestAutosave(edit);
    } catch (e, s) {
      _report(e, s, 'requesting an autosave');
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Mutations
  // -----------------------------------------------------------------------------------------------

  /// Applies [command] as one history entry: plan patch, autosave request and events on commit;
  /// an info toast on rejection. [coalesceKey] joins typing into the newest entry (1 s window).
  EditResult apply(EditCommand command, {String? coalesceKey}) {
    if (!canEdit) return const EditUnchanged();
    try {
      _closeTx(emit: false);
      final edit = _session.edit;
      final out = coalesceKey == null ? edit.apply(command) : edit.apply(command, coalesceKey: coalesceKey);
      return _afterOutcome(out, command.label);
    } catch (e, s) {
      _report(e, s, 'applying ${command.label}');
      return _reject(command.label, InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  /// Applies an undoable pool edit (relink, remove unused media) as one history entry; [adjust]
  /// runs in the same entry (CORE-28 durationMismatch trims).
  EditResult applyPoolEdit(PoolEdit edit, {EditCommand? adjust, String label = 'Edit media'}) {
    if (!canEdit) return const EditUnchanged();
    try {
      _closeTx(emit: false);
      return _afterOutcome(_session.edit.applyPoolEdit(edit, adjust: adjust), label);
    } catch (e, s) {
      _report(e, s, 'applying a pool edit');
      return _reject(label, InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  /// Applies a sticky pool change (imports, probe/proxy/status updates; not in history).
  void applyPoolChange(PoolChange change) {
    final edit = _session.editOrNull;
    if (edit == null) return;
    edit.applyPoolChange(change);
    _set(state.copyWith(project: edit.project));
    _requestAutosave();
  }

  EditResult _afterOutcome(EditOutcome out, String label) {
    final rejection = out.rejection;
    if (rejection != null) return _reject(label, rejection);
    if (!out.changed) {
      _emitCurrent();
      return const EditUnchanged();
    }
    _committed(
      out.project,
      label: label,
      affected: out.affected,
      changedTracks: out.changedTracks,
      notices: out.notices,
      hint: SelectionRules.hintAfter(out),
    );
    return EditApplied(label: label, affected: out.affected, changedTracks: out.changedTracks, notices: out.notices);
  }

  EditResult _reject(String label, EditRejection rejection) {
    _emitCurrent();
    _emit(const EditorHaptic(EditorHapticKind.warning));
    _toast(EditorMessages.forRejection(rejection));
    _emit(EditorRejected(label, rejection));
    return EditRejected(rejection);
  }

  /// The commit path shared by apply, transaction commit and pool edits.
  void _committed(
    EditProject project, {
    required String label,
    Set<ItemId> affected = const {},
    Set<TrackId> changedTracks = const {},
    List<EditNotice> notices = const [],
    SelectionHint? hint,
  }) {
    _consecutiveHistory = 0;
    _session.planSync?.schedule(project);
    _requestAutosave();
    final edit = _session.edit;
    final selection = hint != null && hint.items.isNotEmpty
        ? EditorSelection(items: hint.items, primary: hint.primary ?? hint.items.first, lane: hint.lane)
        : _retained(state.selection, edit.project);
    _set(state.copyWith(
      project: edit.project,
      inTransaction: false,
      history: edit.history,
      save: _readOnly ? SaveStatus.readOnly : SaveStatus.edited,
      selection: selection,
      inspector: _validInspector(state.inspector, selection, edit.project),
    ));
    _emit(EditorCommitted(label: label, affected: affected, changedTracks: changedTracks, notices: notices));
    for (final n in notices) {
      final m = EditorMessages.forNotice(n);
      if (m != null) _toast(m);
    }
  }

  EditorSelection _retained(EditorSelection selection, EditProject project) {
    final index = project.index;
    return selection.retainItems((id) => index.locate(id) != null);
  }

  InspectorRoute? _validInspector(InspectorRoute? route, EditorSelection selection, EditProject project) {
    if (route == null) return null;
    final target = route.target;
    if (target == null) return route;
    if (project.index.locate(target) != null) return route;
    final primary = selection.primary;
    return primary == null ? null : route.retarget(primary);
  }

  /// Opens a gesture transaction labelled [label]; an open one is cancelled first.
  EditTransaction beginTransaction(String label) {
    if (!canEdit) return _ClosedTransaction(label, state.project);
    _closeTx(emit: false);
    final core = _session.edit.begin(label);
    final tx = _tx = _ControllerTransaction(this, core);
    _scheduleTxEmit();
    return tx;
  }

  /// Undoes the last entry (one plan patch); false when there was nothing to undo.
  @override
  bool undo() => _history((e) => e.undo());

  /// Redoes the next entry (one plan patch); false when there was nothing to redo.
  @override
  bool redo() => _history((e) => e.redo());

  /// Moves [steps] entries back (negative) or forward as one step with one plan patch (history
  /// sheet).
  void jumpHistory(int steps) => _history((e) => e.jump(steps));

  bool _history(HistoryStep? Function(EditSession edit) move) {
    if (!canEdit) return false;
    try {
      _closeTx(emit: false);
      final step = move(_session.edit);
      if (step == null) {
        _emitCurrent();
        return false;
      }
      _afterHistory(step);
      return true;
    } catch (e, s) {
      _report(e, s, 'moving in history');
      _emitCurrent();
      return false;
    }
  }

  void _afterHistory(HistoryStep step) {
    _session.planSync?.schedule(step.project);
    _requestAutosave();
    final edit = _session.edit;
    final hint = step.selection;
    final selection = hint != null && hint.items.isNotEmpty
        ? EditorSelection(items: hint.items, primary: hint.primary ?? hint.items.first, lane: hint.lane)
        : _retained(state.selection, edit.project);
    _set(state.copyWith(
      project: edit.project,
      inTransaction: false,
      history: edit.history,
      save: _readOnly ? SaveStatus.readOnly : SaveStatus.edited,
      selection: selection,
      inspector: _validInspector(state.inspector, selection, edit.project),
    ));
    _consecutiveHistory++;
    final undo = step.direction == HistoryDirection.undo;
    final label = step.steps == 1 ? step.label : '${step.steps} edits';
    final message = undo ? EditorMessages.undid(label) : EditorMessages.redid(label);
    _emit(EditorHistoryMoved(direction: step.direction, labels: step.labels, affected: step.affected));
    // ux.md §14.1: touch only, and not after three consecutive undos/redos.
    if (_consecutiveHistory <= 3) _emit(EditorToast(message, touchOnly: true));
    _emit(EditorAnnouncement(message.title));
  }

  // -----------------------------------------------------------------------------------------------
  // Transactions
  // -----------------------------------------------------------------------------------------------

  void _closeTx({required bool emit}) {
    final tx = _tx;
    if (tx == null) return;
    tx._abort();
    _tx = null;
    if (emit) _emitCurrent();
  }

  void _scheduleTxEmit() {
    if (_txEmitScheduled) return;
    _txEmitScheduled = true;
    _frames.schedule(() {
      _txEmitScheduled = false;
      if (_tx != null) _emitCurrent();
    });
  }

  void _emitCurrent() {
    final edit = _session.editOrNull;
    if (edit == null || !mounted) return;
    final project = edit.project;
    final inTx = _tx?.isOpen ?? false;
    if (identical(state.project, project) && state.inTransaction == inTx) return;
    _set(state.copyWith(project: project, inTransaction: inTx));
  }

  void _sendTransients(_ControllerTransaction tx, EditOutcome out) {
    final sync = _session.planSync;
    final compiler = _session.compiler;
    final edit = _session.editOrNull;
    if (sync == null || compiler == null || edit == null) return;
    final base = edit.committedProject.index;
    final working = edit.project;
    final now = working.index;
    final params = <ItemId>[];
    var structural = out.affected.isEmpty || out.affected.length > _ControllerTransaction.maxTransientItems;
    if (!structural) {
      for (final id in out.affected) {
        final a = base.locate(id);
        final b = now.locate(id);
        if (a == null || b == null || a.track.id != b.track.id || a.item.start != b.item.start || a.item.end != b.item.end) {
          structural = true;
          break;
        }
        params.add(id);
      }
    }
    if (structural) {
      // Ghosts show structural changes; the preview updates on commit (ux.md §16.4).
      tx._dropTransients(sync);
      return;
    }
    for (final id in params) {
      try {
        final t = compiler.transientFor(working, id);
        if (t == null) continue;
        sync.sendTransient(id, t);
        tx._sent.add(id);
      } catch (e, s) {
        _report(e, s, 'building a transient');
      }
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Selection, tool, inspector, modes (not history)
  // -----------------------------------------------------------------------------------------------

  /// Selects [item] ([mode]: replace, toggle or extend). Item inspectors follow the primary item.
  void select(ItemId item, {SelectMode mode = SelectMode.replace}) {
    final project = state.project;
    if (project == null) return;
    final loc = project.index.locate(item);
    if (loc == null) return;
    final current = state.selection;
    final EditorSelection next;
    switch (mode) {
      case SelectMode.replace:
        next = EditorSelection(items: {item}, primary: item, lane: loc.track.id);
      case SelectMode.toggle:
        final items = {...current.items};
        if (!items.remove(item)) items.add(item);
        final primary = items.contains(item) ? item : (items.contains(current.primary) ? current.primary : items.firstOrNull);
        next = EditorSelection(items: items, primary: primary, lane: loc.track.id);
      case SelectMode.extend:
        next = EditorSelection(items: {...current.items, item}, primary: item, lane: loc.track.id);
    }
    _setSelection(next);
  }

  /// Selects the item of [lane] under [t] (the lane when there is none).
  void selectAt(TrackId lane, TimeUs t) {
    final project = state.project;
    if (project == null) return;
    final hits = SelectionRules.itemsAt(project, t, lane: lane, includeLocked: true);
    if (hits.isEmpty) {
      _setSelection(EditorSelection(lane: lane));
    } else {
      select(hits.first);
    }
  }

  /// Selects every unlocked item of [lane], or of the project.
  void selectAll({TrackId? lane}) {
    final project = state.project;
    if (project == null) return;
    final ids = lane == null ? SelectionRules.all(project) : SelectionRules.allOnLane(project, lane);
    _setSelection(ids.isEmpty ? EditorSelection.empty : EditorSelection(items: ids, primary: ids.first, lane: lane));
  }

  /// Selects the cut [ref].
  void selectTransition(TransitionRef ref) => _setSelection(EditorSelection(transition: ref, lane: ref.track));

  /// Selects the gap [gap].
  void selectGap(GapRef gap) => _setSelection(EditorSelection(gap: gap, lane: gap.track));

  /// Selects the marker [marker].
  void selectMarker(MarkerId marker) => _setSelection(EditorSelection(marker: marker));

  /// Selects the keyframe [ref] (and its item).
  void selectKeyframe(KeyframeRef ref) => _setSelection(EditorSelection(items: {ref.item}, primary: ref.item, keyframe: ref));

  /// Clears the selection (item inspectors close; project panels stay).
  void clearSelection() => _setSelection(EditorSelection.empty);

  void _setSelection(EditorSelection selection) {
    if (!mounted) return;
    final route = state.inspector;
    InspectorRoute? inspector = route;
    if (route != null && route.target != null) {
      final primary = selection.primary;
      inspector = primary == null ? null : route.retarget(primary);
    }
    if (selection == state.selection && inspector == route) return;
    _set(state.copyWith(selection: selection, inspector: inspector));
  }

  /// Sets the active top-level tool.
  void setTool(ToolId? tool) {
    if (!mounted || state.tool == tool) return;
    _set(state.copyWith(tool: tool));
  }

  /// Opens [route] in the inspector.
  void openInspector(InspectorRoute route) {
    if (!mounted || state.inspector == route) return;
    _set(state.copyWith(inspector: route));
  }

  /// Closes the inspector.
  void closeInspector() {
    if (!mounted || state.inspector == null) return;
    _set(state.copyWith(inspector: null));
  }

  /// Updates the edit modes; ripple and snapping persist in the project's view state.
  void setModes(EditModes Function(EditModes modes) update) {
    if (!mounted) return;
    final next = update(state.modes);
    if (next == state.modes) return;
    final edit = _session.editOrNull;
    if (edit != null && (next.ripple != state.modes.ripple || next.snapping != state.modes.snapping)) {
      edit.updateView((v) => v.copyWith(rippleEnabled: next.ripple, snappingEnabled: next.snapping));
      _requestAutosave();
    }
    _set(state.copyWith(modes: next, project: edit?.project ?? state.project));
  }

  /// Registers [flush], called right before the editor saves on close or when the app is hidden,
  /// to write view state that is still debounced (the playhead's settle, UX-14; FIX-UX-14-1: a seek
  /// right before "Close editor" must reach the saved view state). Returns the remover.
  VoidCallback addViewFlusher(VoidCallback flush) {
    _viewFlushers.add(flush);
    return () => _viewFlushers.remove(flush);
  }

  void _flushViews() {
    for (final flush in [..._viewFlushers]) {
      try {
        flush();
      } catch (e, s) {
        _report(e, s, 'writing the view state');
      }
    }
  }

  /// Persists view state (playhead, zoom, scroll) without history (UX-09, UX-14).
  void updateView(ViewState Function(ViewState view) update) {
    final edit = _session.editOrNull;
    if (edit == null) return;
    edit.updateView(update);
    _requestAutosave();
  }

  /// Media health from UX-40's media health controller.
  void setMediaHealth(MediaHealth media) {
    if (!mounted || state.media == media) return;
    _set(state.copyWith(media: media));
  }

  /// A new availability report changed what is on- or offline (UX-40's media health: after a
  /// relink, on app resume). The compiler reads the report before it resolves, so the plan is
  /// compiled again (FIX-UX-40-1: the relink commit compiled against the report from before the
  /// relink, so the relinked media stayed offline in the preview until the project was reopened).
  void mediaAvailabilityChanged() {
    if (!mounted || !_session.isOpen) return;
    final edit = _session.editOrNull;
    final compiler = _session.compiler;
    if (edit == null || compiler == null) return;
    final sync = _session.planSync;
    if (sync != null) {
      if (sync.currentStatus == PlanSyncStatus.failed) {
        sync.resync();
      } else {
        sync.schedule(edit.committedProject);
      }
    } else {
      // No preview: refresh the compiler's media snapshot for posters and background jobs.
      unawaited(_quietly(() => _resolvingCompile(compiler)(edit.committedProject)));
    }
  }

  /// Background tasks from UX-35's tasks controller.
  void setTasks(List<EditorTaskInfo> tasks) {
    if (!mounted || listEquals(state.tasks, tasks)) return;
    _set(state.copyWith(tasks: tasks));
  }

  // -----------------------------------------------------------------------------------------------
  // EditorShellDelegate
  // -----------------------------------------------------------------------------------------------

  @override
  ValueListenable<EditorShellStatus> get shellStatus => _shell;

  @override
  bool dismissForBack(EditorBackStep step) {
    switch (step) {
      case EditorBackStep.cancelGesture:
        if (_tx == null) return false;
        _closeTx(emit: true);
        return true;
      case EditorBackStep.closePanel:
        if (state.inspector == null) return false;
        closeInspector();
        return true;
      case EditorBackStep.clearSelection:
        if (state.selection.isEmpty) return false;
        clearSelection();
        return true;
      case EditorBackStep.exitFullscreen:
        return false;
    }
  }

  void _syncShell(EditorState s) {
    final failure = s.failure;
    final message = failure == null ? null : EditorMessages.forFailure(failure);
    final next = EditorShellStatus(
      phase: switch (s.phase) {
        EditorPhase.opening => EditorShellPhase.opening,
        EditorPhase.failed => failure is ProjectNotFound ? EditorShellPhase.notFound : EditorShellPhase.failed,
        EditorPhase.ready || EditorPhase.closing || EditorPhase.closed => EditorShellPhase.ready,
      },
      projectName: s.project?.name,
      save: switch (s.save.phase) {
        SavePhase.clean || SavePhase.saved || SavePhase.readOnly => EditorSaveIndicator.saved,
        SavePhase.edited => EditorSaveIndicator.edited,
        SavePhase.saving => EditorSaveIndicator.saving,
        SavePhase.failed => EditorSaveIndicator.failed,
      },
      canUndo: s.history.canUndo,
      canRedo: s.history.canRedo,
      undoLabel: s.history.undoLabel,
      redoLabel: s.history.redoLabel,
      inspectorOpen: s.inspector != null,
      failureTitle: message?.title,
      failureMessage: message?.detail,
    );
    if (_shell.value != next) _shell.value = next;
  }

  // -----------------------------------------------------------------------------------------------
  // Plumbing
  // -----------------------------------------------------------------------------------------------

  void _set(EditorState next) {
    if (mounted) state = next;
  }

  void _emit(EditorEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _toast(EditorMessage message, {EditorToastKind kind = EditorToastKind.info}) => _emit(EditorToast(message, kind: kind));

  static Future<void> _quietly(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  void _report(Object e, StackTrace s, String what) {
    // Logging only (ARCH §19 rule 3): never media paths or user text.
    debugPrint('danaview_editor: error while $what: ${e.runtimeType}');
    assert(() {
      debugPrintStack(stackTrace: s, maxFrames: 8);
      return true;
    }());
  }

  @override
  void dispose() {
    _closeRequested = true;
    final tx = _tx;
    _tx = null;
    tx?._abort();
    if (_session.isOpen && _closing == null) {
      // The provider went away without close(): release the session (best effort, no state).
      unawaited(_releaseSession());
    }
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    unawaited(_events.close());
    _shell.dispose();
    _release();
    super.dispose();
  }
}

/// The controller's transaction (ux.md §16.4).
final class _ControllerTransaction implements EditTransaction {
  _ControllerTransaction(this._c, this._core);

  /// Above this many affected items an update is treated as structural (no transients).
  static const int maxTransientItems = 8;

  final EditorController _c;
  final SessionTransaction _core;
  final Set<ItemId> _sent = {};
  bool _open = true;

  @override
  String get label => _core.label;

  @override
  bool get isOpen => _open && _core.isOpen;

  @override
  EditPreview? get preview => _core.preview;

  @override
  EditProject get working => _c._session.editOrNull?.project ?? (throw StateError('the editor is not open'));

  @override
  EditResult update(EditCommand command) {
    if (!isOpen) return const EditUnchanged();
    try {
      final out = _core.update(command);
      _c._scheduleTxEmit();
      final rejection = out.rejection;
      if (rejection != null) {
        _dropTransients(_c._session.planSync);
        return EditRejected(rejection);
      }
      if (!out.changed) {
        _dropTransients(_c._session.planSync);
        return const EditUnchanged();
      }
      _c._sendTransients(this, out);
      return EditApplied(label: label, affected: out.affected, changedTracks: out.changedTracks, notices: out.notices);
    } catch (e, s) {
      _c._report(e, s, 'updating a gesture');
      return EditRejected(InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  @override
  EditResult commit() {
    if (!isOpen) return const EditUnchanged();
    _open = false;
    if (identical(_c._tx, this)) _c._tx = null;
    try {
      final out = _core.commit();
      final sync = _c._session.planSync;
      if (out.rejection != null || !out.changed) {
        _dropTransients(sync);
        _c._emitCurrent();
        return out.rejection != null ? EditRejected(out.rejection!) : const EditUnchanged();
      }
      _c._committed(
        out.project,
        label: label,
        affected: out.affected,
        changedTracks: out.changedTracks,
        notices: out.notices,
        hint: SelectionRules.hintAfter(out),
      );
      // After schedule(): PlanSync is busy, so the engine clears the transients once the commit's
      // plan is applied and the item never flashes back to its pre-gesture state.
      _dropTransients(sync);
      return EditApplied(label: label, affected: out.affected, changedTracks: out.changedTracks, notices: out.notices);
    } catch (e, s) {
      _c._report(e, s, 'committing a gesture');
      _c._emitCurrent();
      return EditRejected(InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  @override
  void cancel() {
    if (!_open) return;
    _abort();
    if (identical(_c._tx, this)) _c._tx = null;
    _c._emitCurrent();
  }

  /// Cancels without emitting (another mutation follows).
  void _abort() {
    if (!_open) return;
    _open = false;
    try {
      _core.cancel();
    } catch (_) {}
    _dropTransients(_c._session.planSync);
  }

  void _dropTransients(PlanSync? sync) {
    if (_sent.isEmpty) return;
    final items = [..._sent];
    _sent.clear();
    if (sync == null) return;
    for (final id in items) {
      try {
        sync.dropTransientsFor(id);
      } catch (_) {}
    }
  }
}

/// Returned by `beginTransaction` when the editor can't edit: every call is a no-op.
final class _ClosedTransaction implements EditTransaction {
  _ClosedTransaction(this.label, this._project);

  @override
  final String label;

  final EditProject? _project;

  @override
  bool get isOpen => false;

  @override
  EditPreview? get preview => null;

  @override
  EditProject get working => _project ?? (throw StateError('the editor is not open'));

  @override
  EditResult update(EditCommand command) => const EditUnchanged();

  @override
  EditResult commit() => const EditUnchanged();

  @override
  void cancel() {}
}

/// Builds the value of `editorControllerProvider` for [id]: keeps the provider alive until
/// `close()` completes (ARCH §17.3).
EditorController createEditorController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final link = ref.keepAlive();
  final controller = EditorController(
    id: id,
    session: session,
    repository: ref.read(projectRepositoryProvider),
    engine: ref.read(editorEngineProvider),
    prefs: ref.read(editorPrefsProvider),
    compilers: ref.read(planCompilerPortProvider),
    // FIX-M1 (QA-02 M-1): the same tier-aware bound the shell waits for (longer on low/minimal).
    // Read lazily (on the first flush / close), never while the controller is built.
    flushTimeoutOf: () {
      try {
        return EditorLifecycle.flushTimeoutFor(ref.read(editorTierDefaultsProvider).tier);
      } on Object {
        return EditorLifecycle.defaultFlushTimeout;
      }
    },
  );
  controller.onReleased = link.close;

  // Background jobs resume on open (FIX-JOB-RESUME, QA-05 D3, ARCH §15): pending reverse, freeze
  // and proxy jobs (a process death or a close mid-job) are re-queued by the Tasks controller,
  // which nothing else may read until the user touches a clip. Read it once the session attaches;
  // it keeps itself alive until the session detaches.
  var disposed = false;
  void startTasks() {
    if (disposed || !session.isOpen) return;
    try {
      // Through the container: the Tasks controller watches this provider, so reading it through
      // this provider's own ref would be a circular dependency.
      ref.container.read(tasksControllerProvider(id));
    } on Object catch (e) {
      debugPrint('[EditorController] Could not start the background tasks: ${e.runtimeType}');
    }
  }

  void onAttached() {
    // After the listeners of this notification (the state follows the attach in the same turn).
    if (session.attached.value) scheduleMicrotask(startTasks);
  }

  session.attached.addListener(onAttached);
  ref.onDispose(() {
    disposed = true;
    try {
      session.attached.removeListener(onAttached);
    } on Object catch (_) {
      // The session's notifier was disposed first.
    }
  });
  return controller;
}
