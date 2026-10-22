// OWNER: ST-01
//
// CloudflareSpeedProvider against a loopback fake of `/__down` and `/__up` (V2-401): phases,
// health check, typed failures (rateLimited, forbidden, unreachable, stalled), cancel, the v1.0
// endpoints, sizes and parallelism, and the facade routing through an injected provider.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';

const _mb = 1024 * 1024;

const _quick = SpeedTestConfig(
  latencySamples: 3,
  connections: 2,
  downloadDuration: Duration(milliseconds: 1200),
  uploadDuration: Duration(milliseconds: 1200),
  maxDownloadBytes: 200 * _mb,
  maxUploadBytes: 100 * _mb,
  warmUp: Duration(milliseconds: 200),
  sampleInterval: Duration(milliseconds: 50),
  requestTimeout: Duration(seconds: 2),
  stallTimeout: Duration(seconds: 1),
);

/// Windows retries a refused loopback connect for about 2 s before it reports the refusal (Linux,
/// macOS and Android refuse at once), so the "nothing listening" cases give every deadline (request,
/// health, stall and phase length) room above that retry. Below it the refusal would arrive after
/// the deadline and read as `stalled`, which is right for the product but not what these cases pin
/// (FIX-S1Q-A2). On a host that refuses at once the case still ends at once.
const _refusalDeadline = Duration(seconds: 6);

const _refusal = SpeedTestConfig(
  latencySamples: 3,
  connections: 2,
  downloadDuration: _refusalDeadline,
  uploadDuration: _refusalDeadline,
  warmUp: Duration(milliseconds: 200),
  sampleInterval: Duration(milliseconds: 50),
  requestTimeout: _refusalDeadline,
  stallTimeout: _refusalDeadline,
);

class _Fake {
  _Fake._(this._server);

  final HttpServer _server;
  final List<Uri> requests = [];

  /// Status for zero-byte `/__down`, sized `/__down`, and `/__up`.
  int latencyStatus = 200;
  int downStatus = 200;
  int upStatus = 200;

  /// Delay before answering the first zero-byte request.
  Duration firstLatencyDelay = Duration.zero;

  /// Sized downloads send a little and then stall.
  bool stallDownload = false;
  Duration downChunkDelay = Duration.zero;

  int _open = 0;
  int maxConcurrentDown = 0;
  int maxConcurrentUp = 0;
  int _latencySeen = 0;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_Fake> start() async {
    final fake = _Fake._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    fake._server.listen((r) => fake._handle(r).catchError((Object _) {}));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri);
    final response = request.response;
    if (request.uri.path == '/__down') {
      final bytes = int.parse(request.uri.queryParameters['bytes'] ?? '0');
      response.headers
        ..set('cf-meta-colo', 'TST')
        ..set('cf-meta-city', 'Testville')
        ..set('server-timing', 'cfRequestDuration;dur=0.5');
      if (bytes == 0) {
        if (_latencySeen++ == 0 && firstLatencyDelay > Duration.zero) await Future<void>.delayed(firstLatencyDelay);
        response.statusCode = latencyStatus;
        response.contentLength = 0;
        return response.close();
      }
      if (downStatus != 200) {
        response.statusCode = downStatus;
        return response.close();
      }
      response.contentLength = bytes;
      _open++;
      maxConcurrentDown = _open > maxConcurrentDown ? _open : maxConcurrentDown;
      try {
        if (stallDownload) {
          response.add(Uint8List(1024));
          await response.flush();
          await Future<void>.delayed(const Duration(seconds: 30));
          return;
        }
        const chunk = 64 * 1024;
        var sent = 0;
        while (sent < bytes) {
          final n = bytes - sent < chunk ? bytes - sent : chunk;
          response.add(Uint8List(n));
          await response.flush();
          sent += n;
          if (downChunkDelay > Duration.zero) await Future<void>.delayed(downChunkDelay);
        }
        await response.close();
      } finally {
        _open--;
      }
      return;
    }
    if (request.uri.path == '/__up') {
      _open++;
      maxConcurrentUp = _open > maxConcurrentUp ? _open : maxConcurrentUp;
      try {
        await request.drain<void>();
      } finally {
        _open--;
      }
      response.statusCode = upStatus;
      return response.close();
    }
    response.statusCode = 404;
    await response.close();
  }
}

