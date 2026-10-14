// OWNER: QA-06
//
// The eval run (ai.md §16.5): resolves every clip's WAV (repo file checked against its sha256,
// synthetic clip generated, remote clip read from the clip cache the nightly script fills), runs every
// available tier through the native runner and the app's normalizer and segmenter, scores the
// results and applies the regression gate. Smoke mode uses AI-03's deterministic fixture model
// (no download): it proves the whole chain runs and that the hallucination detector fires on audio
// the fixture "transcribes" regardless of content.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:path/path.dart' as p;

import 'manifest.dart';
import 'report.dart';
import 'runner.dart';
import 'scoring.dart';
import 'synth_audio.dart';
import 'timing.dart';

/// Configuration of one eval run.
final class EvalConfig {
  /// Creates a config.
  const EvalConfig({
    required this.runnerPath,
    required this.manifestPath,
    required this.outDir,
    this.modelsDir,
    this.clipCacheDir,
    this.tiers = const ['fast', 'balanced', 'accurate'],
    this.smoke = false,
    this.baselinePath,
    this.updateBaseline = false,
    this.docPath,
    this.decode = const DecodeConfig(),
  });

  /// Reads the `DV_EVAL_*` environment (see tool/eval/README.md); null when DV_EVAL_RUNNER is unset.
  static EvalConfig? fromEnvironment(Map<String, String> env, {required String packageRoot}) {
    final runner = env['DV_EVAL_RUNNER'];
    if (runner == null || runner.isEmpty) return null;
    String rel(String v) => p.isAbsolute(v) ? v : p.join(packageRoot, v);
    final threads = int.tryParse(env['DV_EVAL_THREADS'] ?? '') ?? 4;
    final vadThreshold = double.tryParse(env['DV_EVAL_VAD_THRESHOLD'] ?? '');
    final noSpeech = double.tryParse(env['DV_EVAL_NO_SPEECH_THRESHOLD'] ?? '');
    return EvalConfig(
      runnerPath: rel(runner),
      manifestPath: rel(env['DV_EVAL_MANIFEST'] ?? 'tool/eval/eval_set.json'),
      outDir: rel(env['DV_EVAL_OUT'] ?? 'build/ai_eval'),
      modelsDir: env['DV_EVAL_MODELS_DIR'] == null ? null : rel(env['DV_EVAL_MODELS_DIR']!),
      clipCacheDir: env['DV_EVAL_CLIP_CACHE'] == null ? null : rel(env['DV_EVAL_CLIP_CACHE']!),
      tiers: (env['DV_EVAL_TIERS'] ?? 'fast,balanced,accurate').split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      smoke: env['DV_EVAL_SMOKE'] == '1',
      baselinePath: rel(env['DV_EVAL_BASELINE'] ?? 'tool/eval/baseline.json'),
      updateBaseline: env['DV_EVAL_UPDATE_BASELINE'] == '1',
      docPath: env['DV_EVAL_WRITE_DOC'] == null ? null : rel(env['DV_EVAL_WRITE_DOC']!),
      decode: DecodeConfig(
        threads: threads,
        vadThreshold: vadThreshold ?? SpeechTuning.vadThreshold,
        noSpeechThreshold: noSpeech ?? SpeechTuning.noSpeechThreshold,
      ),
    );
  }

  /// `dv_eval_runner` path.
  final String runnerPath;

  /// Manifest path.
  final String manifestPath;

  /// Report directory.
  final String outDir;

  /// Directory holding the pinned model files (catalog file names); null = none.
  final String? modelsDir;

  /// Directory holding fetched remote clips as `<id>.wav`.
  final String? clipCacheDir;

  /// Tiers to run.
  final List<String> tiers;

  /// Smoke mode (fixture model, no accuracy gate).
  final bool smoke;

  /// Baseline for the gate.
  final String? baselinePath;

  /// Write the measured values as the new baseline.
  final bool updateBaseline;

  /// Rewrite the generated results section of this document.
  final String? docPath;

  /// Decode parameters (VAD path filled in per run).
  final DecodeConfig decode;
}

/// Outcome of [runEval].
final class EvalOutcome {
  /// Creates an outcome.
  const EvalOutcome({
    required this.summaries,
    required this.results,
    required this.gate,
    required this.markdown,
    required this.skippedTiers,
  });

  /// Per-tier summaries (tiers that ran).
  final List<TierSummary> summaries;

  /// Per-clip results.
  final List<ClipResult> results;

  /// Gate findings (empty = passed).
  final List<GateFailure> gate;

  /// The markdown results section.
  final String markdown;

  /// Tiers that did not run, with the reason.
  final Map<String, String> skippedTiers;
}

/// Markers of the generated section in docs/v1.1/editor/ai-eval.md.
const String docBeginMarker = '<!-- ai-eval:results:begin -->';

