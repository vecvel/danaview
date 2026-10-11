// OWNER: AI-07
//
// The polling WhisperJob (ai.md §4.7 "Polling implementation"):
//  * the native job is started off the UI isolate ([VwBindings.jobStart]); cancel/pause/resume/
//    threads requested before it exists are applied as soon as it does;
//  * a `Timer.periodic(250 ms)` reads `vw_job_status_get` (a leaf call); when `segments_ready`
//    is ahead of what was taken it takes the next page (`take_segments_json(taken, 256)`),
//    decodes it and emits [WhisperSegmentsAdded] per chunk, then a [WhisperJobStatus] when the
//    sample changed: at most one status per tick, i.e. <= 4 Hz;
//  * on a terminal state it drains the remaining segments (and the DETECT language result),
//    completes [result], closes [updates] and frees the native job off the UI isolate;
//  * a RUNNING job whose compute time has not moved for 120 s emits [WhisperJobStalled] once
//    (diagnostic only, nothing is killed);
//  * a [Finalizer] frees a native job whose Dart object became unreachable before it was freed.
//    While polling, the timer keeps the job reachable, so awaiting only [result] is safe.
// Transcript text is never logged; exception details carry status names only.

import 'dart:async';

import 'package:meta/meta.dart';

import 'codec.dart';
import 'runtime.dart';
import 'vw_bindings.dart';

/// Timing knobs of the runtime (ai.md defaults).
@immutable
final class WhisperRuntimeTimings {
  /// Creates the timings.
  const WhisperRuntimeTimings({
    this.jobPoll = const Duration(milliseconds: 250),
    this.modelPoll = const Duration(milliseconds: 50),
    this.idleRelease = const Duration(seconds: 60),
    this.stallAfter = const Duration(seconds: 120),
    this.segmentPage = 256,
    this.languageTopN = 5,
  });

  /// Job status poll period (4 Hz).
  final Duration jobPoll;

  /// Model-load state poll period.
  final Duration modelPoll;

  /// A model nobody uses is released this long after its last job or lease.
  final Duration idleRelease;

  /// RUNNING without compute progress for this long emits [WhisperJobStalled].
  final Duration stallAfter;

  /// Segments taken per call.
  final int segmentPage;

  /// Candidates read from a DETECT job.
  final int languageTopN;
}

/// Native handle plus a freed flag, shared by the job and its [Finalizer].
final class _JobCell {
  _JobCell(this.bindings);

  final VwBindings bindings;
  int handle = 0;
  bool freed = false;

  /// Frees once; returns the pending native free (null when nothing was to be freed).
  Future<void>? free() {
    if (freed || handle == 0) return null;
    freed = true;
    return bindings.jobFree(handle).catchError((Object _) {});
  }

  static void reap(_JobCell cell) {
    if (cell.freed || cell.handle == 0) return;
    cell.bindings.jobCancel(cell.handle);
    unawaited(cell.free());
  }
}

/// A [WhisperJob] over a native `vw_job`.
final class NativeWhisperJob implements WhisperJob {
  /// Starts [params] on [model] and polls it. [onEnded] runs once, synchronously when the
  /// terminal state was observed (or the start failed); [result] completes after [updates] closed.
  NativeWhisperJob.start({
    required VwBindings bindings,
    required int model,
    required VwJobParams params,
    required WhisperRuntimeTimings timings,
    void Function(NativeWhisperJob job)? onEnded,
  })  : _b = bindings,
        _timings = timings,
        _detect = params.mode == VwJobMode.detectLanguage,
        _onEnded = onEnded,
        _cell = _JobCell(bindings) {
    _result.future.ignore();
    unawaited(_start(model, params));
  }

  /// A job that failed before it started (busy model, released lease).
  NativeWhisperJob.failed(VwBindings bindings, WhisperException error)
      : _b = bindings,
        _timings = const WhisperRuntimeTimings(),
        _detect = false,
        _onEnded = null,
        _cell = _JobCell(bindings) {
    _result.future.ignore();
    _ended = true;
    _result.completeError(error);
    unawaited(_updates.close());
  }

  /// Frees a dropped job (test hook for the [Finalizer] callback).
  @visibleForTesting
  static void debugReap(NativeWhisperJob job) => _JobCell.reap(job._cell);

  static final Finalizer<_JobCell> _finalizer = Finalizer<_JobCell>(_JobCell.reap);

  final VwBindings _b;
  final WhisperRuntimeTimings _timings;
  final bool _detect;
  final void Function(NativeWhisperJob job)? _onEnded;
  final _JobCell _cell;

