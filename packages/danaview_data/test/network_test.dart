import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';

const _mb = 1024 * 1024;

/// A speed test config scaled down so a full run takes a few seconds.
const _quick = SpeedTestConfig(
  latencySamples: 4,
  connections: 2,
  downloadDuration: Duration(milliseconds: 1500),
  uploadDuration: Duration(milliseconds: 1500),
  maxDownloadBytes: 400 * _mb,
  maxUploadBytes: 200 * _mb,
  warmUp: Duration(milliseconds: 300),
  sampleInterval: Duration(milliseconds: 50),
  requestTimeout: Duration(seconds: 2),
  stallTimeout: Duration(seconds: 2),
);

/// Implements Cloudflare's `/__down` and `/__up`, plus whatever [routes] adds.
class _TestServer {
  _TestServer._(this._server);

  final HttpServer _server;
  final Map<String, Future<void> Function(HttpRequest request)> routes = {};

  /// Per-connection pacing: `null` sends as fast as possible.
  int? downChunkBytes;
  Duration downChunkDelay = Duration.zero;
  int? upChunkDelayMs;

  /// Status for `/__down` requests with more than zero bytes.
  int downStatus = 200;
  int latencyRequests = 0;
  int bytesSent = 0;
  int bytesReceived = 0;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Uri url(String path) => base.resolve(path);

  static Future<_TestServer> start() async {
    final server = _TestServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._server.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      final route = routes[request.uri.path];
      if (route != null) {
        await route(request);
      } else if (request.uri.path == '/__down') {
        await _down(request);
      } else if (request.uri.path == '/__up') {
        await _up(request);
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (_) {
      // The client hung up.
    }
  }

  Future<void> _down(HttpRequest request) async {
    final bytes = int.parse(request.uri.queryParameters['bytes'] ?? '0');
    final response = request.response;
    response.headers
      ..set('cf-meta-colo', 'TST')
      ..set('cf-meta-city', 'Testville')
      ..set('server-timing', 'cfRequestDuration;dur=0.5')
      ..contentType = ContentType.binary;
    if (bytes == 0) {
      latencyRequests++;
    } else if (downStatus != 200) {
      response.statusCode = downStatus;
      await response.close();
      return;
    }
    response.contentLength = bytes;
    final chunkSize = downChunkBytes ?? 256 * 1024;
    final chunk = Uint8List(chunkSize);
    var sent = 0;
    while (sent < bytes) {
      final n = bytes - sent < chunkSize ? bytes - sent : chunkSize;
      response.add(n == chunkSize ? chunk : Uint8List(n));
      await response.flush();
      sent += n;
      bytesSent += n;
      if (downChunkDelay > Duration.zero) await Future<void>.delayed(downChunkDelay);
    }
    await response.close();
  }

  Future<void> _up(HttpRequest request) async {
    await for (final chunk in request) {
      bytesReceived += chunk.length;
      final delay = upChunkDelayMs;
      if (delay != null) await Future<void>.delayed(Duration(milliseconds: delay));
    }
    request.response.headers.set('cf-meta-colo', 'TST');
    await request.response.close();
  }
}

Future<void> _send(HttpRequest request, String body, {String? contentType, int status = 200}) async {
  request.response.statusCode = status;
  if (contentType != null) request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  request.response.write(body);
  await request.response.close();
}

/// Serves [data] with byte-range support unless [ranges] is false.
Future<void> _sendFile(HttpRequest request, Uint8List data, {required String contentType, bool ranges = true}) async {
  final response = request.response;
  response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (ranges) response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  if (ranges && range != null) {
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}')
      ..contentLength = end - start + 1
      ..add(data.sublist(start, end + 1));
  } else {
    response
      ..contentLength = data.length
      ..add(data);
  }
  await response.close();
}

Uint8List _mp4(int length) {
  final data = Uint8List(length);
  data.setAll(0, [0, 0, 0, 0x18, ...ascii.encode('ftypisom')]);
  return data;
}

