// Criterion 2: user keys are passed per call, client side only; never handed
// to Genkit, never in env, URLs or logs.
import 'dart:convert';
import 'dart:io';

import 'package:ais42_genkit_spike/ais42.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support.dart';

const _keyHeader = {
  AiProviderId.gemini: 'x-goog-api-key',
  AiProviderId.anthropic: 'x-api-key',
  AiProviderId.openai: 'authorization',
  AiProviderId.openrouter: 'authorization',
  AiProviderId.xai: 'authorization',
};

void main() {
  late FakeProviderServer fake;
  final logs = <String>[];
  setUpAll(() {
    // Worst case: an app that turns on every logger.
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(
      (r) => logs.add('${r.loggerName} ${r.message} ${r.error ?? ''}'),
    );
  });
  setUp(() async => fake = await FakeProviderServer.start());
  tearDown(() => fake.close());

  for (final id in AiProviderId.values) {
    test('$id: the key reaches only its own header on the wire', () async {
      final p = GenkitLlmProvider(id, loopback: fake.origin);
      final call = await p.prepare(kModels[id]!, textRequest());
      // Genkit only ever saw the placeholder (or nothing, for injected Gemini).
      for (final s in p.lastClient!.seen) {
        expect(jsonEncode(s.headers), isNot(contains(kSecretKey)));
      }
      await p.send(ApiKey(kSecretKey), kModels[id]!, textRequest(),
          AiSendTicket(call.hashes));
      final hit = fake.hits.single;
      final header = hit.headers[_keyHeader[id]]!;
      expect(header, endsWith(kSecretKey));
      // Exactly one header carries it; never the URL, never the body.
      final carrying =
          hit.headers.entries.where((e) => e.value.contains(kSecretKey));
      expect(carrying.map((e) => e.key), [_keyHeader[id]]);
      expect(hit.path, isNot(contains(kSecretKey)));
      expect(utf8.decode(hit.body), isNot(contains(kSecretKey)));
      // The SDK placeholder and SDK tracing headers never leave the device.
      expect(jsonEncode(hit.headers), isNot(contains(kPlaceholderKey)));
      expect(hit.headers.keys, isNot(contains('x-request-id')));
      expect(hit.headers['user-agent'], 'Danaview/1.2.0-spike');
    });
  }

  test('no key, caption text or placeholder in any log record', () {
    expect(logs, isNotEmpty, reason: 'the SDKs do log at fine levels');
    for (final l in logs) {
      expect(l, isNot(contains(kSecretKey)));
      expect(l, isNot(contains(kCaption)));
      expect(l, isNot(contains(kPlaceholderKey)));
    }
  });

  test('no provider key env var is set for this run', () {
    for (final v in [
      'OPENAI_API_KEY',
      'ANTHROPIC_API_KEY',
      'XAI_API_KEY',
      'GEMINI_API_KEY',
      'GOOGLE_API_KEY',
    ]) {
      expect(Platform.environment[v], isNull, reason: v);
    }
  });

  test('ApiKey.toString is redacted', () {
    expect('${ApiKey(kSecretKey)}', isNot(contains('secret')));
    expect('${ApiKey(kSecretKey)}', endsWith('0042)'));
  });
}
