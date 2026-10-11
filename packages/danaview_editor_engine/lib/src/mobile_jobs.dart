// OWNER: ENG-03
//
// Thumbnails, waveforms and media jobs over `JobsHostApi` (ARCH §12.3, §15).
//
// Rules:
// - MobileThumbnailSource keeps at most [MobileThumbnailSource.maxInFlight] (8) `thumbnailTile`
//   calls in flight; the rest wait in one FIFO queue per priority (visible > prefetch >
//   background). Cancelling a queued request never reaches native; cancelling a dispatched one
//   sends `cancelThumbnail` and completes the handle with `EngineCancelled` at once. The slot is
//   freed when native answers, so native never holds more than eight tiles. A native reply that
//   arrives after the cancel is ignored.
// - A MediaJob has a Dart id at once (the API is synchronous); the native job id arrives with the
//   `startJob` reply. Its events come from `channels.router.job(nativeId)` (the router buffers
//   events that race the reply). `progress` forwards 0..1 samples; `jobDone` completes with the
//   result of the expected kind (a wrong or missing payload is `internal`); a `failure` event
//   completes with the mapped failure. `cancel` completes with `EngineCancelled` immediately,
//   sends `cancelJob` (also when it happens before the native id is known: the cancel is sent as
//   soon as the reply arrives) and drops later events. `setPriority` is forwarded once the native
//   id is known; the latest value wins.
// - `proxyStatus` is synchronous: it answers from a per-fingerprint cache fed by proxy jobs
//   started here and by a background `JobsHostApi.proxyStatus` refresh on first use
//   ([MobileMediaJobs.refreshProxyStatus]).

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:danaview_editor_core/model.dart' show TimeRange, TimeUs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'error_mapper.dart';
import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

/// A short random tag so ids of this Dart isolate never collide with ids a previous isolate
/// (hot restart) left in the native engine.
String _instanceTag() => math.Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

/// Sends a fire-and-forget host call; its failure is irrelevant to the caller.
void _fireAndForget(EngineChannels channels, Future<void> Function() call) =>
    unawaited(channels.invoke(call).then<void>((_) {}, onError: (Object _) {}));

// ---------------------------------------------------------------------------------------------
// Thumbnails
// ---------------------------------------------------------------------------------------------

/// Thumbnail strips over `JobsHostApi.thumbnailTile` (ARCH §12.3, ENG-03).
final class MobileThumbnailSource implements ThumbnailSource {
  /// Creates the source. [maxInFlight] is the native concurrency cap (8).
  MobileThumbnailSource(this._channels, {this.maxInFlight = defaultMaxInFlight}) : assert(maxInFlight > 0);

  /// Most tiles requested from native at once (ARCH §15: <= 8 concurrent).
  static const int defaultMaxInFlight = 8;

  final EngineChannels _channels;

  /// Concurrency cap.
  final int maxInFlight;

  final String _tag = _instanceTag();
  int _n = 0;
  int _inFlight = 0;
  final List<Queue<MobileThumbnailHandle>> _queues = [
    for (final _ in ThumbPriority.values) Queue<MobileThumbnailHandle>(),
  ];

  /// `thumbnailTile` calls not answered yet (cancelled ones included until native answers).
  @visibleForTesting
  int get inFlight => _inFlight;

  /// Requests waiting for a slot.
  @visibleForTesting
  int get queued => _queues.fold(0, (n, q) => n + q.length);

  @override
  ThumbnailHandle request(ThumbnailRequest request, {required ThumbPriority priority}) {
    final handle = MobileThumbnailHandle._(this, 'th$_tag-${_n++}', request, priority);
    _queues[priority.index].add(handle);
    _pump();
    return handle;
  }

  void _pump() {
    while (_inFlight < maxInFlight) {
      final next = _nextQueued();
      if (next == null) return;
      _dispatch(next);
    }
  }

  MobileThumbnailHandle? _nextQueued() {
    for (final q in _queues) {
      if (q.isNotEmpty) return q.removeFirst();
    }
    return null;
  }

