// OWNER: CORE-34
// Temporary exploration harness (deleted before hand-off).

import 'dart:io';

import 'package:test/test.dart';

import 'fuzz_coverage.dart';
import 'fuzz_runner.dart';

void main() {
  final first = int.parse(Platform.environment['FZ_FIRST'] ?? '0');
  final count = int.parse(Platform.environment['FZ_COUNT'] ?? '10');
  final steps = int.parse(Platform.environment['FZ_STEPS'] ?? '500');
  test('explore', () {
    final cov = CommandCoverage();
    final failures = <String>[];
    final sw = Stopwatch()..start();
    for (var seed = first; seed < first + count; seed++) {
      final t0 = sw.elapsedMilliseconds;
      final r = FuzzRunner.run(FuzzCase.forSeed(seed, steps: steps));
      cov.addAll(r.coverage);
      final line = 'seed $seed ${sw.elapsedMilliseconds - t0} ms ${r.stats} ${r.failure ?? 'ok'}';
      // ignore: avoid_print
      print(line.length > 1500 ? line.substring(0, 1500) : line);
      if (r.failure != null) failures.add('$seed ${r.failure!.check.name}');
    }
    // ignore: avoid_print
    print(cov.table());
    // ignore: avoid_print
    print('failures: $failures total ${sw.elapsedMilliseconds} ms');
  }, timeout: Timeout.none);
}
