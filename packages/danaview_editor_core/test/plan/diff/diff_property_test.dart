// OWNER: CORE-32
//
// apply(diff(a, b), a) == b over random edit sequences (ARCH §11.8): each step applies a random
// command to a random valid project, compiles the result with the session memo, and checks that
// the patch (also after a JSON round trip) turns the previous plan into the new one; the memoized
// plan equals a fresh compile; and the patch classification agrees with what changed.

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';
import '../compile_visual/support.dart' show resolverFor;
import 'diff_support.dart';

void main() {
  for (var seed = 0; seed < 24; seed++) {
    test('seed $seed: 20 random edits', () {
      final rnd = Random(seed);
      var p = randomProject(seed, const RandomProjectSpec(items: 60));
      final resolver = resolverFor(p);
      final memo = PlanMemo();
      final ctx = EditContext(ids: SeededIdGenerator(seed + 1000), now: DateTime.utc(2026, 10, 10));
      var a = compileMemo(p, resolver, memo: memo).plan;
      var changed = 0;
      for (var step = 0; step < 20; step++) {
        final out = applyCommand(p, randomEdit(p, rnd), ctx);
        if (!out.changed) continue;
        changed++;
        p = out.project;
        final b = compileMemo(p, resolver, memo: memo).plan;
        expect(b, compileMemo(p, resolver).plan, reason: 'memoized compile equals a fresh one (step $step)');
        final patch = diffPlans(a, b);
        expect(withoutReq(applyPatch(a, patch)), withoutReq(b), reason: 'step $step');
        final wire = PlanJson.decodePatchBytes(PlanJson.encodePatchBytes(patch));
        expect(withoutReq(applyPatch(a, wire)), withoutReq(b), reason: 'wire round trip, step $step');
        // Classification agrees with the definition: param-only iff no structural field moved.
        final structural = a.canvas != b.canvas ||
            a.durUs != b.durUs ||
            patch.assetUpserts.isNotEmpty ||
            patch.assetRemovals.isNotEmpty ||
            patch.layers.remove.isNotEmpty ||
            patch.audio.remove.isNotEmpty ||
            patch.layers.upsert.any((l) {
              final old = a.layers.where((x) => x.id == l.id).firstOrNull;
              return old == null || layerTimingChanged(old, l);
            }) ||
            patch.audio.upsert.any((s) {
              final old = a.audio.where((x) => x.id == s.id).firstOrNull;
              return old == null || audioStructureChanged(old, s);
            });
        expect(classifyPatch(a, patch), structural ? PatchClass.structural : PatchClass.paramOnly);
        a = b;
      }
      expect(changed, greaterThan(5));
    });
  }

  test('diff of a plan with itself is empty and applies to itself', () {
    final p = randomProject(3);
    final a = compileMemo(p, resolverFor(p)).plan;
    final patch = diffPlans(a, a);
    expect(isEmptyPatch(patch), isTrue);
    expect(classifyPatch(a, patch), PatchClass.paramOnly);
    expect(applyPatch(a, patch), a);
  });

  test('random pairs of unrelated plans', () {
    for (var seed = 0; seed < 20; seed++) {
      final pa = randomProject(seed, const RandomProjectSpec(items: 40));
      final pb = randomProject(seed + 100, const RandomProjectSpec(items: 40));
      final a = compileMemo(pa, resolverFor(pa)).plan;
      final b = compileMemo(pb, resolverFor(pb)).plan;
      final patch = diffPlans(a, b);
      expect(withoutReq(applyPatch(a, patch)), withoutReq(b));
      expect(classifyPatch(a, patch), PatchClass.structural);
    }
  });

  test('a patch applies only at its from revision (planOutOfSync)', () {
    final p = randomProject(5);
    final a = compileMemo(p, resolverFor(p)).plan;
    final b = a.copyWith(rev: a.rev + 1);
    final patch = diffPlans(a, b);
    expect(patch.from, a.rev);
    expect(patch.to, a.rev + 1);
    expect(() => applyPatch(b, patch), throwsA(isA<PlanOutOfSync>()));
    expect(applyPatch(a, patch).rev, a.rev + 1);
  });

  test('identity-first: unchanged memoized layers are identical objects across compiles', () {
    final p = randomProject(9, const RandomProjectSpec(items: 60));
    final resolver = resolverFor(p);
    final memo = PlanMemo();
    final a = compileMemo(p, resolver, memo: memo).plan;
    final b = compileMemo(p, resolver, memo: memo).plan;
    final byId = {for (final l in a.layers) l.id: l};
    final same = b.layers.where((l) => identical(byId[l.id], l)).length;
    expect(same, greaterThan(b.layers.length ~/ 2));
    final audio = {for (final s in a.audio) s.id: s};
    expect(b.audio.every((s) => identical(audio[s.id], s)), isTrue);
    expect(isEmptyPatch(diffPlans(a, b)), isTrue);
  });
}
