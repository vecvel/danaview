// OWNER: QA-06
//
// Aggregation, regression gate and rendering of the accuracy eval (ai.md §14.2, §16.5):
// corpus-level WER/CER per tier and language, cue boundary error, hallucination rate on non-speech
// clips, CPS distribution per script profile and host speed. The gate compares against
// tool/eval/baseline.json: WER (CER for CJK and no-space scripts) may not regress by more than 1.0
// point absolute per tier and language, and the median cue boundary error may not exceed 200 ms.

import 'dart:convert';

import 'package:danaview_transcription/danaview_transcription.dart';

import 'manifest.dart';
import 'scoring.dart';
import 'timing.dart';

/// Largest allowed absolute WER/CER regression per tier and language (ai.md §14.2).
const double maxErrorRateRegression = 0.010;

/// Largest allowed median cue boundary error, ms (ai.md §14.2).
const double maxMedianBoundaryErrorMs = 200;

/// The measured outcome of one clip on one tier.
final class ClipResult {
  /// Creates a result.
  const ClipResult({
    required this.clip,
    required this.tier,
    required this.ran,
    required this.durationMs,
    this.status = 'ok',
    this.wordEdits = EditCounts.zero,
    this.charEdits = EditCounts.zero,
    this.boundary = BoundaryErrors.none,
    this.cues = const [],
    this.cpsLimit = 0,
    this.rawWordCount = 0,
    this.wordCount = 0,
    this.loadMs = 0,
    this.computeMs = 0,
    this.wallMs = 0,
    this.peakRssBytes = 0,
  });

  /// The clip.
  final EvalClip clip;

  /// Tier name (`fast`, `balanced`, `accurate`, or `fixture` in smoke mode).
  final String tier;

  /// The runner finished the job.
  final bool ran;

  /// `ok`, or why the clip did not run (`unavailable`, `checksum`, a runner state).
  final String status;

  /// Clip length, ms.
  final int durationMs;

  /// WER counts (graphemes for CJK and no-space scripts).
  final EditCounts wordEdits;

  /// CER counts.
  final EditCounts charEdits;

  /// Cue boundary errors against the reference cues.
  final BoundaryErrors boundary;

  /// Generated cues.
  final List<TimedCue> cues;

  /// The layout's reading-speed limit.
  final double cpsLimit;

  /// Words before the normalizer.
  final int rawWordCount;

  /// Words after the normalizer.
  final int wordCount;

  /// Model load, ms.
  final int loadMs;

  /// Compute, ms.
  final int computeMs;

  /// Wall, ms.
  final int wallMs;

  /// Peak RSS of the runner.
  final int peakRssBytes;

  /// A non-speech clip produced words that survived the normalizer.
  bool get hallucinated => clip.kind.isNonSpeech && wordCount > 0;

  /// JSON form (no transcript text: the report lists counts and timings only).
  Map<String, Object?> toJson() => {
        'id': clip.id,
        'tier': tier,
        'language': clip.language,
        'kind': clip.kind.name,
        'status': status,
        'durationMs': durationMs,
        if (ran) ...{
          'wer': wordEdits.toJson(),
          'cer': charEdits.toJson(),
          'boundary': {
            'medianMs': boundary.medianMs,
            'p90Ms': boundary.p90Ms,
            'matched': boundary.matchedCues,
            'reference': boundary.referenceCues,
          },
          'cues': cues.length,
          'cps': cpsDistribution(cues, cpsLimit).toJson(),
          'rawWords': rawWordCount,
          'words': wordCount,
          'loadMs': loadMs,
          'computeMs': computeMs,
          'wallMs': wallMs,
          'peakRssBytes': peakRssBytes,
        },
      };
}

/// Aggregates of one tier and language.
final class LanguageSummary {
  /// Creates a summary.
  const LanguageSummary({
    required this.language,
    required this.clips,
    required this.wordEdits,
    required this.charEdits,
    required this.boundary,
  });

  /// whisper language code.
  final String language;

  /// Speech clips that ran.
  final int clips;

  /// Pooled WER counts.
  final EditCounts wordEdits;

  /// Pooled CER counts.
  final EditCounts charEdits;

  /// Pooled boundary errors.
  final BoundaryErrors boundary;

