// OWNER: QA-06
//
// Entry point of the accuracy eval (ai.md §16.5). It runs under `flutter test` because the app's
// segmenter uses dart:ui types; scripts/ci/editor/nightly.d/ai_eval.sh sets the DV_EVAL_*
// environment and runs:
//
//   flutter test tool/eval/eval_run_test.dart
//
// Without DV_EVAL_RUNNER the test is skipped, so `flutter test tool/eval` stays a fast unit run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'src/eval.dart';

void main() {
  final config = EvalConfig.fromEnvironment(Platform.environment, packageRoot: Directory.current.path);
  test(
    'accuracy eval (${config == null ? 'skipped: DV_EVAL_RUNNER not set' : config.smoke ? 'smoke' : 'models'})',
    () async {
      final outcome = await runEval(config!, log: (line) => stdout.writeln('ai_eval: $line'));
      stdout
        ..writeln(outcome.markdown)
        ..writeln('ai_eval: report ${config.outDir}/report.json');
      for (final e in outcome.skippedTiers.entries) {
        stdout.writeln('ai_eval: tier ${e.key} skipped: ${e.value}');
      }
      expect(outcome.summaries, isNotEmpty, reason: 'no tier ran (models missing?)');
      expect(outcome.gate.map((g) => g.toString()).toList(), isEmpty, reason: 'eval gate');
    },
    skip: config == null ? 'DV_EVAL_RUNNER not set (scripts/ci/editor/nightly.d/ai_eval.sh sets it)' : false,
    timeout: Timeout.none,
  );
}
