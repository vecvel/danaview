import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Stops a [SpeedTestService] run or a [StreamProbe] check; its open sockets are closed at once.
class NetworkCancelToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is first called.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

enum SpeedTestPhase { latency, download, upload, done }

enum SpeedTestErrorKind { offline, timeout, server, secureConnection, interrupted }

class SpeedTestException implements Exception {
  const SpeedTestException(this.kind, this.message);

  /// [status] is the HTTP status the test server answered with.
  factory SpeedTestException.status(int status) {
    if (status == 429) {
      return const SpeedTestException(
        SpeedTestErrorKind.server,
        'The test server is busy right now. Try again in a minute.',
      );
    }
    return SpeedTestException(
      SpeedTestErrorKind.server,
      'The test server returned an error (HTTP $status). Try again later.',
    );
  }

  /// A user-facing explanation of [error], thrown while talking to the test server during [phase].
  factory SpeedTestException.from(Object error, {SpeedTestPhase? phase}) {
    final dropped = switch (phase) {
      SpeedTestPhase.download => 'The connection dropped during the download test.',
      SpeedTestPhase.upload => 'The connection dropped during the upload test.',
      _ => 'The connection to the test server dropped.',
    };
    return switch (error) {
      SpeedTestException() => error,
      TimeoutException() => const SpeedTestException(
          SpeedTestErrorKind.timeout,
          'The test server took too long to respond. Your connection may be slow or unstable.',
        ),
      HandshakeException() => const SpeedTestException(
          SpeedTestErrorKind.secureConnection,
          "Couldn't open a secure connection to the test server. "
          'On public Wi-Fi, sign in to the network first.',
        ),
      SocketException() when !_isDrop(error) => const SpeedTestException(
          SpeedTestErrorKind.offline,
          "Couldn't reach the test server. Check that you're connected to the internet.",
        ),
      _ => SpeedTestException(
          SpeedTestErrorKind.interrupted,
          '$dropped Try again, or switch networks if it keeps happening.',
        ),
    };
  }

  /// A connection that was up and then broke, as opposed to one that never opened.
  static bool _isDrop(SocketException error) {
    final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    return const ['reset', 'broken pipe', 'write failed', 'read failed', 'closed'].any(text.contains);
  }

  final SpeedTestErrorKind kind;
  final String message;

  @override
  String toString() => 'SpeedTestException(${kind.name}): $message';
}

class SpeedTestResult {
  const SpeedTestResult({
    required this.downloadMbps,
    required this.uploadMbps,
    required this.latencyMs,
    required this.jitterMs,
    required this.bytesDownloaded,
    required this.bytesUploaded,
    required this.duration,
    this.colo,
    this.city,
  });

  final double downloadMbps;
  final double uploadMbps;

  /// Median round trip of the idle latency probes, with the server's own processing time removed
  /// when it reports one.
  final double latencyMs;

  /// Mean difference between consecutive latency probes.
  final double jitterMs;
  final int bytesDownloaded;
  final int bytesUploaded;
  final Duration duration;

  /// Data center that served the test (e.g. `FRA`), from the `cf-meta-colo` header.
  final String? colo;
  final String? city;

  int get bytesTransferred => bytesDownloaded + bytesUploaded;

  /// `Frankfurt (FRA)`, `FRA`, or null when the server didn't say.
  String? get serverLabel {
    if (city != null && colo != null) return '$city ($colo)';
    return city ?? colo;
  }
}

/// Progress of a running test. Results of finished phases are filled in as they complete.
class SpeedTestUpdate {
  const SpeedTestUpdate({
    required this.phase,
    required this.progress,
    required this.phaseProgress,
    required this.elapsed,
    this.currentMbps = 0,
    this.latencyMs,
    this.jitterMs,
    this.downloadMbps,
    this.uploadMbps,
    this.bytesTransferred = 0,
    this.colo,
    this.city,
    this.result,
  });

  final SpeedTestPhase phase;

  /// Whole test, 0–1.
  final double progress;

  /// Current phase, 0–1.
  final double phaseProgress;
  final Duration elapsed;

  /// Throughput over roughly the last second of the download or upload phase.
  final double currentMbps;
  final double? latencyMs;
  final double? jitterMs;
  final double? downloadMbps;
  final double? uploadMbps;
  final int bytesTransferred;
  final String? colo;
  final String? city;

