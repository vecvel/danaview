// AOT size probe, custom side: the same five chat calls and three embedding
// calls hand-written over dart:io HttpClient (the AIS-09/AIS-10 shape).
import 'dart:convert';
import 'dart:io';

import 'package:ais42_genkit_spike/src/contracts.dart';
import 'package:ais42_genkit_spike/src/guarded_client.dart' show kForwardedHeaders;

Future<Map<String, Object?>> _post(HttpClient c, Uri u, Map<String, String> h, Object body) async {
  final req = await c.postUrl(u)..followRedirects = false;
  h.forEach(req.headers.set);
  req.headers.contentType = ContentType.json;
  final bytes = utf8.encode(jsonEncode(body));
  req.add(bytes);
  final res = await req.close();
  final text = await utf8.decodeStream(res);
  return jsonDecode(text) as Map<String, Object?>;
}

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.first);
  final c = HttpClient();
  final schema = <String, Object?>{'type': 'object'};
  final k = ApiKey('k');
  Uri u(String host, String path) => base.replace(path: '/$host$path');
  for (final id in AiProviderId.values) {
    final host = kProviderHosts[id]!;
    final Map<String, Object?> out = switch (id) {
      AiProviderId.gemini => await _post(c, u(host, '/v1beta/models/m:generateContent'), {'x-goog-api-key': k.reveal()}, {
        'systemInstruction': {'parts': [{'text': 's'}]},
        'contents': [{'role': 'user', 'parts': [{'text': 't'}]}],
        'generationConfig': {'temperature': 0.2, 'maxOutputTokens': 512, 'responseMimeType': 'application/json', 'responseJsonSchema': schema},
      }),
      AiProviderId.anthropic => await _post(c, u(host, '/v1/messages'), {'x-api-key': k.reveal(), 'anthropic-version': '2023-06-01'}, {
        'model': 'm', 'max_tokens': 512, 'system': 's', 'temperature': 0.2,
        'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': 't'}]}],
        'tools': [{'name': 'out', 'input_schema': schema}], 'tool_choice': {'type': 'tool', 'name': 'out'},
      }),
      _ => await _post(c, u(host, id == AiProviderId.openrouter ? '/api/v1/chat/completions' : '/v1/chat/completions'), {'authorization': 'Bearer ${k.reveal()}'}, {
        'model': 'm', 'temperature': 0.2, 'max_completion_tokens': 512,
        'messages': [{'role': 'system', 'content': 's'}, {'role': 'user', 'content': 't'}],
        'response_format': {'type': 'json_schema', 'json_schema': {'name': 'out', 'strict': true, 'schema': schema}},
      }),
    };
    stdout.writeln(out.length + kForwardedHeaders.length);
  }
  for (final id in [AiProviderId.openai, AiProviderId.openrouter]) {
    stdout.writeln(await _post(c, u(kProviderHosts[id]!, '/v1/embeddings'), {'authorization': 'Bearer ${k.reveal()}'}, {'model': 'e', 'input': ['t']}));
  }
  stdout.writeln(await _post(c, u(kProviderHosts[AiProviderId.gemini]!, '/v1beta/models/e:embedContent'), {'x-goog-api-key': k.reveal()}, {'content': {'parts': [{'text': 't'}]}}));
  c.close();
}
