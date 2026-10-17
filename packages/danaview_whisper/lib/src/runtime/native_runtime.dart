// OWNER: AI-07
//
// The supported runtime (ai.md §4.7): model loading with Dart-side refcounting and the job
// factory. A model is identified by (path, options); every `loadModel` returns a lease on a shared
// native model. The model stays loaded while a lease or a job holds it; once nothing does it is
// released `idleRelease` (60 s) later, or immediately on a memory warning or
// [releaseIdleModels]. `loadModel` polls `dv_model_get_state` (leaf call) every 50 ms; a cancel
// token abandons the result and the native load frees itself.

import 'dart:async';

import 'package:meta/meta.dart';

import '../device/device.dart';
import '../support.dart';
import 'codec.dart';
import 'native_job.dart';
import 'runtime.dart';
import 'dv_bindings.dart';

/// Identity of a loaded model.
@immutable
final class _ModelKey {
  const _ModelKey(this.path, this.params);

  final String path;
  final DvModelParams params;

  @override
  bool operator ==(Object other) => other is _ModelKey && other.path == path && other.params == params;

  @override
  int get hashCode => Object.hash(path, params);
}

final class _Waiter {
  _Waiter(this.completer, this.cancel);

  final Completer<WhisperModel> completer;
  final WhisperCancelToken? cancel;
}

/// One native model shared by leases.
final class _ModelEntry {
  _ModelEntry(this.key, this.handle);

  final _ModelKey key;
  final int handle;
  WhisperModelInfo? info;
  int leases = 0;
  final List<_Waiter> waiters = [];
  NativeWhisperJob? activeJob;
  Timer? loadTimer;
  Timer? idleTimer;
  bool released = false;

  bool get isReady => info != null;
  int get refs => leases + waiters.length + (activeJob == null ? 0 : 1);
}

/// [WhisperRuntime] over a loaded native library.
final class NativeWhisperRuntime implements WhisperRuntime {
  /// Creates the runtime over [bindings] (already ABI-checked by `WhisperRuntime.open`).
  NativeWhisperRuntime({
    required DvBindings bindings,
    required this.device,
    this.timings = const WhisperRuntimeTimings(),
  })  : _b = bindings,
        engineVersion = _safeEngineVersion(bindings);

  final DvBindings _b;

  /// Timing knobs.
  final WhisperRuntimeTimings timings;

  final Map<_ModelKey, _ModelEntry> _models = {};
  StreamSubscription<WhisperDeviceEvent>? _deviceSub;
  bool _deviceListening = false;
  final Set<NativeWhisperJob> _jobs = {};
  bool _disposed = false;

  @override
  WhisperSupport get support => const WhisperSupported();

  @override
  final String engineVersion;

  @override
  final WhisperDeviceChannel device;

  static String _safeEngineVersion(DvBindings b) {
    try {
      return b.engineVersion();
    } catch (_) {
      return '';
    }
  }

  /// Native models currently held (loading or loaded).
  @visibleForTesting
  int get debugModelCount => _models.length;

  @override
  Future<WhisperModel> loadModel(
    String modelPath, {
    WhisperModelOptions options = const WhisperModelOptions(),
    WhisperCancelToken? cancel,
  }) {
    if (_disposed) return Future.error(const WhisperException(WhisperErrorKind.internal, 'runtime disposed'));
    if (cancel?.isCancelled ?? false) return Future.error(const WhisperException(WhisperErrorKind.cancelled));
    _listenToDevice();
    final key = _ModelKey(modelPath, modelParamsOf(options));
    var entry = _models[key];
    if (entry == null) {
      final int handle;
      try {
        handle = _b.modelLoad(modelPath, key.params);
      } catch (_) {
        return Future.error(const WhisperException(WhisperErrorKind.internal, 'dv_model_load'));
      }
      if (handle == 0) {
        return Future.error(const WhisperException(WhisperErrorKind.modelLoadFailed, 'model load: DV_ERR_INVALID_ARG'));
      }
      entry = _ModelEntry(key, handle);
      _models[key] = entry;
      final e = entry;
      e.loadTimer = Timer.periodic(timings.modelPoll, (_) => _pollLoad(e));
    }
    entry.idleTimer?.cancel();
    entry.idleTimer = null;
    if (entry.isReady) return Future.value(_lease(entry));
    final waiter = _Waiter(Completer<WhisperModel>(), cancel);
    entry.waiters.add(waiter);
    return waiter.completer.future;
  }

  _ModelLease _lease(_ModelEntry e) {
    e.leases++;
    return _ModelLease(this, e);
  }

