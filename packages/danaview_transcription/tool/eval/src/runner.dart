// OWNER: QA-06
//
// One eval run of one clip on one tier: the native host runner (tool/eval/native/dv_eval_runner,
// the same shim and whisper.cpp as the apps, CPU) transcribes the WAV with the SpeechTuning
// constants, then the app's own TranscriptNormalizer and DpCaptionSegmenter turn the raw segments
// into cues exactly as the pipeline does (ai.md §8.3, §9). The result carries the words before and
// after normalization, the cues and the runner's timings.

import 'dart:convert';
import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'timing.dart';

/// Decode parameters passed to the runner; defaults are [SpeechTuning].
final class DecodeConfig {
  /// Creates a config.
  const DecodeConfig({
    this.threads = 4,
    this.vadModelPath,
    this.vadThreshold = SpeechTuning.vadThreshold,
    this.vadMinSpeechMs = SpeechTuning.vadMinSpeechMs,
    this.vadMinSilenceMs = SpeechTuning.vadMinSilenceMs,
    this.vadSpeechPadMs = SpeechTuning.vadSpeechPadMs,
    this.noSpeechThreshold = SpeechTuning.noSpeechThreshold,
    this.entropyThreshold = SpeechTuning.entropyThreshold,
    this.logprobThreshold = SpeechTuning.logprobThreshold,
    this.temperatureIncrement = SpeechTuning.temperatureIncrement,
    this.chunkTargetMs = SpeechTuning.chunkTargetMs,
    this.chunkSearchMs = SpeechTuning.chunkSearchMs,
    this.carryPromptWords = SpeechTuning.carryPromptWords,
    this.timeoutSeconds = 3600,
  });

  /// Decoder threads.
  final int threads;

  /// Silero model path; null runs without VAD.
  final String? vadModelPath;

  /// VAD threshold.
  final double vadThreshold;

  /// VAD minimum speech, ms.
  final int vadMinSpeechMs;

  /// VAD minimum silence, ms.
  final int vadMinSilenceMs;

  /// VAD padding, ms.
  final int vadSpeechPadMs;

  /// No-speech threshold.
  final double noSpeechThreshold;

  /// Entropy threshold.
  final double entropyThreshold;

  /// Log-probability threshold.
  final double logprobThreshold;

  /// Temperature increment.
  final double temperatureIncrement;

  /// Chunk target, ms.
  final int chunkTargetMs;

  /// Chunk search window, ms.
  final int chunkSearchMs;

  /// Prompt carry words.
  final int carryPromptWords;

  /// Per-clip timeout.
  final int timeoutSeconds;

  /// Runner arguments.
  List<String> toArgs() => [
        '--threads', '$threads',
        if (vadModelPath != null) ...['--vad-model', vadModelPath!],
        '--vad-threshold', '$vadThreshold',
        '--vad-min-speech-ms', '$vadMinSpeechMs',
        '--vad-min-silence-ms', '$vadMinSilenceMs',
        '--vad-speech-pad-ms', '$vadSpeechPadMs',
        '--no-speech-thold', '$noSpeechThreshold',
        '--entropy-thold', '$entropyThreshold',
        '--logprob-thold', '$logprobThreshold',
        '--temperature-inc', '$temperatureIncrement',
        '--chunk-target-ms', '$chunkTargetMs',
        '--chunk-search-ms', '$chunkSearchMs',
        '--carry-prompt-words', '$carryPromptWords',
        '--timeout-s', '$timeoutSeconds',
      ];

  /// JSON form (recorded in the report).
  Map<String, Object?> toJson() => {
        'threads': threads,
        'vad': vadModelPath != null,
        'vadThreshold': vadThreshold,
        'vadMinSpeechMs': vadMinSpeechMs,
        'vadMinSilenceMs': vadMinSilenceMs,
        'vadSpeechPadMs': vadSpeechPadMs,
        'noSpeechThreshold': noSpeechThreshold,
        'entropyThreshold': entropyThreshold,
        'logprobThreshold': logprobThreshold,
        'temperatureIncrement': temperatureIncrement,
        'chunkTargetMs': chunkTargetMs,
        'chunkSearchMs': chunkSearchMs,
        'carryPromptWords': carryPromptWords,
      };
}

