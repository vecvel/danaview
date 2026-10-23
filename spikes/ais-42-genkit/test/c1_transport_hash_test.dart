// Criterion 1: our guarded client is injected and sees (and hashes) the exact
// bytes before sending; a changed byte is refused before any socket opens.
import 'package:ais42_genkit_spike/ais42.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late FakeProviderServer fake;
  setUp(() async => fake = await FakeProviderServer.start());
  tearDown(() => fake.close());

  for (final id in AiProviderId.values) {
    group('$id', () {
      test('prepare captures exactly one request without touching a socket',
          () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final call = await p.prepare(kModels[id]!, textRequest());
        expect(call.requests, hasLength(1));
        expect(call.requests.single.url.host, kProviderHosts[id]);
        expect(fake.hits, isEmpty);
      });

      test('capture is deterministic: two prepares give the same hash',
          () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final a = await p.prepare(kModels[id]!, textRequest());
        final b = await p.prepare(kModels[id]!, textRequest());
        expect(a.hashes, b.hashes);
      });

      test('the wire body hash equals the consented hash', () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final call = await p.prepare(kModels[id]!, textRequest());
        final ticket = AiSendTicket(call.hashes);
        final res = await p.send(
          ApiKey(kSecretKey),
          kModels[id]!,
          textRequest(),
          ticket,
        );
        expect(res.json, '{"ok":true,"label":"fake"}');
        expect(fake.hits, hasLength(1));
        expect(fake.hits.single.host, kProviderHosts[id]);
        expect(ticket.hashes, contains(fake.hits.single.sha256Hex));
        expect(fake.hits.single.sha256Hex, call.requests.single.sha256Hex);
      });

      test('a changed byte is refused before connecting', () async {
        final p = GenkitLlmProvider(id, loopback: fake.origin);
        final call = await p.prepare(kModels[id]!, textRequest());
        // One character of caption text differs from what was consented.
        final changed = textRequest(text: '${kCaption}x');
        final res = await p.send(
          ApiKey(kSecretKey),
          kModels[id]!,
          changed,
          AiSendTicket(call.hashes),
        ).then<Object>((r) => r, onError: (Object e) => e);
        expect(p.lastClient!.refusals.map((r) => r.reason), [
          'hashNotInTicket',
        ]);
        expect(p.lastClient!.sent, isEmpty);
        expect(fake.hits, isEmpty);
        // Genkit folds the refusal into a failed result rather than throwing.
        if (res is LlmResponse) expect(res.finish, 'failed');
      });
    });
  }

  group('guard', () {
    test('a host outside the allow-list is refused before connecting',
        () async {
      final c = GuardedClient.send(
        provider: AiProviderId.openai,
        key: ApiKey(kSecretKey),
        ticket: AiSendTicket({}),
        loopback: fake.origin,
      );
      await expectLater(
        c.send(http.Request('POST', Uri.parse('https://evil.example/v1/x'))),
        throwsA(isA<TransportRefused>()
            .having((e) => e.reason, 'reason', 'hostNotAllowed')),
      );
      // Another provider's host is also refused: keys go only to their own.
      await expectLater(
        c.send(http.Request('POST', Uri.parse('https://api.x.ai/v1/x'))),
        throwsA(isA<TransportRefused>()
            .having((e) => e.reason, 'reason', 'hostNotAllowed')),
      );
      expect(fake.hits, isEmpty);
    });

    test('http and ?key= URLs are refused', () async {
      final c = GuardedClient.send(
        provider: AiProviderId.gemini,
        key: ApiKey(kSecretKey),
        ticket: AiSendTicket({}),
      );
      await expectLater(
        c.send(http.Request(
            'POST', Uri.parse('http://generativelanguage.googleapis.com/x'))),
        throwsA(isA<TransportRefused>()
            .having((e) => e.reason, 'reason', 'notHttps')),
      );
      await expectLater(
        c.send(http.Request('POST',
            Uri.parse('https://generativelanguage.googleapis.com/x?key=abc'))),
        throwsA(isA<TransportRefused>()
            .having((e) => e.reason, 'reason', 'keyInUrl')),
      );
    });
  });

  group('Gemini injection (the criterion-1 finding)', () {
    test('the public googleAI() works only through a zone override', () async {
      final p = GenkitLlmProvider(
        AiProviderId.gemini,
        loopback: fake.origin,
        geminiInjection: GeminiInjection.zoneOverride,
      );
      final call = await p.prepare(kModels[AiProviderId.gemini]!, textRequest());
      expect(call.requests, hasLength(1));
      // The public path stamps an identifying client header and a key header
      // (our placeholder here) before our guard strips both.
      final seen = p.lastClient!.seen.single.headers;
      expect(seen.keys.map((k) => k.toLowerCase()),
          containsAll(['x-goog-api-client', 'x-goog-api-key']));
      expect(seen['X-Goog-Api-Client'], startsWith('genkit-dart/'));
      final res = await p.send(ApiKey(kSecretKey),
          kModels[AiProviderId.gemini]!, textRequest(), AiSendTicket(call.hashes));
      expect(res.json, contains('"ok":true'));
      expect(fake.hits.single.headers.keys, isNot(contains('x-goog-api-client')));
    });
  });
}
