// OWNER: CORE-37
//
// Property tests (ARCH D-45(A)): over random edit sequences an edit changes the hashes of exactly
// the ranges it overlaps and of no other, `invalidated` reports exactly the vanished hashes, and an
// undo restores the previous hashes (so the old cache entries are found again).
//
// Two generators: plan-level edits of random hand-made plans (every edit changes the pixels of
// its span, so "exactly" is checked in both directions), and real editing commands on random
// projects compiled by the real compiler (checked in the "no other" direction, since some commands
// rewrite layers without changing their pixels, e.g. a split).

import 'dart:math';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:test/test.dart';

import '../../support/random_project.dart';
import '../compile_visual/support.dart' show resolverFor;
import '../diff/diff_support.dart' show compileMemo, randomEdit;
import 'support.dart';

/// A random plan of up to 8 layers in 300 frames.
RenderPlan randomPlan(Random rnd) {
  final layers = <PlanLayer>[];
  final n = 2 + rnd.nextInt(7);
  for (var i = 0; i < n; i++) {
    final k0 = rnd.nextInt(250);
    final k1 = k0 + 5 + rnd.nextInt(45);
    layers.add(switch (rnd.nextInt(4)) {
      0 => solid('s$i#v', k0, k1, z: i, color: 0xFF000000 | rnd.nextInt(0xFFFFFF)),
      _ => media('m$i#v', k0, k1, 'a${rnd.nextInt(3)}', z: i, src: rnd.nextInt(100), xf: PlanTransform(s: 0.5 + rnd.nextInt(4) / 4)),
    });
  }
  return plan(layers, assets: {for (var i = 0; i < 3; i++) 'a$i': video('fp_a$i')});
}

/// A random pixel-changing edit of one layer. Returns the new plan and the spans it touched.
(RenderPlan, List<(TimeUs, TimeUs)>) randomPlanEdit(RenderPlan p, Random rnd) {
  final l = p.layers[rnd.nextInt(p.layers.length)];
  final old = (l.t0, l.t1);
  switch (rnd.nextInt(5)) {
    case 0: // param edit
      final xf = PlanTransform(s: l.xf.s + 0.125, op: l.xf.op);
      return (withLayer(p, copyLayer(l, xf: xf)), [old]);
    case 1: // effect edit
      return (withLayer(p, copyLayer(l, fx: PlanEffects(adj: PlanAdjust(contrast: 0.05 + rnd.nextDouble() * 0.9)))), [old]);
    case 2: // delete
      return (withoutLayer(p, l.id), [old]);
    case 3: // move a media layer by 1..40 frames; recolour a solid
      if (l.kind != PlanLayerKind.media) return (withLayer(p, copyLayer(l, color: (l.color! + 1) | 0xFF000000)), [old]);
      final n = 1 + rnd.nextInt(40);
      final t0 = f(grid.frameIndexOf(l.t0) + n);
      final t1 = f(grid.frameIndexOf(l.t1) + n);
      final s0 = l.map.first.s0;
      final moved = copyLayer(l, t0: t0, t1: t1, map: [MapSegment(t0, t1, s0, s0 + (t1 - t0))]);
      return (withLayer(p, moved), [old, (t0, t1)]);
    default: // add a layer on top
      final k0 = rnd.nextInt(280);
      final added = solid('new${p.rev}#v', k0, k0 + 1 + rnd.nextInt(30), z: 100, color: 0xFFABCDEF);
      return (withLayer(p, added), [(added.t0, added.t1)]);
  }
}

bool _touches(PlanRange r, List<(TimeUs, TimeUs)> spans) => spans.any((s) => r.overlapsSpan(s.$1, s.$2));

void main() {
  group('plan-level random edits', () {
    for (var seed = 0; seed < 40; seed++) {
      test('seed $seed: 25 edits', () {
        final rnd = Random(seed);
        var p = randomPlan(rnd);
        for (var step = 0; step < 25; step++) {
          final (next, spans) = randomPlanEdit(p, rnd);
          if (next.layers.isEmpty) break;
          final before = {for (final r in splitRanges(p)) r: rangeHash(p, r)};
          for (final MapEntry(key: r, value: h) in before.entries) {
            final after = rangeHash(next, r);
            if (_touches(r, spans)) {
              expect(after, isNot(h), reason: 'step $step: an edit overlapping $r changes its hash');
            } else {
              expect(after, h, reason: 'step $step: an edit outside $r keeps its hash');
            }
          }
          // invalidated == old hashes that vanished; every untouched range's entry survives.
          final gone = invalidated(p, next);
          final newHashes = rangeHashes(next).toSet();
          expect(gone, before.values.toSet().difference(newHashes));
          for (final MapEntry(key: r, value: h) in before.entries) {
            if (!_touches(r, spans) && splitRanges(next).contains(r)) expect(gone, isNot(contains(h)));
          }
          // Undo (the previous plan at a later revision) restores every previous hash.
          final undone = p.copyWith(rev: next.rev + 1);
          expect(rangeHashes(undone), before.values.toList(), reason: 'undo restores the hashes');
          expect(invalidated(next, undone).intersection(before.values.toSet()), isEmpty);
          expect(invalidated(p, undone), isEmpty);
          p = next;
        }
      });
    }
  });

  group('real editing commands on compiled projects', () {
    for (var seed = 0; seed < 12; seed++) {
      test('seed $seed: 15 random commands', () {
        final rnd = Random(seed + 77);
        var project = randomProject(seed, const RandomProjectSpec(items: 30));
        final resolver = resolverFor(project);
        final ctx = EditContext(ids: SeededIdGenerator(seed + 500), now: DateTime.utc(2026, 10, 14));
        var a = compileMemo(project, resolver).plan;
        var changed = 0;
        for (var step = 0; step < 15; step++) {
          final out = applyCommand(project, randomEdit(project, rnd), ctx);
          if (!out.changed) continue;
          changed++;
          final previous = project;
          project = out.project;
          final b = compileMemo(project, resolver).plan;
          // Spans touched: old and new extents of every visual layer that differs (pixels may or
          // may not change there), or everything when the canvas changed.
          final spans = <(TimeUs, TimeUs)>[];
          if (a.canvas != b.canvas) spans.add((0, 1 << 50));
          final oldById = {for (final l in a.layers) l.id: l};
          final newById = {for (final l in b.layers) l.id: l};
          for (final id in {...oldById.keys, ...newById.keys}) {
            final o = oldById[id];
            final n = newById[id];
            if (o != null && n != null && o == n && a.assets[o.asset] == b.assets[n.asset]) continue;
            if (o != null) spans.add((o.t0, o.t1));
            if (n != null) spans.add((n.t0, n.t1));
          }
          for (final r in splitRanges(a)) {
            if (_touches(r, spans)) continue;
            expect(rangeHash(b, r), rangeHash(a, r), reason: 'step $step: $r is outside every changed layer');
          }
          // Undo: recompiling the previous project restores the previous hashes.
          final undone = compileMemo(previous, resolver).plan.copyWith(rev: b.rev + 1);
          expect(rangeHashes(undone), rangeHashes(a), reason: 'step $step: undo');
          a = b;
        }
        expect(changed, greaterThan(3));
      });
    }
  });
}
