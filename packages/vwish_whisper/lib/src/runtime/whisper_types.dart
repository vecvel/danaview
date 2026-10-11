// OWNER: AI-07 (value types declared by AI-02's skeleton; AI-07 may extend them)
//
// Public data types of the Dart runtime API (ai.md §4.7): options, requests, job updates, raw
// segments and the typed exception. Pure Dart, no dart:ffi: building one never touches the native
// library. AI-07 maps them to and from the C ABI structs (`vw_job_params`, `vw_job_status`, the
// segment and language JSON documents).

import 'package:meta/meta.dart';

/// whisper DTW alignment-head presets (`whisper_alignment_heads_preset`; off in v1 unless tuning
/// enables them). [nativeValue] is the integer stored in `vw_model_params.dtw_preset`.
enum WhisperDtwPreset {
  /// Off (`0`, the default).
  none(0),

  /// `tiny` (multilingual).
  tiny(4),

  /// `base` (multilingual).
  base(6),

  /// `small` (multilingual).
  small(8);

  const WhisperDtwPreset(this.nativeValue);

  /// Value passed to `vw_model_params.dtw_preset` (`WHISPER_AHEADS_*` of whisper.h).
  final int nativeValue;
}

/// Options for loading a model.
@immutable
final class WhisperModelOptions {
  /// Creates the options.
  const WhisperModelOptions({this.preferGpu = true, this.flashAttention = true, this.dtwPreset});

  /// Request the GPU; the shim applies the iOS GPU policy and may downgrade.
  final bool preferGpu;

  /// Flash attention (forced off when [dtwPreset] is set).
  final bool flashAttention;

  /// DTW token timestamps preset, or null (off).
  final WhisperDtwPreset? dtwPreset;
}

/// What the loaded model reports (`vw_model_info`).
@immutable
final class WhisperModelInfo {
  /// Creates the info.
  const WhisperModelInfo({required this.multilingual, required this.usesGpu, this.gpuFallback = false, this.vocabSize = 0});

  /// Multilingual vocabulary.
  final bool multilingual;

  /// Whether inference runs on the GPU.
  final bool usesGpu;

  /// The GPU was requested but the shim fell back to the CPU.
  final bool gpuFallback;

  /// Vocabulary size.
  final int vocabSize;
}

/// Voice activity detection (Silero) options; defaults are the ai.md values.
@immutable
final class WhisperVadOptions {
  /// Creates the options.
  const WhisperVadOptions({
    required this.modelPath,
    this.threshold = 0.5,
    this.minSpeech = const Duration(milliseconds: 250),
    this.minSilence = const Duration(milliseconds: 300),
    this.speechPad = const Duration(milliseconds: 100),
    this.samplesOverlapSeconds = 0.1,
  });

  /// Path of `ggml-silero-v6.2.0.bin`.
  final String modelPath;

  /// Speech probability threshold.
  final double threshold;

  /// Shortest speech segment kept.
  final Duration minSpeech;

  /// Silence that ends a segment.
  final Duration minSilence;

  /// Padding added around speech.
  final Duration speechPad;

  /// Overlap between VAD samples, seconds.
  final double samplesOverlapSeconds;
}

/// Decoder options; defaults are the ai.md values (QA-06 tunes them in vwish_transcription).
@immutable
final class WhisperDecodeOptions {
  /// Creates the options.
  const WhisperDecodeOptions({
    this.noSpeechThreshold = 0.6,
    this.entropyThreshold = 2.4,
    this.logprobThreshold = -1.0,
    this.temperatureInc = 0.2,
    this.beamSize = 1,
    this.bestOf = 5,
    this.suppressNonSpeech = true,
    this.tokenTimestamps = true,
  });

  /// No-speech probability above which a segment is dropped.
  final double noSpeechThreshold;

  /// Compression/entropy threshold that triggers a temperature fallback.
  final double entropyThreshold;

  /// Average log probability below which the decoder falls back.
  final double logprobThreshold;

  /// Temperature increment per fallback.
  final double temperatureInc;

  /// Beam size; `<= 1` is greedy.
  final int beamSize;

  /// Candidates for temperature fallback sampling.
  final int bestOf;

  /// whisper `suppress_nst`: no `[music]` style annotations.
  final bool suppressNonSpeech;