  /// Set on the final [SpeedTestPhase.done] update.
  final SpeedTestResult? result;
}

class SpeedTestConfig {
  const SpeedTestConfig({
    this.latencySamples = 10,
    this.connections = 4,
    this.downloadDuration = const Duration(seconds: 8),
    this.uploadDuration = const Duration(seconds: 8),
    this.maxDownloadBytes = 100 * _mb,
    this.maxUploadBytes = 40 * _mb,
    this.initialRequestBytes = 256 * 1024,
    this.maxDownloadRequestBytes = 25 * _mb,
    this.maxUploadRequestBytes = 8 * _mb,
    this.warmUp = const Duration(seconds: 1),
    this.sampleInterval = const Duration(milliseconds: 250),
    this.requestTimeout = const Duration(seconds: 10),
    this.stallTimeout = const Duration(seconds: 4),
  });

  /// Decimal, as mobile data plans count it.
  static const int _mb = 1000 * 1000;

  /// Sequential probes after one warm-up request that pays for DNS, TCP and TLS.
  final int latencySamples;

  /// Parallel connections for the download and upload phases.
  final int connections;
  final Duration downloadDuration;
  final Duration uploadDuration;

  /// Each phase stops at its cap or its time box, whichever comes first, so a fast link uses at
  /// most about [maxTotalBytes] and a slow one far less.
  final int maxDownloadBytes;
  final int maxUploadBytes;

  /// Requests start this small and double while they finish quickly, up to the per-request maxima.
  final int initialRequestBytes;
  final int maxDownloadRequestBytes;
  final int maxUploadRequestBytes;

  /// Throughput while TCP ramps up is left out of the result.
  final Duration warmUp;
  final Duration sampleInterval;

  /// Connecting, and waiting for a response's headers.
  final Duration requestTimeout;

  /// A transfer phase fails when no bytes move for this long. Kept well under the phase durations,
  /// or the time box would end a stalled phase first.
  final Duration stallTimeout;

  int get maxTotalBytes => maxDownloadBytes + maxUploadBytes;
}

/// Measures latency, download and upload against Cloudflare's speed test endpoints
/// (`/__down?bytes=N` and `/__up`) using nothing but `dart:io`.
class SpeedTestService {
  SpeedTestService({
    Uri? base,
    HttpClient Function()? clientFactory,
    this.config = const SpeedTestConfig(),
  })  : base = base ?? Uri.parse('https://speed.cloudflare.com'),
        _clientFactory = clientFactory ?? HttpClient.new;

  final Uri base;
  final SpeedTestConfig config;
  final HttpClient Function() _clientFactory;

  static const _latencyWeight = 0.1;
  static const _transferWeight = 0.45;
  static const _uploadChunkBytes = 64 * 1024;

  Uint8List? _payload;

  /// Runs latency, download and upload in turn. The stream ends after the [SpeedTestPhase.done]
  /// update, or with a [SpeedTestException]. Cancelling [cancel] or the subscription stops the test
  /// and closes its sockets; the stream then closes without an error.
  Stream<SpeedTestUpdate> run({NetworkCancelToken? cancel}) {
    final token = cancel ?? NetworkCancelToken();
    late final StreamController<SpeedTestUpdate> controller;
    controller = StreamController<SpeedTestUpdate>(
      onListen: () => _SpeedTestRun(this, controller, token).start(),
      onCancel: token.cancel,
    );
    return controller.stream;
  }