  final StreamController<WhisperJobUpdate> _updates = StreamController<WhisperJobUpdate>.broadcast();
  final Completer<WhisperJobResult> _result = Completer<WhisperJobResult>();
  final List<RawSegment> _segments = [];

  Timer? _timer;
  bool _ended = false;
  bool _cancelRequested = false;
  bool? _pendingPauseAbort;
  bool _pendingResume = false;
  int? _pendingThreads;

  int _taken = 0;
  VwJobStatusData? _lastEmitted;
  int _lastComputeMs = -1;
  Duration _computeUnchanged = Duration.zero;
  bool _stallReported = false;

  /// The native handle (0 before the start completed or after a failed start).
  @visibleForTesting
  int get debugHandle => _cell.handle;

  /// Whether the job has ended (terminal state observed or start failed).
  bool get isEnded => _ended;

  @override
  Stream<WhisperJobUpdate> get updates => _updates.stream;

  @override
  Future<WhisperJobResult> get result => _result.future;

  @override
  void cancel() {
    if (_ended) return;
    _cancelRequested = true;
    if (_cell.handle != 0) _b.jobCancel(_cell.handle);
  }

  @override
  void pause({bool abortCurrentChunk = false}) {
    if (_ended) return;
    if (_cell.handle == 0) {
      _pendingPauseAbort = (_pendingPauseAbort ?? false) || abortCurrentChunk;
      _pendingResume = false;
      return;
    }
    _b.jobPause(_cell.handle, abortCurrentChunk: abortCurrentChunk);
  }

  @override
  void resume() {
    if (_ended) return;
    if (_cell.handle == 0) {
      _pendingPauseAbort = null;
      _pendingResume = true;
      return;
    }
    _b.jobResume(_cell.handle);
  }

  @override
  set threads(int value) {
    if (_ended) return;
    final n = clampThreads(value);
    if (_cell.handle == 0) {
      _pendingThreads = n;
      return;
    }
    _b.jobSetThreads(_cell.handle, n);
  }

  Future<void> _start(int model, VwJobParams params) async {
    VwJobStartResult r;
    try {
      r = await _b.jobStart(model, params);
    } catch (_) {
      r = const VwJobStartResult(0, VwStatus.internal);
    }
    if (_ended) {
      // Abandoned while starting: stop the native job right away.
      if (r.handle != 0) {
        _cell.handle = r.handle;
        _b.jobCancel(r.handle);
        unawaited(_cell.free());
      }
      return;
    }
    if (r.status != VwStatus.ok || r.handle == 0) {
      _end(error: exceptionOf(r.status == VwStatus.ok ? VwStatus.internal : r.status, 'job start'));
      return;
    }
    _cell.handle = r.handle;
    _finalizer.attach(this, _cell, detach: _cell);
    if (_cancelRequested) {
      _b.jobCancel(r.handle);
    } else {
      final threads = _pendingThreads;
      if (threads != null) _b.jobSetThreads(r.handle, threads);
      final abort = _pendingPauseAbort;
      if (abort != null) _b.jobPause(r.handle, abortCurrentChunk: abort);
      if (_pendingResume) _b.jobResume(r.handle);
    }
    _timer = Timer.periodic(_timings.jobPoll, (_) => _poll());
  }

  /// One poll. Public for tests and the poll-cost benchmark; the timer calls it every 250 ms.
  @visibleForTesting
  void poll() => _poll();

  void _poll() {
    if (_ended || _cell.handle == 0) return;
    final s = _b.jobStatus(_cell.handle);
    final terminal = VwJobState.isTerminal(s.state);
    if (s.segmentsReady > _taken) _takeSegments(s.segmentsReady, drain: terminal);
    if (terminal) {
      _finish(s);
      return;
    }
    _watchStall(s);
    if (!_sameSample(_lastEmitted, s)) {
      _lastEmitted = s;
      _updates.add(statusOf(s));
    }
  }

  void _takeSegments(int ready, {required bool drain}) {
    // Without draining one page per tick (ai.md); on the terminal tick everything that is left.
    do {
      final want = ready - _taken;
      final page = want < _timings.segmentPage ? want : _timings.segmentPage;
      final first = _taken;
      final decoded = decodeSegmentsJson(_b.jobTakeSegmentsJson(_cell.handle, first, page), firstIndex: first);
      var got = decoded.count;
      var segments = decoded.segments;
      if (got < 0) {
        // Not a JSON array (never expected from the shim): retry one by one, skipping bad ones.
        segments = [];
        for (var k = 0; k < page; k++) {
          final one = decodeSegmentsJson(_b.jobTakeSegmentsJson(_cell.handle, first + k, 1), firstIndex: first + k);
          segments.addAll(one.segments);
        }
        got = page;
      }
      if (got == 0) return; // stale handle or nothing more: try again next tick
      _taken += got;
      _emitSegments(segments, chunkComplete: _taken >= ready);
    } while (drain && _taken < ready);
  }

