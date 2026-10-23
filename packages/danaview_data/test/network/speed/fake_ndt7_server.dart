// OWNER: ST-02
//
// A loopback fake of the M-Lab locate API and an NDT7 server (V2-401), plus the no-network guard
// the M-Lab tests run under: no socket and no HTTP connection may go to a non-loopback host, so no
// test can ever reach an M-Lab host.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;

const String ndt7Subprotocol = 'net.measurementlab.ndt.v7';
const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

enum FakeDownload {
  /// Binary data and a server measurement every [FakeNdt7Server.measurementInterval] until the
  /// client closes.
  normal,

  /// As [normal], with malformed text messages mixed in.
  malformed,

  /// Upgrades, then closes normally before sending anything.
  closeImmediately,

  /// Sends a little data, then the TCP connection drops (no close frame).
  dropAfterData,

  /// Sends data for [FakeNdt7Server.serverTestLength], then closes normally (the server ending the test).
  serverEndsTest,

  /// Sends one message, then nothing.
  stall,
}

enum FakeUpload {
  /// Counts what arrives and reports it in a measurement every [FakeNdt7Server.measurementInterval].
  normal,

  /// As [normal], with malformed text messages mixed in.
  malformed,

  /// Reads but never reports anything.
  silent,

  /// Upgrades, then closes normally at once.
  closeImmediately,

  /// Reports for a moment, then the TCP connection drops.
  dropAfterData,
}

/// One HTTP request the fake saw.
class FakeRequest {
  FakeRequest(this.uri, this.headers);

  final Uri uri;
  final HttpHeaders headers;

  List<String> get offeredProtocols => [
        for (final value in headers['sec-websocket-protocol'] ?? const <String>[])
          ...value.split(',').map((p) => p.trim()),
      ];
}

class FakeNdt7Server {
  FakeNdt7Server._(this._server);

  final HttpServer _server;
  final List<FakeRequest> requests = [];

  int locateStatus = 200;

  /// Replaces the locate answer when set.
  String? locateBody;
  Duration locateDelay = Duration.zero;

  /// When set, the NDT7 endpoints answer with this HTTP status instead of upgrading.
  int? downloadStatus;
  int? uploadStatus;

  /// Whether the upgrade selects the NDT7 subprotocol.
  bool selectSubprotocol = true;

  FakeDownload download = FakeDownload.normal;
  FakeUpload upload = FakeUpload.normal;
  Duration measurementInterval = const Duration(milliseconds: 50);
  Duration serverTestLength = const Duration(milliseconds: 500);

  /// Download pacing: [chunkBytes] every [chunkInterval].
  int chunkBytes = 32 * 1024;
  Duration chunkInterval = const Duration(milliseconds: 2);

  /// Bytes the upload endpoint received, over all connections.
  int uploadReceived = 0;

  /// The largest single upload message.
  int largestUploadMessage = 0;

  int _sessions = 0;

  int get port => _server.port;
  String get host => '127.0.0.1';

  Uri get locateUrl => Uri.parse('http://$host:$port/v2/nearest/ndt/ndt7');

  /// Requests to the locate endpoint.
  List<FakeRequest> get locateRequests => [for (final r in requests) if (r.uri.path == '/v2/nearest/ndt/ndt7') r];

  List<FakeRequest> get downloadRequests => [for (final r in requests) if (r.uri.path == '/ndt/v7/download') r];

  List<FakeRequest> get uploadRequests => [for (final r in requests) if (r.uri.path == '/ndt/v7/upload') r];

