// AIS-42 spike: a minimal mirror of the D-48 / D-45 contracts that AIS-08 will
// freeze in packages/danaview_ai_providers. Throwaway; no product code imports it.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum AiProviderId { gemini, openai, anthropic, openrouter, xai }

/// D-66 allow-list: exactly one host per provider.
const Map<AiProviderId, String> kProviderHosts = {
  AiProviderId.gemini: 'generativelanguage.googleapis.com',
  AiProviderId.openai: 'api.openai.com',
  AiProviderId.anthropic: 'api.anthropic.com',
  AiProviderId.openrouter: 'openrouter.ai',
  AiProviderId.xai: 'api.x.ai',
};

/// A user key. `toString` is redacted and there is no JSON form (AIS-08).
final class ApiKey {
  ApiKey(this._value);
  final String _value;
  String reveal() => _value;
  String get last4 =>
      _value.length <= 4 ? _value : _value.substring(_value.length - 4);
  @override
  String toString() => 'ApiKey(…$last4)';
}

/// One part of a request: text, WAV audio, or an image (D-48 + D-70a).
sealed class LlmPart {
  const LlmPart();
}

final class TextPart extends LlmPart {
  const TextPart(this.text);
  final String text;
}

final class WavAudioPart extends LlmPart {
  const WavAudioPart(this.bytes);
  final Uint8List bytes;
}

final class ImagePart extends LlmPart {
  const ImagePart(this.bytes, {this.mimeType = 'image/png'});
  final Uint8List bytes;
  final String mimeType;
}

final class LlmRequest {
  const LlmRequest({
    required this.contractId,
    required this.system,
    required this.parts,
    required this.schema,
    this.temperature = 0.2,
    this.maxOutputTokens = 512,
  });
  final String contractId;
  final String system;
  final List<LlmPart> parts;
  final Map<String, Object?> schema;
  final double temperature;
  final int maxOutputTokens;
}

/// The exact bytes of one HTTP request, captured before any consent.
final class PreparedRequest {
  PreparedRequest({
    required this.method,
    required this.url,
    required this.bytes,
  }) : sha256Hex = sha256.convert(bytes).toString();
  final String method;
  final Uri url;
  final Uint8List bytes;
  final String sha256Hex;
}

/// A prepared operation: every request the operation will make, in order.
final class PreparedCall {
  PreparedCall(this.requests);
  final List<PreparedRequest> requests;
  Set<String> get hashes => {for (final r in requests) r.sha256Hex};
}

/// AiSendTicket (D-45): the payload hashes the transport may send.
final class AiSendTicket {
  AiSendTicket(Set<String> hashes) : hashes = Set.unmodifiable(hashes);
  final Set<String> hashes;
}

final class LlmResponse {
  const LlmResponse({required this.json, this.inputTokens, this.outputTokens});
  final String json;
  final int? inputTokens;
  final int? outputTokens;
}

/// The guard refused a request before any socket was opened.
final class TransportRefused implements Exception {
  TransportRefused(this.reason, this.url);
  final String reason;
  final Uri url;
  @override
  String toString() => 'TransportRefused($reason, ${url.host}${url.path})';
}
