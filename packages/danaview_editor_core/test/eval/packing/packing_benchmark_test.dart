// OWNER: CORE-36
//
// Packing budget (BUILD_PLAN CORE-36): after a one-lane change in a 2,000-item project,
// re-deriving that lane's inputs and re-packing every visual layer takes ≤ 0.5 ms on the CI host
// (median of warm runs, asserted with the 3× CI factor used by the core benchmarks; the number is
// printed).

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/random_project.dart';

/// Allowed slowdown of the CI host against the budget.
const int ciFactor = 3;

void main() {
  test('incremental one-lane update at 2,000 items ≤ 0.5 ms (×$ciFactor CI factor)', () {
    final base = randomProject(21, const RandomProjectSpec(items: 2000, maxOverlayLanes: 4));
    final items = base.index.itemCount;
    // Two variants of the busiest overlay or video lane that differ in their last item, so every
    // run re-derives exactly one lane.
    final ti = () {
      var best = -1;
      for (var i = 0; i < base.tracks.length; i++) {
        final t = base.tracks[i];
        if ((t.kind == TrackKind.video || t.kind == TrackKind.overlay) && !t.isMain && t.items.length > 1) {
          if (best < 0 || t.items.length > base.tracks[best].items.length) best = i;
        }
      }
      return best;
    }();
    expect(ti, greaterThanOrEqualTo(0));
    final lane = base.tracks[ti];
    EditProject variant(int drop) {
      final t = lane.copyWith(items: lane.items.sublist(0, lane.items.length - drop), transitions: const []);
      return base.copyWith(timeline: base.timeline.copyWith(tracks: List.of(base.tracks)..[ti] = t));
    }

    final a = variant(0);
    final b = variant(1);
    final cache = PackingInputCache();
    cache.pack(a);
    final layers = packingInputsOf(a).length;
    final sw = Stopwatch();
    final times = <int>[];
    for (var i = 0; i < 400; i++) {
      final p = i.isEven ? b : a;
      sw
        ..reset()
        ..start();
      final r = cache.pack(p);
      sw.stop();
      expect(cache.lastDerived, 1);
      if (i >= 100) times.add(sw.elapsedMicroseconds);
      if (i == 398) expect(r, packVisualLayers(packingInputsOf(p)));
    }
    times.sort();
    final median = times[times.length ~/ 2];
    // ignore: avoid_print
    print('packing: one-lane update of $items items ($layers media layers, lane of ${lane.items.length}): '
        'median ${(median / 1000).toStringAsFixed(3)} ms');
    expect(median, lessThanOrEqualTo(500 * ciFactor));
  });
}