  void _dispatch(MobileThumbnailHandle h) {
    _inFlight++;
    h._dispatched = true;
    unawaited(_channels
        .invoke(() => _channels.jobs.thumbnailTile(h.requestId, thumbnailRequestToMsg(h.request), thumbPriorityToMsg(h.priority)))
        .then<void>(
          (tile) => h._succeed(thumbnailTileFromMsg(tile)),
          onError: (Object e, StackTrace st) => h._fail(mapEngineError(e), st),
        )
        .whenComplete(() {
      _inFlight--;
      _pump();
    }));
  }

  void _cancel(MobileThumbnailHandle h) {
    if (h._result.isCompleted) return;
    if (h._dispatched) {
      _fireAndForget(_channels, () => _channels.jobs.cancelThumbnail(h.requestId));
    } else {
      _queues[h.priority.index].remove(h);
    }
    h._result.completeError(const EngineCancelled());
  }
}

/// A queued or running thumbnail request (ARCH §12.3, ENG-03).
final class MobileThumbnailHandle implements ThumbnailHandle {
  MobileThumbnailHandle._(this._source, this.requestId, this.request, this.priority) {
    _result.future.ignore();
  }

  final MobileThumbnailSource _source;

  /// Id sent to native (`thumbnailTile` / `cancelThumbnail`).
  final String requestId;

  /// The request.
  final ThumbnailRequest request;

  /// Its priority.
  final ThumbPriority priority;

  final Completer<ThumbnailTile> _result = Completer<ThumbnailTile>();
  bool _dispatched = false;

  /// Whether the request reached native.
  @visibleForTesting
  bool get dispatched => _dispatched;

  void _succeed(ThumbnailTile tile) {
    if (!_result.isCompleted) _result.complete(tile);
  }

  void _fail(EngineFailure failure, StackTrace st) {
    if (!_result.isCompleted) _result.completeError(failure, st);
  }

  @override
  Future<ThumbnailTile> get result => _result.future;

  @override
  void cancel() => _source._cancel(this);
}

// ---------------------------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------------------------

/// Lifecycle notifications of a job (used for the proxy status cache).
enum _JobPhase { running, done, failed, cancelled }

/// A native media job (ARCH §12.3, ENG-03). See the file header for the rules.
final class MobileMediaJob<T> implements MediaJob<T> {
  MobileMediaJob._(
    this._channels,
    this.id,
    this.kind,
    this._priority,
    this._decode, [
    this._onPhase,
  ]) {
    _result.future.ignore();
  }

  final EngineChannels _channels;

  @override
  final String id;

  /// Native job kind.
  final JobKindMsg kind;

  final T? Function(JobResultMsg) _decode;
  final void Function(_JobPhase)? _onPhase;
  final StreamController<double> _progress = StreamController<double>.broadcast();
  final Completer<T> _result = Completer<T>();
  JobPriority _priority;
  JobPriority? _sentPriority;
  String? _nativeId;
  bool _sawProgress = false;
  double _lastProgress = 0;

  /// The native job id once `startJob` answered.
  @visibleForTesting
  String? get nativeId => _nativeId;

  /// Whether [result] completed.
  bool get isDone => _result.isCompleted;

  /// The priority last requested.
  JobPriority get priority => _priority;

  void _start(JobRequestMsg request) {
    _sentPriority = _priority;
    unawaited(_channels.invoke(() => _channels.jobs.startJob(request)).then<void>(
          _onStarted,
          onError: (Object e, StackTrace st) => _finishError(mapEngineError(e), st),
        ));
  }

  void _onStarted(String nativeId) {
    _nativeId = nativeId;
    if (_result.isCompleted) {
      // Cancelled (or failed) before native answered: stop the native job now.
      _fireAndForget(_channels, () => _channels.jobs.cancelJob(nativeId));
      _channels.router.release(nativeId);
      return;
    }
    _channels.router.job(nativeId).listen(_onEvent, onDone: _onRouteClosed);
    if (_priority != _sentPriority) _sendPriority();
  }