  static Future<FakeNdt7Server> start() async {
    final fake = FakeNdt7Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    fake._server.listen((r) => fake._handle(r).catchError((Object _) {}));
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// The documented locate v2 answer, pointing at this fake.
  String defaultLocateBody() {
    final session = ++_sessions;
    String url(String kind) => 'ws://$host:$port/ndt/v7/$kind?access_token=token-$kind-$session';
    return jsonEncode({
      'results': [
        {
          'machine': 'mlab1-tst01.mlab-oti.measurement-lab.org',
          'location': {'city': 'Testville', 'country': 'TS'},
          'urls': {
            'ws:///ndt/v7/download': url('download'),
            'ws:///ndt/v7/upload': url('upload'),
            'wss:///ndt/v7/download': url('download'),
            'wss:///ndt/v7/upload': url('upload'),
          },
        },
      ],
    });
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(FakeRequest(request.uri, request.headers));
    final response = request.response;
    switch (request.uri.path) {
      case '/v2/nearest/ndt/ndt7':
        if (locateDelay > Duration.zero) await Future<void>.delayed(locateDelay);
        response.statusCode = locateStatus;
        response.headers.contentType = ContentType.json;
        response.write(locateStatus == 200 ? (locateBody ?? defaultLocateBody()) : '{"error":"busy"}');
        return response.close();
      case '/ndt/v7/download':
        if (downloadStatus case final status?) {
          response.statusCode = status;
          return response.close();
        }
        final socket = await _upgrade(request);
        return _download(socket, WebSocket.fromUpgradedSocket(socket, protocol: _protocol, serverSide: true));
      case '/ndt/v7/upload':
        if (uploadStatus case final status?) {
          response.statusCode = status;
          return response.close();
        }
        final socket = await _upgrade(request);
        return _upload(socket, WebSocket.fromUpgradedSocket(socket, protocol: _protocol, serverSide: true));
    }
    response.statusCode = 404;
    await response.close();
  }

  String? get _protocol => selectSubprotocol ? ndt7Subprotocol : null;

  /// The server half of the WebSocket handshake, done by hand so a test can drop the raw socket.
  Future<Socket> _upgrade(HttpRequest request) {
    final key = request.headers.value('sec-websocket-key')!;
    final accept = base64Encode(sha1.convert(utf8.encode('$key$_webSocketGuid')).bytes);
    final response = request.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
      ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
      ..headers.set('Sec-WebSocket-Accept', accept);
    if (_protocol case final protocol?) response.headers.set('Sec-WebSocket-Protocol', protocol);
    response.contentLength = 0;
    return response.detachSocket();
  }

  static String measurement(String test, {required int bytes, required int micros}) => jsonEncode({
        'AppInfo': {'NumBytes': bytes, 'ElapsedTime': micros},
        'ConnectionInfo': {'Client': '127.0.0.1:1', 'Server': '127.0.0.1:2', 'UUID': 'fake'},
        'Origin': 'server',
        'Test': test,
        'TCPInfo': {
          'BytesAcked': bytes,
          'BytesReceived': test == 'upload' ? bytes : 0,
          'ElapsedTime': micros,
          'MinRTT': 1000,
          'RTT': 1500,
        },
      });

  static const List<String> malformedMessages = [
    'not json at all',
    '[1, 2, 3]',
    '{"AppInfo": "lots"}',
    '{"TCPInfo": {"BytesReceived": "many", "ElapsedTime": -5}}',
    '{"AppInfo": {"NumBytes": 1e400}}',
    '{',
  ];

  Future<void> _download(Socket raw, WebSocket ws) async {
    final clock = Stopwatch()..start();
    var sent = 0;
    var closed = false;
    final done = ws.listen(null, onDone: () => closed = true, onError: (Object _) => closed = true, cancelOnError: true);
    final chunk = Uint8List(chunkBytes);
    var nextMeasurement = Duration.zero;
    try {
      switch (download) {
        case FakeDownload.closeImmediately:
          await ws.close(WebSocketStatus.normalClosure);
          return;
        case FakeDownload.stall:
          ws.add(chunk);
          while (!closed) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return;
        case FakeDownload.normal || FakeDownload.malformed || FakeDownload.dropAfterData || FakeDownload.serverEndsTest:
          var malformed = 0;
          while (!closed) {
            if (download == FakeDownload.dropAfterData && sent >= 4 * chunkBytes) {
              raw.destroy();
              return;
            }
            if (download == FakeDownload.serverEndsTest && clock.elapsed >= serverTestLength) {
              await ws.close(WebSocketStatus.normalClosure);
              return;
            }
            ws.add(chunk);
            sent += chunk.length;
            if (clock.elapsed >= nextMeasurement) {
              nextMeasurement += measurementInterval;
              ws.add(measurement('download', bytes: sent, micros: clock.elapsedMicroseconds));
              if (download == FakeDownload.malformed) {
                ws.add(malformedMessages[malformed++ % malformedMessages.length]);
              }
            }
            await Future<void>.delayed(chunkInterval);
          }
      }
    } catch (_) {
      // The client went away.
    } finally {
      await done.cancel();
    }
  }

  Future<void> _upload(Socket raw, WebSocket ws) async {
    final clock = Stopwatch()..start();
    var received = 0;
    var closed = false;
    if (upload == FakeUpload.closeImmediately) {
      ws.listen(null, onError: (Object _) {});
      await ws.close(WebSocketStatus.normalClosure);
      return;
    }
    final subscription = ws.listen(
      (Object? message) {
        if (message is List<int>) {
          received += message.length;
          uploadReceived += message.length;
          if (message.length > largestUploadMessage) largestUploadMessage = message.length;
        }
      },
      onDone: () => closed = true,
      onError: (Object _) => closed = true,
      cancelOnError: true,
    );
    var malformed = 0;
    try {
      while (!closed) {
        await Future<void>.delayed(measurementInterval);
        if (closed) break;
        if (upload == FakeUpload.dropAfterData && received > 0 && clock.elapsed > const Duration(milliseconds: 150)) {
          raw.destroy();
          return;
        }
        if (upload == FakeUpload.silent) continue;
        ws.add(measurement('upload', bytes: received, micros: clock.elapsedMicroseconds));
        if (upload == FakeUpload.malformed) ws.add(malformedMessages[malformed++ % malformedMessages.length]);
      }
    } catch (_) {
      // The client went away.
    } finally {
      await subscription.cancel();
    }
  }
}

// -------------------------------------------------------------------------------------------------
// No-network guard
// -------------------------------------------------------------------------------------------------

bool isLoopbackHost(Object host) {
  if (host is InternetAddress) return host.isLoopback;
  final text = '$host';
  if (text == 'localhost') return true;
  return InternetAddress.tryParse(text)?.isLoopback ?? false;
}

/// Refuses every socket and HTTP connection to a non-loopback host, and records the attempt.
class NoNetworkGuard {
  NoNetworkGuard._();

