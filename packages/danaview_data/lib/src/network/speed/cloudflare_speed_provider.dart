// OWNER: ST-01
//
// The v1.0 Cloudflare speed test, moved behind [SpeedTestProvider] with no behaviour change
// (V2-401): the same endpoints (`/__down?bytes=N`, `/__up`), request sizes, parallelism, stall
// timeout and result maths. Only `dart:io`.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../speed_test.dart' show NetworkCancelToken, SpeedTestConfig, SpeedTestException, SpeedTestErrorKind, SpeedTestPhase;
import 'phase_result.dart';
import 'speed_test_provider.dart';

/// Measures against Cloudflare's public speed-test endpoints (the default provider, D-ST1).
class CloudflareSpeedProvider implements SpeedTestProvider {
  CloudflareSpeedProvider({
    Uri? base,
    HttpClient Function()? clientFactory,
    this.config = const SpeedTestConfig(),
    this.healthTimeout = defaultHealthTimeout,
  })  : base = base ?? defaultBase,
        _clientFactory = clientFactory ?? HttpClient.new;

  static final Uri defaultBase = Uri.parse('https://speed.cloudflare.com');

  /// D-ST3: the zero-byte health check answers within about 1.5 s or the provider is skipped.
  static const Duration defaultHealthTimeout = Duration(milliseconds: 1500);

  final Uri base;
  final SpeedTestConfig config;
  final Duration healthTimeout;
  final HttpClient Function() _clientFactory;

  static const _uploadChunkBytes = 64 * 1024;

  Uint8List? _payload;

  @override
  String get id => 'cloudflare';

  // -----------------------------------------------------------------------------------------------
  // Phases
  // -----------------------------------------------------------------------------------------------

  @override
  Future<SpeedLatencyResult> latency({
    required NetworkCancelToken cancel,
    bool health = false,
    SpeedProgressCallback? onProgress,
  }) =>
      _guard(SpeedTestPhase.latency, cancel, (client) async {
        final samples = <double>[];
        final clock = Stopwatch()..start();
        double? latencyMs;
        double? jitterMs;
        String? colo;
        String? city;
        for (var i = 0; i <= config.latencySamples; i++) {
          _checkCancelled(cancel);
          final timeout = health && i == 0 && healthTimeout < config.requestTimeout ? healthTimeout : config.requestTimeout;
          final uri = _endpoint('__down', {'bytes': '0', 'measId': '${clock.elapsedMicroseconds}$i'});
          final watch = Stopwatch()..start();
          final request = await client.getUrl(uri).timeout(timeout);
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          final response = await request.close().timeout(timeout);
          watch.stop();
          if (response.statusCode != HttpStatus.ok) {
            await _discard(response);
            throw _StatusError(response.statusCode);
          }
          colo ??= _header(response, 'cf-meta-colo') ?? _header(response, 'colo');
          city ??= _header(response, 'cf-meta-city') ?? _header(response, 'city');
          final serverMs = _serverTimingMs(response.headers['server-timing']);
          await response.drain<void>().timeout(timeout);
          _checkCancelled(cancel);
          // The first request also pays for DNS, TCP and TLS.
          if (i == 0) continue;
          final roundTrip = watch.elapsedMicroseconds / 1000;
          samples.add(math.max(0.0, serverMs != null && serverMs < roundTrip ? roundTrip - serverMs : roundTrip));
          latencyMs = _median(samples);
          jitterMs = _jitter(samples);
          onProgress?.call(SpeedPhaseProgress(
            phaseProgress: i / config.latencySamples,
            latencyMs: latencyMs,
            jitterMs: jitterMs,
            colo: colo,
            city: city,
          ));
        }
        return SpeedLatencyResult(
          providerId: id,
          latencyMs: latencyMs ?? 0,
          jitterMs: jitterMs ?? 0,
          samples: samples.length,
          colo: colo,
          city: city,
        );
      });

  @override
  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _guard(SpeedTestPhase.download, cancel, (client) => _transfer(client, cancel, upload: false, onProgress: onProgress));

  @override
  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _guard(SpeedTestPhase.upload, cancel, (client) => _transfer(client, cancel, upload: true, onProgress: onProgress));

  /// Opens the phase's client, closes it when [cancel] fires or the phase ends, and turns every
  /// error into [SpeedTestCancelled] or a typed [SpeedProviderFailure].
  Future<T> _guard<T>(SpeedTestPhase phase, NetworkCancelToken cancel, Future<T> Function(HttpClient client) body) async {
    if (cancel.isCancelled) throw const SpeedTestCancelled();
    final client = _clientFactory()
      ..connectionTimeout = config.requestTimeout
      // Byte counts must match what crossed the wire.
      ..autoUncompress = false;
    final cancelled = cancel.whenCancelled.then((_) => client.close(force: true));
    try {
      return await body(client);
    } catch (error) {
      if (cancel.isCancelled || error is _Cancelled || error is SpeedTestCancelled) {
        throw const SpeedTestCancelled();
      }
      throw _failure(error, phase);
    } finally {
      client.close(force: true);
      unawaited(cancelled);
    }
  }