  void _onEvent(EngineEventMsg e) {
    if (_result.isCompleted) return;
    switch (e.kind) {
      case EngineEventKindMsg.progress:
        final p = (e.progress ?? 0).clamp(0.0, 1.0);
        _lastProgress = p;
        if (!_sawProgress) {
          _sawProgress = true;
          _onPhase?.call(_JobPhase.running);
        }
        if (!_progress.isClosed) _progress.add(p);
      case EngineEventKindMsg.jobDone:
        final done = e.jobDone!;
        final value = done.kind == kind ? _decode(done) : null;
        if (value == null) {
          _finishError(
            EngineFailure.of(EngineErrorCode.internal, debugDetail: 'job ${kind.name} finished with a ${done.kind.name} result'),
            StackTrace.current,
          );
        } else {
          if (_lastProgress < 1 && !_progress.isClosed) _progress.add(1);
          _result.complete(value as T);
          _onPhase?.call(_JobPhase.done);
          unawaited(_progress.close());
        }
      case EngineEventKindMsg.failure:
        _finishError(failureFromMsg(e.failure!), StackTrace.current);
      default:
        break;
    }
  }

  void _onRouteClosed() {
    if (_result.isCompleted) return;
    _finishError(
      EngineFailure.of(EngineErrorCode.interrupted, debugDetail: 'job event stream closed', retryable: true),
      StackTrace.current,
    );
  }

  void _finishError(EngineFailure failure, StackTrace st) {
    if (_result.isCompleted) return;
    _result.completeError(failure, st);
    _onPhase?.call(failure is EngineCancelled ? _JobPhase.cancelled : _JobPhase.failed);
    unawaited(_progress.close());
  }

  void _sendPriority() {
    final id = _nativeId;
    if (id == null) return;
    final p = _priority;
    _sentPriority = p;
    _fireAndForget(_channels, () => _channels.jobs.setJobPriority(id, jobPriorityToMsg(p)));
  }

  @override
  Stream<double> get progress => _progress.stream;

  @override
  Future<T> get result => _result.future;

  @override
  void cancel() {
    if (_result.isCompleted) return;
    _finishError(const EngineCancelled(), StackTrace.current);
    final id = _nativeId;
    if (id != null) {
      _fireAndForget(_channels, () => _channels.jobs.cancelJob(id));
      _channels.router.release(id);
    }
    // Otherwise _onStarted sends the cancel when the native id arrives.
  }

  @override
  void setPriority(JobPriority priority) {
    if (_result.isCompleted || priority == _priority) return;
    _priority = priority;
    if (_nativeId != null && priority != _sentPriority) _sendPriority();
  }
}

/// Starts [MobileMediaJob]s with locally unique ids.
final class _JobStarter {
  _JobStarter(this.channels, this.prefix);

  final EngineChannels channels;
  final String prefix;
  final String _tag = _instanceTag();
  int _n = 0;

  MobileMediaJob<T> start<T>(
    JobRequestMsg request,
    JobPriority priority,
    T? Function(JobResultMsg) decode, [
    void Function(_JobPhase)? onPhase,
  ]) {
    final job = MobileMediaJob<T>._(channels, '$prefix$_tag-${_n++}', request.kind, priority, decode, onPhase);
    job._start(request);
    return job;
  }
}

GeneratedAsset? _assetOf(JobResultMsg m) => switch (m.asset) {
      final a? => generatedAssetFromMsg(a),
      null => null,
    };

/// Waveform peaks over `JobsHostApi.startJob(waveform)` (ARCH §12.3, ENG-03).
final class MobileWaveformSource implements WaveformSource {
  /// Creates the source.
  MobileWaveformSource(EngineChannels channels) : _starter = _JobStarter(channels, 'wave');

  final _JobStarter _starter;

  @override
  MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0}) => _starter.start<WaveformPeaks>(
        JobRequestMsg(kind: JobKindMsg.waveform, media: mediaToMsg(media), priority: JobPriorityMsg.normal, audioStream: audioStream),
        JobPriority.normal,
        (m) => switch (m.peaks) {
          final p? => waveformPeaksFromMsg(p),
          null => null,
        },
      );
}

/// Proxies, reverse renditions, freeze stills and speech audio over `JobsHostApi`
/// (ARCH §12.3, ENG-03).
///
/// Default priorities (ARCH §12.3): freeze frames and reverse renditions are `interactive` (the
/// user waits), speech audio is `normal`, proxies are `background`.
final class MobileMediaJobs implements MediaJobs {
  /// Creates the jobs service.
  MobileMediaJobs(EngineChannels channels)
      : _channels = channels,
        _starter = _JobStarter(channels, 'job');

  final EngineChannels _channels;
  final _JobStarter _starter;
  final Map<String, ProxyStatus> _proxy = {};
  final Set<String> _proxyRefreshed = {};
  final Map<String, int> _proxyJobs = {};

