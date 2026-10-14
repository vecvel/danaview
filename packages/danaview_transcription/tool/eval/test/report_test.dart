// OWNER: QA-06
//
// Aggregation, the regression gate and the generated markdown section (tool/eval/src/report.dart,
// tool/eval/src/eval.dart).

import 'dart:io';

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../src/eval.dart';
import '../src/manifest.dart';
import '../src/report.dart';
import '../src/scoring.dart';
import '../src/timing.dart';

EvalClip _clip(String id, String lang, ClipKind kind) => EvalClip(
      id: id,
      language: lang,
      kind: kind,
      source: ClipSource.synthetic,
      licence: 'in-house',
      reference: kind == ClipKind.speech ? const ClipReference(text: 'x') : null,
    );

ClipResult _speech(String id, String lang, EditCounts w, EditCounts c, {List<int> boundary = const []}) => ClipResult(
      clip: _clip(id, lang, ClipKind.speech),
      tier: 'balanced',
      ran: true,
      durationMs: 10000,
      wordEdits: w,
      charEdits: c,
      boundary: BoundaryErrors(errorsMs: boundary, referenceCues: boundary.length ~/ 2, matchedCues: boundary.length ~/ 2),
      cues: const [TimedCue(0, 1000, 'abcdefghij'), TimedCue(1000, 2000, 'abcdefghijklmnopqrstu')],
      cpsLimit: 17,
      rawWordCount: 10,
      wordCount: 10,
      computeMs: 2000,
      loadMs: 100,
    );

ClipResult _nonSpeech(String id, {required int raw, required int kept}) => ClipResult(
      clip: _clip(id, 'en', ClipKind.music),
      tier: 'balanced',
      ran: true,
      durationMs: 30000,
      rawWordCount: raw,
      wordCount: kept,
      computeMs: 1000,
    );

EditCounts _e(int s, int d, int i, int n) => EditCounts(substitutions: s, deletions: d, insertions: i, referenceLength: n);

void main() {
  final results = [
    _speech('en-1', 'en', _e(1, 0, 0, 10), _e(2, 0, 0, 40), boundary: [100, 300]),
    _speech('en-2', 'en', _e(0, 1, 1, 10), _e(1, 1, 1, 40), boundary: [50, 50]),
    _speech('ja-1', 'ja', _e(2, 0, 0, 20), _e(2, 0, 0, 20)),
    _nonSpeech('music-1', raw: 3, kept: 0),
    _nonSpeech('music-2', raw: 2, kept: 2),
    ClipResult(clip: _clip('gone', 'en', ClipKind.speech), tier: 'balanced', ran: false, durationMs: 0, status: 'unavailable'),
  ];
  final summary = TierSummary.of('balanced', results);

  test('corpus-level aggregation per language', () {
    expect(summary.languages.map((l) => l.language), ['en', 'ja']);
    final en = summary.languages.first;
    expect(en.clips, 2);
    expect(en.metric, 'wer');
    expect(en.errorRate, closeTo(3 / 20, 1e-12));
    expect(en.boundary.medianMs, 75);
    expect(summary.languages.last.metric, 'cer');
    expect(summary.hallucinationRate, 0.5);
    expect(summary.rawHallucinationRate, 1);
    expect(summary.unavailable, ['gone']);
    expect(summary.failed, isEmpty);
    expect(summary.realTimeFactor, closeTo(8000 / 90000, 1e-12));
    expect(summary.cpsByScript[ScriptProfile.spaceDelimited]!.overLimitFraction, 0.5);
    expect(summary.cpsByScript.keys, containsAll([ScriptProfile.spaceDelimited, ScriptProfile.cjk]));
  });

  test('gate: passes without a baseline and within +1.0 point', () {
    expect(checkGate([summary], const {}), isEmpty);
    expect(
        checkGate([summary], {
          'tiers': {
            'balanced': {'en': {'errorRate': 0.145}, 'ja': {'errorRate': 0.10}},
          },
        }),
        isEmpty);
  });

  test('gate: a WER regression above 1.0 point, a slow boundary and a failed job fail', () {
    final failures = checkGate([summary], {
      'tiers': {
        'balanced': {'en': {'errorRate': 0.13}},
      },
    });
    expect(failures.single.subject, 'en');
    final slow = TierSummary.of('fast', [
      _speech('en-1', 'en', _e(0, 0, 0, 10), _e(0, 0, 0, 10), boundary: [250, 260]),
      ClipResult(clip: _clip('x', 'en', ClipKind.speech), tier: 'fast', ran: false, durationMs: 1, status: 'failed'),
    ]);
    final f = checkGate([slow], const {});
    expect(f.map((g) => g.subject), containsAll(['en', 'x']));
  });

  test('baseline document round-trips the gated rates', () {
    final b = baselineOf([summary], engine: '1.9.4');
    expect(checkGate([summary], b), isEmpty);
    expect(((b['tiers']! as Map)['balanced'] as Map)['ja'], {'metric': 'cer', 'errorRate': 0.1});
  });

  test('markdown has every table and the unavailable clips; the doc section is replaced in place', () async {
    final md = reportMarkdown(
        summaries: [summary],
        meta: {'date': '2026-10-15', 'engine': '1.9.4', 'host': 'macos arm64', 'clips': 6, 'mode': 'test'},
        gate: const []);
    expect(md, contains('| balanced | en | 2 | WER | 15.0% | 1 / 1 / 1 | 75.0 | 240.0 |'));
    expect(md, contains('| balanced | 2 | 100.0% | 50.0% |'));
    expect(md, contains('Clips not available on this host: gone.'));
    expect(md, contains('Gate: passed.'));

    final dir = await Directory.systemTemp.createTemp('dv_eval_doc');
    addTearDown(() => dir.delete(recursive: true));
    final doc = File(p.join(dir.path, 'ai-eval.md'))
      ..writeAsStringSync('# Title\n\n$docBeginMarker\nold\n$docEndMarker\n\nTail\n');
    writeResultsSection(doc.path, md);
    final text = doc.readAsStringSync();
    expect(text, startsWith('# Title\n\n$docBeginMarker\nRun: 2026-10-15'));
    expect(text, isNot(contains('old')));
    expect(text, endsWith('$docEndMarker\n\nTail\n'));
  });
}
