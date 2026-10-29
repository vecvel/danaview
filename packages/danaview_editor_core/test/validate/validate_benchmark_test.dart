// OWNER: CORE-08
//
// Validator budget (BUILD_PLAN CORE-08): full validation of a 2,000-item project ≤ 5 ms and one
// track ≤ 0.5 ms on the CI host, asserted with a 3× CI factor (medians of warm runs; the numbers
// are printed). The one-track case uses a fresh project instance each run, so it includes building
// the id index that a post-command validation pays. Without DV_PERF_STRICT=1 the limits are 4× looser.

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';

/// Allowed slowdown of the CI host against the budget.
const int ciFactor = 3;


/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the budget × [ciFactor]; otherwise (a loaded CI
/// runner) [_looseFactor] times that.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

int medianUs(int runs, void Function() body) {
  final sw = Stopwatch();
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    sw
      ..reset()
      ..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  final project = randomProject(11, const RandomProjectSpec(items: 2000));
  final count = project.index.itemCount;

  test('the benchmark project has about 2,000 items and is valid', () {
    expect(count, inInclusiveRange(1800, 2400));
    expect(validate(project), isEmpty);
  });

  test('full validation of 2,000 items ≤ 5 ms (×$ciFactor CI factor)', () {
    for (var i = 0; i < 30; i++) {
      validate(project);
    }
    final us = medianUs(41, () => validate(project));
    // ignore: avoid_print
    print('validate full ($count items): median ${(us / 1000).toStringAsFixed(2)} ms');
    expect(us, lessThanOrEqualTo(_limit(5000 * ciFactor)), reason: 'median $us µs ($_perfMode)');
  });

  test('validation of one track at 2,000 items ≤ 0.5 ms (×$ciFactor CI factor)', () {
    // The busiest visual lane (the main lane).
    final main = project.tracks.first;
    final only = {main.id};
    EditProject fresh() => EditProject(id: project.id, meta: project.meta, timeline: project.timeline, pool: project.pool);
    for (var i = 0; i < 200; i++) {
      validate(fresh(), only: only);
    }
    final cold = medianUs(201, () => validate(fresh(), only: only));
    final warm = medianUs(201, () => validate(project, only: only));
    // ignore: avoid_print
    print('validate one track (${main.items.length} of $count items): median ${(cold / 1000).toStringAsFixed(3)} ms '
        'with a fresh id index, ${(warm / 1000).toStringAsFixed(3)} ms with the index built');
    expect(cold, lessThanOrEqualTo(_limit(500 * ciFactor)), reason: 'fresh index: median $cold µs ($_perfMode)');
    expect(warm, lessThanOrEqualTo(_limit(500 * ciFactor)), reason: 'built index: median $warm µs ($_perfMode)');
  });
}
