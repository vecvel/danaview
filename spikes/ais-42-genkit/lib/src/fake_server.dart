// AIS-42 spike: loopback fake of the five provider APIs (127.0.0.1 only).
// The guarded client rewrites https://<host>/<path> to
// http://127.0.0.1:<port>/<host>/<path>, so the first path segment names the
// provider host the SDK aimed at.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final class FakeHit {
  FakeHit(this.method, this.host, this.path, this.headers, this.body)
    : sha256Hex = sha256.convert(body).toString();
  final String method;
  final String host;
  final String path;
  final Map<String, String> headers;
  final Uint8List body;
  final String sha256Hex;
  Map<String, Object?> get json =>
      body.isEmpty ? {} : jsonDecode(utf8.decode(body)) as Map<String, Object?>;
}

final class FakeProviderServer {
  FakeProviderServer._(this._server);

  static Future<FakeProviderServer> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = FakeProviderServer._(s);
    s.listen(f._handle);
    return f;
  }

  final HttpServer _server;
  final List<FakeHit> hits = [];

  /// Statuses to answer before the normal reply (for retry checks).
  final List<int> failFirst = [];

  /// The JSON object every chat-style reply carries as its structured output.
  Map<String, Object?> replyObject = {'ok': true, 'label': 'fake'};

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = Uint8List.fromList(
      await req.fold<List<int>>([], (a, b) => a..addAll(b)),
    );
    final segs = req.uri.pathSegments;
    final host = segs.isEmpty ? '' : segs.first;
    final path = '/${segs.skip(1).join('/')}';
    final headers = <String, String>{};
    req.headers.forEach((k, v) => headers[k] = v.join(','));
    hits.add(FakeHit(req.method, host, path, headers, body));

    final res = req.response..headers.contentType = ContentType.json;
    if (failFirst.isNotEmpty) {
      res.statusCode = failFirst.removeAt(0);
      res.write(jsonEncode({
        'error': {'message': 'scripted failure', 'type': 'server_error'},
      }));
      await res.close();
      return;
    }
    final reply = _reply(host, path, req.method, body);
    if (reply == null) {
      res.statusCode = 404;
      res.write(jsonEncode({
        'error': {'message': 'no route $host$path'},
      }));
    } else {
      res.write(jsonEncode(reply));
    }
    await res.close();
  }

  Object? _reply(String host, String path, String method, Uint8List body) {
    final text = jsonEncode(replyObject);
    Map<String, Object?> req() => body.isEmpty
        ? {}
        : jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    // OpenAI-compatible: OpenAI, xAI, OpenRouter.
    if (path.endsWith('/chat/completions')) {
      return {
        'id': 'chatcmpl-fake',
        'object': 'chat.completion',
        'created': 1,
        'model': req()['model'],
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 11,
          'completion_tokens': 7,
          'total_tokens': 18,
        },
      };
    }
    if (path.endsWith('/embeddings')) {
      final input = req()['input'];
      final n = input is List ? input.length : 1;
      return {
        'object': 'list',
        'model': req()['model'],
        'data': [
          for (var i = 0; i < n; i++)
            {
              'object': 'embedding',
              'index': i,
              'embedding': [0.1, 0.2, 0.3],
            },
        ],
        'usage': {'prompt_tokens': 3, 'total_tokens': 3},
      };
    }
    if (path.endsWith('/models') && method == 'GET') {
      return {
        'object': 'list',
        'data': [
          {'id': 'fake-model', 'object': 'model', 'created': 1, 'owned_by': 'x'},
        ],
      };
    }
    // Anthropic.
    if (path == '/v1/messages') {
      return {
        'id': 'msg_fake',
        'type': 'message',
        'role': 'assistant',
        'model': req()['model'],
        'content': [
          {'type': 'text', 'text': text},
        ],
        'stop_reason': 'end_turn',
        'stop_sequence': null,
        'usage': {'input_tokens': 11, 'output_tokens': 7},
      };
    }
    // Gemini.
    if (path.endsWith(':generateContent')) {
      return {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': text},
              ],
            },
            'finishReason': 'STOP',
            'index': 0,
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 11,
          'candidatesTokenCount': 7,
          'totalTokenCount': 18,
        },
      };
    }
    if (path.endsWith(':embedContent')) {
      return {
        'embedding': {
          'values': [0.1, 0.2, 0.3],
        },
      };
    }
    if (path.endsWith(':batchEmbedContents')) {
      final reqs = (req()['requests'] as List?) ?? const [];
      return {
        'embeddings': [
          for (var i = 0; i < reqs.length; i++)
            {
              'values': [0.1, 0.2, 0.3],
            },
        ],
      };
    }
    return null;
  }
}
