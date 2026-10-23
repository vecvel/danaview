// OWNER: ST-01
//
// The v1.0 speed-test API, kept unchanged as a facade over a SpeedTestProvider (V2-401).

import 'dart:async';
import 'dart:io';

import 'speed/cloudflare_speed_provider.dart';
import 'speed/phase_result.dart';
import 'speed/speed_test_provider.dart';

export 'speed/cloudflare_speed_provider.dart' show CloudflareSpeedProvider;
export 'speed/phase_result.dart';
export 'speed/speed_test_provider.dart';

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

/// Measures latency, download and upload, by default against Cloudflare's speed test endpoints
/// (`/__down?bytes=N` and `/__up`) using nothing but `dart:io`.
///
/// Since 1.2.0 (ST-01) this is a facade: the measuring is done by a [SpeedTestProvider]
/// ([CloudflareSpeedProvider] unless [provider] is given), and this class turns its phases into the
/// same [SpeedTestUpdate] stream and [SpeedTestException]s as v1.0.
class SpeedTestService {
  SpeedTestService({
    Uri? base,
    HttpClient Function()? clientFactory,
    this.config = const SpeedTestConfig(),
    SpeedTestProvider? provider,
  })  : base = base ?? CloudflareSpeedProvider.defaultBase,
        _clientFactory = clientFactory,
        _provider = provider;

  final Uri base;
  final SpeedTestConfig config;
  final HttpClient Function()? _clientFactory;

  /// Built on first use, so creating the service opens nothing.
  late final SpeedTestProvider provider =
      _provider ?? CloudflareSpeedProvider(base: base, clientFactory: _clientFactory, config: config);
  final SpeedTestProvider? _provider;

  static const _latencyWeight = 0.1;
  static const _transferWeight = 0.45;

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
}

class _SpeedTestRun {
  _SpeedTestRun(this.service, this.controller, this.token);

  final SpeedTestService service;
  final StreamController<SpeedTestUpdate> controller;
  final NetworkCancelToken token;
  final Stopwatch clock = Stopwatch();

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
    try {
      final provider = service.provider;
      _emit(SpeedTestPhase.latency, phaseProgress: 0);
      final latency = await provider.latency(cancel: token, onProgress: _onLatency);
      latencyMs = latency.latencyMs;
      jitterMs = latency.jitterMs;
      colo ??= latency.colo;
      city ??= latency.city;
      downloadMbps = await _transfer(SpeedTestPhase.download, provider.download);
      uploadMbps = await _transfer(SpeedTestPhase.upload, provider.upload);
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
      if (!token.isCancelled && error is! SpeedTestCancelled) {
        final cause = error is SpeedProviderFailure ? error.cause : error;
        controller.addError(SpeedTestException.from(cause, phase: _phase));
      }
    } finally {
      await controller.close();
    }
  }

  void _onLatency(SpeedPhaseProgress progress) {
    latencyMs = progress.latencyMs ?? latencyMs;
    jitterMs = progress.jitterMs ?? jitterMs;
    colo ??= progress.colo;
    city ??= progress.city;
    _emit(SpeedTestPhase.latency, phaseProgress: progress.phaseProgress);
  }

  Future<double> _transfer(
    SpeedTestPhase phase,
    Future<SpeedTransferResult> Function({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) measure,
  ) async {
    if (token.isCancelled) throw const SpeedTestCancelled();
    _phase = phase;
    final upload = phase == SpeedTestPhase.upload;
    void count(int bytes) {
      if (upload) {
        uploaded = bytes;
      } else {
        downloaded = bytes;
      }
    }

    final result = await measure(
      cancel: token,
      onProgress: (progress) {
        count(progress.bytes);
        _emit(phase, phaseProgress: progress.phaseProgress, current: progress.currentMbps);
      },
    );
    count(result.bytes);
    if (upload) {
      uploadMbps = result.mbps;
    } else {
      downloadMbps = result.mbps;
    }
    _emit(phase, phaseProgress: 1, current: result.mbps);
    return result.mbps;
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
}
