// OWNER: CORE-18
//
// SnapIndex (BUILD_PLAN CORE-18): `nearest` / `nearestForRange` against a brute-force oracle on
// random projects, exclusions, every target kind, tie rules and edge cases.

import 'dart:math';

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';

/// The brute-force target list of [p]: (time, kind, priority) with the same rules as the index.
List<({TimeUs time, SnapKind kind})> oracleTargets(
  EditProject p, {
  Set<ItemId> exclude = const {},
  TimeUs? playhead,
  bool markers = true,
  ItemId? keyframesOf,
  bool cues = true,
  bool transitions = true,
}) {
  final out = <({TimeUs time, SnapKind kind})>[];
  final rate = p.settings.frameRate;
  if (playhead != null) out.add((time: playhead, kind: SnapKind.playhead));
  if (markers) {
    for (final m in p.markers) {
      out.add((time: m.time, kind: SnapKind.marker));
    }
  }
  for (final t in p.tracks) {
    if (!cues && t.kind == TrackKind.subtitle) continue;
    for (final i in t.items) {
      if (exclude.contains(i.id)) continue;
      out
        ..add((time: i.start, kind: SnapKind.itemEdge))
        ..add((time: i.end, kind: SnapKind.itemEdge));
    }
    if (transitions) {
      for (final tr in t.transitions) {
        if (exclude.contains(tr.left) || exclude.contains(tr.right)) continue;
        final right = t.items.firstWhere((i) => i.id == tr.right);
        final cut = rate.frameIndexOf(right.start);
        out
          ..add((time: rate.timeOfFrame(cut - tr.durationFrames ~/ 2), kind: SnapKind.transition))
          ..add((time: rate.timeOfFrame(cut + (tr.durationFrames + 1) ~/ 2), kind: SnapKind.transition));
      }
    }
  }
  if (keyframesOf != null && !exclude.contains(keyframesOf)) {
    final item = p.index.item(keyframesOf);
    final set = item is MediaClip ? item.keyframes : (item is TextItem ? item.keyframes : KeyframeSet.empty);
    for (final tr in set.byChannel.values) {
      for (final k in tr.keys) {
        out.add((time: item!.start + k.t, kind: SnapKind.keyframe));
      }
    }
  }
  return out;
}

int rank(SnapKind k) => switch (k) {
      SnapKind.playhead => 0,
      SnapKind.marker => 1,
      SnapKind.itemEdge => 2,
      SnapKind.transition => 3,
      SnapKind.keyframe => 4,
    };

/// The expected best (time, kind) for probe [t], or null.
({TimeUs time, SnapKind kind})? oracleNearest(List<({TimeUs time, SnapKind kind})> targets, TimeUs t, TimeUs tol) {
  ({TimeUs time, SnapKind kind})? best;
  for (final c in targets) {
    final d = (c.time - t).abs();
    if (d > tol) continue;
    if (best == null) {
      best = c;
      continue;
    }
    final bd = (best.time - t).abs();
    final better = d < bd ||
        (d == bd && c.time == best.time && rank(c.kind) < rank(best.kind)) ||
        (d == bd && c.time != best.time && (rank(c.kind) < rank(best.kind) || (rank(c.kind) == rank(best.kind) && c.time < best.time)));
    if (better) best = c;
  }
  return best;
}