  void _emitSegments(List<RawSegment> segments, {required bool chunkComplete}) {
    if (segments.isEmpty) return;
    _segments.addAll(segments);
    var start = 0;
    for (var k = 1; k <= segments.length; k++) {
      if (k == segments.length || segments[k].chunk != segments[start].chunk) {
        final last = k == segments.length;
        _updates.add(WhisperSegmentsAdded(
          segments: List<RawSegment>.unmodifiable(segments.sublist(start, k)),
          chunk: segments[start].chunk,
          chunkFinal: !last || chunkComplete,
        ));
        start = k;
      }
    }
  }

  void _watchStall(VwJobStatusData s) {
    if (s.state != VwJobState.running) {
      _computeUnchanged = Duration.zero;
      _lastComputeMs = s.computeMs;
      return;
    }
    if (s.computeMs != _lastComputeMs) {
      _lastComputeMs = s.computeMs;
      _computeUnchanged = Duration.zero;
      _stallReported = false;
      return;
    }
    _computeUnchanged += _timings.jobPoll;
    if (!_stallReported && _computeUnchanged >= _timings.stallAfter) {
      _stallReported = true;
      _updates.add(WhisperJobStalled(unchangedFor: _computeUnchanged, computeTime: Duration(milliseconds: s.computeMs)));
    }
  }

  static bool _sameSample(VwJobStatusData? a, VwJobStatusData b) =>
      a != null &&
      a.state == b.state &&
      a.phase == b.phase &&
      a.progressPermille == b.progressPermille &&
      a.chunkIndex == b.chunkIndex &&
      a.chunkCount == b.chunkCount &&
      a.chunksCompleted == b.chunksCompleted &&
      a.processedMs == b.processedMs &&
      a.computeMs == b.computeMs &&
      a.threads == b.threads &&
      a.language == b.language &&
      a.languageP == b.languageP;

  void _finish(VwJobStatusData s) {
    var languages = const <WhisperLanguageProbability>[];
    if (s.state == VwJobState.succeeded && _detect) {
      final lang = decodeLanguageJson(_b.jobLanguageJson(_cell.handle, _timings.languageTopN));
      if (lang != null) {
        languages = lang.top;
        _updates.add(lang);
      }
    }
    _updates.add(statusOf(s));
    switch (s.state) {
      case VwJobState.succeeded:
        final top = languages.isEmpty ? null : languages.first;
        _end(
          result: WhisperJobResult(
            segments: List<RawSegment>.unmodifiable(_segments),
            language: s.language.isNotEmpty ? s.language : (top?.code ?? ''),
            languageP: s.languageP != 0 ? s.languageP : (top?.p ?? 0),
            processed: Duration(milliseconds: s.processedMs),
            computeTime: Duration(milliseconds: s.computeMs),
            languages: languages,
          ),
        );
      case VwJobState.cancelled:
        _end(error: const WhisperException(WhisperErrorKind.cancelled));
      default:
        final code = s.error == VwStatus.ok ? VwStatus.internal : s.error;
        _end(error: code == VwStatus.cancelled ? const WhisperException(WhisperErrorKind.cancelled) : exceptionOf(code));
    }
  }

  void _end({WhisperJobResult? result, WhisperException? error}) {
    if (_ended) return;
    _ended = true;
    _timer?.cancel();
    _timer = null;
    _finalizer.detach(_cell);
    unawaited(_cell.free());
    _onEnded?.call(this);
    // The result completes once every update (and the done event) reached the listeners, so a
    // caller awaiting [result] has seen the whole stream.
    unawaited(_updates.close().whenComplete(() {
      if (error != null) {
        _result.completeError(error);
      } else {
        _result.complete(result);
      }
    }));
  }

  /// Stops polling and frees the native job without waiting for a terminal state (runtime
  /// disposal). [result] fails with `cancelled`.
  void abandon() {
    if (_ended) return;
    if (_cell.handle != 0) _b.jobCancel(_cell.handle);
    _end(error: const WhisperException(WhisperErrorKind.cancelled, 'runtime disposed'));
  }
}