Matcher _failure(SpeedFailureKind kind, SpeedTestPhase phase, {int? status}) => isA<SpeedProviderFailure>()
    .having((f) => f.kind, 'kind', kind)
    .having((f) => f.phase, 'phase', phase)
    .having((f) => f.providerId, 'providerId', 'cloudflare')
    .having((f) => f.status, 'status', status);

void main() {
  late _Fake fake;

  setUp(() async => fake = await _Fake.start());
  tearDown(() => fake.close());

  CloudflareSpeedProvider provider([SpeedTestConfig config = _quick]) =>
      CloudflareSpeedProvider(base: fake.base, config: config);

  group('defaults are the v1.0 ones', () {
    test('endpoint, health timeout and config', () {
      final p = CloudflareSpeedProvider();
      expect(p.id, 'cloudflare');
      expect(p.base, Uri.parse('https://speed.cloudflare.com'));
      expect(p.healthTimeout, const Duration(milliseconds: 1500));
      const c = SpeedTestConfig();
      expect(c.connections, 4);
      expect(c.latencySamples, 10);
      expect(c.initialRequestBytes, 256 * 1024);
      expect(c.maxDownloadRequestBytes, 25 * 1000 * 1000);
      expect(c.maxUploadRequestBytes, 8 * 1000 * 1000);
      expect(c.stallTimeout, const Duration(seconds: 4));
      expect(c.maxTotalBytes, 140 * 1000 * 1000);
      expect(SpeedTestService().base, p.base);
      expect(SpeedTestService().provider, isA<CloudflareSpeedProvider>());
    });

    test('creating the provider or the service opens nothing', () {
      var clients = 0;
      HttpClient factory() {
        clients++;
        return HttpClient();
      }

      final service = SpeedTestService(base: fake.base, clientFactory: factory);
      CloudflareSpeedProvider(base: fake.base, clientFactory: factory);
      expect(service.provider.id, 'cloudflare');
      expect(clients, 0);
      expect(fake.requests, isEmpty);
    });
  });

  group('phases', () {
    test('latency: one warm-up plus the samples, median and server location', () async {
      final progress = <SpeedPhaseProgress>[];
      final result = await provider().latency(cancel: NetworkCancelToken(), onProgress: progress.add);
      expect(result.providerId, 'cloudflare');
      expect(result.samples, _quick.latencySamples);
      expect(result.latencyMs, inInclusiveRange(0, 500));
      expect(result.jitterMs, greaterThanOrEqualTo(0));
      expect(result.colo, 'TST');
      expect(result.city, 'Testville');
      expect(fake.requests, hasLength(_quick.latencySamples + 1));
      for (final uri in fake.requests) {
        expect(uri.path, '/__down');
        expect(uri.queryParameters['bytes'], '0');
      }
      expect(progress.map((p) => p.phaseProgress), [for (var i = 1; i <= _quick.latencySamples; i++) i / _quick.latencySamples]);
      expect(progress.last.latencyMs, result.latencyMs);
    });

    test('download: parallel requests that start at 256 KB, bytes and Mbps reported', () async {
      final progress = <SpeedPhaseProgress>[];
      final result = await provider().download(cancel: NetworkCancelToken(), onProgress: progress.add);
      expect(result.phase, SpeedTestPhase.download);
      expect(result.providerId, 'cloudflare');
      expect(result.bytes, greaterThan(0));
      expect(result.bytes, lessThanOrEqualTo(_quick.maxDownloadBytes));
      expect(result.mbps, greaterThan(10));
      expect(progress, isNotEmpty);
      expect(progress.last.bytes, lessThanOrEqualTo(result.bytes));
      final sizes = fake.requests.map((u) => int.parse(u.queryParameters['bytes']!)).toList();
      expect(sizes.take(_quick.connections), everyElement(_quick.initialRequestBytes));
      expect(sizes, everyElement(lessThanOrEqualTo(_quick.maxDownloadRequestBytes)));
      expect(fake.maxConcurrentDown, _quick.connections);
    });

    test('upload: posts to /__up up to the cap', () async {
      const config = SpeedTestConfig(
        connections: 3,
        uploadDuration: Duration(seconds: 20),
        maxUploadBytes: 3 * _mb,
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 2),
      );
      final result = await provider(config).upload(cancel: NetworkCancelToken());
      expect(result.phase, SpeedTestPhase.upload);
      expect(result.bytes, config.maxUploadBytes);
      expect(result.mbps, greaterThan(0));
      expect(fake.requests.map((u) => u.path), everyElement('/__up'));
      expect(fake.maxConcurrentUp, lessThanOrEqualTo(config.connections));
    });
  });

  group('health check', () {
    test('a slow first answer fails the health check as stalled', () async {
      fake.firstLatencyDelay = const Duration(seconds: 3);
      final watch = Stopwatch()..start();
      await expectLater(
        provider(const SpeedTestConfig(latencySamples: 2, requestTimeout: Duration(seconds: 5)))
            .latency(cancel: NetworkCancelToken(), health: true),
        throwsA(_failure(SpeedFailureKind.stalled, SpeedTestPhase.latency)),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2800)));
    });

    test('without health the same answer is just a slow warm-up', () async {
      fake.firstLatencyDelay = const Duration(milliseconds: 1800);
      final result = await provider(const SpeedTestConfig(latencySamples: 2, requestTimeout: Duration(seconds: 5)))
          .latency(cancel: NetworkCancelToken());
      expect(result.samples, 2);
    });

    test('a healthy server passes', () async {
      final result = await provider().latency(cancel: NetworkCancelToken(), health: true);
      expect(result.samples, _quick.latencySamples);
    });
  });

  group('typed failures', () {
    for (final (status, kind) in [
      (429, SpeedFailureKind.rateLimited),
      (403, SpeedFailureKind.forbidden),
      (503, SpeedFailureKind.serverError),
    ]) {
      test('HTTP $status in latency is ${kind.name}', () async {
        fake.latencyStatus = status;
        await expectLater(
          provider().latency(cancel: NetworkCancelToken()),
          throwsA(_failure(kind, SpeedTestPhase.latency, status: status)),
        );
      });

      test('HTTP $status in download is ${kind.name}', () async {
        fake.downStatus = status;
        await expectLater(
          provider().download(cancel: NetworkCancelToken()),
          throwsA(_failure(kind, SpeedTestPhase.download, status: status)),
        );
      });

      test('HTTP $status in upload is ${kind.name}', () async {
        fake.upStatus = status;
        await expectLater(
          provider().upload(cancel: NetworkCancelToken()),
          throwsA(_failure(kind, SpeedTestPhase.upload, status: status)),
        );
      });
    }

    test('nothing listening is unreachable, in every phase', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close(force: true);
      final p = CloudflareSpeedProvider(base: Uri.parse('http://127.0.0.1:$port'), config: _refusal, healthTimeout: _refusalDeadline);
      await expectLater(p.latency(cancel: NetworkCancelToken()), throwsA(_failure(SpeedFailureKind.unreachable, SpeedTestPhase.latency)));
      await expectLater(p.download(cancel: NetworkCancelToken()), throwsA(_failure(SpeedFailureKind.unreachable, SpeedTestPhase.download)));
      await expectLater(p.upload(cancel: NetworkCancelToken()), throwsA(_failure(SpeedFailureKind.unreachable, SpeedTestPhase.upload)));
    });

    test('a download that stops moving is stalled after the stall timeout', () async {
      fake.stallDownload = true;
      const config = SpeedTestConfig(
        connections: 1,
        downloadDuration: Duration(seconds: 10),
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 1),
        stallTimeout: Duration(milliseconds: 600),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        provider(config).download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.stalled, SpeedTestPhase.download)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    });

    test('the failure keeps the v1.0 cause, so the facade words it the same', () async {
      fake.downStatus = 503;
      try {
        await provider().download(cancel: NetworkCancelToken());
        fail('expected a failure');
      } on SpeedProviderFailure catch (failure) {
        final message = SpeedTestException.from(failure.cause, phase: failure.phase);
        expect(message.kind, SpeedTestErrorKind.server);
        expect(message.message, contains('503'));
      }
    });
  });

  group('cancel', () {
    test('a cancelled token stops a download at once and closes its sockets', () async {
      fake.downChunkDelay = const Duration(milliseconds: 20);
      final token = NetworkCancelToken();
      const config = SpeedTestConfig(connections: 3, downloadDuration: Duration(seconds: 30), sampleInterval: Duration(milliseconds: 50));
      final future = provider(config).download(
        cancel: token,
        onProgress: (p) {
          if (p.bytes > 0) token.cancel();
        },
      );
      await expectLater(future.timeout(const Duration(seconds: 5)), throwsA(isA<SpeedTestCancelled>()));
      final seen = fake.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.requests.length, seen, reason: 'no new requests after cancel');
    });

    test('an already cancelled token opens nothing', () async {
      final token = NetworkCancelToken()..cancel();
      await expectLater(provider().latency(cancel: token), throwsA(isA<SpeedTestCancelled>()));
      await expectLater(provider().upload(cancel: token), throwsA(isA<SpeedTestCancelled>()));
      expect(fake.requests, isEmpty);
    });
  });

  group('facade', () {
    test('SpeedTestService runs through an injected provider', () async {
      final scripted = _ScriptedProvider();
      final updates = await SpeedTestService(provider: scripted).run().toList();
      expect(scripted.calls, ['latency', 'download', 'upload']);
      expect(scripted.health, isFalse, reason: 'the facade alone keeps the v1.0 warm-up');
      final result = updates.last.result!;
      expect(result.latencyMs, 12);
      expect(result.downloadMbps, 80);
      expect(result.uploadMbps, 20);
      expect(result.bytesDownloaded, 1000);
      expect(result.bytesUploaded, 500);
      expect(result.serverLabel, 'Here (HRE)');
      final phases = updates.map((u) => u.phase).toList();
      expect(phases.first, SpeedTestPhase.latency);
      expect(phases, containsAll(SpeedTestPhase.values));
      expect(updates.firstWhere((u) => u.phase == SpeedTestPhase.upload).bytesTransferred, greaterThanOrEqualTo(1000));
    });

    test('a provider failure surfaces as the v1.0 SpeedTestException', () async {
      final scripted = _ScriptedProvider()..failUpload = true;
      await expectLater(
        SpeedTestService(provider: scripted).run(),
        emitsThrough(emitsError(isA<SpeedTestException>()
            .having((e) => e.kind, 'kind', SpeedTestErrorKind.interrupted)
            .having((e) => e.message, 'message', contains('upload')))),
      );
    });
  });
}

