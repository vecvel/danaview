// OWNER: CORE-25
//
// Benchmark (ARCH §18.2): opening a 2,000-item project takes ≤ 150 ms of core time (read +
// checksum + decode + validate/repair + recovery check; measured inline, without the isolate hop,
// best of 5 after a warm-up so other processes on the machine do not decide the result).
// Without DV_PERF_STRICT=1 the limit is 4× looser.

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

import 'support/repo_support.dart';

/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the absolute budget; otherwise (a loaded CI runner)
/// [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

void main() {
  test('open of 2,000 items ≤ 150 ms core time', () async {
    final timers = FakeTimers();
    final repo = memRepo(timers);
    final project = bigProject(2000);
    expect(project.tracks.single.items, hasLength(2000));
    await repo.seed(project);
    const id = ProjectId('pr_big00000001');
    final runs = <int>[];
    for (var i = 0; i < 6; i++) {
      final sw = Stopwatch()..start();
      final loaded = await repo.open(id);
      sw.stop();
      expect(loaded.project.tracks.single.items, hasLength(2000));
      await repo.close(id);
      if (i > 0) runs.add(sw.elapsedMicroseconds);
    }
    runs.sort();
    final best = runs.first / 1000;
    final median = runs[runs.length ~/ 2] / 1000;
    // ignore: avoid_print
    print('open 2,000 items: best ${best.toStringAsFixed(1)} ms, median ${median.toStringAsFixed(1)} ms');
    expect(best, lessThanOrEqualTo(_limit(150)), reason: 'best $best ms ($_perfMode)');
  });
}