  /// Word-level timestamps.
  final bool tokenTimestamps;
}

/// A transcription request (one job over a canonical 16 kHz mono WAV).
@immutable
final class WhisperTranscribeRequest {
  /// Creates a request.
  const WhisperTranscribeRequest({
    required this.wavPath,
    required this.language,
    required this.threads,
    this.rangeStart = Duration.zero,
    this.rangeEnd,
    this.vad,
    this.decode = const WhisperDecodeOptions(),
    this.chunkTarget = const Duration(seconds: 180),
    this.chunkSearch = const Duration(seconds: 15),
    this.carryPromptWords = 24,
    this.initialPrompt,
  });

  /// WAV path (never logged).
  final String wavPath;

  /// whisper language code (`en`, `ja`, ...).
  final String language;

  /// Threads (1..8).
  final int threads;

  /// Inclusive start, relative to the WAV start (resume point).
  final Duration rangeStart;

  /// Exclusive end, or null for the end of the file.
  final Duration? rangeEnd;

  /// VAD options; null = off (tests only).
  final WhisperVadOptions? vad;

  /// Decoder options.
  final WhisperDecodeOptions decode;

  /// Chunk target length.
  final Duration chunkTarget;

  /// Search window around the chunk target for the quietest point.
  final Duration chunkSearch;

  /// Words of the previous chunk carried as the prompt (0..40).
  final int carryPromptWords;

  /// Initial prompt (unused by the v1 UI).
  final String? initialPrompt;
}

/// A language-detection request.
@immutable
final class WhisperDetectRequest {
  /// Creates a request.
  const WhisperDetectRequest({
    required this.wavPath,
    required this.threads,
    this.vad,
    this.maxSpeech = const Duration(seconds: 30),
    this.searchWindow = const Duration(minutes: 10),
  });

  /// WAV path (never logged).
  final String wavPath;

  /// Threads.
  final int threads;

  /// VAD options.
  final WhisperVadOptions? vad;

  /// Speech analysed after the first VAD speech start.
  final Duration maxSpeech;

  /// How far into the file the first speech is searched.
  final Duration searchWindow;
}

/// Cancels a pending model load ([WhisperRuntime.loadModel]).
final class WhisperCancelToken {
  bool _cancelled = false;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Abandons the result; the native load finishes, then frees itself.
  void cancel() => _cancelled = true;
}

/// Job state (`vw_job_state`).
enum WhisperJobState {
  /// Running.
  running,

  /// Paused at a chunk boundary or aborted for the background.
  paused,

  /// Finished.
  succeeded,

  /// Failed.
  failed,

  /// Cancelled.
  cancelled,
}

/// Phase inside a chunk (`vw_phase`).
enum WhisperPhase {
  /// Preparing.
  preparing,

  /// Voice activity detection.
  vad,

  /// Encoder.
  encoding,

  /// Decoder.
  decoding,
}

/// One candidate of language detection.
@immutable
final class WhisperLanguageProbability {
  /// Creates a candidate.
  const WhisperLanguageProbability(this.code, this.p);

  /// whisper language code.
  final String code;

  /// Probability, 0..1.
  final double p;
}

/// A word with its own timing, relative to the WAV start.
@immutable
final class RawWord {
  /// Creates a word.
  const RawWord({required this.text, required this.start, required this.end, required this.probability});

  /// Text (never logged).
  final String text;

  /// Start.
  final Duration start;

  /// End.
  final Duration end;

  /// Token probability.
  final double probability;
}

/// A decoded segment, relative to the WAV start (never logged).
@immutable
final class RawSegment {
  /// Creates a segment.
  const RawSegment({
    required this.index,
    required this.chunk,
    required this.start,
    required this.end,
    required this.text,
    this.noSpeechProb = 0,
    this.avgLogProb = 0,
    this.words = const [],
  });

  /// Index within the job.
  final int index;

  /// Chunk it came from.
  final int chunk;

  /// Start.
  final Duration start;

  /// End.
  final Duration end;

  /// Text.
  final String text;

  /// whisper no-speech probability.
  final double noSpeechProb;

  /// Mean token log probability.
  final double avgLogProb;

  /// Words, when token timestamps are on.
  final List<RawWord> words;
}