  /// The gated error rate: WER, or CER for CJK and no-space scripts.
  double get errorRate => usesWordErrorRate(language) ? wordEdits.rate : charEdits.rate;

  /// Name of [errorRate].
  String get metric => usesWordErrorRate(language) ? 'wer' : 'cer';
}

/// Aggregates of one tier.
final class TierSummary {
  /// Builds the summary of [results] (all of one tier).
  factory TierSummary.of(String tier, List<ClipResult> results) {
    final byLang = <String, List<ClipResult>>{};
    for (final r in results) {
      if (r.ran && r.clip.kind == ClipKind.speech) (byLang[r.clip.language] ??= []).add(r);
    }
    final languages = <LanguageSummary>[];
    for (final lang in byLang.keys.toList()..sort()) {
      final rs = byLang[lang]!;
      languages.add(LanguageSummary(
        language: lang,
        clips: rs.length,
        wordEdits: rs.fold(EditCounts.zero, (a, r) => a + r.wordEdits),
        charEdits: rs.fold(EditCounts.zero, (a, r) => a + r.charEdits),
        boundary: rs.fold(BoundaryErrors.none, (a, r) => a + r.boundary),
      ));
    }
    final nonSpeech = [for (final r in results) if (r.ran && r.clip.kind.isNonSpeech) r];
    final cpsByScript = <ScriptProfile, CpsDistribution>{};
    for (final r in results) {
      if (!r.ran || r.clip.kind != ClipKind.speech) continue;
      final script = languageForWhisperCode(r.clip.language)?.script ?? ScriptProfile.spaceDelimited;
      final d = cpsDistribution(r.cues, r.cpsLimit);
      cpsByScript[script] = cpsByScript[script] == null ? d : cpsByScript[script]! + d;
    }
    final ran = [for (final r in results) if (r.ran) r];
    return TierSummary._(
      tier: tier,
      languages: languages,
      nonSpeechClips: nonSpeech.length,
      hallucinatedClips: nonSpeech.where((r) => r.hallucinated).length,
      rawHallucinatedClips: nonSpeech.where((r) => r.rawWordCount > 0).length,
      nonSpeechWords: nonSpeech.fold(0, (a, r) => a + r.wordCount),
      nonSpeechMs: nonSpeech.fold(0, (a, r) => a + r.durationMs),
      cpsByScript: cpsByScript,
      audioMs: ran.fold(0, (a, r) => a + r.durationMs),
      computeMs: ran.fold(0, (a, r) => a + r.computeMs),
      loadMsMedian: percentile([for (final r in ran) r.loadMs.toDouble()], 50),
      peakRssBytes: ran.fold(0, (a, r) => r.peakRssBytes > a ? r.peakRssBytes : a),
      failed: [for (final r in results) if (!r.ran && r.status != 'unavailable') r.clip.id],
      unavailable: [for (final r in results) if (r.status == 'unavailable') r.clip.id],
    );
  }

  TierSummary._({
    required this.tier,
    required this.languages,
    required this.nonSpeechClips,
    required this.hallucinatedClips,
    required this.rawHallucinatedClips,
    required this.nonSpeechWords,
    required this.nonSpeechMs,
    required this.cpsByScript,
    required this.audioMs,
    required this.computeMs,
    required this.loadMsMedian,
    required this.peakRssBytes,
    required this.failed,
    required this.unavailable,
  });

  /// Tier name.
  final String tier;

  /// Per-language aggregates, sorted by code.
  final List<LanguageSummary> languages;

  /// Non-speech clips that ran.
  final int nonSpeechClips;

  /// Non-speech clips with words after the normalizer.
  final int hallucinatedClips;

  /// Non-speech clips with words before the normalizer.
  final int rawHallucinatedClips;

  /// Words produced on non-speech clips after the normalizer.
  final int nonSpeechWords;

  /// Total non-speech audio, ms.
  final int nonSpeechMs;

  /// CPS distribution per script profile.
  final Map<ScriptProfile, CpsDistribution> cpsByScript;

  /// Audio processed, ms.
  final int audioMs;

  /// Compute, ms.
  final int computeMs;

  /// Median model load, ms.
  final double? loadMsMedian;

