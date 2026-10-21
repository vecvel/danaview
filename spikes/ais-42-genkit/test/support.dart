// Shared fixtures for the AIS-42 spike tests.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ais42_genkit_spike/ais42.dart';

const kModels = {
  AiProviderId.gemini: 'gemini-2.5-flash',
  AiProviderId.openai: 'gpt-4.1-mini',
  AiProviderId.anthropic: 'claude-sonnet-4-5',
  AiProviderId.openrouter: 'openai/gpt-4.1-mini',
  AiProviderId.xai: 'grok-4',
};

final kSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'ok': {'type': 'boolean'},
    'label': {'type': 'string', 'maxLength': 40},
  },
  'required': ['ok', 'label'],
  'additionalProperties': false,
};

const kCaption = 'caption-text-7f3a';
const kSecretKey = 'sk-spike-secret-0042';

LlmRequest textRequest({double temperature = 0.2, String text = kCaption}) =>
    LlmRequest(
      contractId: 'dv.cleanup.v1',
      system: 'You clean captions.',
      parts: [TextPart(text)],
      schema: kSchema,
      temperature: temperature,
    );

final Uint8List kPng = Uint8List.fromList(List.generate(64, (i) => i));
final Uint8List kWav = Uint8List.fromList(List.generate(64, (i) => 255 - i));

Map<String, Object?> bodyJson(PreparedRequest r) =>
    jsonDecode(utf8.decode(r.bytes)) as Map<String, Object?>;
