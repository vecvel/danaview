// OWNER: ST-02
//
// The M-Lab NDT7 fallback provider (V2-401, D-ST1; protocol notes V2-V19). The locate API
// (`mlab_locate.dart`) finds the nearest server, then the download and upload tests run over one
// WebSocket each (`dart:io`, subprotocol `net.measurementlab.ndt.v7`, no compression) and read the
// server's JSON measurement messages. NDT7 measures a single TCP stream, so its numbers are labelled
// "open network" by the coordinator (D-ST4). No third-party dependency.
//
// M-Lab publishes every result, including the client IP, as open data (D-ST2), so this provider runs
// only with an [OpenNetworkConsent] ticket (ARCH rule 28, V2-402): without one every phase throws
// [OpenNetworkConsentRequired] before any socket opens.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../speed_test.dart' show NetworkCancelToken, SpeedTestConfig, SpeedTestErrorKind, SpeedTestException, SpeedTestPhase;
import 'mlab_locate.dart';
import 'phase_result.dart';
import 'speed_test_provider.dart';

export 'mlab_locate.dart' show MLabLocateClient, MLabLocateException, MLabLocateErrorKind, MLabServer;

// -------------------------------------------------------------------------------------------------
// Consent ticket (ARCH rule 28)
// -------------------------------------------------------------------------------------------------

/// The user agreed to run the speed test on the open measurement network (D-ST2 prompt: "Run on
/// open network"). The `accepted` factory may be called only in
/// `packages/danaview_features/lib/src/tools/speed_consent_sheet.dart` (ARCH rule 28, V2-23; the
/// architecture test is ST-04's), so every ticket traces back to that prompt.
final class OpenNetworkConsent {
  const OpenNetworkConsent._(this.acceptedAt);

  /// The user chose "Run on open network" at [at] (or that remembered answer is being restored).
  factory OpenNetworkConsent.accepted(DateTime at) => OpenNetworkConsent._(at);

  final DateTime acceptedAt;

  @override
  String toString() => 'OpenNetworkConsent(${acceptedAt.toIso8601String()})';
}

/// A phase was asked to run without an [OpenNetworkConsent] ticket. Nothing was sent. This is a
/// precondition, not a provider fault, so it is not a [SpeedProviderFailure] and must never count
/// toward the coordinator's skip memory.
class OpenNetworkConsentRequired implements Exception {
  const OpenNetworkConsentRequired(this.phase);

  final SpeedTestPhase phase;

  @override
  String toString() => 'OpenNetworkConsentRequired(${phase.name}): the open-network test needs the user\'s consent';
}

// -------------------------------------------------------------------------------------------------
// Measurement messages
// -------------------------------------------------------------------------------------------------

/// One NDT7 measurement message (a JSON text frame). Every field is optional in the protocol; an
/// unknown or mistyped field reads as null.
class Ndt7Measurement {
  const Ndt7Measurement({
    this.origin,
    this.test,
    this.appNumBytes,
    this.appElapsedMicros,
    this.tcpBytesAcked,
    this.tcpBytesReceived,
    this.tcpElapsedMicros,
    this.minRttMicros,
    this.rttMicros,
  });

  /// `server` or `client`.
  final String? origin;

  /// `download` or `upload`.
  final String? test;

  /// `AppInfo.NumBytes` and `AppInfo.ElapsedTime` (µs).
  final int? appNumBytes;
  final int? appElapsedMicros;

  /// `TCPInfo.BytesAcked`, `TCPInfo.BytesReceived`, `TCPInfo.ElapsedTime` (µs).
  final int? tcpBytesAcked;
  final int? tcpBytesReceived;
  final int? tcpElapsedMicros;

  /// `TCPInfo.MinRTT` and `TCPInfo.RTT` (µs).
  final int? minRttMicros;
  final int? rttMicros;

  /// Measurement messages are small; anything bigger is not one.
  static const int maxLength = 64 * 1024;

