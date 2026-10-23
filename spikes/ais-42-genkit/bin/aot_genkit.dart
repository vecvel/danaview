// AOT size probe, Genkit side: one structured generate per provider plus
// embeddings, all through the guarded client. Not run, only compiled.
import 'dart:io';

import 'package:ais42_genkit_spike/ais42.dart';

Future<void> main(List<String> args) async {
  final schema = <String, Object?>{'type': 'object'};
  for (final id in AiProviderId.values) {
    final p = GenkitLlmProvider(id, loopback: Uri.parse(args.first));
    final r = LlmRequest(
      contractId: 'c',
      system: 's',
      parts: const [TextPart('t')],
      schema: schema,
    );
    final prepared = await p.prepare('m', r);
    final res = await p.send(ApiKey('k'), 'm', r, AiSendTicket(prepared.hashes));
    stdout.writeln(res.json);
    final pe = await p.prepareEmbed('e', const [TextPart('t')]);
    if (pe.requests.isNotEmpty) {
      stdout.writeln(await p.embed(ApiKey('k'), 'e', const [TextPart('t')], AiSendTicket(pe.hashes)));
    }
  }
}