  Uri _endpoint(String path, [Map<String, String>? query]) {
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '$basePath$path', queryParameters: query);
  }

  /// Random, so nothing on the way can compress it; built once and reused for every request body.
  Uint8List get _uploadPayload {
    final existing = _payload;
    if (existing != null) return existing;
    final random = math.Random();
    final words = Uint32List(256 * 1024);
    for (var i = 0; i < words.length; i++) {
      words[i] = random.nextInt(0xFFFFFFFF);
    }
    return _payload = words.buffer.asUint8List();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

typedef _Sample = ({int micros, int bytes});

class _SpeedTestRun {
  _SpeedTestRun(this.service, this.controller, this.token);

  final SpeedTestService service;
  final StreamController<SpeedTestUpdate> controller;
  final NetworkCancelToken token;
  final Stopwatch clock = Stopwatch();

  SpeedTestConfig get config => service.config;

  HttpClient? _client;
  SpeedTestPhase _phase = SpeedTestPhase.latency;
  double? latencyMs;
  double? jitterMs;
  double? downloadMbps;
  double? uploadMbps;
  int downloaded = 0;
  int uploaded = 0;
  String? colo;
  String? city;

  Future<void> start() async {
    clock.start();
    final cancelled = token.whenCancelled.then((_) => _client?.close(force: true));
    try {
      await _measureLatency();
      downloadMbps = await _measureTransfer(upload: false);
      uploadMbps = await _measureTransfer(upload: true);
      final result = SpeedTestResult(
        downloadMbps: downloadMbps!,
        uploadMbps: uploadMbps!,
        latencyMs: latencyMs!,
        jitterMs: jitterMs!,
        bytesDownloaded: downloaded,
        bytesUploaded: uploaded,
        duration: clock.elapsed,
        colo: colo,
        city: city,
      );
      _emit(SpeedTestPhase.done, phaseProgress: 1, result: result);
    } catch (error) {
      if (!token.isCancelled && error is! _Cancelled) {
        controller.addError(SpeedTestException.from(error, phase: _phase));
      }
    } finally {
      _client?.close(force: true);
      _client = null;
      unawaited(cancelled);
      await controller.close();
    }
  }

  HttpClient _openClient() {
    _client?.close(force: true);
    final client = service._clientFactory()
      ..connectionTimeout = config.requestTimeout
      // Byte counts must match what crossed the wire.
      ..autoUncompress = false;
    _client = client;
    return client;
  }

  void _checkCancelled() {
    if (token.isCancelled) throw const _Cancelled();
  }

  void _emit(SpeedTestPhase phase, {required double phaseProgress, double current = 0, SpeedTestResult? result}) {
    if (controller.isClosed || token.isCancelled) return;
    final p = phaseProgress.clamp(0.0, 1.0);
    final progress = switch (phase) {
      SpeedTestPhase.latency => SpeedTestService._latencyWeight * p,
      SpeedTestPhase.download => SpeedTestService._latencyWeight + SpeedTestService._transferWeight * p,
      SpeedTestPhase.upload =>
        SpeedTestService._latencyWeight + SpeedTestService._transferWeight * (1 + p),
      SpeedTestPhase.done => 1.0,
    };
    controller.add(SpeedTestUpdate(
      phase: phase,
      progress: progress,
      phaseProgress: p,
      elapsed: clock.elapsed,
      currentMbps: current,
      latencyMs: latencyMs,
      jitterMs: jitterMs,
      downloadMbps: downloadMbps,
      uploadMbps: uploadMbps,
      bytesTransferred: downloaded + uploaded,
      colo: colo,
      city: city,
      result: result,
    ));
  }

  Future<void> _measureLatency() async {
    final client = _openClient();
    final samples = <double>[];
    _emit(SpeedTestPhase.latency, phaseProgress: 0);
    for (var i = 0; i <= config.latencySamples; i++) {
      _checkCancelled();
      final uri = service._endpoint('__down', {'bytes': '0', 'measId': '${clock.elapsedMicroseconds}$i'});
      final watch = Stopwatch()..start();
      final request = await client.getUrl(uri).timeout(config.requestTimeout);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final response = await request.close().timeout(config.requestTimeout);
      watch.stop();
      if (response.statusCode != HttpStatus.ok) {
        await _discard(response);
        throw SpeedTestException.status(response.statusCode);
      }
      colo ??= _header(response, 'cf-meta-colo') ?? _header(response, 'colo');
      city ??= _header(response, 'cf-meta-city') ?? _header(response, 'city');
      final serverMs = _serverTimingMs(response.headers['server-timing']);
      await response.drain<void>().timeout(config.requestTimeout);
      _checkCancelled();
      // The first request also pays for DNS, TCP and TLS.
      if (i == 0) continue;
      final roundTrip = watch.elapsedMicroseconds / 1000;
      samples.add(math.max(0.0, serverMs != null && serverMs < roundTrip ? roundTrip - serverMs : roundTrip));
      latencyMs = _median(samples);
      jitterMs = _jitter(samples);
      _emit(SpeedTestPhase.latency, phaseProgress: i / config.latencySamples);
    }
  }

  /// Runs [SpeedTestConfig.connections] parallel request loops until the time box or the data cap,
  /// sampling the shared byte count, and returns a robust Mbps figure.
  Future<double> _measureTransfer({required bool upload}) async {
    _checkCancelled();
    final client = _openClient();
    final phase = _phase = upload ? SpeedTestPhase.upload : SpeedTestPhase.download;
    final duration = upload ? config.uploadDuration : config.downloadDuration;
    final cap = upload ? config.maxUploadBytes : config.maxDownloadBytes;
    final maxRequest = upload ? config.maxUploadRequestBytes : config.maxDownloadRequestBytes;
    final phaseClock = Stopwatch()..start();
    final samples = <_Sample>[(micros: 0, bytes: 0)];
    var transferred = 0;
    var reserved = 0;
    var failures = 0;
    var lastProgressMicros = 0;
    var stopped = false;
    Object? failure;

    void stop([Object? error]) {
      if (stopped) return;
      stopped = true;
      failure ??= error;
      // Aborts every in-flight request of this phase.
      client.close(force: true);
    }

    void count(int bytes) {
      transferred += bytes;
      if (upload) {
        uploaded += bytes;
      } else {
        downloaded += bytes;
      }
    }

    void sample() {
      final now = phaseClock.elapsedMicroseconds;
      if (transferred != samples.last.bytes) lastProgressMicros = now;
      samples.add((micros: now, bytes: transferred));
      final timeShare = now / duration.inMicroseconds;
      _emit(
        phase,
        phaseProgress: math.max(timeShare, transferred / cap),
        current: _recentMbps(samples),
      );
      if (now >= duration.inMicroseconds) {
        // Nothing moved after the warm-up: the link stalled, and a 0 Mbps reading would be wrong.
        final warmUp = math.min(config.warmUp.inMicroseconds, now ~/ 4);
        stop(lastProgressMicros <= warmUp ? TimeoutException('No data moved', duration) : null);
      } else if (now - lastProgressMicros >= config.stallTimeout.inMicroseconds) {
        stop(TimeoutException('No data moved', config.stallTimeout));
      }
    }

    Future<void> loop() async {
      var size = config.initialRequestBytes;
      while (!stopped) {
        final bytes = math.min(size, cap - reserved);
        if (bytes <= 0) return;
        reserved += bytes;
        final watch = Stopwatch()..start();
        try {
          if (upload) {
            await _uploadOnce(client, bytes, () => stopped, count);
          } else {
            await _downloadOnce(client, bytes, () => stopped, count);
          }
        } catch (error) {
          if (stopped || token.isCancelled) return;
          // A dropped connection mid-test is retried; a test that can't get going fails.
          failures++;
          if (transferred == 0 || failures >= 3 || error is SpeedTestException) {
            stop(error);
            return;
          }
          continue;
        }
        // Bigger requests keep the pipe full once the link has shown it is fast.
        if (watch.elapsed < const Duration(milliseconds: 1500)) size = math.min(size * 2, maxRequest);
      }
    }

    final ticker = Timer.periodic(config.sampleInterval, (_) => sample());
    try {
      await Future.wait([for (var i = 0; i < config.connections; i++) loop()]);
    } finally {
      ticker.cancel();
      stop();
    }
    _checkCancelled();
    if (failure != null) throw failure!;
    samples.add((micros: phaseClock.elapsedMicroseconds, bytes: transferred));
    final mbps = _robustMbps(samples);
    if (upload) {
      uploadMbps = mbps;
    } else {
      downloadMbps = mbps;
    }
    _emit(phase, phaseProgress: 1, current: mbps);
    return mbps;
  }

  Future<void> _downloadOnce(HttpClient client, int bytes, bool Function() stopped, void Function(int) count) async {
    final uri = service._endpoint('__down', {'bytes': '$bytes'});
    final request = await client.getUrl(uri).timeout(config.requestTimeout);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final response = await request.close().timeout(config.requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await _discard(response);
      throw SpeedTestException.status(response.statusCode);
    }
    await for (final chunk in response) {
      if (stopped()) break;
      count(chunk.length);
    }
  }

  Future<void> _uploadOnce(HttpClient client, int bytes, bool Function() stopped, void Function(int) count) async {
    final payload = service._uploadPayload;
    final request = await client.postUrl(service._endpoint('__up')).timeout(config.requestTimeout);
    // An aborted or force-closed request fails this future; the failure is handled where it surfaces.
    request.done.ignore();
    request
      ..contentLength = bytes
      ..headers.contentType = ContentType('application', 'octet-stream');
    var sent = 0;
    var offset = 0;
    while (sent < bytes) {
      if (stopped()) {
        request.abort();
        return;
      }
      final n = math.min(SpeedTestService._uploadChunkBytes, math.min(bytes - sent, payload.length - offset));
      request.add(Uint8List.sublistView(payload, offset, offset + n));
      // Counted once handed to the socket, so a slow link holds this loop back.
      await request.flush();
      sent += n;
      offset = (offset + n) % payload.length;
      count(n);
    }
    final response = await request.close().timeout(config.requestTimeout);
    await _discard(response);
    if (response.statusCode != HttpStatus.ok) throw SpeedTestException.status(response.statusCode);
  }

  /// Throughput over the last second (or less, early on).
  double _recentMbps(List<_Sample> samples) {
    final last = samples.last;
    final from = last.micros - 1000000;
    var i = samples.length - 1;
    while (i > 0 && samples[i - 1].micros >= from) {
      i--;
    }
    if (i == samples.length - 1 && i > 0) i--;
    return _mbps(last.bytes - samples[i].bytes, last.micros - samples[i].micros);
  }

  /// The 90th percentile of rolling windows after the warm-up; the plain average after warm-up when
  /// the phase was too short for enough windows (a fast link that hit the data cap).
  double _robustMbps(List<_Sample> samples) {
    final end = samples.last;
    if (end.micros <= 0) return 0;
    final warmUp = math.min(config.warmUp.inMicroseconds, end.micros ~/ 4);
    final steady = samples.where((s) => s.micros >= warmUp).toList();
    if (steady.length < 2) return _mbps(end.bytes, end.micros);
    final span = steady.last.micros - steady.first.micros;
    final window = (span ~/ 3).clamp(200000, 1000000);
    final rates = <double>[];
    var i = 0;
    for (var j = 1; j < steady.length; j++) {
      while (i + 1 < j && steady[j].micros - steady[i + 1].micros >= window) {
        i++;
      }
      final dt = steady[j].micros - steady[i].micros;
      if (dt >= window * 0.9) rates.add(_mbps(steady[j].bytes - steady[i].bytes, dt));
    }
    if (rates.length >= 3) return _percentile(rates, 0.9);
    if (span <= 0) return _mbps(end.bytes, end.micros);
    return _mbps(steady.last.bytes - steady.first.bytes, span);
  }

  static double _mbps(int bytes, int micros) => micros <= 0 ? 0 : bytes * 8 / micros;

  /// The first value; `headers.value` throws when a header is repeated.
  static String? _header(HttpClientResponse response, String name) {
    final value = response.headers[name]?.first.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// `cfSpeedEdge;dur=6, cfSpeedWorker;dur=30` → 30: time the server spent, which isn't network
  /// latency. The timings nest, so the longest covers the others.
  static double? _serverTimingMs(List<String>? header) {
    if (header == null) return null;
    final durations = [
      for (final match in RegExp(r'dur=([\d.]+)').allMatches(header.join(',')))
        if (double.tryParse(match.group(1)!) case final value?) value,
    ];
    return durations.isEmpty ? null : durations.reduce(math.max);
  }

  static Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {
      // The socket is going away either way.
    }
  }
}

double _median(List<double> values) => _percentile(values, 0.5);

double _percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  final rank = (sorted.length - 1) * p;
  final lower = rank.floor();
  final upper = rank.ceil();
  if (lower == upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower);
}

double _jitter(List<double> values) {
  if (values.length < 2) return 0;
  var total = 0.0;
  for (var i = 1; i < values.length; i++) {
    total += (values[i] - values[i - 1]).abs();
  }
  return total / (values.length - 1);
}
