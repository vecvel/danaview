// OWNER: CORE-34
//
// Replays every regression fixture in test/fuzz/regressions/ (fuzz_fixture.dart):
//
// * a fixture without `defect` must replay without any failure (known defects not tolerated);
// * a fixture whose `defect` is still listed in fuzz_known_defects.dart must still fail with that
//   defect, and pass when the defect is tolerated. When the owner fixes the defect, this test
//   fails until the entry and the fixture's `defect` field are deleted;
// * every listed defect has at least one fixture.

import 'dart:io';

import 'package:test/test.dart';

import 'fuzz_fixture.dart';
import 'fuzz_known_defects.dart';
import 'fuzz_runner.dart';

void main() {
  final fixtures = FuzzFixture.readAll(Directory('test/fuzz/regressions'));
  final open = {for (final d in knownDefects) d.id};

  test('the regression fixtures load', () {
    expect(fixtures, isNotEmpty);
    expect({for (final f in fixtures) f.name}.length, fixtures.length, reason: 'fixture names are unique');
  });

  test('every open known defect has a regression fixture', () {
    final covered = {for (final f in fixtures) if (f.defect != null) f.defect!};
    expect(open.difference(covered), isEmpty);
  });

  for (final f in fixtures) {
    final defect = f.defect;
    test('${f.name} (${f.steps.length} steps${defect == null ? '' : ', $defect'})', () {
      final strict = FuzzRunner.run(f.toCase(), tolerateKnownDefects: false);
      if (defect == null) {
        expect(strict.failure, isNull, reason: 'the fixed failure ${f.failure?.signature} came back');
        return;
      }
      if (!open.contains(defect)) {
        fail('$defect is not listed in fuzz_known_defects.dart any more. If it is fixed, delete the '
            '"defect" field of ${f.name}.json so the fixture replays as an ordinary regression test.');
      }
      expect(strict.failure, isNotNull,
          reason: '$defect no longer reproduces. If it is fixed, delete its entry in fuzz_known_defects.dart '
              'and the "defect" field of ${f.name}.json.');
      expect(strict.failure!.defect, defect, reason: 'failed differently: ${strict.failure}');
      if (f.failure != null) expect(strict.failure!.signature, f.failure!.signature);
      // Tolerated, the same run passes: nothing else is wrong with it.
      final tolerant = FuzzRunner.run(f.toCase());
      expect(tolerant.failure, isNull);
      expect(tolerant.stats['known:$defect'], greaterThanOrEqualTo(1));
    });
  }
}
