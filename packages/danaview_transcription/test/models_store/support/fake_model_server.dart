// OWNER: AI-09
//
// A loopback HTTP server that behaves like huggingface.co + its CDN for the model downloader tests:
// `/resolve/<file>` answers 302 with `x-linked-size`, `x-linked-etag` and a `Location` to
// `/cdn/<file>`, which honours `Range` (206 / 416) and can be scripted to fail in every way the
// downloader has a path for. Nothing here touches the internet.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// One request the server saw.
final class RecordedRequest {
  RecordedRequest(this.method, this.path, this.headers);

  final String method;
  final String path;
  final Map<String, String> headers;

  String? get range => headers['range'];
  bool get isResolve => path.startsWith('/resolve/');
  bool get isCdn => path.startsWith('/cdn/');
  String get file => path.split('/').last;
}

/// How the CDN answers the next ranged request.
final class Cdn {
  const Cdn._(this.kind, [this.n = 0, this.text]);

  const Cdn.normal() : this._('normal');
  const Cdn.status(int code) : this._('status', code);
  const Cdn.dropAfter(int bytes) : this._('drop', bytes);
  const Cdn.stallAfter(int bytes) : this._('stall', bytes);
  const Cdn.ignoreRange() : this._('ignoreRange');
  const Cdn.badContentRange(String header) : this._('badRange', 0, header);
  const Cdn.extraBytes(int extra) : this._('extra', extra);

  final String kind;
  final int n;
  final String? text;
}

final class FakeModelServer {
  FakeModelServer._(this._server) : port = _server.port;

  final HttpServer _server;
  final Map<String, Uint8List> bodies = {};
  final Map<String, int> advertisedSize = {};
  final Map<String, String> advertisedEtag = {};
  final List<RecordedRequest> requests = [];

  /// Statuses for the next `/resolve/` requests (consumed in order); 302 when empty.
  final List<int> resolveStatuses = [];

  /// Behaviours for the next `/cdn/` requests (consumed in order); normal when empty.
  final List<Cdn> cdnScript = [];

  /// Headers to drop from the 302 (`x-linked-size`, `x-linked-etag`, `location`).
  final Set<String> omitResolveHeaders = {};

  /// Chunk size of the body writes.
  int chunkSize = 16 * 1024;

  final List<Completer<void>> _stalls = [];

  static Future<FakeModelServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeModelServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  final int port;

  Uri resolveUrl(String file) => Uri.parse('http://127.0.0.1:$port/resolve/$file');

  List<RecordedRequest> get resolves => requests.where((r) => r.isResolve).toList();
  List<RecordedRequest> get cdnRequests => requests.where((r) => r.isCdn).toList();

  /// Serves [data] under [spec]; the 302 advertises the spec's size and sha256.
  void serve(SpeechModelSpec spec, Uint8List data) {
    bodies[spec.fileName] = data;
    advertisedSize[spec.fileName] = spec.bytes;
    advertisedEtag[spec.fileName] = spec.sha256;
  }