  /// Attempts since the last [blocked] clear, and over the whole run.
  static final List<String> blocked = [];
  static final List<String> everBlocked = [];
  static IOOverrides? _previousIo;
  static HttpOverrides? _previousHttp;

  static void install() {
    _previousIo = IOOverrides.current;
    _previousHttp = HttpOverrides.current;
    IOOverrides.global = _GuardIo();
    HttpOverrides.global = _GuardHttp();
  }

  static void uninstall() {
    IOOverrides.global = _previousIo;
    HttpOverrides.global = _previousHttp;
  }

  static SocketException _refuse(Object host) {
    blocked.add('$host');
    everBlocked.add('$host');
    return SocketException('No-network guard: $host is not a loopback host');
  }
}

final class _GuardIo extends IOOverrides {
  @override
  Future<Socket> socketConnect(host, int port, {sourceAddress, int sourcePort = 0, Duration? timeout}) {
    if (!isLoopbackHost(host)) return Future.error(NoNetworkGuard._refuse(host));
    return super.socketConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort, timeout: timeout);
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(host, int port, {sourceAddress, int sourcePort = 0}) {
    if (!isLoopbackHost(host)) return Future.error(NoNetworkGuard._refuse(host));
    return super.socketStartConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

class _GuardHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..connectionFactory = (uri, proxyHost, proxyPort) {
      final host = proxyHost ?? uri.host;
      if (!isLoopbackHost(host)) return Future.error(NoNetworkGuard._refuse(host));
      // Loopback fakes are plain HTTP.
      return Socket.startConnect(host, proxyPort ?? uri.port);
    };
}
