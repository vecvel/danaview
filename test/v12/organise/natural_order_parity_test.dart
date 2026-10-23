// OWNER: HOM-19
//
// BUILD_PLAN HOM-19: sort by name uses "the 1.1 natural_sort.dart". danaview_library can't import
// danaview_data (ARCH rule 20), so it carries a port; this pins the port to the real 1.1
// comparator over random and hand-picked names.

import 'dart:math';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compareNatural orders exactly like NaturalSortComparator.compare', () {
    const picked = [
      'Episode 2', 'Episode 10', 'episode 1', 'S01E02', 's01e10', 'a', 'A', '', '10', '9', '010',
      'Movie (2019).mkv', 'Movie (2020).mkv', 'x99999999999999999999999', 'x100000000000000000000000',
      'Ünïcode 3', 'unicode 3', 'file-1', 'file_1', 'file 1',
    ];
    for (final a in picked) {
      for (final b in picked) {
        expect(compareNatural(a, b).sign, NaturalSortComparator.compare(a, b).sign, reason: '"$a" vs "$b"');
      }
    }
    final r = Random(1911);
    const parts = ['a', 'Z', 'ep', ' ', '.', '-', '0', '7', '42', '0009', '123456789012345678901', 'é', '_'];
    String name() => List.generate(r.nextInt(7), (_) => parts[r.nextInt(parts.length)]).join();
    for (var i = 0; i < 5000; i++) {
      final a = name();
      final b = name();
      expect(compareNatural(a, b).sign, NaturalSortComparator.compare(a, b).sign, reason: '"$a" vs "$b"');
    }
  });
}
