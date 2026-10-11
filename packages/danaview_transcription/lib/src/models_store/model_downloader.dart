// OWNER: AI-09
//
// Resumable, verified model downloader (ARCH §16.3, ai.md §5.3). Plain dart:io HttpClient:
//
//  1. consent must equal the catalog disclosure, else `consentMismatch` before any request;
//  2. free-space preflight (remaining + 64 MiB);
//  3. GET the pinned huggingface.co URL with `followRedirects = false` and `User-Agent: Danaview/<v>`;
//     expect 302 and compare `x-linked-size` / `x-linked-etag` with the catalog BEFORE any byte is
//     written; the signed `Location` is never persisted and every retry re-resolves it;
//  4. ranged GET on the Location: 206 appends, 200 restarts, 416 verifies or restarts; sidecar
//     every 4 MiB; 15 s connect and 30 s idle timeouts;
//  5. transient errors (reset, timeout, 5xx, 429) retry 3 times with 2/4/8 s backoff + jitter;
//  6. SHA-256 in an isolate, ggml magic, atomic rename, backup exclusion, manifest update.
//
// Cancellation uses danaview_data's NetworkCancelToken. iOS background: a background task is begun
// when the app leaves the foreground; when it expires the download stops with the partial kept
// and fails with `interrupted`.

library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:danaview_data/danaview_data.dart' show NetworkCancelToken;
import 'package:danaview_whisper/danaview_whisper.dart' show AppStateChanged, BackgroundTaskExpiring, WhisperAppState;

import '../catalog/speech_model_catalog.dart';
import '../contracts/failures.dart';
import '../contracts/transcription_service.dart';
import 'model_file_checks.dart';
import 'model_manifest.dart';
import 'model_store_ports.dart';

const int _mib = 1024 * 1024;

/// A running model download (ai.md §5.3).
abstract interface class ModelDownload {
  /// Progress samples, at most 4 per second plus every phase change. Broadcast.
  Stream<ModelDownloadProgress> get progress;

  /// Completes with the installed model; fails with `ModelDownloadFailure`.
  Future<InstalledSpeechModel> get done;

  /// Stops the download. With [keepPartial] the `.part` file and its sidecar stay for a resume;
  /// without it they are deleted. [done] then fails with `ModelDownloadFailureKind.cancelled`.
  void cancel({bool keepPartial = true});
}

/// Tunables and test seams of the downloader. Production uses the defaults.
final class ModelDownloaderConfig {
  /// Creates a config.
  const ModelDownloaderConfig({
    this.appVersion = '0',
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
    this.retryBackoff = const [Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)],
    this.sidecarEveryBytes = 4 * _mib,
    this.freeSpaceMarginBytes = 64 * _mib,
    this.progressInterval = const Duration(milliseconds: 250),
    this.staleAfter = const Duration(days: 7),
    this.urlFor,
    this.httpClientFactory,
    this.isAllowedRedirect,
    this.delay,
    this.random,
  });

  /// App version for `User-Agent: Danaview/<version>`. Nothing else identifies the user or device.
  final String appVersion;

  /// HttpClient connection timeout.
  final Duration connectTimeout;

  /// Longest wait for response headers or for the next body chunk.
  final Duration idleTimeout;

  /// Wait before retry 1, 2, 3 (jitter is added); its length is the retry count.
  final List<Duration> retryBackoff;

  /// Sidecar rewrite interval in bytes.
  final int sidecarEveryBytes;

  /// Free space kept beyond the remaining bytes.
  final int freeSpaceMarginBytes;

  /// Minimum time between progress samples (4 Hz).
  final Duration progressInterval;

  /// Partials older than this are swept.
  final Duration staleAfter;

  /// Test seam: the URL requested for a spec (default: the catalog URL).
  final Uri Function(SpeechModelSpec spec)? urlFor;

  /// Test seam: the HttpClient to use (default: a plain [HttpClient]).
  final HttpClient Function()? httpClientFactory;

  /// Test seam: whether a `Location` may be followed (default: https on the catalog CDN host).
  final bool Function(Uri location)? isAllowedRedirect;

  /// Test seam: how backoff waits (default: [Future.delayed]).
  final Future<void> Function(Duration duration)? delay;

  /// Test seam: jitter source.
  final math.Random? random;

  /// The URL requested for [spec].
  Uri urlOf(SpeechModelSpec spec) => urlFor?.call(spec) ?? Uri.parse(spec.url);

  /// Whether [location] may be followed.
  bool allowsRedirect(Uri location) {
    final custom = isAllowedRedirect;
    if (custom != null) return custom(location);
    const cdn = SpeechModelCatalog.cdnHost;
    return location.scheme == 'https' && (location.host == cdn || location.host.endsWith('.$cdn'));
  }
}

