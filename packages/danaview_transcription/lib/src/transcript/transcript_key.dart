// OWNER: AI-10
//
// The transcript cache key (ARCH §16.4 step 2, ai.md §8.2):
// `sha256(quickHash | audioStream | modelSha256 | language | paramsVersion | vad)`.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'transcript_models.dart';

/// Builds and validates transcript cache keys.
abstract final class TranscriptKey {
  /// The key of a transcript. [audioStream] null means the first stream (0). [language] is the
  /// whisper code the audio was decoded with (an explicit or detected language, never `auto`).
  static String compute({
    required String quickHash,
    int? audioStream,
    required String modelSha256,
    required String language,
    int paramsVersion = transcriptParamsVersion,
    required bool vad,
  }) {
    final text = '$quickHash|${audioStream ?? 0}|$modelSha256|$language|$paramsVersion|${vad ? 1 : 0}';
    return sha256.convert(utf8.encode(text)).toString();
  }

  static final RegExp _valid = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Whether [key] is safe to use as a file name stem (no separators, dots or traversal).
  static bool isValid(String key) => _valid.hasMatch(key);

  /// Throws [ArgumentError] unless [key] [isValid].
  static void check(String key) {
    if (!isValid(key)) throw ArgumentError.value(key, 'key', 'not a valid transcript key');
  }
}
