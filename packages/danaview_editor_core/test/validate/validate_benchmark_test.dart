// OWNER: CORE-08
//
// Validator budget (BUILD_PLAN CORE-08): full validation of a 2,000-item project ≤ 5 ms and one
// track ≤ 0.5 ms on the CI host, asserted with a 3× CI factor (medians of warm runs; the numbers
// are printed). The one-track case uses a fresh project instance each run, so it includes building
// the id index that a post-command validation pays.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';

/// Allowed slowdown of the CI host against the budget.
const int ciFactor = 3;

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
    expect(us, lessThanOrEqualTo(5000 * ciFactor));
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
    expect(cold, lessThanOrEqualTo(500 * ciFactor));
    expect(warm, lessThanOrEqualTo(500 * ciFactor));
  });
}