void main() {
  group('nearest / nearestForRange against brute force', () {
    for (final seed in [1, 2, 3, 5, 8, 13, 21]) {
      test('random project seed $seed', () {
        final p = randomProject(seed, const RandomProjectSpec(items: 120));
        final rnd = Random(seed);
        final all = [for (final t in p.tracks) ...t.items];
        final exclude = {for (final i in all) if (rnd.nextInt(5) == 0) i.id};
        final playhead = p.duration ~/ 2;
        // Keyframes of the first item that has any.
        ItemId? kf;
        for (final i in all) {
          if ((i is MediaClip && !i.keyframes.isEmpty) || (i is TextItem && !i.keyframes.isEmpty)) {
            kf = i.id;
            break;
          }
        }
        for (final variant in [0, 1, 2]) {
          final ex = variant == 0 ? const <ItemId>{} : exclude;
          final index = SnapIndex.build(
            p,
            exclude: ex,
            playhead: variant == 2 ? null : playhead,
            keyframesOf: kf,
            markers: variant != 2,
            cues: variant != 1,
          );
          final targets = oracleTargets(p,
              exclude: ex,
              playhead: variant == 2 ? null : playhead,
              keyframesOf: kf,
              markers: variant != 2,
              cues: variant != 1);
          expect(index.times, orderedEquals({for (final t in targets) t.time}.toList()..sort()));
          for (var q = 0; q < 400; q++) {
            final t = rnd.nextInt(p.duration + 2 * microsPerSecond) - microsPerSecond ~/ 2;
            final tol = [0, 1, 1000, 33333, 250000, 2 * microsPerSecond][rnd.nextInt(6)];
            final got = index.nearest(t, tol);
            final want = oracleNearest(targets, t, tol);
            if (want == null) {
              expect(got, isNull, reason: 't=$t tol=$tol');
            } else {
              expect(got, isNotNull, reason: 't=$t tol=$tol');
              expect(got!.time, want.time, reason: 't=$t tol=$tol');
              expect(got.kind, want.kind, reason: 't=$t tol=$tol');
              expect(got.distance, (want.time - t).abs());
            }
          }
          for (var q = 0; q < 300; q++) {
            final s = max(0, rnd.nextInt(p.duration + microsPerSecond));
            final e = s + rnd.nextInt(5 * microsPerSecond);
            final tol = [1000, 33333, 250000][rnd.nextInt(3)];
            final got = index.nearestForRange(TimeRange(s, e), tol);
            final ws = oracleNearest(targets, s, tol);
            final we = s == e ? null : oracleNearest(targets, e, tol);
            if (ws == null && we == null) {
              expect(got, isNull);
              continue;
            }
            expect(got, isNotNull);
            final ds = ws == null ? null : (ws.time - s).abs();
            final de = we == null ? null : (we.time - e).abs();
            // The smaller shift wins.
            final best = [if (ds != null) ds, if (de != null) de].reduce(min);
            expect(got!.delta.abs(), best, reason: 'range [$s,$e) tol=$tol');
            final snapped = got.edge == SnapSide.start ? s : e;
            expect(snapped + got.delta, got.hit.time);
          }
        }
      });
    }

    test('delta lands the chosen edge on the target', () {
      final p = project([lane('v', TrackKind.video, [vclip('a', 30, 30), vclip('b', 90, 30)], main: true)]);
      final index = SnapIndex.build(p);
      // A 20-frame range starting 2 frames before b's start: the end edge is 18 frames short of ... no.
      final r = TimeRange(f(70), f(88));
      final hit = index.nearestForRange(r, f(3))!;
      expect(hit.edge, SnapSide.end);
      expect(hit.hit.time, f(90));
      expect(hit.delta, f(90) - f(88));
    });
  });

  group('target kinds', () {
    late EditProject p;
    setUp(() {
      final base = project([
        lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 60, 60), vclip('c', 200, 30)],
            main: true, transitions: [transition('tx', 'a', 'b', frames: 10)]),
        lane('t', TrackKind.text, [text('x', 10, 30)]),
        lane('s', TrackKind.subtitle, [cue('q', 300, 30)]),
      ]);
      p = base.copyWith(timeline: base.timeline.copyWith(markers: [Marker(id: MarkerId('mk_1'), time: f(150))]));
    });

    test('clip edges report item, lane and side', () {
      final i = SnapIndex.build(p);
      final h = i.nearest(f(200) + 5, 100)!;
      expect(h.kind, SnapKind.itemEdge);
      expect(h.item, ItemId('c'));
      expect(h.track, TrackId('v'));
      expect(h.side, SnapSide.start);
      expect(h.time, f(200));
      expect(h.distance, 5);
      expect(i.nearest(f(230), 0)!.side, SnapSide.end);
    });

    test('markers and the playhead', () {
      final i = SnapIndex.build(p, playhead: f(100));
      expect(i.nearest(f(150) + 1, 10)!.kind, SnapKind.marker);
      expect(i.nearest(f(150) + 1, 10)!.marker, MarkerId('mk_1'));
      expect(i.nearest(f(100) - 3, 10)!.kind, SnapKind.playhead);
      expect(SnapIndex.build(p, markers: false).nearest(f(150), 10), isNull);
      expect(SnapIndex.build(p).nearest(f(100), 10), isNull);
    });

    test('transition window boundaries (cut 60, 10 frames: [55, 65))', () {
      final i = SnapIndex.build(p);
      final a = i.nearest(f(55), 0)!;
      expect(a.kind, SnapKind.transition);
      expect(a.transition, TransitionId('tx'));
      expect(a.side, SnapSide.start);
      expect(i.nearest(f(65), 0)!.side, SnapSide.end);
      expect(SnapIndex.build(p, transitions: false).nearest(f(55), 0), isNull);
    });

    test('odd transition length: window [cut − ⌊n/2⌋, cut + ⌈n/2⌉)', () {
      final q = project([
        lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 60, 60)], main: true, transitions: [transition('tx', 'a', 'b', frames: 7)]),
      ]);
      final i = SnapIndex.build(q);
      expect(i.nearest(f(57), 0)!.kind, SnapKind.transition);
      expect(i.nearest(f(64), 0)!.kind, SnapKind.transition);
      expect(i.nearest(f(56), 0), isNull);
      expect(i.nearest(f(65), 0), isNull);
    });

    test('cues can be left out', () {
      expect(SnapIndex.build(p).nearest(f(300), 0)!.item, ItemId('q'));
      expect(SnapIndex.build(p, cues: false).nearest(f(300), 0), isNull);
    });

    test('keyframes of one item', () {
      final clip = vclip('k', 0, 120, keyframes: KeyframeSet({'transform.rotation': KeyframeTrack([Keyframe(f(20), 0), Keyframe(f(80), 1)])}));
      final q = project([lane('v', TrackKind.video, [clip], main: true)]);
      expect(SnapIndex.build(q).nearest(f(20), 0), isNull);
      final h = SnapIndex.build(q, keyframesOf: ItemId('k')).nearest(f(80) + 2, 5)!;
      expect(h.kind, SnapKind.keyframe);
      expect(h.item, ItemId('k'));
      expect(h.time, f(80));
      expect(SnapIndex.build(q, keyframesOf: ItemId('k'), exclude: {ItemId('k')}).nearest(f(20), 0), isNull);
    });
  });

  group('exclusions and ties', () {
    test('excluded items are not targets, nor are transitions touching them', () {
      final p = project([
        lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 60, 60), vclip('c', 120, 30)],
            main: true, transitions: [transition('tx', 'a', 'b', frames: 10)]),
      ]);
      final full = SnapIndex.build(p);
      expect(full.nearest(f(60), 0)!.kind, SnapKind.itemEdge);
      expect(full.nearest(f(55), 0)!.kind, SnapKind.transition);
      final ex = SnapIndex.build(p, exclude: {ItemId('b')});
      expect(ex.nearest(f(55), 0), isNull, reason: 'the transition touches b');
      // a ends at 60 and is still a target; b's own end (120) is shared with c's start.
      expect(ex.nearest(f(60), 0)!.item, ItemId('a'));
      expect(ex.nearest(f(120), 0)!.item, ItemId('c'));
      final exBoth = SnapIndex.build(p, exclude: {ItemId('a'), ItemId('b'), ItemId('c')});
      expect(exBoth.isEmpty, isTrue);
    });

    test('equal distance prefers the better kind, then the earlier', () {
      final q = project([lane('v', TrackKind.video, [vclip('a', 30, 30)], main: true)]);
      final short = project([lane('v', TrackKind.video, [vclip('a', 30, 10)], main: true)]);
      final marked = short.copyWith(
        timeline: short.timeline.copyWith(markers: [Marker(id: MarkerId('mk'), time: f(60))]),
      );
      // Frame 50 is exactly 10 frames from the clip end (frame 40, earlier) and the marker (frame 60).
      final i = SnapIndex.build(marked);
      expect(i.nearest(f(50), f(11))!.kind, SnapKind.marker, reason: 'marker outranks an edge at the same distance');
      // No priority difference: the earlier target wins.
      final j = SnapIndex.build(q);
      expect(j.nearest(f(45), f(15))!.time, f(30));
      expect(j.nearest(f(45), f(15))!.item, ItemId('a'));
    });

    test('the best kind wins when targets share a time', () {
      final q = project([lane('v', TrackKind.video, [vclip('a', 0, 30)], main: true)]);
      final i = SnapIndex.build(q, playhead: f(30));
      expect(i.length, 2); // 0 and 30
      expect(i.nearest(f(30), 0)!.kind, SnapKind.playhead);
    });
  });

  group('edge cases', () {
    test('empty project and empty index', () {
      final p = project(const []);
      final i = SnapIndex.build(p);
      expect(i.isEmpty, isTrue);
      expect(i.nearest(0, 1 << 40), isNull);
      expect(i.nearestForRange(const TimeRange(0, 10), 1 << 40), isNull);
      expect(SnapIndex.empty.nearest(5, 5), isNull);
    });

    test('negative tolerance finds nothing; zero tolerance needs an exact hit', () {
      final p = project([lane('v', TrackKind.video, [vclip('a', 0, 30)], main: true)]);
      final i = SnapIndex.build(p);
      expect(i.nearest(0, -1), isNull);
      expect(i.nearest(1, 0), isNull);
      expect(i.nearest(0, 0)!.distance, 0);
    });

    test('probes before the first and after the last target', () {
      final p = project([lane('v', TrackKind.video, [vclip('a', 30, 30)], main: true)]);
      final i = SnapIndex.build(p);
      expect(i.nearest(0, f(30))!.time, f(30));
      expect(i.nearest(f(500), f(10)), isNull);
      expect(i.nearest(f(61), f(5))!.time, f(60));
    });

    test('a zero-length range probes once', () {
      final p = project([lane('v', TrackKind.video, [vclip('a', 30, 30)], main: true)]);
      final r = SnapIndex.build(p).nearestForRange(TimeRange(f(31), f(31)), f(2))!;
      expect(r.edge, SnapSide.start);
      expect(r.delta, f(30) - f(31));
    });

    test('the index is a snapshot: later project changes do not leak in', () {
      final p = project([lane('v', TrackKind.video, [vclip('a', 30, 30)], main: true)]);
      final i = SnapIndex.build(p);
      final q = applyCommand(p, DeleteItems({ItemId('a')}), ctx()).project;
      expect(q.index.itemCount, 0);
      expect(i.nearest(f(30), 0)!.item, ItemId('a'));
    });
  });
}