/// What the native runner reported for one job.
final class RunnerOutput {
  /// Creates an output.
  const RunnerOutput({
    required this.exitCode,
    required this.state,
    required this.engine,
    required this.loadMs,
    required this.wallMs,
    required this.computeMs,
    required this.processedMs,
    required this.peakRssBytes,
    required this.segments,
    this.error = 0,
  });

  /// Parses the runner's stdout document.
  factory RunnerOutput.parse(String stdout, int exitCode) {
    final Object? doc;
    try {
      doc = jsonDecode(stdout.trim());
    } on FormatException {
      return RunnerOutput.failed(exitCode, 'unparseable');
    }
    if (doc is! Map<String, Object?>) return RunnerOutput.failed(exitCode, 'unparseable');
    final model = (doc['model'] as Map<String, Object?>?) ?? const {};
    final job = (doc['job'] as Map<String, Object?>?) ?? const {};
    if (doc['error'] is String) return RunnerOutput.failed(exitCode, doc['error']! as String);
    return RunnerOutput(
      exitCode: exitCode,
      state: (job['state'] as String?) ?? 'unknown',
      error: (job['error'] as num?)?.toInt() ?? 0,
      engine: (doc['engine'] as String?) ?? '',
      loadMs: (model['loadMs'] as num?)?.toInt() ?? 0,
      wallMs: (job['wallMs'] as num?)?.toInt() ?? 0,
      computeMs: (job['computeMs'] as num?)?.toInt() ?? 0,
      processedMs: (job['processedMs'] as num?)?.toInt() ?? 0,
      peakRssBytes: (doc['peakRssBytes'] as num?)?.toInt() ?? 0,
      segments: decodeShimSegments(doc['segments']),
    );
  }

  /// A failed run.
  factory RunnerOutput.failed(int exitCode, String state) => RunnerOutput(
        exitCode: exitCode,
        state: state,
        engine: '',
        loadMs: 0,
        wallMs: 0,
        computeMs: 0,
        processedMs: 0,
        peakRssBytes: 0,
        segments: const [],
      );

  /// Runner exit code (0 = finished).
  final int exitCode;

  /// Job state name (`succeeded`, `failed`, ...) or a runner error (`model_load`, `unparseable`).
  final String state;

  /// `dv_status` of a failed job (10 = NO_SPEECH, a valid outcome).
  final int error;

  /// whisper.cpp version.
  final String engine;

  /// Model load time, ms.
  final int loadMs;

  /// Job wall time, ms.
  final int wallMs;

  /// Time inside whisper calls, ms.
  final int computeMs;

  /// Audio covered, ms.
  final int processedMs;

  /// Peak resident set size of the runner process.
  final int peakRssBytes;

  /// Segments in absolute source µs (the WAV starts at 0).
  final List<TranscriptSegment> segments;

  /// The job finished (with speech or with NO_SPEECH).
  bool get finished => exitCode == 0 && (state == 'succeeded' || (state == 'failed' && error == 10));
}

