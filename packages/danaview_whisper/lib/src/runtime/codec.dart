// OWNER: AI-07
//
// Pure mapping between the Dart API types and the C ABI values (ai.md §4.5/§4.7):
//  * the schema-1 segment JSON of `dv_job_take_segments_json`
//    ([{i, c, t0, t1, text, nsp, lp, w:[{t, t0, t1, p}]}], times in ms relative to the WAV start),
//  * the language JSON of `dv_job_language_probs_json` ({lang:[{code, p}], speechStartMs}),
//  * `dv_status` -> [WhisperErrorKind], job state and phase codes,
//  * requests -> [DvJobParams].
// Decoding is tolerant: unknown keys are ignored, a malformed element is skipped, wrong types fall
// back to defaults. Nothing here logs; transcript text never leaves the returned objects.

import 'dart:convert';

import 'dv_bindings.dart';
import 'whisper_types.dart';

/// Decoded page of segments: [segments] are the valid elements, [count] how many elements the
/// array held (malformed ones included), so the caller advances its cursor past them.
final class DecodedSegments {
  /// Creates the page.
  const DecodedSegments(this.segments, this.count);

  /// Valid segments in order.
  final List<RawSegment> segments;

  /// Elements in the array (valid or not); -1 when the document itself was not a JSON array.
  final int count;
}

/// Decodes one `dv_job_take_segments_json` page. [firstIndex] is the absolute index of the first
/// element (used when an element has no `i`).
DecodedSegments decodeSegmentsJson(String? json, {int firstIndex = 0}) {
  if (json == null) return const DecodedSegments([], -1);
  Object? doc;
  try {
    doc = jsonDecode(json);
  } on FormatException {
    return const DecodedSegments([], -1);
  }
  if (doc is! List<Object?>) return const DecodedSegments([], -1);
  final out = <RawSegment>[];
  for (var k = 0; k < doc.length; k++) {
    final s = decodeSegment(doc[k], fallbackIndex: firstIndex + k);
    if (s != null) out.add(s);
  }
  return DecodedSegments(out, doc.length);
}

/// Decodes one segment object; null when it lacks a usable time range.
RawSegment? decodeSegment(Object? raw, {int fallbackIndex = 0}) {
  if (raw is! Map<String, Object?>) return null;
  final t0 = _int(raw['t0']);
  final t1 = _int(raw['t1']);
  if (t0 == null || t1 == null || t0 < 0 || t1 < t0) return null;
  final text = raw['text'];
  final words = <RawWord>[];
  final rawWords = raw['w'];
  if (rawWords is List<Object?>) {
    for (final w in rawWords) {
      final word = _word(w);
      if (word != null) words.add(word);
    }
  }
  return RawSegment(
    index: _int(raw['i']) ?? fallbackIndex,
    chunk: _int(raw['c']) ?? 0,
    start: Duration(milliseconds: t0),
    end: Duration(milliseconds: t1),
    text: text is String ? text : '',
    noSpeechProb: _double(raw['nsp']) ?? 0,
    avgLogProb: _double(raw['lp']) ?? 0,
    words: List<RawWord>.unmodifiable(words),
  );
}

RawWord? _word(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final text = raw['t'];
  final t0 = _int(raw['t0']);
  final t1 = _int(raw['t1']);
  if (text is! String || t0 == null || t1 == null || t0 < 0 || t1 < t0) return null;
  return RawWord(
    text: text,
    start: Duration(milliseconds: t0),
    end: Duration(milliseconds: t1),
    probability: (_double(raw['p']) ?? 0).clamp(0.0, 1.0),
  );
}

/// Decodes the DETECT result; null when absent or malformed.
WhisperLanguageResult? decodeLanguageJson(String? json) {
  if (json == null) return null;
  Object? doc;
  try {
    doc = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (doc is! Map<String, Object?>) return null;
  final list = doc['lang'];
  final top = <WhisperLanguageProbability>[];
  if (list is List<Object?>) {
    for (final e in list) {
      if (e is! Map<String, Object?>) continue;
      final code = e['code'];
      final p = _double(e['p']);
      if (code is! String || code.isEmpty || p == null) continue;
      top.add(WhisperLanguageProbability(code, p.clamp(0.0, 1.0)));
    }
  }
  top.sort((a, b) => b.p.compareTo(a.p));
  final start = _int(doc['speechStartMs']);
  return WhisperLanguageResult(
    top: List<WhisperLanguageProbability>.unmodifiable(top),
    speechStart: start == null || start < 0 ? null : Duration(milliseconds: start),
  );
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite) return v.round();
  return null;
}

double? _double(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  return null;
}

/// Maps a `dv_status` to the Dart error kind.
WhisperErrorKind errorKindOf(int status) => switch (status) {
      DvStatus.modelLoad => WhisperErrorKind.modelLoadFailed,
      DvStatus.wavFormat => WhisperErrorKind.invalidAudio,
      DvStatus.io => WhisperErrorKind.io,
      DvStatus.oom => WhisperErrorKind.outOfMemory,
      DvStatus.cancelled => WhisperErrorKind.cancelled,
      DvStatus.inference => WhisperErrorKind.inference,
      DvStatus.busy => WhisperErrorKind.busy,
      DvStatus.vadModel => WhisperErrorKind.vadModelMissing,
      DvStatus.noSpeech => WhisperErrorKind.noSpeech,
      _ => WhisperErrorKind.internal,
    };

/// A [WhisperException] for a `dv_status`; [detail] names the code, never paths or text.
WhisperException exceptionOf(int status, [String? context]) {
  final name = statusName(status);
  return WhisperException(errorKindOf(status), context == null ? name : '$context: $name');
}

