// OWNER: ENG-04
//
// Export over `ExportHostApi` (ARCH §12.4, §14, D-22, D-39).
//
// Rules:
// - Plans cross the channel as UTF-8 JSON bytes (`PlanTransport.encodePlan`, API-02; large plans
//   are encoded in an isolate). Every host call goes through `EngineChannels.invoke`, so failures
//   are `EngineFailure`s (never a raw PlatformException).
// - A [MobileExportJob] listens to `channels.router.job(jobId)`. The router already limits
//   `exportProgress` to <= 4 Hz (phase, background and warning changes pass at once) and buffers
//   events that race the `start` reply. `exportProgress` maps to [ExportProgress]; `jobDone`
//   with an export result completes [ExportJob.result] (a missing or wrong-kind payload is
//   `internal`); a `failure` event completes it with the mapped failure (`cancelled` →
//   `EngineCancelled`); a route that closes without a terminal event is `interrupted`
//   (retryable).
// - `cancel` completes the result with `EngineCancelled` at once, stops routing the job's events
//   (late events are dropped) and sends `ExportHostApi.cancel`, which deletes the partial file and
//   the iOS segments. It is idempotent; a failing native cancel does not resurrect the job.
// - The service keeps the jobs of this isolate by id. `activeJobs()` maps every native record
//   (`exportJobStateFromMsg`) and reports each job id at most once per call:
//   - `running` → [ExportRunning] with the live job of this isolate when there is one (the same
//     object every time), otherwise a job reattached over the router (hot restart / relaunch).
//     A running record for a job this isolate already saw finish (a race with the native store)
//     is dropped.
//   - `resumable` (iOS, D-22) and `interrupted` for a job this isolate still holds end that job
//     with a retryable `interrupted` failure, without marking the id as ended in the router, so
//     `resume(jobId)` can listen to the same id again.
//   - One-shot records (`interrupted`, `completedWhileDetached`; D-22, D-39) are returned until
//     [MobileExportService.consumeJobRecord]; once consumed they are never reported again by this
//     service, even if the native store still lists them.
// - `resume(jobId)` re-attaches to the id native answers (normally the same id).

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';
import 'error_mapper.dart' show failureFromMsg;

/// Export over `ExportHostApi` (ARCH §12.4, §14, ENG-04). See the file header for the rules.
final class MobileExportService implements ExportService {
  /// Creates the export service.
  MobileExportService(this._channels);

  final EngineChannels _channels;

  /// Jobs started, resumed or reattached by this isolate, by id (finished ones included until a
  /// newer job takes the id).
  final Map<String, MobileExportJob> _jobs = {};

  /// One-shot records consumed by this isolate.
  final Set<String> _consumed = {};

  /// The job of this isolate with [jobId], if any.
  @visibleForTesting
  MobileExportJob? jobOf(String jobId) => _jobs[jobId];

  @override
  Future<ExportPreflight> preflight(RenderPlan plan, EncodeSettings settings) async {
    final bytes = await PlanTransport.encodePlan(plan);
    final msg = await _channels.invoke(() => _channels.export.preflight(bytes, encodeSettingsToMsg(settings)));
    return exportPreflightFromMsg(msg);
  }

  @override
  Future<ExportJob> start(
    RenderPlan plan,
    EncodeSettings settings, {
    required String outputPath,
    required String title,
    ExportDetachedHandoff whenDetached = ExportDetachedHandoff.saveToGallery,
  }) async {
    final bytes = await PlanTransport.encodePlan(plan);
    final jobId = await _channels.invoke(
      () => _channels.export.start(bytes, encodeSettingsToMsg(settings), outputPath, title, detachedHandoffToMsg(whenDetached)),
    );
    return _attach(jobId);
  }

  @override
  Future<ExportJob> resume(String jobId) async {
    final live = _jobs[jobId];
    if (live != null && !live.isDone) return live;
    final id = await _channels.invoke(() => _channels.export.resume(jobId));
    _consumed.remove(id);
    return _attach(id, replace: true);
  }

