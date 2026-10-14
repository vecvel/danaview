// OWNER: QA-06
//
// End-to-end smoke of the eval chain with AI-03's deterministic fixture model: native runner ->
// shim segments -> app normalizer and segmenter -> scores -> gate -> reports. Runs when the host
// runner is built (scripts/ci/editor/nightly.d/ai_eval.sh builds it at
// build/eval_runner/dv_eval_runner, or DV_EVAL_RUNNER points at one); skipped otherwise.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../src/eval.dart';

void main() {
  final runner = Platform.environment['DV_EVAL_RUNNER'] ?? p.join(Directory.current.path, 'build', 'eval_runner', 'dv_eval_runner');
  final available = File(runner).existsSync();

  test('smoke eval over the committed eval set', () async {
    final out = await Directory.systemTemp.createTemp('dv_eval_smoke');
    addTearDown(() => out.delete(recursive: true));
    final config = EvalConfig(
      runnerPath: runner,
      manifestPath: p.join(Directory.current.path, 'tool', 'eval', 'eval_set.json'),
      outDir: out.path,
      smoke: true,
    );
    final first = await runEval(config);
    expect(first.gate, isEmpty, reason: first.gate.join('\n'));
    expect(first.summaries.single.tier, 'fixture');
    final s = first.summaries.single;
    expect(s.nonSpeechClips, 4);
    expect(s.rawHallucinationRate, 1);
    expect(s.languages.single.language, 'en');
    // The fixture says "hello world" every 2 s over jfk.wav: every reference word is an error.
    expect(s.languages.single.errorRate, greaterThanOrEqualTo(1));
    final report = jsonDecode(File(p.join(out.path, 'report.json')).readAsStringSync()) as Map<String, Object?>;
    expect((report['gate']! as Map)['passed'], isTrue);
    expect(File(p.join(out.path, 'report.md')).readAsStringSync(), contains('| fixture | en | 1 | WER |'));
    // No transcript text in the JSON report.
    expect(File(p.join(out.path, 'report.json')).readAsStringSync(), isNot(contains('hello')));

    // Deterministic: a second run scores identically.
    final second = await runEval(config);
    expect(second.summaries.single.languages.single.wordEdits, s.languages.single.wordEdits);
    expect(second.summaries.single.hallucinatedClips, s.hallucinatedClips);
  }, skip: available ? false : 'dv_eval_runner not built (scripts/ci/editor/nightly.d/ai_eval.sh --build-only)', timeout: const Timeout(Duration(minutes: 5)));
}