/// The `DV_*` name of a status code.
String statusName(int status) => switch (status) {
      DvStatus.ok => 'DV_OK',
      DvStatus.invalidArg => 'DV_ERR_INVALID_ARG',
      DvStatus.modelLoad => 'DV_ERR_MODEL_LOAD',
      DvStatus.wavFormat => 'DV_ERR_WAV_FORMAT',
      DvStatus.io => 'DV_ERR_IO',
      DvStatus.oom => 'DV_ERR_OOM',
      DvStatus.cancelled => 'DV_ERR_CANCELLED',
      DvStatus.inference => 'DV_ERR_INFERENCE',
      DvStatus.busy => 'DV_ERR_BUSY',
      DvStatus.vadModel => 'DV_ERR_VAD_MODEL',
      DvStatus.noSpeech => 'DV_ERR_NO_SPEECH',
      DvStatus.internal => 'DV_ERR_INTERNAL',
      _ => 'status $status',
    };

/// Maps `dv_job_state` (unknown values read as running).
WhisperJobState jobStateOf(int state) => switch (state) {
      DvJobState.paused => WhisperJobState.paused,
      DvJobState.succeeded => WhisperJobState.succeeded,
      DvJobState.failed => WhisperJobState.failed,
      DvJobState.cancelled => WhisperJobState.cancelled,
      _ => WhisperJobState.running,
    };

/// Maps `dv_phase` (unknown values read as preparing).
WhisperPhase phaseOf(int phase) => switch (phase) {
      1 => WhisperPhase.vad,
      2 => WhisperPhase.encoding,
      3 => WhisperPhase.decoding,
      _ => WhisperPhase.preparing,
    };

/// The status sample the job publishes.
WhisperJobStatus statusOf(DvJobStatusData s) => WhisperJobStatus(
      state: jobStateOf(s.state),
      phase: phaseOf(s.phase),
      fraction: (s.progressPermille / 1000).clamp(0.0, 1.0),
      chunkIndex: s.chunkIndex,
      chunkCount: s.chunkCount,
      chunksCompleted: s.chunksCompleted,
      processed: Duration(milliseconds: s.processedMs < 0 ? 0 : s.processedMs),
      computeTime: Duration(milliseconds: s.computeMs < 0 ? 0 : s.computeMs),
      threads: s.threads,
      language: s.language,
      languageP: s.languageP,
    );

/// Model params of [options].
DvModelParams modelParamsOf(WhisperModelOptions options) {
  final dtw = options.dtwPreset?.nativeValue ?? 0;
  return DvModelParams(useGpu: options.preferGpu, flashAttn: options.flashAttention && dtw == 0, dtwPreset: dtw);
}

/// Thread count clamped to the ABI's 1..8.
int clampThreads(int n) => n.clamp(1, 8);

/// Job params of a transcription request.
DvJobParams transcribeParamsOf(WhisperTranscribeRequest r) {
  final vad = r.vad;
  final d = r.decode;
  return DvJobParams(
    mode: DvJobMode.transcribe,
    wavPath: r.wavPath,
    rangeStartMs: r.rangeStart.inMilliseconds < 0 ? 0 : r.rangeStart.inMilliseconds,
    rangeEndMs: r.rangeEnd == null ? -1 : r.rangeEnd!.inMilliseconds,
    language: r.language,
    nThreads: clampThreads(r.threads),
    chunkTargetMs: r.chunkTarget.inMilliseconds,
    chunkSearchMs: r.chunkSearch.inMilliseconds,
    vadEnabled: vad != null,
    vadModelPath: vad?.modelPath,
    vadThreshold: vad?.threshold ?? 0.5,
    vadMinSpeechMs: vad?.minSpeech.inMilliseconds ?? 250,
    vadMinSilenceMs: vad?.minSilence.inMilliseconds ?? 300,
    vadSpeechPadMs: vad?.speechPad.inMilliseconds ?? 100,
    vadSamplesOverlapS: vad?.samplesOverlapSeconds ?? 0.1,
    tokenTimestamps: d.tokenTimestamps,
    noSpeechThold: d.noSpeechThreshold,
    entropyThold: d.entropyThreshold,
    logprobThold: d.logprobThreshold,
    temperatureInc: d.temperatureInc,
    beamSize: d.beamSize,
    bestOf: d.bestOf,
    suppressNst: d.suppressNonSpeech,
    carryPromptWords: r.carryPromptWords.clamp(0, 40),
    initialPrompt: r.initialPrompt,
  );
}

/// Job params of a language-detection request.
DvJobParams detectParamsOf(WhisperDetectRequest r) {
  final vad = r.vad;
  return DvJobParams(
    mode: DvJobMode.detectLanguage,
    wavPath: r.wavPath,
    language: 'auto',
    nThreads: clampThreads(r.threads),
    vadEnabled: vad != null,
    vadModelPath: vad?.modelPath,
    vadThreshold: vad?.threshold ?? 0.5,
    vadMinSpeechMs: vad?.minSpeech.inMilliseconds ?? 250,
    vadMinSilenceMs: vad?.minSilence.inMilliseconds ?? 300,
    vadSpeechPadMs: vad?.speechPad.inMilliseconds ?? 100,
    vadSamplesOverlapS: vad?.samplesOverlapSeconds ?? 0.1,
    carryPromptWords: 0,
    detectMaxSpeechMs: r.maxSpeech.inMilliseconds,
    detectSearchMs: r.searchWindow.inMilliseconds,
  );
}

/// Decodes NUL-terminated native UTF-8. The shim guarantees valid UTF-8; a violation asserts in
/// debug and is replaced (U+FFFD) in release, so invalid bytes never surface as an exception.
String decodeNativeUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    assert(false, 'dv_whisper returned invalid UTF-8');
    return utf8.decode(bytes, allowMalformed: true);
  }
}