  @override
  Future<List<ExportJobState>> activeJobs() async {
    final records = await _channels.invoke(_channels.export.activeJobs);
    final seen = <String>{};
    final out = <ExportJobState>[];
    for (final r in records) {
      final id = r.jobId;
      if (id.isEmpty || !seen.add(id)) continue;
      switch (r.state) {
        case ExportJobStateKindMsg.running:
          final live = _jobs[id];
          if (live != null && live.isDone) continue; // finished here; the native store lags.
          out.add(ExportRunning(_attach(id)));
        case ExportJobStateKindMsg.resumable:
          _jobs[id]?._interruptedElsewhere();
          if (_consumed.contains(id)) continue;
          out.add(exportJobStateFromMsg(r, reattach: _attach));
        case ExportJobStateKindMsg.interrupted:
        case ExportJobStateKindMsg.completedWhileDetached:
          if (r.state == ExportJobStateKindMsg.interrupted) _jobs[id]?._interruptedElsewhere();
          if (_consumed.contains(id)) continue;
          out.add(exportJobStateFromMsg(r, reattach: _attach));
      }
    }
    return List<ExportJobState>.unmodifiable(out);
  }

  @override
  Future<void> consumeJobRecord(String jobId) async {
    await _channels.invoke(() => _channels.export.consumeJobRecord(jobId));
    _consumed.add(jobId);
  }

  /// The live job [jobId] of this isolate, or a new one listening to the router.
  MobileExportJob _attach(String jobId, {bool replace = false}) {
    final existing = _jobs[jobId];
    if (existing != null && !(replace && existing.isDone)) return existing;
    final job = MobileExportJob._(_channels, jobId);
    _jobs[jobId] = job;
    job._listen();
    return job;
  }
}

/// A running export (ARCH §12.4, ENG-04). See the file header of `mobile_export.dart`.
final class MobileExportJob implements ExportJob {
  MobileExportJob._(this._channels, this.id) {
    _result.future.ignore();
  }

  final EngineChannels _channels;

  @override
  final String id;

  final StreamController<ExportProgress> _progress = StreamController<ExportProgress>.broadcast();
  final Completer<ExportResult> _result = Completer<ExportResult>();
  StreamSubscription<EngineEventMsg>? _sub;
  ExportProgress? _last;
  Future<void>? _cancelling;

  /// Whether [result] completed.
  bool get isDone => _result.isCompleted;

  /// The latest progress sample (a reattached UI shows it before the next sample arrives).
  ExportProgress? get lastProgress => _last;

  @override
  Stream<ExportProgress> get progress => _progress.stream;

  @override
  Future<ExportResult> get result => _result.future;

  void _listen() {
    _sub = _channels.router.job(id).listen(_onEvent, onDone: _onRouteClosed);
  }

  void _onEvent(EngineEventMsg e) {
    if (_result.isCompleted) return;
    switch (e.kind) {
      case EngineEventKindMsg.exportProgress:
        final p = exportProgressFromMsg(e.exportProgress!);
        _last = p;
        if (!_progress.isClosed) _progress.add(p);
      case EngineEventKindMsg.jobDone:
        final done = e.jobDone!;
        final r = done.kind == JobKindMsg.export ? done.exportResult : null;
        if (r == null) {
          _finishError(
            EngineFailure.of(EngineErrorCode.internal, debugDetail: 'export finished with a ${done.kind.name} result'),
            StackTrace.current,
          );
        } else {
          _result.complete(exportResultFromMsg(r));
          _closeProgress();
        }
      case EngineEventKindMsg.failure:
        _finishError(failureFromMsg(e.failure!), StackTrace.current);
      default:
        break;
    }
  }

  void _onRouteClosed() {
    _sub = null;
    if (_result.isCompleted) return;
    _finishError(
      EngineFailure.of(EngineErrorCode.interrupted, debugDetail: 'export event stream closed', retryable: true),
      StackTrace.current,
    );
  }

  /// Native reports this job as resumable or interrupted while this isolate still listens: end it
  /// without marking the id as ended in the router (a resume may reuse the id).
  void _interruptedElsewhere() {
    if (_result.isCompleted) return;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    _finishError(
      EngineFailure.of(EngineErrorCode.interrupted, debugDetail: 'export interrupted', retryable: true),
      StackTrace.current,
    );
  }

  void _finishError(EngineFailure failure, StackTrace st) {
    if (_result.isCompleted) return;
    _result.completeError(failure, st);
    _closeProgress();
  }

  void _closeProgress() {
    if (!_progress.isClosed) unawaited(_progress.close());
  }

  @override
  Future<void> cancel() {
    final pending = _cancelling;
    if (pending != null) return pending;
    if (_result.isCompleted) return Future<void>.value();
    _finishError(const EngineCancelled(), StackTrace.current);
    _sub = null;
    _channels.router.release(id);
    return _cancelling = _channels.invoke(() => _channels.export.cancel(id)).then<void>((_) {}, onError: (Object _) {});
  }
}
