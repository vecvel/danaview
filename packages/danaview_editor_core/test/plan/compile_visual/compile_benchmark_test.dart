// OWNER: CORE-30
//
// Compile budget (BUILD_PLAN CORE-30): a full compile of a 2,000-item project takes ≤ 60 ms in an
// isolate on the CI host. The compile runs inside `Isolate.run` (as callers do above 300 items);
// the median of warm compiles timed inside the isolate is asserted with the 3× CI factor used by
// the core benchmarks. The isolate round trip (spawn + send + compile + return) is printed too. Without DV_PERF_STRICT=1 the limit
// is 4× looser.

import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';
import 'support.dart';

/// Allowed slowdown of the CI host against the budget.
const int ciFactor = 3;

/// The budget of one full compile in µs.
const int budgetUs = 60000;


/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the budget × [ciFactor]; otherwise (a loaded CI
/// runner) [_looseFactor] times that.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

void main() {
  test('full compile of 2,000 items ≤ 60 ms in an isolate (×$ciFactor CI factor)', () async {
    final p = randomProject(30, const RandomProjectSpec(items: 2000, maxOverlayLanes: 4));
    expect(p.index.itemCount, greaterThanOrEqualTo(2000));
    expect(shouldCompileInIsolate(p), isTrue);
    final resolver = resolverFor(p);

    final (medianPreview, medianExport, layers) = await Isolate.run(() {
      final sw = Stopwatch();
      int median(PlanTarget target) {
        final times = <int>[];
        for (var i = 0; i < 25; i++) {
          sw
            ..reset()
            ..start();
          compilePlan(p, target, resolver);
          sw.stop();
          if (i >= 5) times.add(sw.elapsedMicroseconds);
        }
        times.sort();
        return times[times.length ~/ 2];
      }

      final layers = compilePlan(p, PlanTarget.preview, resolver).plan.layers.length;
      return (median(PlanTarget.preview), median(PlanTarget.export), layers);
    });

    // One cold round trip as callers see it (spawn, copy the project in, compile, copy the plan out).
    final once = Stopwatch()..start();
    final plan = await Isolate.run(() => compileRenderPlan(p, PlanTarget.preview, resolver));
    once.stop();
    expect(plan.layers, hasLength(layers));

    // ignore: avoid_print
    print('compile: ${p.index.itemCount} items, $layers layers: median preview '
        '${(medianPreview / 1000).toStringAsFixed(2)} ms, export ${(medianExport / 1000).toStringAsFixed(2)} ms '
        '(in isolate); one Isolate.run round trip ${(once.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms');
    expect(medianPreview, lessThanOrEqualTo(_limit(budgetUs * ciFactor)), reason: 'preview median $medianPreview µs ($_perfMode)');
    expect(medianExport, lessThanOrEqualTo(_limit(budgetUs * ciFactor)), reason: 'export median $medianExport µs ($_perfMode)');
  });
}
