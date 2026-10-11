// OWNER: AI-07
//
// The C ABI of src/vw_whisper.h as a pointer-free Dart interface (ai.md §4.7 "fake bindings").
// The runtime only talks to [VwBindings]: the real implementation lives in
// `lib/src/ffi/library_loader.dart` (the only runtime file that imports dart:ffi) and tests pass a
// fake. Native handles are opaque non-zero integers (the pointer address); 0 is the null handle.
//
// Calls are split by cost:
//  * synchronous members are leaf FFI calls that return in microseconds (status reads, flag
//    stores, a mutex-guarded JSON copy) and run on the calling (UI) isolate;
//  * `Future` members may block natively (joining a thread, freeing a context, probing a WAV
//    header, `vw_shutdown_all`) and the FFI implementation runs them on a helper isolate, so the UI
//    isolate never waits inside FFI.

import 'dart:async';

import 'package:meta/meta.dart';

/// `vw_status` codes.
abstract final class VwStatus {
  /// `VW_OK`.
  static const int ok = 0;

  /// `VW_ERR_INVALID_ARG`.
  static const int invalidArg = 1;

  /// `VW_ERR_MODEL_LOAD`.
  static const int modelLoad = 2;

  /// `VW_ERR_WAV_FORMAT`.
  static const int wavFormat = 3;

  /// `VW_ERR_IO`.
  static const int io = 4;

  /// `VW_ERR_OOM`.
  static const int oom = 5;

  /// `VW_ERR_CANCELLED`.
  static const int cancelled = 6;

  /// `VW_ERR_INFERENCE`.
  static const int inference = 7;

  /// `VW_ERR_BUSY`.
  static const int busy = 8;

  /// `VW_ERR_VAD_MODEL`.
  static const int vadModel = 9;

  /// `VW_ERR_NO_SPEECH`.
  static const int noSpeech = 10;

  /// `VW_ERR_INTERNAL`.
  static const int internal = 99;
}

/// `vw_model_state`.
abstract final class VwModelState {
  /// `VW_MODEL_LOADING`.
  static const int loading = 0;

  /// `VW_MODEL_READY`.
  static const int ready = 1;

  /// `VW_MODEL_FAILED`.
  static const int failed = 2;
}

/// `vw_job_state`.
abstract final class VwJobState {
  /// `VW_JOB_RUNNING`.
  static const int running = 1;

  /// `VW_JOB_PAUSED`.
  static const int paused = 2;

  /// `VW_JOB_SUCCEEDED`.
  static const int succeeded = 3;

  /// `VW_JOB_FAILED`.
  static const int failed = 4;

  /// `VW_JOB_CANCELLED`.
  static const int cancelled = 5;

  /// Whether [state] is terminal.
  static bool isTerminal(int state) => state == succeeded || state == failed || state == cancelled;
}

/// `vw_job_mode`.
abstract final class VwJobMode {
  /// `VW_MODE_TRANSCRIBE`.
  static const int transcribe = 0;

  /// `VW_MODE_DETECT_LANGUAGE`.
  static const int detectLanguage = 1;
}

/// Log levels of `vw_set_log_level` (0 off ... 4 debug; the shim defaults to warn).
abstract final class VwLogLevel {
  /// Off.
  static const int off = 0;

  /// Errors.
  static const int error = 1;

  /// Warnings (default).
  static const int warn = 2;

  /// Info.
  static const int info = 3;

  /// Debug.
  static const int debug = 4;
}

/// `vw_model_params`.
@immutable
final class VwModelParams {
  /// Creates the params.
  const VwModelParams({this.useGpu = true, this.flashAttn = true, this.dtwPreset = 0});

  /// Request the GPU.
  final bool useGpu;

  /// Flash attention.
  final bool flashAttn;

  /// `whisper_alignment_heads_preset`, 0 = off.
  final int dtwPreset;

  @override
  bool operator ==(Object other) =>
      other is VwModelParams && other.useGpu == useGpu && other.flashAttn == flashAttn && other.dtwPreset == dtwPreset;

  @override
  int get hashCode => Object.hash(useGpu, flashAttn, dtwPreset);
}

