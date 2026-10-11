// OWNER: QA-06 (placeholder created by AI-08's scaffold)
//
// ai.md defaults for decoding and segmentation; QA-06 tunes them with the evaluation harness.

/// Decoding and segmentation defaults (ai.md §4.5, §9.2).
abstract final class SpeechTuning {
  /// Chunk target in ms.
  static const int chunkTargetMs = 180000;

  /// Search window around the chunk target in ms.
  static const int chunkSearchMs = 15000;

  /// No-speech threshold.
  static const double noSpeechThreshold = 0.6;

  /// Entropy threshold.
  static const double entropyThreshold = 2.4;

  /// Log-probability threshold.
  static const double logprobThreshold = -1.0;

  /// Words of the previous chunk carried as the prompt.
  static const int carryPromptWords = 24;

  /// Language auto-detect acceptance threshold (D-19).
  static const double autoDetectMinProbability = 0.6;

  /// Standard preset: max characters per line (space-delimited scripts; 32 for 9:16).
  static const int standardMaxCharsPerLine = 42;

  /// Standard preset: max reading speed in characters per second.
  static const double standardMaxCps = 17;
}