  SpeedProviderFailure _failure(Object error, SpeedTestPhase phase) {
    if (error is SpeedProviderFailure) return error;
    if (error is _StatusError) {
      return SpeedProviderFailure(
        kind: SpeedProviderFailure.kindForStatus(error.status),
        phase: phase,
        providerId: id,
        cause: SpeedTestException.status(error.status),
        status: error.status,
      );
    }
    // The v1.0 wording decides what kind of failure it was, so both always agree.
    final kind = switch (SpeedTestException.from(error, phase: phase).kind) {
      SpeedTestErrorKind.offline || SpeedTestErrorKind.secureConnection => SpeedFailureKind.unreachable,
      SpeedTestErrorKind.timeout => SpeedFailureKind.stalled,
      SpeedTestErrorKind.server => SpeedFailureKind.serverError,
      SpeedTestErrorKind.interrupted => SpeedFailureKind.interrupted,
    };
    return SpeedProviderFailure(kind: kind, phase: phase, providerId: id, cause: error);
  }

  /// Runs [SpeedTestConfig.connections] parallel request loops until the time box or the data cap,
  /// sampling the shared byte count, and returns a robust Mbps figure.
  Future<SpeedTransferResult> _transfer(
    HttpClient client,
    NetworkCancelToken cancel, {
    required bool upload,
    SpeedProgressCallback? onProgress,
  }) async {
    final phase = upload ? SpeedTestPhase.upload : SpeedTestPhase.download;
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

    void count(int bytes) => transferred += bytes;

    void sample() {
      final now = phaseClock.elapsedMicroseconds;
      if (transferred != samples.last.bytes) lastProgressMicros = now;
      samples.add((micros: now, bytes: transferred));
      final timeShare = now / duration.inMicroseconds;
      if (!cancel.isCancelled) {
        onProgress?.call(SpeedPhaseProgress(
          phaseProgress: math.max(timeShare, transferred / cap),
          currentMbps: _recentMbps(samples),
          bytes: transferred,
        ));
      }
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
          if (stopped || cancel.isCancelled) return;
          // A dropped connection mid-test is retried; a test that can't get going fails.
          failures++;
          if (transferred == 0 || failures >= 3 || error is _StatusError) {
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
    _checkCancelled(cancel);
    if (failure != null) throw failure!;
    samples.add((micros: phaseClock.elapsedMicroseconds, bytes: transferred));
    return SpeedTransferResult(
      providerId: id,
      phase: phase,
      mbps: _robustMbps(samples),
      bytes: transferred,
      duration: phaseClock.elapsed,
    );
  }

  Future<void> _downloadOnce(HttpClient client, int bytes, bool Function() stopped, void Function(int) count) async {
    final uri = _endpoint('__down', {'bytes': '$bytes'});
    final request = await client.getUrl(uri).timeout(config.requestTimeout);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final response = await request.close().timeout(config.requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await _discard(response);
      throw _StatusError(response.statusCode);
    }
    await for (final chunk in response) {
      if (stopped()) break;
      count(chunk.length);
    }
  }

  Future<void> _uploadOnce(HttpClient client, int bytes, bool Function() stopped, void Function(int) count) async {
    final payload = _uploadPayload;
    final request = await client.postUrl(_endpoint('__up')).timeout(config.requestTimeout);
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
      final n = math.min(_uploadChunkBytes, math.min(bytes - sent, payload.length - offset));
      request.add(Uint8List.sublistView(payload, offset, offset + n));
      // Counted once handed to the socket, so a slow link holds this loop back.
      await request.flush();
      sent += n;
      offset = (offset + n) % payload.length;
      count(n);
    }
    final response = await request.close().timeout(config.requestTimeout);
    await _discard(response);
    if (response.statusCode != HttpStatus.ok) throw _StatusError(response.statusCode);
  }

  // -----------------------------------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------------------------------

  void _checkCancelled(NetworkCancelToken cancel) {
    if (cancel.isCancelled) throw const _Cancelled();
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

  /// Throughput over the last second (or less, early on).
  static double _recentMbps(List<_Sample> samples) {
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

/// An HTTP error status from the test server.
class _StatusError implements Exception {
  const _StatusError(this.status);

  final int status;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

typedef _Sample = ({int micros, int bytes});

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