/// `vw_model_info`.
@immutable
final class VwModelInfoData {
  /// Creates the info.
  const VwModelInfoData({
    this.multilingual = false,
    this.nVocab = 0,
    this.modelType = 0,
    this.ftype = 0,
    this.gpuUsed = false,
    this.gpuFallback = false,
  });

  /// Multilingual vocabulary.
  final bool multilingual;

  /// Vocabulary size.
  final int nVocab;

  /// whisper model type.
  final int modelType;

  /// ggml file type.
  final int ftype;

  /// The GPU is in use.
  final bool gpuUsed;

  /// The GPU was requested but the shim fell back to the CPU.
  final bool gpuFallback;
}

/// `vw_model_error`: status plus a diagnostic message without paths.
@immutable
final class VwModelErrorData {
  /// Creates the error.
  const VwModelErrorData(this.status, [this.message = '']);

  /// `vw_status`.
  final int status;

  /// Diagnostic message (never a path or transcript text).
  final String message;
}

/// `vw_job_params` (strings are copied natively).
@immutable
final class VwJobParams {
  /// Creates the params; defaults are the header's.
  const VwJobParams({
    required this.mode,
    required this.wavPath,
    this.rangeStartMs = 0,
    this.rangeEndMs = -1,
    this.language = 'en',
    this.nThreads = 4,
    this.chunkTargetMs = 180000,
    this.chunkSearchMs = 15000,
    this.chunkMinMs = 10000,
    this.vadEnabled = false,
    this.vadModelPath,
    this.vadThreshold = 0.5,
    this.vadMinSpeechMs = 250,
    this.vadMinSilenceMs = 300,
    this.vadSpeechPadMs = 100,
    this.vadSamplesOverlapS = 0.1,
    this.tokenTimestamps = true,
    this.noSpeechThold = 0.6,
    this.entropyThold = 2.4,
    this.logprobThold = -1.0,
    this.temperatureInc = 0.2,
    this.beamSize = 1,
    this.bestOf = 5,
    this.suppressNst = true,
    this.carryPromptWords = 24,
    this.initialPrompt,
    this.detectMaxSpeechMs = 30000,
    this.detectSearchMs = 600000,
  });

  /// `vw_job_mode`.
  final int mode;

  /// WAV path (never logged).
  final String wavPath;

  /// Inclusive range start, ms.
  final int rangeStartMs;

  /// Exclusive range end, ms; -1 = end of file.
  final int rangeEndMs;

  /// whisper language code ("auto" in DETECT mode).
  final String language;

  /// Threads, 1..8.
  final int nThreads;

  /// Chunk target, ms.
  final int chunkTargetMs;

  /// Chunk search window, ms.
  final int chunkSearchMs;

  /// Shortest chunk, ms.
  final int chunkMinMs;

  /// VAD on.
  final bool vadEnabled;

  /// VAD model path.
  final String? vadModelPath;

  /// VAD threshold.
  final double vadThreshold;

  /// VAD min speech, ms.
  final int vadMinSpeechMs;

  /// VAD min silence, ms.
  final int vadMinSilenceMs;

  /// VAD padding, ms.
  final int vadSpeechPadMs;

  /// VAD sample overlap, seconds.
  final double vadSamplesOverlapS;

  /// Word timestamps.
  final bool tokenTimestamps;

  /// No-speech threshold.
  final double noSpeechThold;

  /// Entropy threshold.
  final double entropyThold;

  /// Log-prob threshold.
  final double logprobThold;

  /// Temperature increment.
  final double temperatureInc;

  /// Beam size (<= 1 greedy).
  final int beamSize;

  /// Best-of for temperature fallback.
  final int bestOf;

  /// Suppress non-speech tokens.
  final bool suppressNst;

  /// Prompt words carried between chunks, 0..40.
  final int carryPromptWords;

  /// Initial prompt.
  final String? initialPrompt;

  /// DETECT: speech analysed, ms.
  final int detectMaxSpeechMs;

  /// DETECT: search window, ms.
  final int detectSearchMs;
}