const _master = '''
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Deutsch",URI="audio/de.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",URI="subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=700000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",FRAME-RATE=25.000,AUDIO="aud"
v360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
v720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=29.970
https://cdn.example.com/v1080/index.m3u8
''';

const _vod = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:6.0,
seg0.ts
#EXTINF:6.0,
seg1.ts
#EXTINF:4.5,
seg2.ts
#EXT-X-ENDLIST
''';

const _live = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:1200
#EXTINF:4.0,
live1200.ts
#EXTINF:4.0,
live1201.ts
''';

const _mpd = '''
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1M30.5S" minBufferTime="PT2S">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="1" bandwidth="1500000" width="1280" height="720" codecs="avc1.4d401f" frameRate="30000/1001"/>
      <Representation id="2" bandwidth="4500000" width="1920" height="1080" codecs="avc1.640028" frameRate="30"/>
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="a" bandwidth="128000" codecs="mp4a.40.2"/>
    </AdaptationSet>
  </Period>
</MPD>
''';

Future<List<SpeedTestUpdate>> _collect(Stream<SpeedTestUpdate> stream) => stream.toList();

void main() {
  late _TestServer server;

  setUp(() async => server = await _TestServer.start());
  tearDown(() => server.close());

  group('SpeedTestService', () {
    test('runs latency, download and upload in order and reports a result', () async {
      final service = SpeedTestService(base: server.base, config: _quick);
      final updates = await _collect(service.run());

      final phases = updates.map((u) => u.phase).toList();
      expect(phases.first, SpeedTestPhase.latency);
      expect(phases.last, SpeedTestPhase.done);
      for (var i = 1; i < phases.length; i++) {
        expect(phases[i].index, greaterThanOrEqualTo(phases[i - 1].index), reason: 'phases go forward');
        expect(updates[i].progress, greaterThanOrEqualTo(updates[i - 1].progress - 1e-9), reason: 'progress grows');
      }
      expect(phases, containsAll(SpeedTestPhase.values));

      final result = updates.last.result!;
      expect(result.latencyMs, greaterThanOrEqualTo(0));
      expect(result.latencyMs, lessThan(500));
      expect(result.jitterMs, greaterThanOrEqualTo(0));
      expect(result.downloadMbps, greaterThan(10));
      expect(result.uploadMbps, greaterThan(10));
      expect(result.bytesDownloaded, greaterThan(0));
      expect(result.bytesUploaded, greaterThan(0));
      expect(result.bytesDownloaded, lessThanOrEqualTo(_quick.maxDownloadBytes));
      expect(result.bytesUploaded, lessThanOrEqualTo(_quick.maxUploadBytes));
      expect(result.colo, 'TST');
      expect(result.serverLabel, 'Testville (TST)');
      // One warm-up request plus the samples.
      expect(server.latencyRequests, _quick.latencySamples + 1);
      expect(updates.where((u) => u.phase == SpeedTestPhase.download).last.latencyMs, result.latencyMs);
    });

    test('stops each phase at its data cap on a fast link', () async {
      const config = SpeedTestConfig(
        latencySamples: 2,
        connections: 4,
        downloadDuration: Duration(seconds: 20),
        uploadDuration: Duration(seconds: 20),
        maxDownloadBytes: 6 * _mb,
        maxUploadBytes: 3 * _mb,
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 2),
      );
      final watch = Stopwatch()..start();
      final updates = await _collect(SpeedTestService(base: server.base, config: config).run());
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      final result = updates.last.result!;
      expect(result.bytesDownloaded, config.maxDownloadBytes);
      expect(result.bytesUploaded, config.maxUploadBytes);
      expect(server.bytesReceived, config.maxUploadBytes);
      expect(result.downloadMbps, greaterThan(0));
    });

    test('measures a throttled download close to its real rate', () async {
      // Two connections, each sending 32 KB every 50 ms: about 10.5 Mbps in total.
      server
        ..downChunkBytes = 32 * 1024
        ..downChunkDelay = const Duration(milliseconds: 50);
      const config = SpeedTestConfig(
        latencySamples: 2,
        connections: 2,
        downloadDuration: Duration(seconds: 3),
        uploadDuration: Duration(milliseconds: 600),
        warmUp: Duration(milliseconds: 500),
        sampleInterval: Duration(milliseconds: 100),
        requestTimeout: Duration(seconds: 2),
      );
      final updates = await _collect(SpeedTestService(base: server.base, config: config).run());
      final download = updates.last.result!.downloadMbps;
      expect(download, inInclusiveRange(5, 16));
      final live = updates.where((u) => u.phase == SpeedTestPhase.download && u.currentMbps > 0);
      expect(live, isNotEmpty);
    });

    test('a slow upload measures lower than a fast one', () async {
      const config = SpeedTestConfig(
        latencySamples: 2,
        connections: 2,
        downloadDuration: Duration(milliseconds: 500),
        uploadDuration: Duration(seconds: 3),
        maxDownloadBytes: 2 * _mb,
        warmUp: Duration(milliseconds: 800),
        sampleInterval: Duration(milliseconds: 100),
        requestTimeout: Duration(seconds: 3),
        stallTimeout: Duration(seconds: 3),
      );
      final fast = (await _collect(SpeedTestService(base: server.base, config: config).run())).last.result!;
      server.upChunkDelayMs = 20;
      final slow = (await _collect(SpeedTestService(base: server.base, config: config).run())).last.result!;
      expect(slow.uploadMbps, lessThan(fast.uploadMbps / 2));
      expect(slow.uploadMbps, greaterThan(0));
    });

    test('a server error fails with a friendly message after the latency phase', () async {
      server.downStatus = 503;
      final updates = <SpeedTestUpdate>[];
      Object? error;
      final done = Completer<void>();
      SpeedTestService(base: server.base, config: _quick)
          .run()
          .listen(updates.add, onError: (Object e) => error = e, onDone: done.complete);
      await done.future;
      expect(updates.map((u) => u.phase), contains(SpeedTestPhase.latency));
      expect(updates.map((u) => u.phase), isNot(contains(SpeedTestPhase.done)));
      expect(error, isA<SpeedTestException>().having((e) => e.kind, 'kind', SpeedTestErrorKind.server));
      expect((error! as SpeedTestException).message, contains('503'));
    });

    test('reports offline when nothing is listening', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close(force: true);
      final service = SpeedTestService(base: Uri.parse('http://127.0.0.1:$port'), config: _quick);
      await expectLater(
        service.run(),
        emitsThrough(emitsError(isA<SpeedTestException>().having((e) => e.kind, 'kind', SpeedTestErrorKind.offline))),
      );
    });

    test('times out when the server never answers', () async {
      final pending = <HttpRequest>[];
      server.routes['/__down'] = (request) async => pending.add(request);
      const config = SpeedTestConfig(requestTimeout: Duration(milliseconds: 400));
      final watch = Stopwatch()..start();
      await expectLater(
        SpeedTestService(base: server.base, config: config).run(),
        emitsThrough(emitsError(isA<SpeedTestException>().having((e) => e.kind, 'kind', SpeedTestErrorKind.timeout))),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a download that stalls fails with a timeout', () async {
      server.routes['/__down'] = (request) async {
        final bytes = int.parse(request.uri.queryParameters['bytes']!);
        request.response.contentLength = bytes;
        if (bytes == 0) return request.response.close();
        // Headers and a little data, then nothing.
        request.response.add(Uint8List(1024));
        await request.response.flush();
      };
      const config = SpeedTestConfig(
        latencySamples: 1,
        connections: 1,
        downloadDuration: Duration(seconds: 10),
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 1),
        stallTimeout: Duration(milliseconds: 600),
      );
      await expectLater(
        SpeedTestService(base: server.base, config: config).run(),
        emitsThrough(emitsError(isA<SpeedTestException>().having((e) => e.kind, 'kind', SpeedTestErrorKind.timeout))),
      );
    });

    test('a phase that stalls before its stall timeout still fails, not 0 Mbps', () async {
      // The stall timeout outlasts the phase, so only the time box can catch it.
      server.routes['/__down'] = (request) async {
        final bytes = int.parse(request.uri.queryParameters['bytes']!);
        request.response.contentLength = bytes;
        if (bytes == 0) return request.response.close();
        request.response.add(Uint8List(1024));
        await request.response.flush();
      };
      const config = SpeedTestConfig(
        latencySamples: 1,
        connections: 1,
        downloadDuration: Duration(milliseconds: 800),
        sampleInterval: Duration(milliseconds: 50),
        requestTimeout: Duration(seconds: 2),
        stallTimeout: Duration(seconds: 1),
      );
      await expectLater(
        SpeedTestService(base: server.base, config: config).run(),
        emitsThrough(emitsError(isA<SpeedTestException>().having((e) => e.kind, 'kind', SpeedTestErrorKind.timeout))),
      );
    });

    test('by default a stall is caught well before a phase ends', () {
      const config = SpeedTestConfig();
      expect(config.stallTimeout, lessThan(config.downloadDuration));
      expect(config.stallTimeout, lessThan(config.uploadDuration));
      // Decimal megabytes, as data plans count them.
      expect(config.maxTotalBytes, 140 * 1000 * 1000);
    });

    test('cancelling stops the test, closes its sockets and ends the stream quietly', () async {
      server
        ..downChunkBytes = 16 * 1024
        ..downChunkDelay = const Duration(milliseconds: 20);
      const config = SpeedTestConfig(
        latencySamples: 2,
        connections: 3,
        downloadDuration: Duration(seconds: 30),
        sampleInterval: Duration(milliseconds: 50),
      );
      final token = NetworkCancelToken();
      final updates = <SpeedTestUpdate>[];
      Object? error;
      final done = Completer<void>();
      SpeedTestService(base: server.base, config: config).run(cancel: token).listen(
        (update) {
          updates.add(update);
          if (update.phase == SpeedTestPhase.download && update.currentMbps > 0) token.cancel();
        },
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(error, isNull);
      expect(updates.last.phase, SpeedTestPhase.download);
      await _expectNoMoreTraffic(server);
    });

    test('cancelling the subscription stops the test too', () async {
      server
        ..downChunkBytes = 16 * 1024
        ..downChunkDelay = const Duration(milliseconds: 20);
      const config = SpeedTestConfig(latencySamples: 1, connections: 2, downloadDuration: Duration(seconds: 30));
      final reachedDownload = Completer<void>();
      final subscription = SpeedTestService(base: server.base, config: config).run().listen((update) {
        if (update.phase == SpeedTestPhase.download && update.currentMbps > 0 && !reachedDownload.isCompleted) {
          reachedDownload.complete();
        }
      });
      await reachedDownload.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      await _expectNoMoreTraffic(server);
    });
  });

  group('StreamProbe', () {
    final probe = StreamProbe(timeout: const Duration(seconds: 2));

    test('a seekable MP4 is playable', () async {
      server.routes['/video.mp4'] = (r) => _sendFile(r, _mp4(2 * _mb), contentType: 'video/mp4');
      final result = await probe.check(server.url('/video.mp4'));
      expect(result.statusCode, 200);
      expect(result.kind, StreamKind.video);
      expect(result.container, 'MP4');
      expect(result.contentType, 'video/mp4');
      expect(result.contentLength, 2 * _mb);
      expect(result.acceptsRanges, isTrue);
      expect(result.seekable, isTrue);
      expect(result.timeToFirstByte, isNotNull);
      expect(result.issues, isEmpty);
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a slow server gets a note, not a worse verdict', () async {
      server.routes['/slow.mp4'] = (r) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _sendFile(r, _mp4(4096), contentType: 'video/mp4');
      };
      final result = await StreamProbe(slowResponse: const Duration(milliseconds: 200)).check(server.url('/slow.mp4'));
      expect(result.timeToFirstByte, greaterThan(const Duration(milliseconds: 350)));
      expect(
        result.issues.where((i) => i.level == StreamIssueLevel.info).map((i) => i.message),
        contains(contains('slow to respond')),
      );
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a server without range support might not play', () async {
      server.routes['/noseek.mp4'] = (r) => _sendFile(r, _mp4(64 * 1024), contentType: 'video/mp4', ranges: false);
      final result = await probe.check(server.url('/noseek.mp4'));
      expect(result.seekable, isFalse);
      expect(result.issues.map((i) => i.message), contains(contains('Server does not support seeking')));
      expect(result.verdict, StreamVerdict.mightNotPlay);
    });

    test('reads only the start of a large file', () async {
      final sent = <int>[0];
      server.routes['/huge.mkv'] = (request) async {
        final response = request.response
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..contentLength = 500 * _mb;
        final chunk = Uint8List(64 * 1024)..setAll(0, const [0x1A, 0x45, 0xDF, 0xA3]);
        for (var i = 0; i < 8000; i++) {
          response.add(chunk);
          await response.flush();
          sent[0] += chunk.length;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await response.close();
      };
      final watch = Stopwatch()..start();
      final result = await probe.check(server.url('/huge.mkv'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(result.kind, StreamKind.video);
      expect(result.container, 'Matroska');
      expect(result.seekable, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sent[0], lessThan(8 * _mb));
    });

    test('follows redirects and records the chain', () async {
      server.routes['/a'] = (r) async {
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, '/b?x=1');
        await r.response.close();
      };
      server.routes['/b'] = (r) async {
        r.response
          ..statusCode = 301
          ..headers.set(HttpHeaders.locationHeader, server.url('/video.mp4').toString());
        await r.response.close();
      };
      server.routes['/video.mp4'] = (r) => _sendFile(r, _mp4(4096), contentType: 'video/mp4');
      final result = await probe.check(server.url('/a'));
      expect(result.redirects.map((r) => r.statusCode), [302, 301]);
      expect(result.redirects.first.to, server.url('/b?x=1'));
      expect(result.finalUrl, server.url('/video.mp4'));
      expect(result.wasRedirected, isTrue);
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a redirect loop is not playable', () async {
      server.routes['/loop'] = (r) async {
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, '/loop');
        await r.response.close();
      };
      final result = await probe.check(server.url('/loop'));
      expect(result.verdict, StreamVerdict.notPlayable);
      expect(result.issues.single.message, contains('Too many redirects'));
    });

    test('a redirect to a malformed address is reported, not thrown', () async {
      server.routes['/a'] = (r) async {
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, '/b');
        await r.response.close();
      };
      server.routes['/b'] = (r) async {
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, 'http://[bad');
        await r.response.close();
      };
      final result = await probe.check(server.url('/a'));
      expect(result.verdict, StreamVerdict.notPlayable);
      expect(result.issues.single.message, 'The server redirected to an invalid address.');
      expect(result.redirects.map((r) => r.to), [server.url('/b')]);
      expect(result.finalUrl, server.url('/b'));
      expect(result.statusCode, 302);
    });

    test('a master playlist whose first level has a malformed address might not play', () async {
      server.routes['/hls/master.m3u8'] = (r) => _send(
            r,
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nhttp://[bad/index.m3u8\n',
            contentType: 'application/vnd.apple.mpegurl',
          );
      final result = await probe.check(server.url('/hls/master.m3u8'));
      expect(result.manifest!.variants, hasLength(1));
      expect(result.issues.map((i) => i.message), contains(contains('invalid address')));
      expect(result.verdict, StreamVerdict.mightNotPlay);
    });

    test('an HLS master playlist lists its variants and its first level decides live or VOD', () async {
      server.routes['/hls/master.m3u8'] = (r) => _send(r, _master, contentType: 'application/vnd.apple.mpegurl');
      server.routes['/hls/v360/index.m3u8'] = (r) => _send(r, _vod, contentType: 'application/vnd.apple.mpegurl');
      final result = await probe.check(server.url('/hls/master.m3u8'));
      expect(result.kind, StreamKind.hls);
      final manifest = result.manifest!;
      expect(manifest.isMaster, isTrue);
      expect(manifest.variants, hasLength(3));
      final first = manifest.variants.first;
      expect(first.bandwidth, 800000);
      expect(first.averageBandwidth, 700000);
      expect((first.width, first.height), (640, 360));
      expect(first.codecs, 'avc1.4d401e,mp4a.40.2');
      expect(first.frameRate, 25);
      expect(manifest.variants.last.uri, 'https://cdn.example.com/v1080/index.m3u8');
      expect(manifest.audioTracks, 2);
      expect(manifest.subtitleTracks, 1);
      expect(manifest.isLive, isFalse);
      expect(manifest.duration, const Duration(milliseconds: 16500));
      expect(manifest.segmentCount, 3);
      expect(result.seekable, isNull);
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a master playlist whose first level is forbidden might not play', () async {
      server.routes['/hls/master.m3u8'] = (r) => _send(r, _master, contentType: 'application/x-mpegURL');
      server.routes['/hls/v360/index.m3u8'] = (r) => _send(r, 'no', status: 403);
      final result = await probe.check(server.url('/hls/master.m3u8'));
      expect(result.manifest!.variants, hasLength(3));
      expect(result.manifest!.isLive, isNull);
      expect(result.issues.map((i) => i.message), contains(contains('HTTP 403')));
      expect(result.verdict, StreamVerdict.mightNotPlay);
    });

    test('a media playlist without an end marker is live', () async {
      // Served as plain text: the #EXTM3U header gives it away.
      server.routes['/live'] = (r) => _send(r, _live, contentType: 'text/plain');
      final result = await probe.check(server.url('/live'));
      expect(result.kind, StreamKind.hls);
      expect(result.manifest!.isMaster, isFalse);
      expect(result.manifest!.isLive, isTrue);
      expect(result.manifest!.targetDuration, const Duration(seconds: 4));
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a huge playlist is read only in part, so live or VOD stays unknown', () async {
      final big = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:2\n');
      for (var i = 0; big.length < 400 * 1024; i++) {
        big.write('#EXTINF:2.0,\nsegment-with-a-long-name-$i.ts\n');
      }
      big.write('#EXT-X-ENDLIST\n');
      server.routes['/big.m3u8'] = (r) => _send(r, big.toString(), contentType: 'application/vnd.apple.mpegurl');
      final result = await probe.check(server.url('/big.m3u8'));
      expect(result.manifest!.truncated, isTrue);
      expect(result.manifest!.isLive, isNull);
      expect(result.issues.map((i) => i.message), contains(contains('256 KB')));
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a DRM-protected playlist is not playable', () async {
      server.routes['/drm.m3u8'] = (r) => _send(
            r,
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"\n'
            '#EXTINF:6.0,\na.ts\n#EXT-X-ENDLIST\n',
            contentType: 'application/vnd.apple.mpegurl',
          );
      final result = await probe.check(server.url('/drm.m3u8'));
      expect(result.manifest!.drm, isTrue);
      expect(result.verdict, StreamVerdict.notPlayable);
    });

    test('AES-128 encryption is fine', () async {
      server.routes['/aes.m3u8'] = (r) => _send(
            r,
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:6.0,\na.ts\n#EXT-X-ENDLIST\n',
            contentType: 'application/vnd.apple.mpegurl',
          );
      final result = await probe.check(server.url('/aes.m3u8'));
      expect(result.manifest!.encryption, 'AES-128');
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a DASH manifest reports duration and representations', () async {
      server.routes['/stream.mpd'] = (r) => _send(r, _mpd, contentType: 'application/dash+xml');
      final result = await probe.check(server.url('/stream.mpd'));
      expect(result.kind, StreamKind.dash);
      final manifest = result.manifest!;
      expect(manifest.isLive, isFalse);
      expect(manifest.duration, const Duration(seconds: 90, milliseconds: 500));
      expect(manifest.variants.map((v) => v.height), [720, 1080]);
      expect(manifest.variants.first.frameRate, closeTo(29.97, 0.01));
      expect(manifest.audioTracks, 1);
      expect(result.verdict, StreamVerdict.playable);
    });

    test('a web page is not a video', () async {
      server.routes['/watch'] = (r) => _send(
            r,
            '<!DOCTYPE html><html><head><title>Video</title></head><body></body></html>',
            contentType: 'text/html; charset=utf-8',
          );
      final result = await probe.check(server.url('/watch'));
      expect(result.kind, StreamKind.webPage);
      expect(result.verdict, StreamVerdict.notPlayable);
      expect(result.issues.first.message, contains('This is a web page, not a video'));
    });

    test('HTTP errors explain themselves', () async {
      server.routes['/forbidden.mp4'] = (r) => _send(r, 'nope', status: 403);
      final forbidden = await probe.check(server.url('/forbidden.mp4'));
      expect(forbidden.statusCode, 403);
      expect(forbidden.issues.single.message, startsWith('403 Forbidden'));
      expect(forbidden.verdict, StreamVerdict.notPlayable);

      final missing = await probe.check(server.url('/missing.mp4'));
      expect(missing.issues.single.message, startsWith('404 Not Found'));
      expect(missing.verdict, StreamVerdict.notPlayable);
    });

    test('an unrecognized format might not play', () async {
      server.routes['/blob'] = (r) => _send(r, 'just some text', contentType: 'application/octet-stream');
      final result = await probe.check(server.url('/blob'));
      expect(result.kind, StreamKind.unknown);
      expect(result.verdict, StreamVerdict.mightNotPlay);
    });

    test('a server that never answers times out', () async {
      final pending = <HttpRequest>[];
      server.routes['/hang'] = (r) async => pending.add(r);
      final result = await StreamProbe(timeout: const Duration(milliseconds: 400)).check(server.url('/hang'));
      expect(result.statusCode, isNull);
      expect(result.issues.single.message, contains("didn't respond"));
      expect(result.verdict, StreamVerdict.notPlayable);
    });

    test('a refused connection is not playable', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close(force: true);
      final result = await probe.check(Uri.parse('http://127.0.0.1:$port/video.mp4'));
      expect(result.verdict, StreamVerdict.notPlayable);
      expect(result.issues.single.message, contains('refused'));
    });

    test('cancelling stops the check', () async {
      final pending = <HttpRequest>[];
      server.routes['/hang'] = (r) async => pending.add(r);
      final token = NetworkCancelToken();
      final check = StreamProbe(timeout: const Duration(seconds: 10)).check(server.url('/hang'), cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      token.cancel();
      await expectLater(
        check.timeout(const Duration(seconds: 2)),
        throwsA(isA<StreamProbeException>().having((e) => e.cancelled, 'cancelled', isTrue)),
      );
    });

    test('links that are not http(s) are refused', () async {
      await expectLater(
        probe.check(Uri.parse('rtsp://camera.local/stream')),
        throwsA(isA<StreamProbeException>().having((e) => e.message, 'message', contains('RTSP'))),
      );
    });
  });

  group('parseHlsPlaylist', () {
    test('an event playlist without an end marker is live; VOD type is not', () {
      expect(parseHlsPlaylist('#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:2,\na.ts\n').isLive, isTrue);
      expect(parseHlsPlaylist('#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2,\na.ts\n').isLive, isFalse);
    });

    test('handles CRLF line endings and Widevine keys', () {
      final playlist = parseHlsPlaylist(
        '#EXTM3U\r\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI="data:x",KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"\r\n'
        '#EXTINF:3.5,title\r\na.ts\r\n#EXT-X-ENDLIST\r\n',
      );
      expect(playlist.drm, isTrue);
      expect(playlist.duration, const Duration(milliseconds: 3500));
      expect(playlist.isLive, isFalse);
    });
  });
}

/// The client's sockets are gone once the server can no longer push data down them.
Future<void> _expectNoMoreTraffic(_TestServer server) async {
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final sent = server.bytesSent;
  await Future<void>.delayed(const Duration(milliseconds: 400));
  expect(server.bytesSent - sent, lessThan(64 * 1024));
}