/// Decodes the shim's schema-1 segment array (`[{i, c, t0, t1, text, nsp, lp, w:[{t, t0, t1, p}]}]`,
/// ms) into transcript segments; malformed elements are skipped.
List<TranscriptSegment> decodeShimSegments(Object? raw) {
  if (raw is! List<Object?>) return const [];
  final out = <TranscriptSegment>[];
  for (final s in raw) {
    if (s is! Map<String, Object?>) continue;
    final t0 = (s['t0'] as num?)?.toInt();
    final t1 = (s['t1'] as num?)?.toInt();
    if (t0 == null || t1 == null || t0 < 0 || t1 < t0) continue;
    final words = <TranscriptWord>[];
    for (final w in (s['w'] as List<Object?>?) ?? const <Object?>[]) {
      if (w is! Map<String, Object?>) continue;
      final a = (w['t0'] as num?)?.toInt();
      final b = (w['t1'] as num?)?.toInt();
      final t = w['t'];
      if (a == null || b == null || t is! String || b < a) continue;
      words.add(TranscriptWord(
        text: t.trim(),
        startUs: a * 1000,
        endUs: b * 1000,
        probability: ((w['p'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
      ));
    }
    out.add(TranscriptSegment(
      startUs: t0 * 1000,
      endUs: t1 * 1000,
      text: (s['text'] as String?) ?? '',
      noSpeechProb: (s['nsp'] as num?)?.toDouble() ?? 0,
      avgLogProb: (s['lp'] as num?)?.toDouble() ?? 0,
      words: words,
    ));
  }
  return out;
}

/// The app pipeline's view of one transcript: normalized words and segmented cues.
final class ProcessedTranscript {
  /// Creates a result.
  const ProcessedTranscript({
    required this.rawWords,
    required this.words,
    required this.cues,
    required this.cpsLimit,
    required this.report,
  });

  /// Words as whisper produced them.
  final List<TranscriptWord> rawWords;

  /// Words after the normalizer.
  final List<TranscriptWord> words;

  /// Cues from the segmenter (Standard preset, 30 fps landscape project), ms.
  final List<TimedCue> cues;

  /// The layout's reading-speed limit for the language.
  final double cpsLimit;

  /// What the normalizer removed.
  final NormalizationReport report;

  /// Hypothesis text (normalized words joined by the language's rule).
  String get text => joinTranscriptWords(words.map((w) => w.text));
}

/// Runs the app's normalizer and segmenter over [segments] of a clip of [durationMs] in
/// [language] (ai.md §8.3, §9).
ProcessedTranscript processTranscript(List<TranscriptSegment> segments, {required String language, required int durationMs}) {
  final normalized = const TranscriptNormalizer().normalize(segments, language: language, unitEndUs: durationMs * 1000);
  final words = [for (final s in normalized.segments) ...s.words];
  const settings = SegmentationSettings();
  final context = SegmentationContext.forProject(languageCode: language, settings: settings, frameRate: FrameRate.fps30);
  final drafts = const DpCaptionSegmenter().segment(
    [for (final w in words) TimedWord(text: w.text, start: w.startUs, end: w.endUs, p: w.probability)],
    context,
  );
  return ProcessedTranscript(
    rawWords: [for (final s in segments) ...s.words],
    words: words,
    cues: [for (final d in drafts) TimedCue(d.range.start ~/ 1000, d.range.end ~/ 1000, d.text)],
    cpsLimit: CaptionLayout.resolve(settings, context.script).maxCps,
    report: normalized.report,
  );
}

/// Invokes the native runner at [runnerPath].
final class NativeRunner {
  /// Creates an invoker.
  const NativeRunner(this.runnerPath);

  /// Path of `dv_eval_runner`.
  final String runnerPath;

  /// Transcribes [wavPath] in [language] with [modelPath] and [config].
  Future<RunnerOutput> transcribe({
    required String modelPath,
    required String wavPath,
    required String language,
    DecodeConfig config = const DecodeConfig(),
  }) async {
    final r = await Process.run(
      runnerPath,
      ['transcribe', '--model', modelPath, '--wav', wavPath, '--language', language, ...config.toArgs()],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return RunnerOutput.parse(r.stdout as String, r.exitCode);
  }

  /// Writes the deterministic fixture whisper and VAD models (smoke mode).
  Future<bool> writeFixtureModels({required String modelPath, String? vadPath}) async {
    final r = await Process.run(runnerPath, [
      'write-fixture-model',
      '--out', modelPath,
      if (vadPath != null) ...['--vad-out', vadPath],
    ]);
    return r.exitCode == 0;
  }
}