/// Where the store keeps a download's files.
final class ModelStoreLayout {
  /// Layout under `<support>/danaview/speech/models/`.
  ModelStoreLayout(String supportDirectory) : dir = p.join(supportDirectory, 'danaview', 'speech', 'models');

  /// The models folder.
  final String dir;

  /// `manifest.json`.
  String get manifest => p.join(dir, 'manifest.json');

  /// Final path of [spec].
  String fileOf(SpeechModelSpec spec) => p.join(dir, spec.fileName);

  /// `.part` path of [spec].
  String partOf(SpeechModelSpec spec) => '${fileOf(spec)}.part';

  /// Sidecar path of [spec].
  String sidecarOf(SpeechModelSpec spec) => '${fileOf(spec)}.part.json';
}

/// Store operations a download needs.
abstract interface class ModelDownloadHost {
  /// The installed, verified record of [spec], or null.
  Future<InstalledSpeechModel?> installedOf(SpeechModelSpec spec);

  /// Moves the verified `.part` of [spec] into place: atomic rename, backup exclusion, manifest.
  Future<InstalledSpeechModel> commit(SpeechModelSpec spec);

  /// Records that the downloaded file of [modelId] failed verification.
  void reportCorrupt(String modelId);

  /// Receives progress samples (the store mirrors them into its status).
  void reportProgress(String modelId, ModelDownloadProgress progress);
}

/// A download that failed before it began (consent mismatch, unknown model).
final class FailedModelDownload implements ModelDownload {
  /// Creates a download that fails with [kind].
  FailedModelDownload(ModelDownloadFailureKind kind) : done = Future<InstalledSpeechModel>.error(ModelDownloadFailure(kind)) {
    done.ignore();
  }

  @override
  final Future<InstalledSpeechModel> done;

  @override
  Stream<ModelDownloadProgress> get progress => const Stream<ModelDownloadProgress>.empty();

  @override
  void cancel({bool keepPartial = true}) {}
}

enum _CancelReason { none, user, backgroundExpired }

/// Thrown inside the task when the cancel token fired.
final class _Stopped implements Exception {
  const _Stopped();
}

/// A failure worth retrying.
final class _Transient implements Exception {
  const _Transient(this.kind);
  final ModelDownloadFailureKind kind;
}

enum _AttemptOutcome { fetched, restart }

/// The task behind one [ModelDownload]. Created by the store; one runs at a time.
final class ModelDownloadTask implements ModelDownload {
  /// Creates and starts a download of [model] (plus [vad] when non-null).
  ModelDownloadTask({
    required this.model,
    required this.vad,
    required this.totalBytes,
    required this.layout,
    required this.platform,
    required this.wakelock,
    required this.config,
    required this.host,
  }) {
    _done.future.then<void>((_) {}, onError: (Object _) {});
    scheduleMicrotask(_run);
  }

  /// The model being installed.
  final SpeechModelSpec model;

  /// The VAD model to install with it, if any.
  final SpeechModelSpec? vad;

  /// Bytes in total as disclosed to the user (progress denominator).
  final int totalBytes;

  /// File layout.
  final ModelStoreLayout layout;

  /// Device services.
  final ModelStorePlatform platform;

  /// Wakelock held while running.
  final DownloadWakelock wakelock;

  /// Tunables.
  final ModelDownloaderConfig config;

  /// The store.
  final ModelDownloadHost host;

  final StreamController<ModelDownloadProgress> _progress = StreamController<ModelDownloadProgress>.broadcast();
  final Completer<InstalledSpeechModel> _done = Completer<InstalledSpeechModel>();
  final NetworkCancelToken _token = NetworkCancelToken();
  final Set<HttpClient> _clients = {};
  final Stopwatch _clock = Stopwatch()..start();

  _CancelReason _reason = _CancelReason.none;
  bool _keepPartial = true;
  int? _backgroundTask;
  StreamSubscription<Object?>? _events;

