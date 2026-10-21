// OWNER: ST-02
//
// MLabNdt7Provider and the locate client against a loopback fake locate + NDT7 server (V2-401):
// download, upload, malformed messages, early close, typed failures, cancel, the consent ticket
// (ARCH rule 28), and the no-network guard (no request to an M-Lab host in any test).

import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_data/src/network/speed/mlab_ndt7_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_ndt7_server.dart';

const _mb = 1024 * 1024;

const _quick = SpeedTestConfig(
  latencySamples: 3,
  downloadDuration: Duration(milliseconds: 800),
  uploadDuration: Duration(milliseconds: 800),
  maxDownloadBytes: 200 * _mb,
  maxUploadBytes: 100 * _mb,
  warmUp: Duration(milliseconds: 200),
  sampleInterval: Duration(milliseconds: 50),
  requestTimeout: Duration(seconds: 2),
  stallTimeout: Duration(milliseconds: 600),
);

final _ticket = OpenNetworkConsent.accepted(DateTime.utc(2026, 10, 22));

Matcher _failure(SpeedFailureKind kind, SpeedTestPhase phase, {int? status}) => isA<SpeedProviderFailure>()
    .having((f) => f.kind, 'kind', kind)
    .having((f) => f.phase, 'phase', phase)
    .having((f) => f.providerId, 'providerId', 'mlab')
    .having((f) => f.status, 'status', status);

