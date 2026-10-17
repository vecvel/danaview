// OWNER: CORE-08
//
// Properties on random projects (BUILD_PLAN CORE-08 acceptance):
// * incremental `validate(only: S)` equals the full result filtered to S (plus project-level
//   violations) on 500 random projects, valid and corrupted;
// * `repair()` of a corrupted project always validates clean and reports what it fixed;
// * `repair()` of a valid project is the identity.

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';
import 'corruption.dart';

void main() {
  test('incremental only: equals full validation on 500 random projects', () {
    var withViolations = 0;
    for (var seed = 0; seed < 500; seed++) {
      final rnd = Random(seed);
      var p = randomProject(seed, const RandomProjectSpec(items: 40));
      if (seed % 5 != 0) p = corrupt(p, rnd);
      final full = validate(p);
      if (full.isNotEmpty) withViolations++;
      final ids = p.tracks.map((t) => t.id).toList();
      for (var round = 0; round < 3; round++) {
        final only = {for (final id in ids) if (rnd.nextBool()) id};
        final expected = [for (final v in full) if (v.track == null || only.contains(v.track)) v];
        expect(validate(p, only: only), expected, reason: 'seed $seed only $only');
      }
      // One track at a time, the union is the full result.
      final union = <Violation>{};
      for (final id in ids.toSet()) {
        union.addAll(validate(p, only: {id}));
      }
      expect(union, full.toSet(), reason: 'seed $seed');
      expect(validateTimeline(p.timeline, p.pool), full);
    }
    expect(withViolations, greaterThan(350));
  });

  test('every corruption is detected and repaired', () {
    for (final entry in corruptions.entries) {
      var hits = 0;
      for (var seed = 0; seed < 40; seed++) {
        final rnd = Random(seed);
        final base = randomProject(seed, const RandomProjectSpec(items: 30));
        final bad = entry.value(base, rnd);
        if (bad == null) continue;
        final v = validate(bad);
        if (v.isEmpty) continue; // a few mutations can land on a value that is still valid
        hits++;
        final (fixed, warnings) = repair(bad, ids: SeededIdGenerator(seed));
        expect(validate(fixed), isEmpty, reason: '${entry.key} seed $seed: ${validate(fixed).take(4).join('\n')}');
        expect(warnings, isNotEmpty, reason: entry.key);
      }
      expect(hits, greaterThan(10), reason: '${entry.key} is rarely detected');
    }
  });

  test('repair of 500 randomly corrupted projects validates clean', () {
    for (var seed = 0; seed < 500; seed++) {
      final rnd = Random(seed);
      final applied = <String>[];
      final bad = corrupt(randomProject(seed, const RandomProjectSpec(items: 40)), rnd, maxCount: 5, applied: applied);
      final (fixed, warnings) = repair(bad, ids: SeededIdGenerator(seed));
      final left = validate(fixed);
      expect(left, isEmpty, reason: 'seed $seed after $applied: ${left.take(4).join('\n')}');
      if (validate(bad).isNotEmpty) expect(warnings, isNotEmpty);
      // Repair is idempotent.
      final (again, more) = repair(fixed);
      expect(identical(again, fixed), isTrue);
      expect(more, isEmpty);
    }
  });

  test('repair of a valid project is the identity with no warnings', () {
    for (var seed = 0; seed < 50; seed++) {
      final p = randomProject(seed);
      final (out, warnings) = repair(p);
      expect(identical(out, p), isTrue);
      expect(warnings, isEmpty);
    }
  });
}