  /// Null when [text] is not a JSON object with an `AppInfo` or `TCPInfo` object.
  static Ndt7Measurement? tryParse(String text) {
    if (text.length > maxLength) return null;
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final app = json['AppInfo'];
    final tcp = json['TCPInfo'];
    if (app is! Map<String, Object?> && tcp is! Map<String, Object?>) return null;
    int? number(Object? map, String key) {
      if (map is! Map<String, Object?>) return null;
      final value = map[key];
      if (value is! num || !value.isFinite || value < 0) return null;
      return value.toInt();
    }

    String? string(Object? value) => value is String ? value : null;
    return Ndt7Measurement(
      origin: string(json['Origin']),
      test: string(json['Test']),
      appNumBytes: number(app, 'NumBytes'),
      appElapsedMicros: number(app, 'ElapsedTime'),
      tcpBytesAcked: number(tcp, 'BytesAcked'),
      tcpBytesReceived: number(tcp, 'BytesReceived'),
      tcpElapsedMicros: number(tcp, 'ElapsedTime'),
      minRttMicros: number(tcp, 'MinRTT'),
      rttMicros: number(tcp, 'RTT'),
    );
  }

  /// Bytes the server says it has received (upload): `TCPInfo.BytesReceived`, else `AppInfo.NumBytes`.
  ({int bytes, int micros})? get serverReceived {
    if (tcpBytesReceived case final bytes? when (tcpElapsedMicros ?? 0) > 0) return (bytes: bytes, micros: tcpElapsedMicros!);
    if (appNumBytes case final bytes? when (appElapsedMicros ?? 0) > 0) return (bytes: bytes, micros: appElapsedMicros!);
    return null;
  }
}

// -------------------------------------------------------------------------------------------------
// Provider
// -------------------------------------------------------------------------------------------------

/// Measures against the nearest M-Lab NDT7 server, only with the user's consent (D-ST1, D-ST2).
///
/// * **latency**: the locate request (the health check: it must answer within [healthTimeout] when
///   `health` is set), then one warm-up and [SpeedTestConfig.latencySamples] TCP connects to the
///   server's port. A TCP connect is one round trip and moves no test data.
/// * **download / upload**: one NDT7 WebSocket each, time-boxed by
///   [SpeedTestConfig.downloadDuration] / [SpeedTestConfig.uploadDuration] and capped by
///   [SpeedTestConfig.maxDownloadBytes] / [SpeedTestConfig.maxUploadBytes], like the default
///   provider. Download speed is the bytes received over the elapsed time; upload speed is what the
///   server's measurements say it received (`TCPInfo.BytesReceived / TCPInfo.ElapsedTime`).
class MLabNdt7Provider implements SpeedTestProvider {
  MLabNdt7Provider({
    required OpenNetworkConsent? Function() consent,
    MLabLocateClient? locate,
    HttpClient Function()? clientFactory,
    this.config = const SpeedTestConfig(),
    this.healthTimeout = defaultHealthTimeout,
    this.locateMaxAge = defaultLocateMaxAge,
    DateTime Function()? now,
  })  : _consent = consent,
        locate = locate ?? MLabLocateClient(clientFactory: clientFactory),
        _clientFactory = clientFactory ?? HttpClient.new,
        _now = now ?? DateTime.now;

  static const String subprotocol = 'net.measurementlab.ndt.v7';

  /// D-ST3, as for the default provider.
  static const Duration defaultHealthTimeout = Duration(milliseconds: 1500);

  /// Locate access tokens are short-lived; an older answer is fetched again.
  static const Duration defaultLocateMaxAge = Duration(seconds: 60);

  /// The NDT7 spec's upload message sizes: start at 8 KiB, grow while a message is under 1/16 of
  /// what was sent so far, never above 16 MiB (and never above [SpeedTestConfig.maxUploadRequestBytes]).
  static const int initialUploadMessageBytes = 1 << 13;
  static const int maxUploadMessageBytes = 1 << 24;

  /// Upload bytes handed to the socket but not yet reported received by the server are kept under
  /// this, or half a second at the measured rate when that is more.
  static const int minUploadWindowBytes = 4 * 1024 * 1024;

  final OpenNetworkConsent? Function() _consent;
  final MLabLocateClient locate;
  final SpeedTestConfig config;
  final Duration healthTimeout;
  final Duration locateMaxAge;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _now;

  _Located? _located;
  Uint8List? _payload;

  @override
  String get id => 'mlab';

  // -----------------------------------------------------------------------------------------------
  // Phases
  // -----------------------------------------------------------------------------------------------

