// AIS-42 spike: a Genkit-backed provider behind the spike's LlmProvider mirror.
//
// D-48 says `prepare` is pure and yields the body bytes before consent. Genkit
// builds the bytes inside `generate`, so prepare runs the same call through a
// capturing GuardedClient that records the bytes and aborts before any socket;
// `send` then reruns the call through a sending GuardedClient that refuses any
// body whose SHA-256 is not in the ticket.
import 'dart:convert';

import 'package:genkit/genkit.dart' as g;
import 'package:genkit_anthropic/genkit_anthropic.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
// The only way to inject an http.Client into the Gemini plugin: the public
// `googleAI()` takes an apiKey only. Both ignores are spike evidence (report §C1).
// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member
import 'package:genkit_google_genai/src/google_api_client.dart'
    show GoogleGenAiPluginImpl;
import 'package:genkit_openai/genkit_openai.dart';
import 'package:http/http.dart' as http;
import 'package:schemantic/schemantic.dart';

import 'contracts.dart';
import 'guarded_client.dart';

/// How the Gemini plugin gets our client.
enum GeminiInjection {
  /// `GoogleGenAiPluginImpl(httpClient:)` from `src/` (@visibleForTesting).
  testOnlyConstructor,

  /// Public `googleAI()` inside `http.runWithClient` (zone override).
  zoneOverride,
}

const String kOpenRouterBaseUrl = 'https://openrouter.ai/api/v1';

final class GenkitLlmProvider {
  GenkitLlmProvider(
    this.id, {
    this.loopback,
    this.geminiInjection = GeminiInjection.testOnlyConstructor,
  });

  final AiProviderId id;
  final Uri? loopback;
  final GeminiInjection geminiInjection;
  String get host => kProviderHosts[id]!;

  /// Clients used by the last operation (evidence for the tests).
  GuardedClient? lastClient;

  // ---------------------------------------------------------------- generate

  Future<PreparedCall> prepare(String modelId, LlmRequest r) async {
    final c = GuardedClient.capture(provider: id);
    lastClient = c;
    try {
      await _generate(c, modelId, r);
    } on Object catch (_) {
      // CaptureAbort (possibly wrapped by Genkit) is the expected outcome.
    }
    return PreparedCall([
      for (final s in c.seen)
        PreparedRequest(method: s.method, url: s.url, bytes: s.bytes),
    ]);
  }

  Future<LlmResponse> send(
    ApiKey key,
    String modelId,
    LlmRequest r,
    AiSendTicket ticket,
  ) async {
    final c = GuardedClient.send(
      provider: id,
      key: key,
      ticket: ticket,
      loopback: loopback,
    );
    lastClient = c;
    try {
      final res = await _generate(c, modelId, r);
      return LlmResponse(
        json: jsonEncode(res.output),
        inputTokens: res.usage?.inputTokens?.toInt(),
        outputTokens: res.usage?.outputTokens?.toInt(),
      );
    } finally {
      c.close();
    }
  }

  // --------------------------------------------------------------- embedding

  Future<PreparedCall> prepareEmbed(String modelId, List<LlmPart> doc) async {
    final c = GuardedClient.capture(provider: id);
    lastClient = c;
    try {
      await _embed(c, modelId, doc);
    } on Object catch (_) {}
    return PreparedCall([
      for (final s in c.seen)
        PreparedRequest(method: s.method, url: s.url, bytes: s.bytes),
    ]);
  }

  Future<List<double>> embed(
    ApiKey key,
    String modelId,
    List<LlmPart> doc,
    AiSendTicket ticket,
  ) async {
    final c = GuardedClient.send(
      provider: id,
      key: key,
      ticket: ticket,
      loopback: loopback,
    );
    lastClient = c;
    try {
      final e = await _embed(c, modelId, doc);
      return e.first.embedding;
    } finally {
      c.close();
    }
  }

  // ------------------------------------------------------------------ Genkit

  g.Genkit _genkit(http.Client c) =>
      g.Genkit(plugins: [_plugin(c)], isDevEnv: false, promptDir: null);

