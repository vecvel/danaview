// OWNER: QA-06
//
// Decided decoding, VAD, segmentation and device-policy constants for Auto captions (ai.md §4.5,
// §9.2, §9.4, §14; BUILD_PLAN QA-06). Every value and its status (measured, retained default,
// provisional) is recorded in docs/v1.1/editor/ai-eval.md, which the eval harness
// (tool/eval/) regenerates. Changing a value here requires a nightly eval run (ai.md §16.5) and an
// update of that document; tool/eval/test/tuning_test.dart pins the values against the document and
// checks that the shim, runtime and segmenter defaults agree with them.

/// Decoding, VAD, segmentation and device-policy constants (ai.md §4.5, §9.2, §9.4, §14).
abstract final class SpeechTuning {
  // --- Chunking and decoding (ai.md §4.5) -------------------------------------------------------

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

  /// Temperature increment per fallback (greedy decoding, beam size 1, otherwise).
  static const double temperatureIncrement = 0.2;

  /// Words of the previous chunk carried as the prompt.
  static const int carryPromptWords = 24;

  /// Language auto-detect acceptance threshold (D-19).
  static const double autoDetectMinProbability = 0.6;

  // --- Silero VAD (ai.md §4.5; whisper.cpp v1.9.4 defaults kept) --------------------------------

  /// Speech probability threshold.
  static const double vadThreshold = 0.5;

  /// Shortest speech run kept, ms.
  static const int vadMinSpeechMs = 250;

  /// Silence that ends a speech run, ms.
  static const int vadMinSilenceMs = 300;

  /// Padding around each speech run, ms.
  static const int vadSpeechPadMs = 100;

  /// Overlap between VAD windows, seconds.
  static const double vadSamplesOverlapSeconds = 0.1;

  // --- Segmentation reading limits (ai.md §9.2; V-A10) -------------------------------------------

  /// Standard preset: max characters per line (space-delimited scripts; 32 for 9:16).
  static const int standardMaxCharsPerLine = 42;

  /// Standard preset: max reading speed in characters per second.
  static const double standardMaxCps = 17;

  /// Short-phrases preset: max reading speed, space-delimited and no-space scripts.
  static const double shortPhrasesMaxCps = 20;

  /// Chinese and Japanese, Standard and Single line: max reading speed (V-A10).
  static const double cjkMaxCps = 9;

  /// Chinese and Japanese, Short phrases: max reading speed (V-A10).
  static const double cjkShortPhrasesMaxCps = 10;

  /// Korean, Standard and Single line: max reading speed (V-A10).
  static const double koreanMaxCps = 12;

  /// Korean, Short phrases: max reading speed (V-A10).
  static const double koreanShortPhrasesMaxCps = 14;

  // --- Device policy (ai.md §4.4, §5.1, §6.1; V-A4) ----------------------------------------------

  /// Lowest Apple GPU family (`MTLGPUFamilyApple<N>`) that runs whisper on Metal. 6 = A13; A12
  /// (Apple5) stays on the CPU (V-A4).
  static const int metalMinAppleGpuFamily = 6;

  /// Lowest iOS version (major, minor) that runs whisper on Metal.
  static const (int, int) metalMinIosVersion = (16, 4);

  /// Allowance for the first Metal initialisation on a device (embedded kernel library compile),
  /// added to the first ETA of a session on a Metal device (ai.md §14.1 estimate 1-5 s; V-A4).
  static const int firstMetalInitAllowanceMs = 5000;

  /// Preflight requires this multiple of the tier's peak memory budget to be available.
  static const double preflightMemoryFactor = 1.3;

  /// Android Balanced keeps base q5_1 (false); true would switch to `ggml-base-q8_0.bin` on
  /// Android dot-product CPUs (ai.md §5.1).
  static const bool androidBalancedUsesQ8 = false;

  // --- Language quality hint (ai.md §9.4) ----------------------------------------------------------

  /// The 30 languages with the lowest published FLEURS WER (whisper large-v2, Radford et al. 2022,
  /// appendix D). Every other language carries `qualityHint`: Fast and Balanced are weak there, so
  /// the sheet recommends Accurate. Provisional until the nightly eval has per-tier numbers.
  static const Set<String> fleursTop30 = {
    'es', 'it', 'en', 'pt', 'de', 'ja', 'ru', 'pl', 'ca', 'nl', //
    'ko', 'fr', 'id', 'tr', 'uk', 'sv', 'ms', 'no', 'fi', 'vi', //
    'th', 'sk', 'el', 'cs', 'hr', 'tl', 'da', 'ro', 'zh', 'bg', //
  };

  /// Whether Fast and Balanced are weak for the whisper language [whisperCode], so the sheet
  /// recommends Accurate (ai.md §9.4).
  static bool qualityHintFor(String whisperCode) => !fleursTop30.contains(whisperCode);
}