  /// Highest runner peak RSS.
  final int peakRssBytes;

  /// Clips whose job failed.
  final List<String> failed;

  /// Clips whose audio was not available on this host.
  final List<String> unavailable;

  /// Hallucination rate after the normalizer (null without non-speech clips).
  double? get hallucinationRate => nonSpeechClips == 0 ? null : hallucinatedClips / nonSpeechClips;

  /// Hallucination rate of raw whisper output.
  double? get rawHallucinationRate => nonSpeechClips == 0 ? null : rawHallucinatedClips / nonSpeechClips;

  /// Compute time per audio time (host CPU).
  double? get realTimeFactor => audioMs == 0 ? null : computeMs / audioMs;

  /// JSON form.
  Map<String, Object?> toJson() => {
        'languages': {
          for (final l in languages)
            l.language: {
              'clips': l.clips,
              'metric': l.metric,
              'errorRate': l.errorRate,
              'wer': l.wordEdits.toJson(),
              'cer': l.charEdits.toJson(),
              'boundaryMedianMs': l.boundary.medianMs,
              'boundaryP90Ms': l.boundary.p90Ms,
              'boundaryMatched': l.boundary.matchedFraction,
            },
        },
        'hallucination': {
          'clips': nonSpeechClips,
          'hallucinated': hallucinatedClips,
          'rate': hallucinationRate,
          'rawRate': rawHallucinationRate,
          'wordsPerMinute': nonSpeechMs == 0 ? null : nonSpeechWords / (nonSpeechMs / 60000),
        },
        'cps': {for (final e in cpsByScript.entries) e.key.name: e.value.toJson()},
        'speed': {
          'audioMs': audioMs,
          'computeMs': computeMs,
          'realTimeFactor': realTimeFactor,
          'loadMsMedian': loadMsMedian,
          'peakRssBytes': peakRssBytes,
        },
        'failed': failed,
        'unavailable': unavailable,
      };
}

/// One regression-gate finding.
final class GateFailure {
  /// Creates a finding.
  const GateFailure(this.tier, this.subject, this.message);

  /// Tier.
  final String tier;

  /// Language or clip id.
  final String subject;

  /// What failed.
  final String message;

  @override
  String toString() => '$tier/$subject: $message';
}

/// Checks [summaries] against [baseline] (`{"tiers": {tier: {lang: {"errorRate": x}}}}`): no clip
/// may fail to run, WER/CER may not regress by more than [maxErrorRateRegression], and the median
/// boundary error may not exceed [maxMedianBoundaryErrorMs].
List<GateFailure> checkGate(List<TierSummary> summaries, Map<String, Object?> baseline) {
  final out = <GateFailure>[];
  final tiers = (baseline['tiers'] as Map<String, Object?>?) ?? const {};
  for (final s in summaries) {
    for (final id in s.failed) {
      out.add(GateFailure(s.tier, id, 'the job did not finish'));
    }
    final base = (tiers[s.tier] as Map<String, Object?>?) ?? const {};
    for (final l in s.languages) {
      final b = (base[l.language] as Map<String, Object?>?)?['errorRate'];
      if (b is num && l.errorRate > b + maxErrorRateRegression + 1e-12) {
        out.add(GateFailure(s.tier, l.language,
            '${l.metric.toUpperCase()} ${_pct(l.errorRate)} regressed from ${_pct(b.toDouble())} (limit +${_pct(maxErrorRateRegression)})'));
      }
      final median = l.boundary.medianMs;
      if (median != null && median > maxMedianBoundaryErrorMs) {
        out.add(GateFailure(s.tier, l.language, 'median cue boundary error ${median.round()} ms > ${maxMedianBoundaryErrorMs.round()} ms'));
      }
    }
  }
  return out;
}

/// The baseline document for [summaries] (written with `DV_EVAL_UPDATE_BASELINE=1`).
Map<String, Object?> baselineOf(List<TierSummary> summaries, {required String engine}) => {
      'schema': 1,
      'engine': engine,
      'tiers': {
        for (final s in summaries)
          s.tier: {
            for (final l in s.languages) l.language: {'metric': l.metric, 'errorRate': l.errorRate},
          },
      },
    };

