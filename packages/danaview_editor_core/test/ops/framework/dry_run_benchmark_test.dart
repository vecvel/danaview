// OWNER: CORE-09
//
// Dry-run budget (BUILD_PLAN CORE-09): `dryRun` of a gesture command, limits and post-step
// validation included, takes ≤ 1 ms on a 1,000-item project (median of warm runs with one context
// per session so packing stays incremental; asserted with the 3× CI factor used by the core
// benchmarks; the numbers are printed). Without DV_PERF_STRICT=1 the limit is 4× looser.

import 'dart:io' show Platform;

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
int medianUs(void Function(int i) run, {int warm = 100, int n = 300}) {
  final sw = Stopwatch();
  final times = <int>[];
  for (var i = 0; i < warm + n; i++) {
    sw
      ..reset()
      ..start();
    run(i);
    sw.stop();
    if (i >= warm) times.add(sw.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  test('dryRun incl. limits ≤ 1 ms at 1,000 items (×$ciFactor CI factor)', () {
    final p = randomProject(33, const RandomProjectSpec(items: 1000));
    final items = p.index.itemCount;
    expect(items, greaterThanOrEqualTo(900));
    final rate = p.settings.frameRate;
    // The busiest visual lane that is not the main lane (its clips feed the packing check).
    final lane = (p.tracks.where((t) => (t.kind == TrackKind.overlay || t.kind == TrackKind.video) && !t.isMain && t.items.length > 2).toList()
          ..sort((a, b) => b.items.length.compareTo(a.items.length)))
        .first;
    final mid = lane.items[lane.items.length ~/ 2];
    final main = p.tracks.firstWhere((t) => t.isMain);
    final mainMid = main.items[main.items.length ~/ 2];
    final one = rate.timeOfFrame(1);
    final cases = <String, EditCommand>{
      'move overlay clip 1 frame': MoveItems({mid.id}, one),
      'move overlay clip 1 frame (clamp)': MoveItems({mid.id}, one, clamp: true),
      'trim overlay end -1 frame': TrimItem(mid.id, TrimEdge.end, mid.end - one, clamp: true),
      'ripple trim main end -1 frame': TrimItem(mainMid.id, TrimEdge.end, mainMid.end - one, ripple: true, clamp: true),
      'split main mid clip': SplitItems({mainMid.id}, rate.timeOfFrame((rate.frameIndexOf(mainMid.start) + rate.frameIndexOf(mainMid.end)) ~/ 2)),
    };
    final context = EditContext(ids: SeededIdGenerator(900001), now: DateTime.utc(2026, 10, 10));
    final out = StringBuffer('dryRun at $items items:');
    for (final e in cases.entries) {
      final probe = dryRun(p, e.value, context);
      expect(probe.rejection, isNot(isA<InternalInconsistency>()), reason: e.key);
      final median = medianUs((_) => dryRun(p, e.value, context));
      out.write(' ${e.key} ${(median / 1000).toStringAsFixed(3)} ms${probe.isRejected ? ' (${probe.rejection!.code})' : ''};');
      expect(median, lessThanOrEqualTo(_limit(1000 * ciFactor)), reason: '${e.key}: median $median µs ($_perfMode)');
    }
    // ignore: avoid_print
    print(out);
  });
}
