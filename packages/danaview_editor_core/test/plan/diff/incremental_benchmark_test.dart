// OWNER: CORE-32
//
// Incremental compile budget (BUILD_PLAN CORE-32, ARCH §11.8): after a one-item edit of a
// 2,000-item project, compiling with the session's PlanMemo plus diffing against the previous
// plan takes ≤ 3 ms (median of warm runs, asserted with the 3× CI factor of the core benchmarks),
// and only the edited item is re-lowered (one visual memo miss). Without DV_PERF_STRICT=1 the time
// limit is 4× looser; the memo and patch checks always apply.

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';
import '../compile_visual/support.dart' show resolverFor;
import 'diff_support.dart';

const int ciFactor = 3;
const int budgetUs = 3000;


/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the budget × [ciFactor]; otherwise (a loaded CI
/// runner) [_looseFactor] times that.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

void main() {
  test('one-item edit at 2,000 items: compile + diff ≤ 3 ms (×$ciFactor CI factor)', () {
    var p = randomProject(30, const RandomProjectSpec(items: 2000, maxOverlayLanes: 4));
    expect(p.index.itemCount, greaterThanOrEqualTo(2000));
    final resolver = resolverFor(p);
    final memo = PlanMemo();
    final ctx = EditContext(ids: SeededIdGenerator(7), now: DateTime.utc(2026, 10, 10));
    var a = compileMemo(p, resolver, memo: memo).plan;
    final clips = <MediaClip>[
      for (final t in p.tracks)
        if (t.kind == TrackKind.video || t.kind == TrackKind.overlay)
          for (final i in t.items)
            if (i is MediaClip && i.visual != null) i,
    ];
    final times = <int>[];
    final sw = Stopwatch();
    for (var i = 0; i < 60; i++) {
      final c = clips[(i * 37) % clips.length];
      final v = c.visual!;
      final out = applyCommand(p, SetVisual([c.id], v.copyWith(transform: v.transform.copyWith(opacity: (i % 10) / 10))), ctx);
      if (!out.changed) continue;
      p = out.project;
      memo.resetStats();
      sw
        ..reset()
        ..start();
      final b = compileMemo(p, resolver, memo: memo).plan;
      final patch = diffPlans(a, b);
      sw.stop();
      if (i >= 20) times.add(sw.elapsedMicroseconds); // the first 20 warm the JIT
      expect(memo.misses, 1, reason: 'only the edited clip is re-lowered');
      expect(patch.layers.remove, isEmpty);
      expect(patch.layers.upsert.map((l) => PlanIds.itemOf(l.id)).toSet(), {c.id});
      expect(classifyPatch(a, patch), PatchClass.paramOnly);
      a = b;
    }
    times.sort();
    final median = times[times.length ~/ 2];
    // ignore: avoid_print
    print('incremental compile + diff at ${p.index.itemCount} items (${a.layers.length} layers, ${a.audio.length} audio): '
        'median ${(median / 1000).toStringAsFixed(2)} ms, max ${(times.last / 1000).toStringAsFixed(2)} ms');
    expect(median, lessThanOrEqualTo(_limit(budgetUs * ciFactor)), reason: 'median $median µs ($_perfMode)');
  });
}
