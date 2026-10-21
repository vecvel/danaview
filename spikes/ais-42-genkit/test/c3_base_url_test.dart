// Criterion 3: OpenRouter and xAI through the OpenAI plugin, with the base URL
// fixed by us to the D-66 host.
import 'package:ais42_genkit_spike/ais42.dart';
import 'package:genkit/genkit.dart' as g;
import 'package:genkit_openai/genkit_openai.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late FakeProviderServer fake;
  setUp(() async => fake = await FakeProviderServer.start());
  tearDown(() => fake.close());

  test('OpenRouter: openAI(baseUrl: $kOpenRouterBaseUrl)', () async {
    final p = GenkitLlmProvider(AiProviderId.openrouter, loopback: fake.origin);
    final call = await p.prepare('openai/gpt-4.1-mini', textRequest());
    expect(call.requests.single.url.toString(),
        'https://openrouter.ai/api/v1/chat/completions');
    // No attribution headers (D-47).
    final h = p.lastClient!.seen.single.headers.keys.map((k) => k.toLowerCase());
    expect(h, isNot(contains('http-referer')));
    expect(h, isNot(contains('x-title')));
  });

  test('xAI: the xAI() handle of genkit_openai defaults to api.x.ai', () async {
    final p = GenkitLlmProvider(AiProviderId.xai, loopback: fake.origin);
    final call = await p.prepare('grok-4', textRequest());
    expect(call.requests.single.url.toString(),
        'https://api.x.ai/v1/chat/completions');
  });

  test('a different base URL is refused by the guard, not trusted', () async {
    final guard = GuardedClient.send(
      provider: AiProviderId.openrouter,
      key: ApiKey(kSecretKey),
      ticket: AiSendTicket({}),
      loopback: fake.origin,
    );
    final ai = g.Genkit(
      plugins: [
        openAI(
          name: 'openrouter',
          apiKey: kPlaceholderKey,
          baseUrl: 'https://proxy.example/api/v1',
          httpClient: guard,
        ),
      ],
      isDevEnv: false,
      promptDir: null,
    );
    final res = await ai.generate(
      model: openAI.model('m', namespace: 'openrouter'),
      prompt: 'x',
    );
    expect(res.finishReason.value, 'failed');
    expect(guard.refusals.single.reason, 'hostNotAllowed');
    expect(fake.hits, isEmpty);
    await ai.shutdown();
  });
}