  g.GenkitPlugin _plugin(http.Client c) => switch (id) {
    AiProviderId.gemini => switch (geminiInjection) {
      GeminiInjection.testOnlyConstructor => GoogleGenAiPluginImpl(
        httpClient: c,
      ),
      // Placeholder key: the guard replaces the header the plugin sets.
      GeminiInjection.zoneOverride => googleAI(apiKey: kPlaceholderKey),
    },
    AiProviderId.openai => openAI(apiKey: kPlaceholderKey, httpClient: c),
    AiProviderId.openrouter => openAI(
      name: 'openrouter',
      apiKey: kPlaceholderKey,
      baseUrl: kOpenRouterBaseUrl,
      httpClient: c,
    ),
    AiProviderId.xai => xAI(apiKey: kPlaceholderKey, httpClient: c),
    AiProviderId.anthropic => anthropic(
      apiKey: kPlaceholderKey,
      httpClient: c,
    ),
  };

  Future<T> _zoned<T>(http.Client c, Future<T> Function() f) =>
      id == AiProviderId.gemini &&
          geminiInjection == GeminiInjection.zoneOverride
      ? http.runWithClient(f, () => c)
      : f();

  Future<g.GenerateResult<Map<String, Object?>>> _generate(
    http.Client c,
    String modelId,
    LlmRequest r,
  ) => _zoned(c, () async {
    final ai = _genkit(c);
    try {
      final parts = [for (final p in r.parts) _part(p)];
      final schema = SchemanticType.from<Map<String, Object?>>(
        jsonSchema: r.schema,
        parse: (j) => (j as Map).cast<String, Object?>(),
      );
      return await switch (id) {
        AiProviderId.gemini => ai.generate(
          model: googleAI.gemini(modelId),
          system: r.system,
          promptParts: parts,
          config: GeminiOptions(
            temperature: r.temperature,
            maxOutputTokens: r.maxOutputTokens,
          ),
          outputSchema: schema,
          outputConstrained: true,
        ),
        AiProviderId.anthropic => ai.generate(
          model: anthropic.model(modelId),
          system: r.system,
          promptParts: parts,
          config: AnthropicOptions(
            temperature: r.temperature,
            maxTokens: r.maxOutputTokens,
          ),
          outputSchema: schema,
          outputConstrained: true,
        ),
        AiProviderId.openai ||
        AiProviderId.openrouter ||
        AiProviderId.xai => ai.generate(
          model: switch (id) {
            AiProviderId.xai => xAI.model(modelId),
            AiProviderId.openrouter => openAI.model(
              modelId,
              namespace: 'openrouter',
            ),
            _ => openAI.model(modelId),
          },
          system: r.system,
          promptParts: parts,
          config: OpenAIChatOptions(
            temperature: r.temperature,
            maxTokens: r.maxOutputTokens,
          ),
          outputSchema: schema,
          outputConstrained: true,
        ),
      };
    } finally {
      await ai.shutdown();
    }
  });

  Future<List<g.Embedding>> _embed(
    http.Client c,
    String modelId,
    List<LlmPart> doc,
  ) => _zoned(c, () async {
    final ai = _genkit(c);
    try {
      final document = g.DocumentData(content: [for (final p in doc) _part(p)]);
      return await switch (id) {
        AiProviderId.gemini => ai.embed(
          embedder: googleAI.textEmbedding(modelId),
          document: document,
        ),
        AiProviderId.openai => ai.embed(
          embedder: openAI.embedder(modelId),
          document: document,
        ),
        AiProviderId.openrouter => ai.embed(
          embedder: openAI.embedder(modelId, namespace: 'openrouter'),
          document: document,
        ),
        AiProviderId.xai => ai.embed(
          embedder: openAI.embedder(modelId, namespace: defaultXaiNamespace),
          document: document,
        ),
        AiProviderId.anthropic => ai.embed(
          embedder: g.embedderRef('anthropic/$modelId'),
          document: document,
        ),
      };
    } finally {
      await ai.shutdown();
    }
  });

  static g.Part _part(LlmPart p) => switch (p) {
    TextPart(:final text) => g.TextPart(text: text),
    WavAudioPart(:final bytes) => g.MediaPart(
      media: g.Media(
        contentType: 'audio/wav',
        url: 'data:audio/wav;base64,${base64Encode(bytes)}',
      ),
    ),
    ImagePart(:final bytes, :final mimeType) => g.MediaPart(
      media: g.Media(
        contentType: mimeType,
        url: 'data:$mimeType;base64,${base64Encode(bytes)}',
      ),
    ),
  };
}
