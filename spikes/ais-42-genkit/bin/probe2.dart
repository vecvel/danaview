import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:ais42_genkit_spike/ais42.dart';

const emb = {
  AiProviderId.gemini: 'gemini-embedding-001',
  AiProviderId.openai: 'text-embedding-3-small',
  AiProviderId.anthropic: 'none',
  AiProviderId.openrouter: 'openai/text-embedding-3-small',
  AiProviderId.xai: 'v1',
};
final schema = <String, Object?>{'type': 'object','properties': {'ok': {'type': 'boolean'}},'required': ['ok'],'additionalProperties': false};

Future<void> main() async {
  final logs = <String>[];
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) => logs.add('${r.loggerName}: ${r.message}'));
  final fake = await FakeProviderServer.start();
  final png = Uint8List.fromList(List.generate(64, (i) => i));
  // Gemini via zone
  final gz = GenkitLlmProvider(AiProviderId.gemini, loopback: fake.origin, geminiInjection: GeminiInjection.zoneOverride);
  final req = LlmRequest(contractId: 'p', system: 's', parts: const [TextPart('caption-secret')], schema: schema);
  final pz = await gz.prepare('gemini-2.5-flash', req);
  print('gemini zone captured=${pz.requests.length} headers=${gz.lastClient!.seen.firstOrNull?.headers}');
  if (pz.requests.isNotEmpty) {
    final r = await gz.send(ApiKey('sk-zone-9999'), 'gemini-2.5-flash', req, AiSendTicket(pz.hashes));
    print('  zone send ok ${r.json}; wire=${gz.lastClient!.sent.last.headers}');
  }
  for (final id in AiProviderId.values) {
    final p = GenkitLlmProvider(id, loopback: fake.origin);
    for (final doc in [<LlmPart>[const TextPart('embed me')], <LlmPart>[ImagePart(png)]]) {
      final pc = await p.prepareEmbed(emb[id]!, doc);
      final kind = doc.first is TextPart ? 'text' : 'image';
      if (pc.requests.isEmpty) { print('$id embed/$kind: no request'); continue; }
      final r = pc.requests.first;
      print('$id embed/$kind: ${r.url.path} ${utf8.decode(r.bytes).substring(0, utf8.decode(r.bytes).length.clamp(0, 300))}');
      try { final v = await p.embed(ApiKey('k'), emb[id]!, doc, AiSendTicket(pc.hashes)); print('  ok $v'); } catch (e) { print('  FAIL $e'); }
    }
  }
  // retries
  for (final id in AiProviderId.values) {
    final p = GenkitLlmProvider(id, loopback: fake.origin);
    final pc = await p.prepare('m', req);
    fake.hits.clear();
    fake.failFirst..clear()..addAll([503, 503, 503, 503, 503]);
    final sw = Stopwatch()..start();
    try { await p.send(ApiKey('k'), 'm', req, AiSendTicket(pc.hashes)); print('$id retry: ok'); } catch (e) { print('$id retry: failed ${e.runtimeType}'); }
    print('  attempts seen=${p.lastClient!.seen.length} sent=${p.lastClient!.sent.length} refusals=${p.lastClient!.refusals.map((r)=>r.reason).toList()} hits=${fake.hits.length} in ${sw.elapsedMilliseconds}ms');
    fake.failFirst.clear();
  }
  print('LOG RECORDS: ${logs.length}');
  for (final l in logs.where((l) => l.contains('caption-secret') || l.contains('sk-') || l.contains('placeholder'))) { print('  LEAK: ${l.substring(0, l.length.clamp(0, 200))}'); }
  for (final l in logs.take(15)) print('  log: ${l.substring(0, l.length.clamp(0, 160))}');
  await fake.close();
}