  @override
  Future<SpeedLatencyResult> latency({
    required NetworkCancelToken cancel,
    bool health = false,
    SpeedProgressCallback? onProgress,
  }) =>
      _guard(SpeedTestPhase.latency, cancel, () async {
        final timeout = health && healthTimeout < config.requestTimeout ? healthTimeout : config.requestTimeout;
        final server = await _server(cancel, timeout: timeout);
        final url = server.downloadUrl;
        final samples = <double>[];
        double? latencyMs;
        double? jitterMs;
        Object? address;
        for (var i = 0; i <= config.latencySamples; i++) {
          _checkCancelled(cancel);
          final watch = Stopwatch()..start();
          final socket = await _connectOnce(address ?? url.host, url.port, cancel);
          watch.stop();
          address ??= socket.remoteAddress;
          socket.destroy();
          _checkCancelled(cancel);
          // The first connect also pays for the DNS lookup.
          if (i == 0) continue;
          samples.add(watch.elapsedMicroseconds / 1000);
          latencyMs = _percentile(samples, 0.5);
          jitterMs = _jitter(samples);
          onProgress?.call(SpeedPhaseProgress(
            phaseProgress: i / config.latencySamples,
            latencyMs: latencyMs,
            jitterMs: jitterMs,
            city: server.city,
          ));
        }
        return SpeedLatencyResult(
          providerId: id,
          latencyMs: latencyMs ?? 0,
          jitterMs: jitterMs ?? 0,
          samples: samples.length,
          city: server.city,
        );
      });

