// OWNER: QA-04
//
// The CORE-35 core rows of ARCH §18.2 measured on the phone itself (CORE-35's acceptance asks for
// them "recorded for one mid-tier Android and one iPhone through QA-04"): `apply` / `dryRun` on
// one lane of 1,000 items, incremental compile + diff at 2,000 items, full compile + plan encode
// at 2,000 items, project open at 2,000 items and the autosave encode. The measuring code is
// CORE-35's own benchmark (packages/danaview_editor_core/benchmark/src, imported by path so the
// numbers are the same rows the CI host gates), run here in the app's isolate with the
// generated `large_2000` project (the fixture file is not on the phone).
//
// Host runs use the quick sample sizes; device profile runs use the full ones.
//
//   cd packages/danaview_editor
//   flutter test integration_test/perf/core_rows_perf_test.dart -d flutter-tester

import 'dart:convert';

import 'package:danaview_editor_core/codec.dart' show ProjectJsonCodec;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../../danaview_editor_core/benchmark/src/core_benchmarks.dart';
import '../../../danaview_editor_core/benchmark/src/harness.dart';
import '../../../danaview_editor_core/benchmark/src/large_project.dart';
import 'perf_support.dart';

void _report(MetricResult r) {
  final budget = Budget('core.${r.id}', low: r.budgetUs / 1000, mid: r.budgetUs / 1000, unit: 'ms p90');
  budget.check(r.p90 / 1000, {
    'p50': (r.p50 / 1000).toStringAsFixed(3),
    'max': (r.max / 1000).toStringAsFixed(3),
    'n': r.samples.length,
    'gatedOnCi': r.budgetGated,
    'label': r.label.replaceAll('|', '/'),
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CORE-35 rows on this device', (tester) async {
    final sizes = BenchSizes(quick: !kProfileMode);
    final lane = buildOneLaneProject();
    final large = buildLargeProject();
    final shape = shapeOf(large);
    expect(shape.items, LargeShape.items);
    expect(shape.cues, LargeShape.cues);
    final body = Uint8List.fromList(utf8.encode(ProjectJsonCodec().encode(large)));
    final results = [
      ...commandBenchmarks(lane, sizes),
      ...planBenchmarks(large, sizes),
      openBenchmark(body, sizes),
    ];
    expect(results.map((r) => r.id), containsAll(['apply_1000', 'dry_run_1000', 'open_2000']));
    results.forEach(_report);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
