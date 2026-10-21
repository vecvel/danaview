// Criterion 5: embeddings, multimodal input and schema-mode structured output,
// per provider, as the bytes Genkit hands our guard.
import 'package:ais42_genkit_spike/ais42.dart';
import 'package:test/test.dart';

import 'support.dart';

const _embedModels = {
  AiProviderId.gemini: 'gemini-embedding-001',
  AiProviderId.openai: 'text-embedding-3-small',
  AiProviderId.anthropic: 'none',
  AiProviderId.openrouter: 'openai/text-embedding-3-small',
  AiProviderId.xai: 'v1',
};

LlmRequest _with(LlmPart extra) => LlmRequest(
  contractId: 'dv.emotion.v1',
  system: 's',
  parts: [const TextPart(kCaption), extra],
  schema: kSchema,
);

List<Object?> _userParts(AiProviderId id, Map<String, Object?> body) =>
    switch (id) {
      AiProviderId.gemini =>
        ((body['contents'] as List).last as Map)['parts'] as List,
      _ => ((body['messages'] as List).last as Map)['content'] as List,
    };

void main() {
  late FakeProviderServer fake;
  setUp(() async => fake = await FakeProviderServer.start());
  tearDown(() => fake.close());

  group('structured output in schema mode', () {
    test('Gemini: responseMimeType json + responseJsonSchema', () async {
      final p = GenkitLlmProvider(AiProviderId.gemini, loopback: fake.origin);
      final b = bodyJson((await p.prepare('m', textRequest())).requests.single);
      final gc = b['generationConfig'] as Map;
      expect(gc['responseMimeType'], 'application/json');
      expect(gc['responseJsonSchema'], isA<Map>());
    });

    test('Anthropic: native output_config json_schema, but maxLength dropped',
        () async {
      final p = GenkitLlmProvider(AiProviderId.anthropic, loopback: fake.origin);
      final b = bodyJson((await p.prepare('m', textRequest())).requests.single);
      final f = (b['output_config'] as Map)['format'] as Map;
      expect(f['type'], 'json_schema');
      final label = ((f['schema'] as Map)['properties'] as Map)['label'] as Map;
      expect(label.containsKey('maxLength'), isFalse);
    });

    for (final id in [
      AiProviderId.openai,
      AiProviderId.openrouter,
      AiProviderId.xai,
    ]) {
      test('$id: json_schema is sent with strict hard-coded to false (FAIL)',
          () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final b =
            bodyJson((await p.prepare(kModels[id]!, textRequest())).requests.single);
        final rf = b['response_format'] as Map;
        expect(rf['type'], 'json_schema');
        // ARCH §7.3 wants a strict schema; genkit_openai 1.0.1 always sends
        // `strict: false` (chat.dart buildOpenAIResponseFormat) with no option.
        expect((rf['json_schema'] as Map)['strict'], isFalse);
      });
    }
  });

  group('image input', () {
    for (final id in AiProviderId.values) {
      test('$id: an image part is sent in the provider-native shape', () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final call = await p.prepare(kModels[id]!, _with(ImagePart(kPng)));
        final parts = _userParts(id, bodyJson(call.requests.single));
        final img = parts.last as Map;
        switch (id) {
          case AiProviderId.gemini:
            expect((img['inlineData'] as Map)['mimeType'], 'image/png');
          case AiProviderId.anthropic:
            expect(img['type'], 'image');
            expect((img['source'] as Map)['type'], 'base64');
          default:
            expect(img['type'], 'image_url');
        }
      });
    }
  });

  group('audio input (WAV clips, D-50)', () {
    test('Gemini: inlineData audio/wav', () async {
      final p = GenkitLlmProvider(AiProviderId.gemini, loopback: fake.origin);
      final call = await p.prepare('m', _with(WavAudioPart(kWav)));
      final part = _userParts(AiProviderId.gemini, bodyJson(call.requests.single))
          .last as Map;
      expect((part['inlineData'] as Map)['mimeType'], 'audio/wav');
    });

    for (final id in [
      AiProviderId.openai,
      AiProviderId.openrouter,
      AiProviderId.xai,
    ]) {
      test('$id: WAV goes out as a `file` part, not `input_audio` (FAIL)',
          () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final call = await p.prepare(kModels[id]!, _with(WavAudioPart(kWav)));
        final part = _userParts(id, bodyJson(call.requests.single)).last as Map;
        expect(part['type'], 'file');
        expect((part['file'] as Map)['filename'], 'document.wav');
        expect(part.containsKey('input_audio'), isFalse);
      });
    }

    test('Anthropic: no request at all (the provider has no audio input)',
        () async {
      final p = GenkitLlmProvider(AiProviderId.anthropic, loopback: fake.origin);
      final call = await p.prepare('m', _with(WavAudioPart(kWav)));
      expect(call.requests, isEmpty);
    });
  });

  group('embeddings', () {
    for (final id in AiProviderId.values) {
      test('$id: text and image embeddings', () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final text = await p.prepareEmbed(_embedModels[id]!, const [
          TextPart('embed me'),
        ]);
        final image = await p.prepareEmbed(_embedModels[id]!, [ImagePart(kPng)]);
        switch (id) {
          case AiProviderId.gemini:
            expect(text.requests.single.url.path, endsWith(':embedContent'));
            expect(image.requests.single.url.path, endsWith(':embedContent'));
            final v = await p.embed(ApiKey(kSecretKey), _embedModels[id]!,
                [ImagePart(kPng)], AiSendTicket(image.hashes));
            expect(v, [0.1, 0.2, 0.3]);
          case AiProviderId.openai || AiProviderId.openrouter:
            expect(text.requests.single.url.path, endsWith('/embeddings'));
            expect(image.requests, isEmpty, reason: 'text-only embedder');
            final v = await p.embed(ApiKey(kSecretKey), _embedModels[id]!,
                const [TextPart('embed me')], AiSendTicket(text.hashes));
            expect(v, [0.1, 0.2, 0.3]);
          case AiProviderId.anthropic || AiProviderId.xai:
            expect(text.requests, isEmpty, reason: 'no Genkit embedder');
            expect(image.requests, isEmpty);
        }
      });
    }
  });
}