  void _pollLoad(_ModelEntry e) {
    if (e.released) {
      e.loadTimer?.cancel();
      return;
    }
    // Abandoned waiters first: a cancelled load never returns a model.
    for (final w in List<_Waiter>.of(e.waiters)) {
      if (w.cancel?.isCancelled ?? false) {
        e.waiters.remove(w);
        w.completer.completeError(const WhisperException(WhisperErrorKind.cancelled));
      }
    }
    final state = _b.modelState(e.handle);
    if (state == DvModelState.loading) {
      if (e.refs == 0) _releaseNow(e); // everyone gave up; the native loader frees itself
      return;
    }
    e.loadTimer?.cancel();
    e.loadTimer = null;
    final info = state == DvModelState.ready ? _b.modelInfo(e.handle) : null;
    if (info == null) {
      final err = _b.modelError(e.handle);
      final code = err.status == DvStatus.ok || err.status == DvStatus.invalidArg ? DvStatus.modelLoad : err.status;
      final message = err.message.isEmpty ? statusName(code) : '${statusName(code)}: ${err.message}';
      final failure = WhisperException(errorKindOf(code), message);
      final waiters = List<_Waiter>.of(e.waiters);
      e.waiters.clear();
      _releaseNow(e);
      for (final w in waiters) {
        w.completer.completeError(failure);
      }
      return;
    }
    e.info = WhisperModelInfo(
      multilingual: info.multilingual,
      usesGpu: info.gpuUsed,
      gpuFallback: info.gpuFallback,
      vocabSize: info.nVocab,
    );
    final waiters = List<_Waiter>.of(e.waiters);
    e.waiters.clear();
    for (final w in waiters) {
      w.completer.complete(_lease(e));
    }
    _maybeIdle(e);
  }

  void _maybeIdle(_ModelEntry e) {
    if (e.released || e.refs > 0) return;
    if (!e.isReady) {
      _releaseNow(e);
      return;
    }
    e.idleTimer?.cancel();
    e.idleTimer = Timer(timings.idleRelease, () => _releaseNow(e));
  }

  void _releaseNow(_ModelEntry e) {
    if (e.released) return;
    e.released = true;
    e.loadTimer?.cancel();
    e.idleTimer?.cancel();
    e.loadTimer = null;
    e.idleTimer = null;
    if (identical(_models[e.key], e)) _models.remove(e.key);
    unawaited(_b.modelRelease(e.handle).catchError((Object _) {}));
  }

  @override
  Future<void> releaseIdleModels() async {
    for (final e in List<_ModelEntry>.of(_models.values)) {
      if (e.refs == 0) _releaseNow(e);
    }
  }

  void _listenToDevice() {
    if (_deviceListening) return;
    _deviceListening = true;
    _deviceSub = device.events.listen(
      (event) {
        if (event is MemoryWarning) unawaited(releaseIdleModels());
      },
      // A finished stream (no plugin) needs no cancel; cancelling a done subscription is avoided.
      onDone: () => _deviceSub = null,
    );
  }

  WhisperJob _startJob(_ModelEntry e, DvJobParams params) {
    if (_disposed || e.released) {
      return NativeWhisperJob.failed(_b, const WhisperException(WhisperErrorKind.internal, 'model released'));
    }
    if (e.activeJob != null) return NativeWhisperJob.failed(_b, exceptionOf(DvStatus.busy));
    e.idleTimer?.cancel();
    e.idleTimer = null;
    late final NativeWhisperJob job;
    job = NativeWhisperJob.start(
      bindings: _b,
      model: e.handle,
      params: params,
      timings: timings,
      onEnded: (j) {
        _jobs.remove(j);
        if (identical(e.activeJob, j)) e.activeJob = null;
        _maybeIdle(e);
      },
    );
    if (!job.isEnded) {
      e.activeJob = job;
      _jobs.add(job);
    }
    return job;
  }

  /// Cancels and frees every job, releases every model and stops listening (tests, teardown).
  @visibleForTesting
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final j in List<NativeWhisperJob>.of(_jobs)) {
      j.abandon();
    }
    for (final e in List<_ModelEntry>.of(_models.values)) {
      for (final w in e.waiters) {
        w.completer.completeError(const WhisperException(WhisperErrorKind.cancelled, 'runtime disposed'));
      }
      e.waiters.clear();
      _releaseNow(e);
    }
    final sub = _deviceSub;
    _deviceSub = null;
    if (sub != null) unawaited(sub.cancel());
  }
}

/// A lease on a shared model.
final class _ModelLease implements WhisperModel {
  _ModelLease(this._rt, this._e);

  final NativeWhisperRuntime _rt;
  final _ModelEntry _e;
  bool _released = false;

  @override
  WhisperModelInfo get info => _e.info!;

  @override
  bool get isBusy => _e.activeJob != null;

  @override
  WhisperJob detectLanguage(WhisperDetectRequest request) => _job(detectParamsOf(request));

  @override
  WhisperJob transcribe(WhisperTranscribeRequest request) => _job(transcribeParamsOf(request));

  WhisperJob _job(DvJobParams params) {
    if (_released) {
      return NativeWhisperJob.failed(_rt._b, const WhisperException(WhisperErrorKind.internal, 'model released'));
    }
    return _rt._startJob(_e, params);
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _e.leases--;
    _rt._maybeIdle(_e);
  }
}
