// OWNER: CORE-34
//
// fuzz-lite (BUILD_PLAN CORE-34): 200 seeds × 500 steps inside `dart test`, tagged `fuzz-lite`.
// The seeds are split over the `fuzz_lite_shard<i>_test.dart` files: `dart test` runs each test
// file in its own isolate, so the shards run in parallel.
//
// Every shard also checks the command coverage report: each EditCommand subtype was exercised and
// changed the project at least once. A failing seed is minimized and written as a regression
// fixture to build/core_fuzz/fixtures/; the test failure names the file and the command that
// reproduces it.
//
// Environment (local exploration): FUZZ_FIRST (first seed, default 0), FUZZ_SEEDS (default 200),
// FUZZ_STEPS (default 500). The nightly job runs 10,000 seeds through fuzz_main.dart.

import 'dart:io';

import 'package:test/test.dart';

import 'fuzz_coverage.dart';
import 'fuzz_fixture.dart';
import 'fuzz_minimizer.dart';
import 'fuzz_runner.dart';

/// Number of `fuzz_lite_shard<i>_test.dart` files.
const int fuzzLiteShards = 4;

int _env(String name, int fallback) => int.tryParse(Platform.environment[name] ?? '') ?? fallback;

/// Declares the fuzz-lite test of shard [shard] of [shards]: seeds `first + shard + k * shards`.
void fuzzLiteShard(int shard, {int shards = fuzzLiteShards}) {
  final first = _env('FUZZ_FIRST', 0);
  final count = _env('FUZZ_SEEDS', 200);
  final steps = _env('FUZZ_STEPS', 500);
  final seeds = [for (var k = shard; k < count; k += shards) first + k];

  test('fuzz-lite shard ${shard + 1}/$shards: ${seeds.length} seeds × $steps steps', () {
    final coverage = CommandCoverage();
    final known = <String, int>{};
    final failed = <int, FuzzFailure>{};
    var stopped = 0;
    for (final seed in seeds) {
      final r = FuzzRunner.run(FuzzCase.forSeed(seed, steps: steps));
      coverage.addAll(r.coverage);
      r.stats.forEach((k, v) {
        if (k.startsWith('known:')) known[k.substring(6)] = (known[k.substring(6)] ?? 0) + v;
      });
      if (r.stats.containsKey('stoppedAtStep')) stopped++;
      if (r.failure != null) failed[seed] = r.failure!;
    }
    printOnFailure(coverage.table());

    if (failed.isNotEmpty) {
      final report = StringBuffer('${failed.length} of ${seeds.length} seeds failed:\n');
      failed.forEach((seed, f) => report.writeln('  seed $seed: ${_firstLine('$f')}'));
      // Minimize the first failure into a regression fixture.
      final seed = failed.keys.first;
      try {
        final m = FuzzMinimizer(timeBudget: const Duration(minutes: 2), tolerateKnownDefects: true)
            .minimize(FuzzCase.forSeed(seed, steps: steps));
        final file = FuzzFixture.ofCase(fixtureNameFor(m.failure, seed), m.fuzzCase,
                failure: m.failure, note: 'Minimized by fuzz-lite from seed $seed ($steps steps): $m.')
            .write(Directory('build/core_fuzz/fixtures'));
        report.writeln('seed $seed $m: ${file.path} (copy it into test/fuzz/regressions/).');
      } on Object catch (e) {
        report.writeln('seed $seed could not be minimized: $e');
      }
      report.write('Reproduce: dart run test/fuzz/fuzz_main.dart --seed $seed --steps $steps --trace');
      fail(report.toString());
    }

    if (seeds.length >= 25) {
      expect(coverage.unexercised, isEmpty, reason: 'EditCommand subtypes the generator never ran');
      expect(coverage.neverApplied, isEmpty, reason: 'EditCommand subtypes that never changed the project');
    }
    // The coverage summary of the shard (the full table is in fuzz_main.dart's report).
    // ignore: avoid_print
    print('fuzz-lite shard ${shard + 1}/$shards: ${seeds.length} seeds passed; '
        '${allCommandNames.length - coverage.unexercised.length}/${allCommandNames.length} EditCommand subtypes exercised; '
        '${stopped == 0 ? '' : '$stopped runs stopped at a known validator defect; '}'
        'open known defects fired: ${known.isEmpty ? 'none' : known}');
  }, timeout: const Timeout(Duration(minutes: 15)));
}

String _firstLine(String s) {
  final i = s.indexOf('\n');
  final line = i < 0 ? s : s.substring(0, i);
  return line.length > 600 ? '${line.substring(0, 600)}...' : line;
}
