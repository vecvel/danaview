// OWNER: UX-13
//
// The per-pointer-move cost of a drag (ARCH §17.4: dryRun per move ≤ 2 ms): the snap lookup plus
// the move/trim dryRun on the large project of ux.md §17.6 (4 lanes × 1000 clips). Measured as
// the median of many moves after a warm-up; the strict ≤ 2 ms budget applies to release builds on
// devices (QA-04); this debug-VM test fails at 4× that, which catches algorithmic regressions
// (anything linear in the project per move with a large constant). The 8 ms applies with
// DV_PERF_STRICT=1 (a quiet dev Mac); a loaded CI runner gets 4× that.

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/snapping.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../canvas/canvas_fixtures.dart';

/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the 8 ms debug-VM limit; otherwise (a loaded CI runner)
/// [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';
double get _limitMs => _perfStrict ? 8 : 8.0 * _looseFactor;

double _medianMs(List<int> micros) {
  final sorted = [...micros]..sort();
  return sorted[sorted.length ~/ 2] / 1000;
}

/// [largeProject] made valid for edits: its main-lane clips carry visual props (the painting
/// fixture leaves them null, which validator rule I3 refuses once an edit touches the lane).
EditProject _validLarge() {
  final p = largeProject(count: 1000, lanes: 4);
  final tracks = [
    for (final t in p.timeline.tracks)
      t.kind == TrackKind.video
          ? t.copyWith(items: [for (final i in t.items) (i as MediaClip).copyWith(visual: VisualProps.neutral)])
          : t,
  ];
  return p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));
}

void main() {
  final project = _validLarge();
  final ctx = EditContext(pool: project.pool);

  List<int> measure(EditCommand Function(int step) commandAt, {int steps = 120, TimelineSnapping? snap}) {
    final out = <int>[];
    for (var i = 0; i < steps + 20; i++) {
      final sw = Stopwatch()..start();
      snap?.snapTime(500 * s + i * 1000, pxPerSecond: 60);
      final p = dryRun(project, commandAt(i), ctx);
      sw.stop();
      expect(p.rejection, isNull);
      if (i >= 20) out.add(sw.elapsedMicroseconds);
    }
    return out;
  }

  test('move: snap + dryRun per pointer move', () {
    final snap = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_m500')}, playhead: 0, thresholdPx: 8);
    final ms = _medianMs(measure((i) => MoveItems({const ItemId('it_m500')}, (i % 30) * 33333, clamp: true), snap: snap));
    // ignore: avoid_print
    print('move median ${ms.toStringAsFixed(3)} ms');
    expect(ms, lessThan(_limitMs), reason: 'move median ($_perfMode)');
  });

  test('ripple trim: snap + dryRun per pointer move', () {
    final snap = TimelineSnapping.forDrag(project, dragged: {const ItemId('it_m500')}, playhead: 0, thresholdPx: 8);
    final ms = _medianMs(measure((i) => TrimItem(const ItemId('it_m500'), TrimEdge.end, 501 * s - (i % 20) * 33333, ripple: true, clamp: true),
        snap: snap));
    // ignore: avoid_print
    print('ripple trim median ${ms.toStringAsFixed(3)} ms');
    expect(ms, lessThan(_limitMs), reason: 'ripple trim median ($_perfMode)');
  });
}