  ModelDownloadPhase _phase = ModelDownloadPhase.preparing;
  int _baseReceived = 0;
  int _received = 0;
  Duration _lastEmit = Duration.zero;
  int _lastEmitBytes = 0;
  double _rate = 0;
  bool _emittedAny = false;

  /// Latest sample.
  ModelDownloadProgress get latest => ModelDownloadProgress(phase: _phase, received: _received, total: totalBytes, bytesPerSecond: _rate);

  @override
  Stream<ModelDownloadProgress> get progress => _progress.stream;

  @override
  Future<InstalledSpeechModel> get done => _done.future;

  @override
  void cancel({bool keepPartial = true}) => _stop(_CancelReason.user, keepPartial: keepPartial);

  void _stop(_CancelReason reason, {bool keepPartial = true}) {
    if (_done.isCompleted) return;
    if (_reason == _CancelReason.none) _reason = reason;
    // A discard request wins over a keep request.
    _keepPartial = _keepPartial && keepPartial;
    _token.cancel();
    for (final c in _clients.toList()) {
      c.close(force: true);
    }
  }

  // ------------------------------------------------------------------------------------------
  // Run
  // ------------------------------------------------------------------------------------------

  Future<void> _run() async {
    final files = <SpeechModelSpec>[model, if (vad != null) vad!];
    InstalledSpeechModel? result;
    ModelDownloadFailure? failure;
    try {
      _events = platform.events.listen(_onDeviceEvent, onError: (Object _) {});
      try {
        await wakelock.acquire();
      } on Object {
        // A missing wakelock never blocks a download.
      }
      _emit(force: true);

      final needed = <SpeechModelSpec>[];
      for (final f in files) {
        if (await host.installedOf(f) == null) needed.add(f);
      }
      if (needed.isNotEmpty) {
        await Directory(layout.dir).create(recursive: true);
        var remaining = 0;
        for (final f in needed) {
          remaining += f.bytes - await _resumablePartLength(f);
        }
        final free = await platform.freeDiskBytes(layout.dir);
        if (free != null && free < remaining + config.freeSpaceMarginBytes) {
          throw const ModelDownloadFailure(ModelDownloadFailureKind.diskFull);
        }
        _throwIfStopped();

        var left = needed.fold<int>(0, (s, f) => s + f.bytes);
        for (final f in needed) {
          _baseReceived = totalBytes - left;
          _received = _baseReceived;
          await _fetch(f);
          left -= f.bytes;
        }
        _baseReceived = totalBytes;
        _received = totalBytes;
      }
      result = await host.installedOf(model);
      if (result == null) throw const ModelDownloadFailure(ModelDownloadFailureKind.interrupted);
      _phase = ModelDownloadPhase.finishing;
      _emit(force: true);
    } on Object catch (e) {
      failure = _failureOf(e);
    }
    // Files and the wakelock are released before [done] completes, so a caller that awaits
    // [done] sees the final state on disk.
    await _cleanup(files);
    if (_done.isCompleted) return;
    if (failure != null) {
      _done.completeError(failure);
    } else {
      _done.complete(result);
    }
  }

  Future<void> _cleanup(List<SpeechModelSpec> files) async {
    await _events?.cancel();
    _events = null;
    final task = _backgroundTask;
    _backgroundTask = null;
    if (task != null) {
      try {
        await platform.endBackgroundTask(task);
      } on Object {
        // Best effort.
      }
    }
    try {
      await wakelock.release();
    } on Object {
      // Best effort.
    }
    if (_reason != _CancelReason.none && !_keepPartial) {
      for (final f in files) {
        await _deleteQuietly(layout.partOf(f));
        await _deleteQuietly(layout.sidecarOf(f));
      }
    }
    for (final c in _clients.toList()) {
      c.close(force: true);
    }
    _clients.clear();
    await _progress.close();
  }

  void _onDeviceEvent(Object? event) {
    if (event is AppStateChanged) {
      if (event.state == WhisperAppState.background && _backgroundTask == null) {
        unawaited(_beginBackgroundTask());
      } else if (event.state == WhisperAppState.foreground) {
        final id = _backgroundTask;
        _backgroundTask = null;
        if (id != null) unawaited(platform.endBackgroundTask(id));
      }
    } else if (event is BackgroundTaskExpiring) {
      // The OS is about to suspend us: stop with the partial kept ("interrupted").
      _stop(_CancelReason.backgroundExpired);
    }
  }