  @override
  Future<SpeedTransferResult> download({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _guard(SpeedTestPhase.download, cancel, () async {
        final server = await _server(cancel, timeout: config.requestTimeout, take: SpeedTestPhase.download);
        final socket = await _open(server.downloadUrl, cancel);
        return _runDownload(socket, cancel, onProgress);
      });

  @override
  Future<SpeedTransferResult> upload({required NetworkCancelToken cancel, SpeedProgressCallback? onProgress}) =>
      _guard(SpeedTestPhase.upload, cancel, () async {
        final server = await _server(cancel, timeout: config.requestTimeout, take: SpeedTestPhase.upload);
        final socket = await _open(server.uploadUrl, cancel);
        return _runUpload(socket, cancel, onProgress);
      });

  // -----------------------------------------------------------------------------------------------
  // Consent, locate, connect
  // -----------------------------------------------------------------------------------------------

  /// Checks the ticket, then turns every error into [SpeedTestCancelled] or a [SpeedProviderFailure].
  Future<T> _guard<T>(SpeedTestPhase phase, NetworkCancelToken cancel, Future<T> Function() body) async {
    if (_consent() == null) throw OpenNetworkConsentRequired(phase);
    if (cancel.isCancelled) throw const SpeedTestCancelled();
    try {
      return await body();
    } catch (error) {
      if (cancel.isCancelled || error is _Cancelled || error is MLabLocateCancelled || error is SpeedTestCancelled) {
        throw const SpeedTestCancelled();
      }
      throw _failure(error, phase);
    }
  }

  /// The located server, fetched again when there is none, it is older than [locateMaxAge], or the
  /// URL that [take] needs was already used (each access token is good for one test).
  Future<MLabServer> _server(NetworkCancelToken cancel, {required Duration timeout, SpeedTestPhase? take}) async {
    var located = _located;
    final stale = located == null ||
        _now().difference(located.at) > locateMaxAge ||
        (take == SpeedTestPhase.download && located.downloadUsed) ||
        (take == SpeedTestPhase.upload && located.uploadUsed);
    if (stale) {
      final server = await locate.nearest(timeout: timeout, cancel: cancel);
      located = _located = _Located(server, _now());
    }
    if (take == SpeedTestPhase.download) located.downloadUsed = true;
    if (take == SpeedTestPhase.upload) located.uploadUsed = true;
    return located.server;
  }

  Future<Socket> _connectOnce(Object host, int port, NetworkCancelToken cancel) async {
    final task = await Socket.startConnect(host, port);
    final cancelled = cancel.whenCancelled.then((_) => task.cancel());
    try {
      return await task.socket.timeout(config.requestTimeout, onTimeout: () {
        task.cancel();
        throw TimeoutException('No answer', config.requestTimeout);
      });
    } finally {
      unawaited(cancelled);
    }
  }

  /// Opens the NDT7 WebSocket. The server must select [subprotocol].
  Future<WebSocket> _open(Uri url, NetworkCancelToken cancel) async {
    _checkCancelled(cancel);
    final client = _clientFactory()
      ..connectionTimeout = config.requestTimeout
      ..userAgent = '${locate.clientName}/${locate.clientVersion}';
    final cancelled = cancel.whenCancelled.then((_) => client.close(force: true));
    final target = url.replace(queryParameters: {
      ...url.queryParameters,
      'client_name': locate.clientName,
      'client_version': locate.clientVersion,
    });
    try {
      final socket = await WebSocket.connect(
        target.toString(),
        protocols: const [subprotocol],
        // Byte counts must match what crossed the wire, and NDT7 forbids compression.
        compression: CompressionOptions.compressionOff,
        customClient: client,
      ).timeout(config.requestTimeout);
      if (cancel.isCancelled) {
        unawaited(socket.close(WebSocketStatus.goingAway).catchError((Object _) {}));
        throw const _Cancelled();
      }
      if (socket.protocol != subprotocol) {
        unawaited(socket.close(WebSocketStatus.protocolError).catchError((Object _) {}));
        throw const _Unexpected('The server did not select the NDT7 subprotocol');
      }
      return socket;
    } finally {
      // The upgraded socket is detached from the client, so this only drops a pending connect.
      client.close(force: true);
      unawaited(cancelled);
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Download
  // -----------------------------------------------------------------------------------------------

  Future<SpeedTransferResult> _runDownload(WebSocket socket, NetworkCancelToken cancel, SpeedProgressCallback? onProgress) {
    final session = _Session(socket, cancel, config, upload: false);
    final subscription = socket.listen(
      (Object? message) {
        if (session.stopped) return;
        if (message is String) {
          session.count(message.length);
          final measurement = Ndt7Measurement.tryParse(message);
          if (measurement != null) session.lastMeasurement = measurement;
        } else if (message is List<int>) {
          session.count(message.length);
        }
        if (session.transferred >= config.maxDownloadBytes) session.finish();
      },
      onError: session.connectionError,
      onDone: session.connectionDone,
      cancelOnError: true,
    );
    return session.run(
      onProgress: onProgress,
      cap: config.maxDownloadBytes,
      duration: config.downloadDuration,
      cleanUp: subscription.cancel,
      result: (bytes, elapsed) => SpeedTransferResult(
        providerId: id,
        phase: SpeedTestPhase.download,
        mbps: _mbps(bytes, elapsed.inMicroseconds),
        bytes: bytes,
        duration: elapsed,
      ),
    );
  }

  // -----------------------------------------------------------------------------------------------
  // Upload
  // -----------------------------------------------------------------------------------------------

  Future<SpeedTransferResult> _runUpload(WebSocket socket, NetworkCancelToken cancel, SpeedProgressCallback? onProgress) {
    final session = _Session(socket, cancel, config, upload: true);
    final cap = config.maxUploadBytes;
    final maxMessage = math.min(maxUploadMessageBytes, math.max(initialUploadMessageBytes, config.maxUploadRequestBytes));
    var received = 0;
    var wake = Completer<void>();

    void signal() {
      if (!wake.isCompleted) wake.complete();
    }

    final subscription = socket.listen(
      (Object? message) {
        if (message is! String) return;
        final measurement = Ndt7Measurement.tryParse(message);
        final report = measurement?.serverReceived;
        if (measurement == null || report == null) return;
        session.lastMeasurement = measurement;
        if (report.bytes > received) {
          received = report.bytes;
          session.acknowledge(received);
        }
        signal();
      },
      onError: (Object error) {
        session.connectionError(error);
        signal();
      },
      onDone: () {
        session.connectionDone();
        signal();
      },
      cancelOnError: true,
    );

    Future<void> send() async {
      var size = initialUploadMessageBytes;
      final clock = Stopwatch()..start();
      while (!session.stopped) {
        final rate = clock.elapsedMicroseconds <= 0 ? 0.0 : received / clock.elapsedMicroseconds * 1e6;
        final window = math.max(math.max(minUploadWindowBytes, 2 * size), (rate * 0.5).round());
        if (session.transferred - received >= window) {
          // Wait for the server to catch up; a server that never does is a stall.
          session.blocked = true;
          wake = Completer<void>();
          await Future.any([wake.future, Future<void>.delayed(const Duration(milliseconds: 20))]);
          continue;
        }
        session.blocked = false;
        final n = math.min(size, cap - session.transferred);
        if (n <= 0) {
          session.finish();
          return;
        }
        try {
          socket.add(Uint8List.sublistView(_uploadPayload(maxMessage), 0, n));
        } catch (error) {
          if (!session.stopped) session.connectionError(error);
          return;
        }
        session.count(n);
        if (size < maxMessage && size < session.transferred / 16) size = math.min(size * 2, maxMessage);
        // Lets the socket write and measurement messages arrive between messages.
        await Future<void>.delayed(Duration.zero);
      }
    }

    unawaited(send());
    return session.run(
      onProgress: onProgress,
      cap: cap,
      duration: config.uploadDuration,
      cleanUp: subscription.cancel,
      result: (bytes, elapsed) {
        final report = session.lastMeasurement?.serverReceived;
        return SpeedTransferResult(
          providerId: id,
          phase: SpeedTestPhase.upload,
          mbps: report != null ? _mbps(report.bytes, report.micros) : _mbps(bytes, elapsed.inMicroseconds),
          bytes: bytes,
          duration: elapsed,
        );
      },
    );
  }

  // -----------------------------------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------------------------------

  SpeedProviderFailure _failure(Object error, SpeedTestPhase phase) {
    SpeedProviderFailure failure(SpeedFailureKind kind, Object cause, {int? status}) =>
        SpeedProviderFailure(kind: kind, phase: phase, providerId: id, cause: cause, status: status);
    final unexpected = const SpeedTestException(
      SpeedTestErrorKind.server,
      'The test server returned an unexpected answer. Try again later.',
    );
    switch (error) {
      case SpeedProviderFailure():
        return error;
      case MLabLocateException(kind: MLabLocateErrorKind.status, :final status?):
      case WebSocketException(httpStatusCode: final status?):
        return failure(SpeedProviderFailure.kindForStatus(status), SpeedTestException.status(status), status: status);
      case MLabLocateException():
      case WebSocketException():
      case _Unexpected():
        return failure(SpeedFailureKind.serverError, unexpected);
      case _Interrupted(:final cause):
        return failure(SpeedFailureKind.interrupted, cause);
    }
    // The v1.0 wording decides what kind of failure it was, so both always agree.
    final kind = switch (SpeedTestException.from(error, phase: phase).kind) {
      SpeedTestErrorKind.offline || SpeedTestErrorKind.secureConnection => SpeedFailureKind.unreachable,
      SpeedTestErrorKind.timeout => SpeedFailureKind.stalled,
      SpeedTestErrorKind.server => SpeedFailureKind.serverError,
      SpeedTestErrorKind.interrupted => SpeedFailureKind.interrupted,
    };
    return failure(kind, error);
  }

  void _checkCancelled(NetworkCancelToken cancel) {
    if (cancel.isCancelled) throw const _Cancelled();
  }

  /// Random, so nothing on the way can compress it; built once at the largest message size.
  Uint8List _uploadPayload(int size) {
    final existing = _payload;
    if (existing != null && existing.length >= size) return existing;
    final random = math.Random();
    final words = Uint32List((size + 3) ~/ 4);
    for (var i = 0; i < words.length; i++) {
      words[i] = random.nextInt(0xFFFFFFFF);
    }
    return _payload = words.buffer.asUint8List(0, size);
  }
}

class _Located {
  _Located(this.server, this.at);

  final MLabServer server;
  final DateTime at;
  bool downloadUsed = false;
  bool uploadUsed = false;
}

/// One running NDT7 transfer: the time box, the cap, stall detection, progress, cancel and how the
/// connection ended.
class _Session {
  _Session(this.socket, this.cancel, this.config, {required this.upload});

  final WebSocket socket;
  final NetworkCancelToken cancel;
  final SpeedTestConfig config;
  final bool upload;

  final Stopwatch clock = Stopwatch()..start();
  final Completer<void> _done = Completer<void>();

  /// Bytes received (download) or handed to the socket (upload).
  int transferred = 0;

  /// Upload: what the server reports received. Progress and stalls are judged on it.
  int acknowledged = 0;

  /// Upload: the sender is waiting for the server to catch up.
  bool blocked = false;
  Ndt7Measurement? lastMeasurement;

  bool stopped = false;
  Object? _failure;
  int _lastProgressMicros = 0;

  final List<({int micros, int bytes})> _samples = [(micros: 0, bytes: 0)];

  void count(int bytes) {
    transferred += bytes;
    if (!upload) _progressed();
  }

  void acknowledge(int bytes) {
    acknowledged = bytes;
    _progressed();
  }

  void _progressed() => _lastProgressMicros = clock.elapsedMicroseconds;

  /// The client ends the test: time box or cap reached.
  void finish() => _stop();

  void fail(Object error) => _stop(error: error);

  void connectionError(Object error) => _stop(error: _Interrupted(error));

  /// The server closed the connection.
  void connectionDone() {
    if (stopped) return;
    // A normal close after real data is the server ending the test (NDT7 servers stop after about
    // ten seconds); anything else is the connection dropping.
    final normal = socket.closeCode == WebSocketStatus.normalClosure;
    final measured = upload ? acknowledged : transferred;
    final warmUp = math.min(config.warmUp.inMicroseconds, (upload ? config.uploadDuration : config.downloadDuration).inMicroseconds ~/ 4);
    if (normal && measured > 0 && clock.elapsedMicroseconds >= warmUp) {
      _stop();
    } else {
      _stop(error: const _Interrupted(_EarlyClose()));
    }
  }

  void _stop({Object? error}) {
    if (stopped) return;
    stopped = true;
    clock.stop();
    _failure = error;
    if (socket.readyState == WebSocket.open) {
      unawaited(socket.close(error == null ? WebSocketStatus.normalClosure : WebSocketStatus.goingAway).catchError((Object _) {}));
    }
    if (!_done.isCompleted) _done.complete();
  }

  Future<SpeedTransferResult> run({
    required SpeedProgressCallback? onProgress,
    required int cap,
    required Duration duration,
    required Future<void> Function() cleanUp,
    required SpeedTransferResult Function(int bytes, Duration elapsed) result,
  }) async {
    final cancelled = cancel.whenCancelled.then((_) => _stop(error: const _Cancelled()));
    void sample() {
      if (stopped) return;
      final now = clock.elapsedMicroseconds;
      _samples.add((micros: now, bytes: upload && lastMeasurement != null ? acknowledged : transferred));
      onProgress?.call(SpeedPhaseProgress(
        phaseProgress: math.min(1.0, math.max(now / duration.inMicroseconds, transferred / cap)),
        currentMbps: _recentMbps(_samples),
        bytes: transferred,
      ));
      if (now >= duration.inMicroseconds) {
        // Nothing moved after the warm-up: the link stalled, and a 0 Mbps reading would be wrong.
        final warmUp = math.min(config.warmUp.inMicroseconds, now ~/ 4);
        final measured = upload ? acknowledged : transferred;
        if (measured == 0 || _lastProgressMicros <= warmUp) {
          fail(TimeoutException('No data moved', duration));
        } else {
          finish();
        }
      } else if ((!upload || blocked) && now - _lastProgressMicros >= config.stallTimeout.inMicroseconds) {
        fail(TimeoutException('No data moved', config.stallTimeout));
      }
    }

    final ticker = Timer.periodic(config.sampleInterval, (_) => sample());
    try {
      await _done.future;
    } finally {
      ticker.cancel();
      unawaited(cleanUp().catchError((Object _) {}));
      unawaited(cancelled);
    }
    if (cancel.isCancelled || _failure is _Cancelled) throw const _Cancelled();
    if (_failure != null) throw _failure!;
    return result(transferred, clock.elapsed);
  }

  /// Throughput over the last second (or less, early on).
  static double _recentMbps(List<({int micros, int bytes})> samples) {
    final last = samples.last;
    final from = last.micros - 1000000;
    var i = samples.length - 1;
    while (i > 0 && samples[i - 1].micros >= from) {
      i--;
    }
    if (i == samples.length - 1 && i > 0) i--;
    return _mbps(last.bytes - samples[i].bytes, last.micros - samples[i].micros);
  }
}

/// The server answered in a way NDT7 doesn't allow.
class _Unexpected implements Exception {
  const _Unexpected(this.message);

  final String message;

  @override
  String toString() => 'Unexpected NDT7 answer: $message';
}

/// A connection that was up and then broke mid-phase.
class _Interrupted implements Exception {
  const _Interrupted(this.cause);

  final Object cause;
}

/// The server closed the test before it had measured anything.
class _EarlyClose implements Exception {
  const _EarlyClose();

  @override
  String toString() => 'The test server closed the connection early';
}

class _Cancelled implements Exception {
  const _Cancelled();
}

double _mbps(int bytes, int micros) => micros <= 0 ? 0 : bytes * 8 / micros;

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
