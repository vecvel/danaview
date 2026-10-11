// OWNER: AI-07
//
// Pure mapping between the Dart API types and the C ABI values (ai.md §4.5/§4.7):
//  * the schema-1 segment JSON of `vw_job_take_segments_json`
//    ([{i, c, t0, t1, text, nsp, lp, w:[{t, t0, t1, p}]}], times in ms relative to the WAV start),
//  * the language JSON of `vw_job_language_probs_json` ({lang:[{code, p}], speechStartMs}),
//  * `vw_status` -> [WhisperErrorKind], job state and phase codes,
//  * requests -> [VwJobParams].
// Decoding is tolerant: unknown keys are ignored, a malformed element is skipped, wrong types fall
// back to defaults. Nothing here logs; transcript text never leaves the returned objects.

import 'dart:convert';

import 'vw_bindings.dart';
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

/// Decodes one `vw_job_take_segments_json` page. [firstIndex] is the absolute index of the first
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

/// Maps a `vw_status` to the Dart error kind.
WhisperErrorKind errorKindOf(int status) => switch (status) {
      VwStatus.modelLoad => WhisperErrorKind.modelLoadFailed,
      VwStatus.wavFormat => WhisperErrorKind.invalidAudio,
      VwStatus.io => WhisperErrorKind.io,
      VwStatus.oom => WhisperErrorKind.outOfMemory,
      VwStatus.cancelled => WhisperErrorKind.cancelled,
      VwStatus.inference => WhisperErrorKind.inference,
      VwStatus.busy => WhisperErrorKind.busy,
      VwStatus.vadModel => WhisperErrorKind.vadModelMissing,
      VwStatus.noSpeech => WhisperErrorKind.noSpeech,
      _ => WhisperErrorKind.internal,
    };

/// A [WhisperException] for a `vw_status`; [detail] names the code, never paths or text.
WhisperException exceptionOf(int status, [String? context]) {
  final name = statusName(status);
  return WhisperException(errorKindOf(status), context == null ? name : '$context: $name');
}

/// The `VW_*` name of a status code.
String statusName(int status) => switch (status) {
      VwStatus.ok => 'VW_OK',
      VwStatus.invalidArg => 'VW_ERR_INVALID_ARG',
      VwStatus.modelLoad => 'VW_ERR_MODEL_LOAD',
      VwStatus.wavFormat => 'VW_ERR_WAV_FORMAT',
      VwStatus.io => 'VW_ERR_IO',
      VwStatus.oom => 'VW_ERR_OOM',
      VwStatus.cancelled => 'VW_ERR_CANCELLED',
      VwStatus.inference => 'VW_ERR_INFERENCE',
      VwStatus.busy => 'VW_ERR_BUSY',
      VwStatus.vadModel => 'VW_ERR_VAD_MODEL',
      VwStatus.noSpeech => 'VW_ERR_NO_SPEECH',
      VwStatus.internal => 'VW_ERR_INTERNAL',
      _ => 'status $status',
    };

/// Maps `vw_job_state` (unknown values read as running).
WhisperJobState jobStateOf(int state) => switch (state) {
      VwJobState.paused => WhisperJobState.paused,
      VwJobState.succeeded => WhisperJobState.succeeded,
      VwJobState.failed => WhisperJobState.failed,
      VwJobState.cancelled => WhisperJobState.cancelled,
      _ => WhisperJobState.running,
    };

/// Maps `vw_phase` (unknown values read as preparing).
WhisperPhase phaseOf(int phase) => switch (phase) {
      1 => WhisperPhase.vad,
      2 => WhisperPhase.encoding,
      3 => WhisperPhase.decoding,
      _ => WhisperPhase.preparing,
    };

/// The status sample the job publishes.
WhisperJobStatus statusOf(VwJobStatusData s) => WhisperJobStatus(
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
VwModelParams modelParamsOf(WhisperModelOptions options) {
  final dtw = options.dtwPreset?.nativeValue ?? 0;
  return VwModelParams(useGpu: options.preferGpu, flashAttn: options.flashAttention && dtw == 0, dtwPreset: dtw);
}

/// Thread count clamped to the ABI's 1..8.
int clampThreads(int n) => n.clamp(1, 8);

/// Job params of a transcription request.
VwJobParams transcribeParamsOf(WhisperTranscribeRequest r) {
  final vad = r.vad;
  final d = r.decode;
  return VwJobParams(
    mode: VwJobMode.transcribe,
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
VwJobParams detectParamsOf(WhisperDetectRequest r) {
  final vad = r.vad;
  return VwJobParams(
    mode: VwJobMode.detectLanguage,
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
    assert(false, 'vw_whisper returned invalid UTF-8');
    return utf8.decode(bytes, allowMalformed: true);
  }
}