  Future<void> close() async {
    for (final s in _stalls) {
      if (!s.isCompleted) s.complete();
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    requests.add(RecordedRequest(req.method, req.uri.path, headers));
    final res = req.response;
    try {
      if (req.uri.path.startsWith('/resolve/')) {
        await _resolve(req, res);
      } else if (req.uri.path.startsWith('/cdn/')) {
        await _cdn(req, res);
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } on Object {
      // The client hung up (cancel, timeout).
    }
  }

  Future<void> _resolve(HttpRequest req, HttpResponse res) async {
    final file = req.uri.pathSegments.last;
    if (resolveStatuses.isNotEmpty) {
      final status = resolveStatuses.removeAt(0);
      if (status != HttpStatus.found) {
        res.statusCode = status;
        await res.close();
        return;
      }
    }
    if (!bodies.containsKey(file)) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.statusCode = HttpStatus.found;
    if (!omitResolveHeaders.contains('x-linked-size')) res.headers.set('x-linked-size', '${advertisedSize[file]}');
    if (!omitResolveHeaders.contains('x-linked-etag')) res.headers.set('x-linked-etag', '"${advertisedEtag[file]}"');
    if (!omitResolveHeaders.contains('location')) res.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:$port/cdn/$file?Expires=1');
    await res.close();
  }

  Future<void> _cdn(HttpRequest req, HttpResponse res) async {
    final file = req.uri.pathSegments.last;
    final data = bodies[file];
    final step = cdnScript.isEmpty ? const Cdn.normal() : cdnScript.removeAt(0);
    if (data == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    if (step.kind == 'status') {
      res.statusCode = step.n;
      await res.close();
      return;
    }
    final range = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    if (range != null && step.kind != 'ignoreRange') {
      final m = RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      start = m == null ? 0 : int.parse(m.group(1)!);
      if (start >= data.length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${data.length}');
        await res.close();
        return;
      }
    }
    final partial = range != null && step.kind != 'ignoreRange';
    final body = Uint8List.sublistView(data, start);
    if (partial) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, step.kind == 'badRange' ? step.text! : 'bytes $start-${data.length - 1}/${data.length}');
    } else {
      res.statusCode = HttpStatus.ok;
    }
    final extra = step.kind == 'extra' ? step.n : 0;
    res.bufferOutput = false;
    res.contentLength = body.length + extra;
    var sent = 0;
    Future<void> sendUpTo(int limit) async {
      while (sent < limit) {
        final end = math.min(sent + chunkSize, limit);
        res.add(body.sublist(sent, end));
        sent = end;
        await res.flush();
      }
    }

    final cutAt = step.n;
    if (step.kind == 'drop' && cutAt < body.length) {
      await sendUpTo(cutAt);
      // Closing short of the promised Content-Length makes the server drop the connection, which
      // is what a reset mid-body looks like to the client.
      try {
        await res.close();
      } on HttpException {
        // Expected: content size below contentLength.
      }
      return;
    }
    if (step.kind == 'stall' && cutAt < body.length) {
      await sendUpTo(cutAt);
      await res.flush();
      final gate = Completer<void>();
      _stalls.add(gate);
      await gate.future;
      return;
    }
    await sendUpTo(body.length);
    if (extra > 0) res.add(Uint8List(extra));
    await res.close();
  }
}

/// A model file: ggml magic then deterministic pseudo-random bytes.
Uint8List modelBytes(int length, {int seed = 1, bool magic = true}) {
  final rnd = math.Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rnd.nextInt(256);
  }
  if (magic) out.setRange(0, 4, ggmlMagicBytes);
  return out;
}

/// A small spec whose bytes and hash match [data] (host `huggingface.co`, like the catalog).
SpeechModelSpec specFor(String id, Uint8List data, {SpeechModelTier tier = SpeechModelTier.fast}) => SpeechModelSpec(
      id: id,
      tier: tier,
      fileName: 'ggml-$id.bin',
      url: 'https://huggingface.co/test/whisper/resolve/rev/ggml-$id.bin',
      bytes: data.length,
      sha256: sha256.convert(data).toString(),
      minDeviceRamBytes: 0,
      peakMemoryBudgetBytes: 1,
    );

/// The consent a user would give for [spec] (+ [vad]) in a test catalog.
UserConsent consentFor(SpeechModelSpec spec, {SpeechModelSpec? vad, DateTime? at}) => UserConsent.accepted(
      ConsentDisclosure.forTesting(
        modelId: spec.id,
        fileName: spec.fileName,
        host: spec.host,
        cdnHost: SpeechModelCatalog.cdnHost,
        sha256: spec.sha256,
        totalBytes: spec.bytes + (vad?.bytes ?? 0),
        includesVad: vad != null,
      ),
      acceptedAt: at ?? DateTime.utc(2026, 10, 10),
    );
