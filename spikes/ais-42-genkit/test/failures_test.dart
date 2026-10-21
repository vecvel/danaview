// Transport control beyond the five criteria: retries and error typing
// (D-48 retries with identical bytes; typed AiFailure).
import 'package:ais42_genkit_spike/ais42.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late FakeProviderServer fake;
  setUp(() async => fake = await FakeProviderServer.start());
  tearDown(() => fake.close());

  test('the SDK retries 429 itself; the guard can only cap the attempts',
      () async {
    final p = GenkitLlmProvider(AiProviderId.openai, loopback: fake.origin);
    final call = await p.prepare('m', textRequest());
    fake.failFirst.addAll(List.filled(6, 429));
    final res = await p.send(
        ApiKey(kSecretKey), 'm', textRequest(), AiSendTicket(call.hashes));
    // openai_dart's RetryPolicy (3 retries, 1 s base) drives the loop; the
    // guard refuses the 4th identical attempt (1 + D-48's 2 retries).
    expect(fake.hits, hasLength(3));
    expect(fake.hits.map((h) => h.sha256Hex).toSet(), call.hashes);
    expect(p.lastClient!.refusals.single.reason, 'tooManyAttempts');
    expect(res.finish, 'failed');
  }, timeout: const Timeout(Duration(seconds: 60)));

  for (final id in AiProviderId.values) {
    test('$id: 503 is not retried and comes back as finish=failed + a string',
        () async {
      final p = GenkitLlmProvider(id, loopback: fake.origin);
      final call = await p.prepare(kModels[id]!, textRequest());
      fake.failFirst.add(503);
      final res = await p.send(ApiKey(kSecretKey), kModels[id]!, textRequest(),
          AiSendTicket(call.hashes));
      expect(fake.hits, hasLength(1), reason: 'D-48 wants 2 retries on 503');
      expect(res.finish, 'failed');
      expect(res.finishMessage, contains('scripted failure'));
      // Typed mapping must come from the guard's own record of the response.
      expect(p.lastClient!.responses.single.status, 503);
    });
  }
}