/// The full JSON report.
String reportJson({
  required List<TierSummary> summaries,
  required List<ClipResult> results,
  required Map<String, Object?> meta,
  required List<GateFailure> gate,
}) =>
    const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      ...meta,
      'gate': {'passed': gate.isEmpty, 'failures': [for (final g in gate) g.toString()]},
      'tiers': {for (final s in summaries) s.tier: s.toJson()},
      'clips': [for (final r in results) r.toJson()],
    });

/// Markdown tables for docs/v1.1/editor/ai-eval.md (the generated results section).
String reportMarkdown({required List<TierSummary> summaries, required Map<String, Object?> meta, required List<GateFailure> gate}) {
  final b = StringBuffer()
    ..writeln('Run: ${meta['date']} · engine whisper.cpp ${meta['engine']} · host ${meta['host']} (CPU) · '
        'manifest ${meta['clips']} clips · mode ${meta['mode']}')
    ..writeln()
    ..writeln('**Accuracy (WER; CER for zh/ja and no-space scripts), corpus level**')
    ..writeln()
    ..writeln('| Tier | Language | Clips | Metric | Error rate | S / D / I | Boundary median (ms) | Boundary p90 (ms) |')
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final s in summaries) {
    if (s.languages.isEmpty) b.writeln('| ${s.tier} | — | 0 | — | — | — | — | — |');
    for (final l in s.languages) {
      final e = usesWordErrorRate(l.language) ? l.wordEdits : l.charEdits;
      b.writeln('| ${s.tier} | ${l.language} | ${l.clips} | ${l.metric.toUpperCase()} | ${_pct(l.errorRate)} | '
          '${e.substitutions} / ${e.deletions} / ${e.insertions} | ${_num(l.boundary.medianMs)} | ${_num(l.boundary.p90Ms)} |');
    }
  }
  b
    ..writeln()
    ..writeln('**Hallucination on non-speech clips (silence, noise, music)**')
    ..writeln()
    ..writeln('| Tier | Clips | Raw whisper output with words | After normalizer | Words per minute after normalizer |')
    ..writeln('|---|---|---|---|---|');
  for (final s in summaries) {
    final j = s.toJson()['hallucination']! as Map<String, Object?>;
    b.writeln('| ${s.tier} | ${s.nonSpeechClips} | ${_pctN(s.rawHallucinationRate)} | ${_pctN(s.hallucinationRate)} | '
        '${_num(j['wordsPerMinute'] as double?)} |');
  }
  b
    ..writeln()
    ..writeln('**Reading speed of generated cues (Standard preset)**')
    ..writeln()
    ..writeln('| Tier | Script | Cues | Limit (cps) | p50 | p90 | Max | Over limit |')
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final s in summaries) {
    for (final e in s.cpsByScript.entries) {
      final d = e.value;
      b.writeln('| ${s.tier} | ${e.key.name} | ${d.values.length} | ${_num(d.limit)} | ${_num(d.p50)} | ${_num(d.p90)} | '
          '${_num(d.max)} | ${_pct(d.overLimitFraction)} |');
    }
  }
  b
    ..writeln()
    ..writeln('**Host speed (CPU, not a device figure)**')
    ..writeln()
    ..writeln('| Tier | Audio (s) | Compute (s) | Compute / audio | Model load median (ms) | Peak RSS (MB) |')
    ..writeln('|---|---|---|---|---|---|');
  for (final s in summaries) {
    b.writeln('| ${s.tier} | ${_num(s.audioMs / 1000)} | ${_num(s.computeMs / 1000)} | ${_num(s.realTimeFactor, 3)} | '
        '${_num(s.loadMsMedian)} | ${_num(s.peakRssBytes / (1024 * 1024))} |');
  }
  final missing = {for (final s in summaries) ...s.unavailable};
  if (missing.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Clips not available on this host: ${(missing.toList()..sort()).join(', ')}.');
  }
  b
    ..writeln()
    ..writeln(gate.isEmpty ? 'Gate: passed.' : 'Gate: FAILED: ${gate.join('; ')}.');
  return b.toString();
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _pctN(double? v) => v == null ? '—' : _pct(v);
String _num(double? v, [int digits = 1]) => v == null ? '—' : v.toStringAsFixed(digits);