/// End marker.
const String docEndMarker = '<!-- ai-eval:results:end -->';

/// Runs the eval described by [config]; [log] receives progress lines (never transcript text).
Future<EvalOutcome> runEval(EvalConfig config, {void Function(String line)? log}) async {
  final say = log ?? (_) {};
  final manifest = EvalManifest.load(config.manifestPath);
  final runner = NativeRunner(config.runnerPath);
  final work = Directory(p.join(config.outDir, 'work'))..createSync(recursive: true);

  // Clip audio.
  final wavs = <String, String?>{};
  final status = <String, String>{};
  for (final clip in manifest.clips) {
    final (path, why) = await _resolveWav(clip, manifest, config, work.path);
    wavs[clip.id] = path;
    status[clip.id] = why;
  }

  // Models per tier.
  final tierModels = <String, String>{};
  final skipped = <String, String>{};
  String? vadPath;
  if (config.smoke) {
    final model = p.join(work.path, 'fixture-whisper.bin');
    if (!await runner.writeFixtureModels(modelPath: model)) throw StateError('the runner could not write the fixture model');
    tierModels['fixture'] = model;
  } else {
    for (final tier in config.tiers) {
      final spec = SpeechModelCatalog.models.where((m) => m.tier.name == tier).firstOrNull;
      if (spec == null) {
        skipped[tier] = 'unknown tier';
        continue;
      }
      final path = config.modelsDir == null ? null : p.join(config.modelsDir!, spec.fileName);
      if (path == null || !File(path).existsSync()) {
        skipped[tier] = '${spec.fileName} not in the model cache';
        continue;
      }
      tierModels[tier] = path;
    }
    final vad = config.modelsDir == null ? null : p.join(config.modelsDir!, SpeechModelCatalog.vad.fileName);
    if (vad != null && File(vad).existsSync()) vadPath = vad;
  }
  final decode = DecodeConfig(
    threads: config.decode.threads,
    vadModelPath: vadPath,
    vadThreshold: config.decode.vadThreshold,
    vadMinSpeechMs: config.decode.vadMinSpeechMs,
    vadMinSilenceMs: config.decode.vadMinSilenceMs,
    vadSpeechPadMs: config.decode.vadSpeechPadMs,
    noSpeechThreshold: config.decode.noSpeechThreshold,
    entropyThreshold: config.decode.entropyThreshold,
    logprobThreshold: config.decode.logprobThreshold,
    temperatureIncrement: config.decode.temperatureIncrement,
    chunkTargetMs: config.decode.chunkTargetMs,
    chunkSearchMs: config.decode.chunkSearchMs,
    carryPromptWords: config.decode.carryPromptWords,
    timeoutSeconds: config.decode.timeoutSeconds,
  );

  // Runs.
  final results = <ClipResult>[];
  var engine = '';
  for (final entry in tierModels.entries) {
    final tier = entry.key;
    for (final clip in manifest.clips) {
      final wav = wavs[clip.id];
      if (wav == null) {
        results.add(ClipResult(clip: clip, tier: tier, ran: false, durationMs: 0, status: status[clip.id]!));
        continue;
      }
      final durationMs = wavDurationMs(wav) ?? 0;
      final out = await runner.transcribe(modelPath: entry.value, wavPath: wav, language: clip.language, config: decode);
      if (out.engine.isNotEmpty) engine = out.engine;
      say('$tier ${clip.id}: ${out.state} (${out.computeMs} ms compute, ${out.segments.length} segments)');
      if (!out.finished) {
        results.add(ClipResult(clip: clip, tier: tier, ran: false, durationMs: durationMs, status: out.state));
        continue;
      }
      results.add(scoreClip(clip, tier, out, durationMs));
    }
  }

  final summaries = [for (final tier in tierModels.keys) TierSummary.of(tier, [for (final r in results) if (r.tier == tier) r])];
  Map<String, Object?> baseline = const {};
  if (!config.smoke && config.baselinePath != null && File(config.baselinePath!).existsSync()) {
    baseline = jsonDecode(File(config.baselinePath!).readAsStringSync()) as Map<String, Object?>;
  }
  final gate = config.smoke ? smokeChecks(summaries, results) : checkGate(summaries, baseline);
  final meta = <String, Object?>{
    'date': DateTime.now().toUtc().toIso8601String().substring(0, 10),
    'engine': engine.isEmpty ? '?' : engine,
    'host': _host(),
    'clips': manifest.clips.length,
    'mode': config.smoke ? 'smoke (fixture model)' : 'models: ${tierModels.keys.join(', ')}${vadPath == null ? '' : ' + VAD'}',
    'decode': decode.toJson(),
    'skippedTiers': skipped,
  };
  final markdown = reportMarkdown(summaries: summaries, meta: meta, gate: gate);
  Directory(config.outDir).createSync(recursive: true);
  File(p.join(config.outDir, 'report.json'))
      .writeAsStringSync(reportJson(summaries: summaries, results: results, meta: meta, gate: gate));
  File(p.join(config.outDir, 'report.md')).writeAsStringSync(markdown);
  if (!config.smoke && config.updateBaseline && config.baselinePath != null && summaries.isNotEmpty) {
    File(config.baselinePath!)
        .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baselineOf(summaries, engine: engine))}\n');
  }
  if (!config.smoke && config.docPath != null && summaries.isNotEmpty) {
    writeResultsSection(config.docPath!, markdown);
  }
  return EvalOutcome(summaries: summaries, results: results, gate: gate, markdown: markdown, skippedTiers: skipped);
}