  Future<void> _beginBackgroundTask() async {
    final id = await platform.beginBackgroundTask('danaview.speech.model.download');
    if (id == null) return;
    if (_done.isCompleted || _backgroundTask != null) {
      await platform.endBackgroundTask(id);
      return;
    }
    _backgroundTask = id;
  }

  // ------------------------------------------------------------------------------------------
  // One file
  // ------------------------------------------------------------------------------------------

  Future<void> _fetch(SpeechModelSpec spec) async {
    var retries = 0;
    var restarts = 0;
    while (true) {
      _throwIfStopped();
      _phase = ModelDownloadPhase.downloading;
      final have = await _resumablePartLength(spec);
      _received = _baseReceived + have;
      if (have >= spec.bytes) break;
      _emit(force: true);
      var progressed = false;
      try {
        final outcome = await _attempt(spec, have, () => progressed = true);
        if (outcome == _AttemptOutcome.restart) {
          if (++restarts > 2) throw const ModelDownloadFailure(ModelDownloadFailureKind.server);
          await _discardPartial(spec);
          continue;
        }
        if (await _partLength(spec) >= spec.bytes) break;
        // The server ended the body early without an error.
        throw const _Transient(ModelDownloadFailureKind.interrupted);
      } on Object catch (e) {
        _throwIfStopped();
        final transient = _transientOf(e);
        if (transient == null) rethrow;
        if (progressed) retries = 0;
        if (retries >= config.retryBackoff.length) throw ModelDownloadFailure(transient.kind);
        final base = config.retryBackoff[retries];
        retries++;
        final jitter = Duration(milliseconds: ((config.random ?? _random).nextDouble() * base.inMilliseconds * 0.25).round());
        await _wait(base + jitter);
      }
    }
    await _verifyAndCommit(spec);
  }

  static final math.Random _random = math.Random();

  Future<void> _wait(Duration d) async {
    final delay = config.delay;
    if (delay != null) {
      await delay(d);
    } else {
      await Future.any<void>([Future<void>.delayed(d), _token.whenCancelled]);
    }
    _throwIfStopped();
  }

