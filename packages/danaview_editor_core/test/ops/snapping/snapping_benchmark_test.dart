// OWNER: CORE-18
//
// SnapIndex budget (BUILD_PLAN CORE-18): build ≤ 1 ms at 2,000 items, `nearest` ≤ 20 µs (median of
// warm runs; asserted with the 3× CI factor used by the core benchmarks; the numbers are printed).
// Without DV_PERF_STRICT=1 the limits are 4× looser.

import 'dart:io' show Platform;
import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../../support/random_project.dart';

/// Allowed slowdown of the CI host against the budget.
const int ciFactor = 3;


/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the budget × [ciFactor]; otherwise (a loaded CI
/// runner) [_looseFactor] times that.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

/// Median µs of [run] over [n] warm runs (after [warm] discarded ones).
double medianUs(void Function(int i) run, {int warm = 200, int n = 400}) {
  final sw = Stopwatch();
  final times = <int>[];
  for (var i = 0; i < warm + n; i++) {
    sw
      ..reset()
      ..start();
    run(i);
    sw.stop();
    if (i >= warm) times.add(sw.elapsedMicroseconds == 0 ? sw.elapsedTicks * 1000000 ~/ sw.frequency : sw.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2].toDouble();
}

void main() {
  late EditProject p;
  setUpAll(() {
    p = randomProject(77, const RandomProjectSpec(items: 2000, transitions: true));
  });

  test('build ≤ 1 ms at 2,000 items (×$ciFactor CI factor)', () {
    expect(p.index.itemCount, greaterThanOrEqualTo(1800));
    final build = medianUs((_) => SnapIndex.build(p, playhead: p.duration ~/ 3));
    // ignore: avoid_print
    print('SnapIndex.build: ${p.index.itemCount} items -> $build µs (median)');
    expect(build, lessThanOrEqualTo(_limit(1000 * ciFactor)), reason: 'median $build µs ($_perfMode)');
  });

  test('nearest and nearestForRange ≤ 20 µs (×$ciFactor CI factor)', () {
    final index = SnapIndex.build(p, playhead: p.duration ~/ 3);
    final rnd = Random(5);
    final probes = [for (var i = 0; i < 1024; i++) rnd.nextInt(p.duration + 1)];
    final tol = p.settings.frameRate.frameUs * 4;
    var sink = 0;
    // Queries are far below the clock's resolution: time batches of 1,024 and divide.
    final nearest = medianUs((_) {
          for (var i = 0; i < 1024; i++) {
            sink += index.nearest(probes[i], tol)?.time ?? 0;
          }
        }, warm: 50, n: 200) /
        1024;
    final range = medianUs((_) {
          for (var i = 0; i < 1024; i++) {
            sink += index.nearestForRange(TimeRange(probes[i], probes[i] + 700000), tol)?.delta ?? 0;
          }
        }, warm: 50, n: 200) /
        1024;
    // ignore: avoid_print
    print('SnapIndex.nearest: ${nearest.toStringAsFixed(2)} µs, nearestForRange: ${range.toStringAsFixed(2)} µs (median, sink $sink)');
    expect(nearest, lessThanOrEqualTo(_limit(20 * ciFactor)), reason: 'nearest $nearest µs ($_perfMode)');
    expect(range, lessThanOrEqualTo(_limit(20 * ciFactor)), reason: 'nearestForRange $range µs ($_perfMode)');
  });
}