class _ScriptedProvider implements SpeedTestProvider {
  final List<String> calls = [];
  bool? health;
  bool failUpload = false;

  @override
  String get id => 'scripted';

  @override
  Future<SpeedLatencyResult> latency({required NetworkCancelToken cancel, bool health = false, SpeedProgressCallback? onProgress}) async {
    calls.add('latency');
    this.health = health;
    onProgress?.call(const SpeedPhaseProgress(phaseProgress: 1, latencyMs: 12, jitterMs: 1, colo: 'HRE', city: 'Here'));
    return const SpeedLatencyResult(providerId: 'scripted', latencyMs: 12, jitterMs: 1, samples: 1, colo: 'HRE', city: 'Here');
  }

  @override
  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) async {
    calls.add('download');
    onProgress?.call(const SpeedPhaseProgress(phaseProgress: 0.5, currentMbps: 70, bytes: 400));
    return const SpeedTransferResult(
        providerId: 'scripted', phase: SpeedTestPhase.download, mbps: 80, bytes: 1000, duration: Duration(seconds: 1));
  }

  @override
  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) async {
    calls.add('upload');
    onProgress?.call(const SpeedPhaseProgress(phaseProgress: 0.5, currentMbps: 15, bytes: 200));
    if (failUpload) {
      throw const SpeedProviderFailure(
        kind: SpeedFailureKind.interrupted,
        phase: SpeedTestPhase.upload,
        providerId: 'scripted',
        cause: SocketException('Connection reset by peer'),
      );
    }
    return const SpeedTransferResult(
        providerId: 'scripted', phase: SpeedTestPhase.upload, mbps: 20, bytes: 500, duration: Duration(seconds: 1));
  }
}