/// Result of `vw_job_start`.
@immutable
final class VwJobStartResult {
  /// Creates the result.
  const VwJobStartResult(this.handle, this.status);

  /// Job handle (0 on failure).
  final int handle;

  /// `vw_status`.
  final int status;
}

/// `vw_job_status`.
@immutable
final class VwJobStatusData {
  /// Creates the status.
  const VwJobStatusData({
    required this.state,
    this.error = VwStatus.ok,
    this.phase = 0,
    this.progressPermille = 0,
    this.chunkIndex = 0,
    this.chunkCount = 0,
    this.chunksCompleted = 0,
    this.segmentsReady = 0,
    this.processedMs = 0,
    this.computeMs = 0,
    this.threads = 0,
    this.language = '',
    this.languageP = 0,
  });

  /// `vw_job_state`.
  final int state;

  /// `vw_status` when FAILED/CANCELLED.
  final int error;

  /// `vw_phase`.
  final int phase;

  /// 0..1000.
  final int progressPermille;

  /// Current chunk.
  final int chunkIndex;

  /// Chunks in total.
  final int chunkCount;

  /// Final chunks.
  final int chunksCompleted;

  /// Segments available to take.
  final int segmentsReady;

  /// Audio covered, ms.
  final int processedMs;

  /// Wall time in whisper calls, ms.
  final int computeMs;

  /// Threads in use.
  final int threads;

  /// Language used or detected.
  final String language;

  /// Detection probability.
  final double languageP;
}

/// The vw_* C ABI without pointers. Handles are opaque non-zero integers.
abstract interface class VwBindings {
  /// `vw_abi_version()`.
  int abiVersion();

  /// `vw_engine_version()` ("" when null).
  String engineVersion();

  /// `vw_cpu_features()`.
  int cpuFeatures();

  /// `vw_set_log_level(level)`.
  void setLogLevel(int level);

  /// `vw_shutdown_all()`: cancels and joins every job, frees every model (hot restart hygiene).
  Future<void> shutdownAll();

  /// `vw_model_load(path, params)`: starts a native loader thread; 0 on invalid arguments.
  int modelLoad(String path, VwModelParams params);

  /// `vw_model_get_state(model)`.
  int modelState(int model);

  /// `vw_model_error(model, ...)`.
  VwModelErrorData modelError(int model);

  /// `vw_model_info_get(model, ...)`: null unless the call returned `VW_OK`.
  VwModelInfoData? modelInfo(int model);

  /// `vw_model_release(model)` (may free the context natively).
  Future<void> modelRelease(int model);

  /// `vw_job_start(model, params, &status)` (probes the WAV header natively).
  Future<VwJobStartResult> jobStart(int model, VwJobParams params);

  /// `vw_job_status_get(job, ...)`, a leaf call.
  VwJobStatusData jobStatus(int job);

  /// `vw_job_take_segments_json(job, from, max)`: a JSON array, or null for a stale handle.
  String? jobTakeSegmentsJson(int job, int from, int max);

  /// `vw_job_language_probs_json(job, topN)`: null until a DETECT job succeeded.
  String? jobLanguageJson(int job, int topN);

  /// `vw_job_cancel(job)`.
  void jobCancel(int job);

  /// `vw_job_pause(job, abort)`.
  void jobPause(int job, {required bool abortCurrentChunk});

  /// `vw_job_resume(job)`.
  void jobResume(int job);

  /// `vw_job_set_threads(job, n)`.
  void jobSetThreads(int job, int threads);

  /// `vw_job_free(job)` (cancels if running and joins the native thread).
  Future<void> jobFree(int job);
}

/// Opens the native library. Throwing a [VwLibraryUnavailable] (or anything else) makes the
/// runtime report `unsupported(libraryUnavailable)`.
typedef VwBindingsFactory = FutureOr<VwBindings> Function();

/// The native library could not be opened.
final class VwLibraryUnavailable implements Exception {
  /// Creates the exception. [detail] names the library, never a user path.
  const VwLibraryUnavailable(this.detail);

  /// What failed.
  final String detail;

  @override
  String toString() => 'VwLibraryUnavailable($detail)';
}
