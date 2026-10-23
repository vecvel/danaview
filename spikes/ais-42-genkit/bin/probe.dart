// AIS-42 spike probe: prints what each Genkit plugin hands the guarded client.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ais42_genkit_spike/ais42.dart';

const models = {
  AiProviderId.gemini: 'gemini-2.5-flash',
  AiProviderId.openai: 'gpt-4.1-mini',
  AiProviderId.anthropic: 'claude-sonnet-4-5',
  AiProviderId.openrouter: 'openai/gpt-4.1-mini',
  AiProviderId.xai: 'grok-4',
};

final schema = <String, Object?>{
  'type': 'object',
  'properties': {
    'ok': {'type': 'boolean'},
    'label': {'type': 'string', 'maxLength': 40},
  },
  'required': ['ok', 'label'],
  'additionalProperties': false,
};

Future<void> main(List<String> args) async {
  final fake = await FakeProviderServer.start();
  final png = Uint8List.fromList(List.generate(64, (i) => i));
  final wav = Uint8List.fromList(List.generate(64, (i) => 255 - i));
  for (final id in AiProviderId.values) {
    final p = GenkitLlmProvider(id, loopback: fake.origin);
    for (final variant in ['text', 'image', 'audio']) {
      final req = LlmRequest(
        contractId: 'probe',
        system: 'You label captions.',
        parts: [
          const TextPart('hello'),
          if (variant == 'image') ImagePart(png),
          if (variant == 'audio') WavAudioPart(wav),
        ],
        schema: schema,
      );
      final a = await p.prepare(models[id]!, req);
      final b = await p.prepare(models[id]!, req);
      print('=== $id/$variant captured=${a.requests.length} '
          'deterministic=${a.hashes.length == 1 && a.hashes.containsAll(b.hashes)}');
      if (a.requests.isEmpty) {
        print('  no request; seen=${p.lastClient!.seen.length}');
        continue;
      }
      final r = a.requests.first;
      print('  ${r.method} ${r.url}');
      print('  sdk headers: ${p.lastClient!.seen.first.headers.keys.toList()}');
      final body = utf8.decode(r.bytes);
      print('  body: ${body.length > 900 ? body.substring(0, 900) : body}');
      try {
        final res = await p.send(ApiKey('sk-test-1234'), models[id]!, req, AiSendTicket(a.hashes));
        print('  send ok: ${res.json} in=${res.inputTokens} out=${res.outputTokens}');
        print('  wire headers: ${p.lastClient!.sent.last.headers}');
      } catch (e) {
        print('  send FAILED: $e');
      }
    }
  }
  await fake.close();
}
