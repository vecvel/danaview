// OWNER: ST-02
//
// The M-Lab locate API v2 (V2-401, V2-V19): `GET locate.measurementlab.net/v2/nearest/ndt/ndt7`
// answers with the nearest NDT7 servers and, per server, short-lived access-token URLs for the
// download and upload tests. Only `dart:io` and `dart:convert`. Called only by [MLabNdt7Provider],
// which checks the open-network consent (ARCH rule 28) before anything here opens a socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../speed_test.dart' show NetworkCancelToken;

/// The keys of the locate response's `urls` map (NDT7 over TLS, and the plain variant).
const String _wssDownloadKey = 'wss:///ndt/v7/download';
const String _wssUploadKey = 'wss:///ndt/v7/upload';
const String _wsDownloadKey = 'ws:///ndt/v7/download';
const String _wsUploadKey = 'ws:///ndt/v7/upload';

/// One NDT7 server the locate API returned.
class MLabServer {
  const MLabServer({
    required this.machine,
    required this.downloadUrl,
    required this.uploadUrl,
    this.city,
    this.country,
  });

  /// The machine name, e.g. `mlab1-lga05.mlab-oti.measurement-lab.org`. Internal only (D-ST5).
  final String machine;

  /// Where the server says it is.
  final String? city;
  final String? country;

  /// `wss://…/ndt/v7/download?access_token=…` and the upload twin. Each token is good for one test.
  final Uri downloadUrl;
  final Uri uploadUrl;

  @override
  String toString() => 'MLabServer($machine, ${city ?? '?'})';
}

/// Why the locate request failed.
enum MLabLocateErrorKind {
  /// The locate API answered with an HTTP error ([MLabLocateException.status]).
  status,

  /// The answer was not the documented JSON, or named no usable server.
  malformed,
}

class MLabLocateException implements Exception {
  const MLabLocateException(this.kind, this.message, {this.status});

  final MLabLocateErrorKind kind;
  final String message;
  final int? status;

  @override
  String toString() => 'MLabLocateException(${kind.name}${status == null ? '' : ', HTTP $status'}): $message';
}

/// Finds the nearest NDT7 server.
class MLabLocateClient {
  MLabLocateClient({
    Uri? endpoint,
    HttpClient Function()? clientFactory,
    this.clientName = defaultClientName,
    this.clientVersion = defaultClientVersion,
    bool Function(Uri url)? acceptServerUrl,
  })  : endpoint = endpoint ?? defaultEndpoint,
        _clientFactory = clientFactory ?? HttpClient.new,
        acceptServerUrl = acceptServerUrl ?? isMLabServerUrl;

  static final Uri defaultEndpoint = Uri.parse('https://locate.measurementlab.net/v2/nearest/ndt/ndt7');

  /// M-Lab asks every client to identify itself (`client_name`, `client_version`).
  static const String defaultClientName = 'danaview';
  static const String defaultClientVersion = '1.2.0';

  final Uri endpoint;
  final String clientName;
  final String clientVersion;

  /// Which test URLs are trusted. By default only `wss://` on `*.measurement-lab.org` (ARCH §N-7),
  /// so a tampered answer can't point the test anywhere else.
  final bool Function(Uri url) acceptServerUrl;
  final HttpClient Function() _clientFactory;

  /// `wss://` on a `measurement-lab.org` host.
  static bool isMLabServerUrl(Uri url) =>
      url.isScheme('wss') && (url.host == 'measurement-lab.org' || url.host.endsWith('.measurement-lab.org'));

  /// The request URL, with the client identification M-Lab asks for.
  Uri get requestUrl => endpoint.replace(queryParameters: {
        ...endpoint.queryParameters,
        'client_name': clientName,
        'client_version': clientVersion,
      });

  /// The first usable server of the nearest list. Throws [MLabLocateException] for an HTTP error or
  /// a malformed answer, a [TimeoutException] when [timeout] passes, a [SocketException] (or
  /// [HandshakeException]) when the API can't be reached, and [MLabLocateCancelled] on [cancel].
  Future<MLabServer> nearest({required Duration timeout, required NetworkCancelToken cancel}) async {
    if (cancel.isCancelled) throw const MLabLocateCancelled();
    final client = _clientFactory()
      ..connectionTimeout = timeout
      ..userAgent = '$clientName/$clientVersion';
    final closeOnCancel = cancel.whenCancelled.then((_) => client.close(force: true));
    try {
      final body = await () async {
        final request = await client.getUrl(requestUrl);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          throw MLabLocateException(MLabLocateErrorKind.status, 'HTTP ${response.statusCode}', status: response.statusCode);
        }
        return text;
      }()
          .timeout(timeout);
      if (cancel.isCancelled) throw const MLabLocateCancelled();
      return parse(body, acceptServerUrl: acceptServerUrl).first;
    } catch (error) {
      if (cancel.isCancelled) throw const MLabLocateCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      unawaited(closeOnCancel);
    }
  }

  /// The usable servers of a locate answer, nearest first. Throws [MLabLocateException]
  /// ([MLabLocateErrorKind.malformed]) when the body isn't the documented shape or no server has
  /// both a download and an upload URL that [acceptServerUrl] trusts.
  static List<MLabServer> parse(String body, {bool Function(Uri url) acceptServerUrl = isMLabServerUrl}) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const MLabLocateException(MLabLocateErrorKind.malformed, 'The answer is not JSON');
    }
    final results = json is Map<String, Object?> ? json['results'] : null;
    if (results is! List) {
      throw const MLabLocateException(MLabLocateErrorKind.malformed, 'The answer has no results list');
    }
    final servers = <MLabServer>[];
    for (final entry in results) {
      if (entry is! Map<String, Object?>) continue;
      final urls = entry['urls'];
      if (urls is! Map<String, Object?>) continue;
      Uri? pick(String secure, String plain) {
        for (final key in [secure, plain]) {
          final value = urls[key];
          if (value is! String) continue;
          final url = Uri.tryParse(value);
          if (url != null && url.host.isNotEmpty && acceptServerUrl(url)) return url;
        }
        return null;
      }

      final download = pick(_wssDownloadKey, _wsDownloadKey);
      final upload = pick(_wssUploadKey, _wsUploadKey);
      if (download == null || upload == null) continue;
      final location = entry['location'];
      String? text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
      servers.add(MLabServer(
        machine: text(entry['machine']) ?? download.host,
        city: location is Map<String, Object?> ? text(location['city']) : null,
        country: location is Map<String, Object?> ? text(location['country']) : null,
        downloadUrl: download,
        uploadUrl: upload,
      ));
    }
    if (servers.isEmpty) {
      throw const MLabLocateException(MLabLocateErrorKind.malformed, 'The answer names no usable server');
    }
    return servers;
  }
}

/// The locate request stopped because its cancel token fired.
class MLabLocateCancelled implements Exception {
  const MLabLocateCancelled();
}