void main() {
  late FakeNdt7Server fake;

  setUpAll(NoNetworkGuard.install);
  tearDownAll(() {
    NoNetworkGuard.uninstall();
  });

  setUp(() async {
    NoNetworkGuard.blocked.clear();
    fake = await FakeNdt7Server.start();
  });
  tearDown(() async {
    await fake.close();
  });

  MLabLocateClient locate() => MLabLocateClient(endpoint: fake.locateUrl, acceptServerUrl: (u) => isLoopbackHost(u.host));

  MLabNdt7Provider provider({
    SpeedTestConfig config = _quick,
    OpenNetworkConsent? Function()? consent,
    DateTime Function()? now,
  }) =>
      MLabNdt7Provider(consent: consent ?? () => _ticket, locate: locate(), config: config, now: now);

  group('defaults', () {
    test('M-Lab endpoints, subprotocol, health timeout; creating it opens nothing', () {
      final p = MLabNdt7Provider(consent: () => _ticket);
      expect(p.id, 'mlab');
      expect(MLabNdt7Provider.subprotocol, 'net.measurementlab.ndt.v7');
      expect(p.locate.endpoint, Uri.parse('https://locate.measurementlab.net/v2/nearest/ndt/ndt7'));
      expect(p.healthTimeout, const Duration(milliseconds: 1500));
      expect(p.locate.requestUrl.queryParameters, {'client_name': 'danaview', 'client_version': '1.2.0'});
      expect(NoNetworkGuard.blocked, isEmpty);
    });

    test('only wss on measurement-lab.org is trusted by default', () {
      bool ok(String url) => MLabLocateClient.isMLabServerUrl(Uri.parse(url));
      expect(ok('wss://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/download'), isTrue);
      expect(ok('ws://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/download'), isFalse);
      expect(ok('wss://measurement-lab.org.evil.example/ndt/v7/download'), isFalse);
      expect(ok('wss://127.0.0.1/ndt/v7/download'), isFalse);
    });

    test('the no-network guard blocks the real M-Lab hosts', () async {
      final p = MLabNdt7Provider(consent: () => _ticket, config: _quick);
      await expectLater(
        p.latency(cancel: NetworkCancelToken(), health: true),
        throwsA(_failure(SpeedFailureKind.unreachable, SpeedTestPhase.latency)),
      );
      expect(NoNetworkGuard.blocked, ['locate.measurementlab.net']);
      await expectLater(
        Socket.connect('ndt-mlab1-lga05.mlab-oti.measurement-lab.org', 443),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('consent ticket (ARCH rule 28)', () {
    test('every phase refuses to run without a ticket, before any connection', () async {
      final p = provider(consent: () => null);
      final cancel = NetworkCancelToken();
      await expectLater(p.latency(cancel: cancel), throwsA(isA<OpenNetworkConsentRequired>()));
      await expectLater(p.latency(cancel: cancel, health: true), throwsA(isA<OpenNetworkConsentRequired>()));
      await expectLater(p.download(cancel: cancel), throwsA(isA<OpenNetworkConsentRequired>()));
      await expectLater(
        p.upload(cancel: cancel),
        throwsA(isA<OpenNetworkConsentRequired>().having((e) => e.phase, 'phase', SpeedTestPhase.upload)),
      );
      expect(fake.requests, isEmpty);
    });

    test('a ticket withdrawn between phases stops the next phase', () async {
      OpenNetworkConsent? current = _ticket;
      final p = provider(consent: () => current);
      await p.latency(cancel: NetworkCancelToken());
      current = null;
      final before = fake.requests.length;
      await expectLater(p.download(cancel: NetworkCancelToken()), throwsA(isA<OpenNetworkConsentRequired>()));
      expect(fake.requests, hasLength(before));
    });

    test('the refusal is not a provider failure', () {
      expect(const OpenNetworkConsentRequired(SpeedTestPhase.download), isNot(isA<SpeedProviderFailure>()));
      expect(_ticket.acceptedAt, DateTime.utc(2026, 10, 22));
    });
  });

  group('locate', () {
    test('parses the documented answer and prefers wss', () {
      const body = '''
{"results":[{"machine":"mlab1-lga05.mlab-oti.measurement-lab.org","location":{"city":"New York","country":"US"},
"urls":{"ws:///ndt/v7/download":"ws://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=a",
"ws:///ndt/v7/upload":"ws://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=b",
"wss:///ndt/v7/download":"wss://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=c",
"wss:///ndt/v7/upload":"wss://ndt-mlab1-lga05.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=d"}}]}''';
      final servers = MLabLocateClient.parse(body);
      expect(servers, hasLength(1));
      expect(servers.single.city, 'New York');
      expect(servers.single.country, 'US');
      expect(servers.single.machine, 'mlab1-lga05.mlab-oti.measurement-lab.org');
      expect(servers.single.downloadUrl.scheme, 'wss');
      expect(servers.single.downloadUrl.queryParameters['access_token'], 'c');
      expect(servers.single.uploadUrl.queryParameters['access_token'], 'd');
    });

    test('malformed answers are rejected', () {
      for (final body in [
        'nope',
        '[]',
        '{"results": 3}',
        '{"results": []}',
        '{"results": [{"urls": {"wss:///ndt/v7/download": "wss://x.measurement-lab.org/d"}}]}',
        '{"results": [{"urls": {"wss:///ndt/v7/download": "wss://evil.example/d", "wss:///ndt/v7/upload": "wss://evil.example/u"}}]}',
      ]) {
        expect(
          () => MLabLocateClient.parse(body),
          throwsA(isA<MLabLocateException>().having((e) => e.kind, 'kind', MLabLocateErrorKind.malformed)),
          reason: body,
        );
      }
    });

    test('a malformed locate answer fails the phase before any test connection', () async {
      fake.locateBody = '{"results": "soon"}';
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.serverError, SpeedTestPhase.download)),
      );
      expect(fake.downloadRequests, isEmpty);
    });

    test('locate 429 and 403 are rateLimited and forbidden', () async {
      fake.locateStatus = 429;
      await expectLater(
        provider().latency(cancel: NetworkCancelToken(), health: true),
        throwsA(_failure(SpeedFailureKind.rateLimited, SpeedTestPhase.latency, status: 429)),
      );
      fake.locateStatus = 403;
      await expectLater(
        provider().upload(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.forbidden, SpeedTestPhase.upload, status: 403)),
      );
    });

    test('a slow locate fails the health check as stalled', () async {
      fake.locateDelay = const Duration(seconds: 3);
      final watch = Stopwatch()..start();
      await expectLater(
        provider(config: const SpeedTestConfig(latencySamples: 2, requestTimeout: Duration(seconds: 5)))
            .latency(cancel: NetworkCancelToken(), health: true),
        throwsA(_failure(SpeedFailureKind.stalled, SpeedTestPhase.latency)),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2800)));
    });

    test('a closed locate port is unreachable', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final p = MLabNdt7Provider(
        consent: () => _ticket,
        config: _quick,
        locate: MLabLocateClient(endpoint: Uri.parse('http://127.0.0.1:$port/v2/nearest/ndt/ndt7')),
      );
      await expectLater(
        p.latency(cancel: NetworkCancelToken(), health: true),
        throwsA(_failure(SpeedFailureKind.unreachable, SpeedTestPhase.latency)),
      );
    });

    test('one locate serves a whole run; a used token or an old answer is fetched again', () async {
      var clock = DateTime.utc(2026, 10, 22, 12);
      final p = provider(now: () => clock);
      await p.latency(cancel: NetworkCancelToken(), health: true);
      await p.download(cancel: NetworkCancelToken());
      await p.upload(cancel: NetworkCancelToken());
      expect(fake.locateRequests, hasLength(1));
      expect(fake.locateRequests.single.uri.queryParameters['client_name'], 'danaview');
      // The download token was used: a second download locates again.
      await p.download(cancel: NetworkCancelToken());
      expect(fake.locateRequests, hasLength(2));
      clock = clock.add(const Duration(minutes: 2));
      await p.latency(cancel: NetworkCancelToken());
      expect(fake.locateRequests, hasLength(3));
      final tokens = [for (final r in fake.downloadRequests) r.uri.queryParameters['access_token']];
      expect(tokens.toSet(), hasLength(tokens.length));
    });
  });

  group('latency', () {
    test('TCP connects to the located server: one warm-up plus the samples', () async {
      final progress = <SpeedPhaseProgress>[];
      final result = await provider().latency(cancel: NetworkCancelToken(), health: true, onProgress: progress.add);
      expect(result.providerId, 'mlab');
      expect(result.samples, _quick.latencySamples);
      expect(result.latencyMs, inInclusiveRange(0, 500));
      expect(result.jitterMs, greaterThanOrEqualTo(0));
      expect(result.city, 'Testville');
      expect(result.colo, isNull);
      expect(progress.map((p) => p.phaseProgress), [for (var i = 1; i <= _quick.latencySamples; i++) i / _quick.latencySamples]);
      // Only the locate request is HTTP; no test data moved.
      expect(fake.requests.map((r) => r.uri.path), ['/v2/nearest/ndt/ndt7']);
    });
  });

  group('download', () {
    test('NDT7 WebSocket with the subprotocol; bytes and Mbps from one stream', () async {
      final progress = <SpeedPhaseProgress>[];
      final result = await provider().download(cancel: NetworkCancelToken(), onProgress: progress.add);
      expect(result.providerId, 'mlab');
      expect(result.phase, SpeedTestPhase.download);
      expect(result.bytes, greaterThan(0));
      expect(result.mbps, greaterThan(1));
      expect(result.duration, greaterThanOrEqualTo(_quick.downloadDuration));
      expect(result.duration, lessThan(_quick.downloadDuration + const Duration(milliseconds: 600)));
      expect(progress, isNotEmpty);
      expect(progress.last.bytes, lessThanOrEqualTo(result.bytes));
      expect(progress.map((p) => p.phaseProgress), everyElement(inInclusiveRange(0, 1)));
      final request = fake.downloadRequests.single;
      expect(request.offeredProtocols, ['net.measurementlab.ndt.v7']);
      expect(request.uri.queryParameters['access_token'], startsWith('token-download-'));
      expect(request.uri.queryParameters['client_name'], 'danaview');
      expect(request.headers.value('sec-websocket-extensions'), isNull);
    });

    test('stops at the data cap', () async {
      const config = SpeedTestConfig(
        downloadDuration: Duration(seconds: 20),
        maxDownloadBytes: 1 * _mb,
        warmUp: Duration(milliseconds: 100),
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 2),
      );
      final result = await provider(config: config).download(cancel: NetworkCancelToken());
      expect(result.bytes, greaterThanOrEqualTo(config.maxDownloadBytes));
      expect(result.bytes, lessThan(config.maxDownloadBytes + 64 * 1024));
      expect(result.duration, lessThan(const Duration(seconds: 5)));
    });

    test('malformed measurement messages are ignored', () async {
      fake.download = FakeDownload.malformed;
      final result = await provider().download(cancel: NetworkCancelToken());
      expect(result.bytes, greaterThan(0));
      expect(result.mbps, greaterThan(1));
    });

    test('the server closing at once is an interrupted phase', () async {
      fake.download = FakeDownload.closeImmediately;
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.interrupted, SpeedTestPhase.download)),
      );
    });

    test('a dropped connection mid-test is interrupted', () async {
      fake.download = FakeDownload.dropAfterData;
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.interrupted, SpeedTestPhase.download)),
      );
    });

    test('the server ending the test normally after the warm-up gives a result', () async {
      fake
        ..download = FakeDownload.serverEndsTest
        ..serverTestLength = const Duration(milliseconds: 400);
      final result = await provider(config: _quick).download(cancel: NetworkCancelToken());
      expect(result.bytes, greaterThan(0));
      expect(result.duration, lessThan(_quick.downloadDuration));
    });

    test('no bytes moving is stalled', () async {
      fake.download = FakeDownload.stall;
      final watch = Stopwatch()..start();
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.stalled, SpeedTestPhase.download)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('HTTP 429 and 403 on the upgrade are rateLimited and forbidden', () async {
      fake.downloadStatus = 429;
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.rateLimited, SpeedTestPhase.download, status: 429)),
      );
      fake.downloadStatus = 403;
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.forbidden, SpeedTestPhase.download, status: 403)),
      );
    });

    test('a server that does not select the NDT7 subprotocol is refused', () async {
      fake.selectSubprotocol = false;
      await expectLater(
        provider().download(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.serverError, SpeedTestPhase.download)),
      );
    });
  });

  group('upload', () {
    test('NDT7 messages that grow from 8 KiB; Mbps from the server measurements', () async {
      final progress = <SpeedPhaseProgress>[];
      final result = await provider().upload(cancel: NetworkCancelToken(), onProgress: progress.add);
      expect(result.providerId, 'mlab');
      expect(result.phase, SpeedTestPhase.upload);
      expect(result.bytes, greaterThan(0));
      expect(result.mbps, greaterThan(1));
      expect(fake.uploadReceived, greaterThan(0));
      expect(fake.uploadReceived, lessThanOrEqualTo(result.bytes));
      expect(fake.largestUploadMessage, greaterThan(MLabNdt7Provider.initialUploadMessageBytes));
      expect(fake.largestUploadMessage, lessThanOrEqualTo(_quick.maxUploadRequestBytes));
      expect(progress, isNotEmpty);
      final request = fake.uploadRequests.single;
      expect(request.offeredProtocols, ['net.measurementlab.ndt.v7']);
      expect(request.uri.queryParameters['access_token'], startsWith('token-upload-'));
    });

    test('stops at the data cap', () async {
      const config = SpeedTestConfig(
        uploadDuration: Duration(seconds: 20),
        maxUploadBytes: 2 * _mb,
        warmUp: Duration(milliseconds: 100),
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 2),
      );
      final result = await provider(config: config).upload(cancel: NetworkCancelToken());
      expect(result.bytes, config.maxUploadBytes);
      expect(result.duration, lessThan(const Duration(seconds: 5)));
    });

    test('malformed server messages are ignored', () async {
      fake.upload = FakeUpload.malformed;
      final result = await provider().upload(cancel: NetworkCancelToken());
      expect(result.mbps, greaterThan(1));
    });

    test('a server that never reports what it received is stalled', () async {
      fake.upload = FakeUpload.silent;
      await expectLater(
        provider().upload(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.stalled, SpeedTestPhase.upload)),
      );
    });

    test('the server closing at once is interrupted', () async {
      fake.upload = FakeUpload.closeImmediately;
      await expectLater(
        provider().upload(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.interrupted, SpeedTestPhase.upload)),
      );
    });

    test('a dropped connection mid-test is interrupted', () async {
      fake.upload = FakeUpload.dropAfterData;
      await expectLater(
        provider().upload(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.interrupted, SpeedTestPhase.upload)),
      );
    });

    test('HTTP 429 on the upgrade is rateLimited', () async {
      fake.uploadStatus = 429;
      await expectLater(
        provider().upload(cancel: NetworkCancelToken()),
        throwsA(_failure(SpeedFailureKind.rateLimited, SpeedTestPhase.upload, status: 429)),
      );
    });
  });

  group('measurement messages', () {
    test('a server measurement is parsed', () {
      final m = Ndt7Measurement.tryParse(FakeNdt7Server.measurement('upload', bytes: 5000, micros: 250000))!;
      expect(m.origin, 'server');
      expect(m.test, 'upload');
      expect(m.appNumBytes, 5000);
      expect(m.tcpBytesReceived, 5000);
      expect(m.tcpElapsedMicros, 250000);
      expect(m.minRttMicros, 1000);
      expect(m.rttMicros, 1500);
      expect(m.serverReceived, (bytes: 5000, micros: 250000));
    });

    test('malformed messages read as null or as missing fields', () {
      for (final text in FakeNdt7Server.malformedMessages) {
        final m = Ndt7Measurement.tryParse(text);
        expect(m?.serverReceived, isNull, reason: text);
      }
      expect(Ndt7Measurement.tryParse('{"Origin":"server"}'), isNull);
      expect(Ndt7Measurement.tryParse('{"AppInfo":{}}${' ' * (Ndt7Measurement.maxLength)}'), isNull);
      final partial = Ndt7Measurement.tryParse('{"AppInfo":{"NumBytes":10,"ElapsedTime":"soon"}}')!;
      expect(partial.appNumBytes, 10);
      expect(partial.appElapsedMicros, isNull);
      expect(partial.serverReceived, isNull);
    });
  });

  group('cancel', () {
    test('cancelling a running download ends it at once with SpeedTestCancelled', () async {
      final cancel = NetworkCancelToken();
      final p = provider(config: const SpeedTestConfig(downloadDuration: Duration(seconds: 20), requestTimeout: Duration(seconds: 2)));
      final run = p.download(cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      cancel.cancel();
      await expectLater(run, throwsA(isA<SpeedTestCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('cancelling a running upload ends it with SpeedTestCancelled', () async {
      final cancel = NetworkCancelToken();
      final p = provider(config: const SpeedTestConfig(uploadDuration: Duration(seconds: 20), maxUploadBytes: 4000 * _mb, requestTimeout: Duration(seconds: 2)));
      final run = p.upload(cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      cancel.cancel();
      await expectLater(run, throwsA(isA<SpeedTestCancelled>()));
    });

    test('an already cancelled token opens nothing', () async {
      final cancel = NetworkCancelToken()..cancel();
      await expectLater(provider().latency(cancel: cancel), throwsA(isA<SpeedTestCancelled>()));
      await expectLater(provider().download(cancel: cancel), throwsA(isA<SpeedTestCancelled>()));
      expect(fake.requests, isEmpty);
    });
  });

  group('behind the v1.0 facade', () {
    test('SpeedTestService runs a whole test on the provider', () async {
      final updates = await SpeedTestService(provider: provider()).run().toList();
      final result = updates.last.result!;
      expect(updates.last.phase, SpeedTestPhase.done);
      expect(result.downloadMbps, greaterThan(0));
      expect(result.uploadMbps, greaterThan(0));
      expect(result.city, 'Testville');
      expect(result.serverLabel, 'Testville');
      expect(fake.locateRequests, hasLength(1));
    });
  });

  test('no request reached a non-loopback host', () {
    // Every test above ran under the guard; only the guard test itself tried the real hosts.
    expect(NoNetworkGuard.everBlocked, ['locate.measurementlab.net', 'ndt-mlab1-lga05.mlab-oti.measurement-lab.org']);
  });
}
