// AIS-42 spike: the guarded HTTP client that stands in for AIS-08's
// HttpTransport. Genkit (and the vendor SDKs under its plugins) only ever see
// this client; every byte they want to send passes through [send] here.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'contracts.dart';

/// Thrown in capture mode once the request bytes are recorded: nothing is sent.
final class CaptureAbort implements Exception {
  @override
  String toString() => 'CaptureAbort';
}

/// What the SDK handed the client, before any header rewrite.
final class SeenRequest {
  SeenRequest(this.method, this.url, this.headers, this.bytes)
    : sha256Hex = sha256.convert(bytes).toString();
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Uint8List bytes;
  final String sha256Hex;
}

enum GuardMode { capture, send }

/// Header names the guard forwards from the SDK. Everything else is dropped;
/// the key header and User-Agent are set by the guard itself.
const Set<String> kForwardedHeaders = {
  'content-type',
  'accept',
  'anthropic-version',
  'anthropic-beta',
};

/// Placeholder key handed to Genkit plugins so they never read an env var.
/// The guard strips it and writes the real key at send time.
const String kPlaceholderKey = 'dv-placeholder-not-a-key';

final class GuardedClient extends http.BaseClient {
  GuardedClient.capture({required this.provider})
    : mode = GuardMode.capture,
      key = null,
      ticket = null,
      loopback = null,
      maxAttemptsPerHash = 0;

  GuardedClient.send({
    required this.provider,
    required ApiKey this.key,
    required AiSendTicket this.ticket,
    this.loopback,
    this.maxAttemptsPerHash = 3, // 1 + D-48's two retries
  }) : mode = GuardMode.send;

  final AiProviderId provider;
  final GuardMode mode;
  final ApiKey? key;
  final AiSendTicket? ticket;

  /// Debug/test only: reroute every allowed request to this loopback origin
  /// (D-66 `DANAVIEW_AI_FAKE_HOST`). The URL the SDK built is still checked
  /// against the real provider host first.
  final Uri? loopback;
  final int maxAttemptsPerHash;

  /// Every request the SDK handed us (captured or sent or refused).
  final List<SeenRequest> seen = [];

  /// Requests that actually went to a socket, after the rewrite.
  final List<SeenRequest> sent = [];

  /// Refusals, in order.
  final List<TransportRefused> refusals = [];

  final Map<String, int> _attempts = {};
  IOClient? _io;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final s = SeenRequest(
      request.method,
      request.url,
      Map.of(request.headers),
      bytes,
    );
    seen.add(s);

    _refuseUnless(request.url.scheme == 'https', 'notHttps', request.url);
    _refuseUnless(
      request.url.host == kProviderHosts[provider],
      'hostNotAllowed',
      request.url,
    );
    _refuseUnless(
      !request.url.queryParameters.containsKey('key'),
      'keyInUrl',
      request.url,
    );

    if (mode == GuardMode.capture) throw CaptureAbort();

    _refuseUnless(
      ticket!.hashes.contains(s.sha256Hex),
      'hashNotInTicket',
      request.url,
    );
    final n = (_attempts[s.sha256Hex] ?? 0) + 1;
    _attempts[s.sha256Hex] = n;
    _refuseUnless(n <= maxAttemptsPerHash, 'tooManyAttempts', request.url);

    final target = loopback == null
        ? request.url
        : request.url.replace(
            scheme: loopback!.scheme,
            host: loopback!.host,
            port: loopback!.port,
            path: '/${request.url.host}${request.url.path}',
          );
    final out = http.Request(request.method, target)
      ..followRedirects = false
      ..persistentConnection = true
      ..bodyBytes = bytes;
    request.headers.forEach((k, v) {
      if (kForwardedHeaders.contains(k.toLowerCase())) out.headers[k] = v;
    });
    out.headers['user-agent'] = 'Danaview/1.2.0-spike';
    out.headers.addAll(_keyHeader(provider, key!));
    sent.add(SeenRequest(out.method, target, Map.of(out.headers), bytes));

    _io ??= IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = null,
    );
    return _io!.send(out);
  }

  void _refuseUnless(bool ok, String reason, Uri url) {
    if (ok) return;
    final r = TransportRefused(reason, url);
    refusals.add(r);
    throw r;
  }

  @override
  void close() {
    _io?.close();
    _io = null;
  }
}

Map<String, String> _keyHeader(AiProviderId p, ApiKey k) => switch (p) {
  AiProviderId.gemini => {'x-goog-api-key': k.reveal()},
  AiProviderId.anthropic => {'x-api-key': k.reveal()},
  _ => {'authorization': 'Bearer ${k.reveal()}'},
};