/// A job update on [WhisperJob.updates].
@immutable
sealed class WhisperJobUpdate {
  const WhisperJobUpdate();
}

/// Status sample, throttled to 4 Hz.
final class WhisperJobStatus extends WhisperJobUpdate {
  /// Creates a sample.
  const WhisperJobStatus({
    required this.state,
    required this.phase,
    required this.fraction,
    this.chunkIndex = 0,
    this.chunkCount = 0,
    this.chunksCompleted = 0,
    this.processed = Duration.zero,
    this.computeTime = Duration.zero,
    this.threads = 0,
    this.language = '',
    this.languageP = 0,
  });

  /// State.
  final WhisperJobState state;

  /// Phase.
  final WhisperPhase phase;

  /// 0..1 over the requested range.
  final double fraction;

  /// 0-based current chunk.
  final int chunkIndex;

  /// Chunks in total (known after planning).
  final int chunkCount;

  /// Chunks whose segments are final.
  final int chunksCompleted;

  /// Audio covered by completed work.
  final Duration processed;

  /// Wall time spent in whisper calls (excludes pauses).
  final Duration computeTime;

  /// Threads in use.
  final int threads;

  /// Language used or detected.
  final String language;

  /// Detection probability.
  final double languageP;
}

/// New segments are available.
final class WhisperSegmentsAdded extends WhisperJobUpdate {
  /// Creates the update.
  const WhisperSegmentsAdded({required this.segments, required this.chunk, required this.chunkFinal});

  /// The segments.
  final List<RawSegment> segments;

  /// Chunk they belong to.
  final int chunk;

  /// Whether the chunk is complete.
  final bool chunkFinal;
}

/// Result of a language-detection job.
final class WhisperLanguageResult extends WhisperJobUpdate {
  /// Creates the update.
  const WhisperLanguageResult({required this.top, this.speechStart});

  /// Most likely languages, best first.
  final List<WhisperLanguageProbability> top;

  /// Where speech was first found, relative to the WAV start.
  final Duration? speechStart;
}

/// Diagnostic (ai.md §4.7): the job has been RUNNING for [unchangedFor] without its compute time
/// advancing. Emitted once per stall; nothing is killed automatically.
final class WhisperJobStalled extends WhisperJobUpdate {
  /// Creates the update.
  const WhisperJobStalled({required this.unchangedFor, required this.computeTime});

  /// How long the compute time has not changed.
  final Duration unchangedFor;

  /// The compute time that stopped advancing.
  final Duration computeTime;
}

/// Final result of a job.
@immutable
final class WhisperJobResult {
  /// Creates the result.
  const WhisperJobResult({
    this.segments = const [],
    this.language = '',
    this.languageP = 0,
    this.processed = Duration.zero,
    this.computeTime = Duration.zero,
    this.languages = const [],
  });

  /// Every segment, in order.
  final List<RawSegment> segments;

  /// Language used or detected.
  final String language;

  /// Detection probability.
  final double languageP;

  /// Audio processed.
  final Duration processed;

  /// Wall time in whisper calls.
  final Duration computeTime;

  /// Detection candidates (DETECT jobs).
  final List<WhisperLanguageProbability> languages;
}

/// Why a native call or the library failed.
enum WhisperErrorKind {
  /// The native library is missing on this platform or ABI.
  libraryUnavailable,

  /// The library's `vw_abi_version()` differs from the Dart bindings.
  abiMismatch,

  /// The model failed to load.
  modelLoadFailed,

  /// Out of memory.
  outOfMemory,

  /// The WAV is not canonical 16 kHz mono s16.
  invalidAudio,

  /// File access failed.
  io,

  /// Inference failed.
  inference,

  /// Cancelled.
  cancelled,

  /// A job is already running on the model.
  busy,

  /// The VAD model is missing or invalid.
  vadModelMissing,

  /// No speech found.
  noSpeech,

  /// Anything else.
  internal,
}

/// Failure of the runtime. [detail] never contains transcript text or paths.
final class WhisperException implements Exception {
  /// Creates the exception.
  const WhisperException(this.kind, [this.detail]);

  /// Kind.
  final WhisperErrorKind kind;

  /// Diagnostic detail.
  final String? detail;

  @override
  String toString() => 'WhisperException(${kind.name}${detail == null ? '' : ': $detail'})';
}