  Future<_AttemptOutcome> _attempt(SpeechModelSpec spec, int have, void Function() onProgress) async {
    final client = _newClient();
    try {
      final location = await _resolve(client, spec);
      _throwIfStopped();

      final request = await client.getUrl(location).timeout(config.connectTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close().timeout(config.idleTimeout);

      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>().timeout(config.idleTimeout);
        return have == spec.bytes ? _AttemptOutcome.fetched : _AttemptOutcome.restart;
      }
      if (status == HttpStatus.tooManyRequests || status >= 500) {
        await response.drain<void>().timeout(config.idleTimeout);
        throw const _Transient(ModelDownloadFailureKind.server);
      }

      final bool append;
      if (status == HttpStatus.partialContent) {
        final range = _ContentRange.tryParse(response.headers.value(HttpHeaders.contentRangeHeader));
        if (range == null || range.start != have || (range.total != null && range.total != spec.bytes)) {
          await response.drain<void>().timeout(config.idleTimeout);
          return _AttemptOutcome.restart;
        }
        append = true;
      } else if (status == HttpStatus.ok) {
        // Range ignored (or none sent): the body is the whole file.
        final length = response.contentLength;
        if (length >= 0 && length != spec.bytes) {
          await response.drain<void>().timeout(config.idleTimeout);
          throw const ModelDownloadFailure(ModelDownloadFailureKind.sizeMismatch);
        }
        append = false;
        if (have > 0) _received = _baseReceived;
      } else {
        await response.drain<void>().timeout(config.idleTimeout);
        throw const ModelDownloadFailure(ModelDownloadFailureKind.server);
      }

      await _writeBody(spec, response, append: append, startAt: append ? have : 0, onProgress: onProgress);
      return _AttemptOutcome.fetched;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// Steps 3 of ai.md §5.3: the pinned URL must answer 302 with the catalog size and hash.
  Future<Uri> _resolve(HttpClient client, SpeechModelSpec spec) async {
    final url = config.urlOf(spec);
    final request = await client.getUrl(url).timeout(config.connectTimeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(config.idleTimeout);
    final status = response.statusCode;
    final size = response.headers.value('x-linked-size');
    final etag = response.headers.value('x-linked-etag');
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>().timeout(config.idleTimeout);

    if (status == HttpStatus.tooManyRequests || status >= 500) throw const _Transient(ModelDownloadFailureKind.server);
    if (status != HttpStatus.found && status != HttpStatus.temporaryRedirect) {
      throw const ModelDownloadFailure(ModelDownloadFailureKind.server);
    }
    // Nothing is written before both headers equal the catalog (a mismatch is not retried).
    if (int.tryParse(size ?? '') != spec.bytes) throw const ModelDownloadFailure(ModelDownloadFailureKind.sizeMismatch);
    if (_normalizeEtag(etag) != spec.sha256.toLowerCase()) {
      throw const ModelDownloadFailure(ModelDownloadFailureKind.checksumMismatch);
    }
    if (location == null || location.isEmpty) throw const ModelDownloadFailure(ModelDownloadFailureKind.server);
    final target = url.resolve(location);
    if (!config.allowsRedirect(target)) throw const ModelDownloadFailure(ModelDownloadFailureKind.server);
    return target;
  }

  static String _normalizeEtag(String? etag) {
    var v = (etag ?? '').trim();
    if (v.startsWith('W/')) v = v.substring(2);
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
    return v.toLowerCase();
  }

  Future<void> _writeBody(
    SpeechModelSpec spec,
    HttpClientResponse response, {
    required bool append,
    required int startAt,
    required void Function() onProgress,
  }) async {
    final part = File(layout.partOf(spec));
    final raf = await part.open(mode: append ? FileMode.append : FileMode.write);
    var written = startAt;
    var sinceSidecar = 0;
    try {
      await _writeSidecar(spec, written);
      await for (final chunk in response.timeout(config.idleTimeout)) {
        _throwIfStopped();
        if (written + chunk.length > spec.bytes) {
          await raf.close();
          await _discardPartial(spec);
          throw const ModelDownloadFailure(ModelDownloadFailureKind.sizeMismatch);
        }
        await raf.writeFrom(chunk);
        written += chunk.length;
        sinceSidecar += chunk.length;
        _received = _baseReceived + written;
        onProgress();
        if (sinceSidecar >= config.sidecarEveryBytes) {
          sinceSidecar = 0;
          await raf.flush();
          await _writeSidecar(spec, written);
        }
        _emit();
      }
    } finally {
      try {
        await raf.flush();
        await raf.close();
      } on FileSystemException {
        // Closed above after an overflow.
      }
      if (await part.exists()) await _writeSidecar(spec, await part.length());
    }
  }

  Future<void> _verifyAndCommit(SpeechModelSpec spec) async {
    _throwIfStopped();
    _phase = ModelDownloadPhase.verifying;
    _received = _baseReceived + spec.bytes;
    _emit(force: true);

    final part = layout.partOf(spec);
    final String sum;
    try {
      sum = await sha256OfFile(part);
    } on FileSystemException {
      throw const _Transient(ModelDownloadFailureKind.interrupted);
    }
    _throwIfStopped();
    if (sum != spec.sha256.toLowerCase() || !await hasGgmlMagic(part)) {
      await _discardPartial(spec);
      host.reportCorrupt(spec.id);
      throw const ModelDownloadFailure(ModelDownloadFailureKind.checksumMismatch);
    }
    _phase = ModelDownloadPhase.finishing;
    _emit(force: true);
    await host.commit(spec);
  }

  // ------------------------------------------------------------------------------------------
  // Partial files
  // ------------------------------------------------------------------------------------------

  Future<int> _partLength(SpeechModelSpec spec) async {
    final f = File(layout.partOf(spec));
    return await f.exists() ? await f.length() : 0;
  }

  /// Length of the part file when its sidecar says it belongs to this catalog entry; otherwise the
  /// part is deleted and 0 is returned.
  Future<int> _resumablePartLength(SpeechModelSpec spec) async {
    final length = await _partLength(spec);
    if (length == 0) {
      await _deleteQuietly(layout.sidecarOf(spec));
      return 0;
    }
    final side = await PartialSidecar.read(layout.sidecarOf(spec));
    final valid = side != null &&
        side.sha256 == spec.sha256.toLowerCase() &&
        side.bytes == spec.bytes &&
        side.url == spec.url &&
        side.catalogRevision == SpeechModelCatalog.revision &&
        length <= spec.bytes &&
        length >= side.written;
    if (!valid) {
      await _discardPartial(spec);
      return 0;
    }
    return length;
  }

  Future<void> _writeSidecar(SpeechModelSpec spec, int written) => writeStringAtomic(
        layout.sidecarOf(spec),
        PartialSidecar(
          url: spec.url,
          bytes: spec.bytes,
          sha256: spec.sha256.toLowerCase(),
          written: written,
          updatedAt: DateTime.now().toUtc(),
          catalogRevision: SpeechModelCatalog.revision,
        ).encode(),
      );

  Future<void> _discardPartial(SpeechModelSpec spec) async {
    await _deleteQuietly(layout.partOf(spec));
    await _deleteQuietly(layout.sidecarOf(spec));
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Nothing more to do.
    }
  }

  // ------------------------------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------------------------------

  HttpClient _newClient() {
    final client = (config.httpClientFactory ?? HttpClient.new)();
    client
      ..connectionTimeout = config.connectTimeout
      ..idleTimeout = config.idleTimeout
      ..autoUncompress = false
      ..userAgent = 'Danaview/${config.appVersion}';
    _clients.add(client);
    if (_token.isCancelled) client.close(force: true);
    return client;
  }

  void _throwIfStopped() {
    if (_token.isCancelled) throw const _Stopped();
  }

  void _emit({bool force = false}) {
    if (_progress.isClosed) return;
    final now = _clock.elapsed;
    final elapsed = now - _lastEmit;
    if (!force && _emittedAny && elapsed < config.progressInterval && _received < totalBytes) return;
    if (_emittedAny && elapsed.inMicroseconds > 0 && _received >= _lastEmitBytes) {
      final instant = (_received - _lastEmitBytes) * 1e6 / elapsed.inMicroseconds;
      _rate = _rate == 0 ? instant : _rate * 0.7 + instant * 0.3;
    }
    _emittedAny = true;
    _lastEmit = now;
    _lastEmitBytes = _received;
    final sample = latest;
    host.reportProgress(model.id, sample);
    _progress.add(sample);
  }

  ModelDownloadFailure _failureOf(Object e) {
    if (e is ModelDownloadFailure) return e;
    if (e is _Stopped || _reason != _CancelReason.none) {
      return ModelDownloadFailure(
        _reason == _CancelReason.backgroundExpired ? ModelDownloadFailureKind.interrupted : ModelDownloadFailureKind.cancelled,
      );
    }
    final transient = _transientOf(e);
    if (transient != null) return ModelDownloadFailure(transient.kind);
    return ModelDownloadFailure(_classify(e));
  }

  /// The retryable form of [e], or null when it must not be retried.
  static _Transient? _transientOf(Object e) {
    if (e is _Transient) return e;
    if (e is TimeoutException) return const _Transient(ModelDownloadFailureKind.timeout);
    if (e is SocketException) {
      return _isDrop(e) ? const _Transient(ModelDownloadFailureKind.interrupted) : null;
    }
    if (e is HandshakeException || e is TlsException) return null;
    if (e is HttpException) return const _Transient(ModelDownloadFailureKind.interrupted);
    return null;
  }

  static ModelDownloadFailureKind _classify(Object e) {
    if (e is HandshakeException || e is TlsException) return ModelDownloadFailureKind.secureConnection;
    if (e is SocketException) return _isDrop(e) ? ModelDownloadFailureKind.interrupted : ModelDownloadFailureKind.offline;
    if (e is TimeoutException) return ModelDownloadFailureKind.timeout;
    if (e is FileSystemException) {
      final code = e.osError?.errorCode;
      if (code == 28 || code == 112 || (e.message + (e.osError?.message ?? '')).toLowerCase().contains('no space')) {
        return ModelDownloadFailureKind.diskFull;
      }
      return ModelDownloadFailureKind.interrupted;
    }
    return ModelDownloadFailureKind.interrupted;
  }

  /// A connection that was up and then broke, as opposed to one that never opened (the same
  /// classification as danaview_data's speed test).
  static bool _isDrop(SocketException error) {
    final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    return const ['reset', 'broken pipe', 'write failed', 'read failed', 'closed'].any(text.contains);
  }
}

/// `Content-Range: bytes <start>-<end>/<total>`.
final class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int? total;

  static _ContentRange? tryParse(String? header) {
    if (header == null) return null;
    final m = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header);
    if (m == null) return null;
    return _ContentRange(int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3) == '*' ? null : int.parse(m.group(3)!));
  }
}