  MobileMediaJob<T> _start<T>(
    JobKindMsg kind,
    EngineMedia media,
    JobPriority priority,
    T? Function(JobResultMsg) decode, {
    int? audioStream,
    int? sourceStartUs,
    int? sourceEndUs,
    int? sourceTimeUs,
    String? outputPath,
    void Function(_JobPhase)? onPhase,
  }) =>
      _starter.start<T>(
        JobRequestMsg(
          kind: kind,
          media: mediaToMsg(media),
          priority: jobPriorityToMsg(priority),
          audioStream: audioStream,
          sourceStartUs: sourceStartUs,
          sourceEndUs: sourceEndUs,
          sourceTimeUs: sourceTimeUs,
          outputPath: outputPath,
        ),
        priority,
        decode,
        onPhase,
      );

  @override
  MediaJob<GeneratedAsset> proxy(EngineMedia media) {
    final fp = media.fingerprint;
    _proxy[fp] = ProxyStatus.queued;
    _proxyJobs[fp] = (_proxyJobs[fp] ?? 0) + 1;
    return _start<GeneratedAsset>(JobKindMsg.proxy, media, JobPriority.background, _assetOf, onPhase: (phase) {
      switch (phase) {
        case _JobPhase.running:
          _proxy[fp] = ProxyStatus.running;
          return;
        case _JobPhase.done:
          _proxy[fp] = ProxyStatus.ready;
        case _JobPhase.failed:
          _proxy[fp] = ProxyStatus.failed;
        case _JobPhase.cancelled:
          if (_proxy[fp] != ProxyStatus.ready) _proxy[fp] = ProxyStatus.none;
      }
      final left = (_proxyJobs[fp] ?? 1) - 1;
      if (left <= 0) {
        _proxyJobs.remove(fp);
      } else {
        _proxyJobs[fp] = left;
      }
    });
  }

  @override
  MediaJob<GeneratedAsset> reverse(EngineMedia media, TimeRange source, {required String outputPath}) => _start<GeneratedAsset>(
        JobKindMsg.reverse,
        media,
        JobPriority.interactive,
        _assetOf,
        sourceStartUs: source.start,
        sourceEndUs: source.end,
        outputPath: outputPath,
      );

  @override
  MediaJob<GeneratedAsset> freezeFrame(EngineMedia media, TimeUs sourceTime, {required String outputPath}) => _start<GeneratedAsset>(
        JobKindMsg.freeze,
        media,
        JobPriority.interactive,
        _assetOf,
        sourceTimeUs: sourceTime,
        outputPath: outputPath,
      );

  @override
  MediaJob<ExtractedSpeechAudio> extractSpeechAudio(SpeechAudioJobRequest request) => _start<ExtractedSpeechAudio>(
        JobKindMsg.speechAudio,
        request.media,
        JobPriority.normal,
        (m) => switch (m.speech) {
          final s? => extractedSpeechAudioFromMsg(s),
          null => null,
        },
        audioStream: request.audioStream,
        sourceStartUs: request.range.start,
        sourceEndUs: request.range.end,
        outputPath: request.outputPath,
      );

  /// The cached proxy state of [media]. The first query for a fingerprint also refreshes the
  /// cache from native in the background ([refreshProxyStatus]); until then it answers
  /// [ProxyStatus.none] (or the state of a proxy job started here).
  @override
  ProxyStatus proxyStatus(EngineMedia media) {
    final fp = media.fingerprint;
    if (_proxyRefreshed.add(fp) && !_proxyJobs.containsKey(fp)) {
      unawaited(refreshProxyStatus(media).then<void>((_) {}, onError: (Object _) => _proxyRefreshed.remove(fp)));
    }
    return _proxy[fp] ?? ProxyStatus.none;
  }

  /// Asks native for the proxy state of [media] and caches it (a proxy job running here keeps its
  /// own, fresher state).
  Future<ProxyStatus> refreshProxyStatus(EngineMedia media) async {
    final fp = media.fingerprint;
    final status = proxyStatusFromMsg(await _channels.invoke(() => _channels.jobs.proxyStatus(fp)));
    if (_proxyJobs.containsKey(fp)) return _proxy[fp] ?? status;
    _proxy[fp] = status;
    return status;
  }
}