/// Scores one finished runner output.
ClipResult scoreClip(EvalClip clip, String tier, RunnerOutput out, int durationMs) {
  final processed = processTranscript(out.segments, language: clip.language, durationMs: durationMs);
  final ref = clip.reference;
  final hyp = processed.text;
  return ClipResult(
    clip: clip,
    tier: tier,
    ran: true,
    durationMs: durationMs,
    wordEdits: ref == null ? EditCounts.zero : wordEdits(ref.text, hyp, clip.language),
    charEdits: ref == null ? EditCounts.zero : characterEdits(ref.text, hyp),
    boundary: ref == null || ref.cues.isEmpty ? BoundaryErrors.none : boundaryErrors(ref.cues, processed.cues),
    cues: processed.cues,
    cpsLimit: processed.cpsLimit,
    rawWordCount: processed.rawWords.length,
    wordCount: processed.words.length,
    loadMs: out.loadMs,
    computeMs: out.computeMs,
    wallMs: out.wallMs,
    peakRssBytes: out.peakRssBytes,
  );
}

/// Smoke-mode checks: every available clip ran, every speech clip produced cues, and the
/// hallucination detector flagged every non-speech clip in the raw output (the fixture model
/// "speaks" over any audio).
List<GateFailure> smokeChecks(List<TierSummary> summaries, List<ClipResult> results) {
  final out = <GateFailure>[];
  for (final s in summaries) {
    for (final id in s.failed) {
      out.add(GateFailure(s.tier, id, 'the job did not finish'));
    }
    if (s.nonSpeechClips > 0 && s.rawHallucinationRate != 1) {
      out.add(GateFailure(s.tier, 'hallucination', 'raw rate ${s.rawHallucinationRate} != 1 on the fixture model'));
    }
  }
  for (final r in results) {
    if (r.ran && r.clip.kind == ClipKind.speech && r.cues.isEmpty) out.add(GateFailure(r.tier, r.clip.id, 'no cues'));
  }
  if (!results.any((r) => r.ran)) out.add(const GateFailure('fixture', '*', 'no clip ran'));
  return out;
}

/// Replaces the text between [docBeginMarker] and [docEndMarker] in [docPath] with [markdown].
void writeResultsSection(String docPath, String markdown) {
  final file = File(docPath);
  final doc = file.readAsStringSync();
  final a = doc.indexOf(docBeginMarker);
  final b = doc.indexOf(docEndMarker);
  if (a < 0 || b < a) throw StateError('$docPath has no generated results section');
  file.writeAsStringSync('${doc.substring(0, a + docBeginMarker.length)}\n$markdown${doc.substring(b)}');
}

Future<(String?, String)> _resolveWav(EvalClip clip, EvalManifest manifest, EvalConfig config, String work) async {
  switch (clip.source) {
    case ClipSource.repo:
      final path = p.normalize(p.join(manifest.directory, clip.path));
      final f = File(path);
      if (!f.existsSync()) return (null, 'unavailable');
      final digest = sha256.convert(await f.readAsBytes()).toString();
      if (digest != clip.sha256) return (null, 'checksum');
      return (path, 'ok');
    case ClipSource.synthetic:
      final path = p.join(work, '${clip.id}.wav');
      await writeSynthWav(clip.synth!, path);
      return (path, 'ok');
    case ClipSource.remote:
      // The nightly script downloads, verifies (sha256, bytes) and converts remote clips to
      // `<cache>/<id>.wav`; anything else means the clip is not available on this host.
      final dir = config.clipCacheDir;
      if (dir == null) return (null, 'unavailable');
      final path = p.join(dir, '${clip.id}.wav');
      if (!File(path).existsSync() || wavDurationMs(path) == null) return (null, 'unavailable');
      return (path, 'ok');
  }
}

String _host() {
  final v = Platform.version;
  final i = v.lastIndexOf('on "');
  return i < 0 ? Platform.operatingSystem : v.substring(i + 4).replaceAll('"', '');
}
