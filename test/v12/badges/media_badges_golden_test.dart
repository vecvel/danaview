// OWNER: HOM-13
//
// BUILD_PLAN HOM-13 acceptance: a golden per badge combination, each over a light and a dark
// thumbnail, plus the compact (narrow cell) form. Refresh with
//   flutter test test/v12/badges/media_badges_golden_test.dart --update-goldens
// and inspect the images in goldens/ before keeping them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'badges_support.dart';

void main() {
  for (final MapEntry(key: name, value: badges) in badgeCombinations.entries) {
    testWidgets('golden: $name over light and dark thumbnails', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(badgeApp(Row(mainAxisSize: MainAxisSize.min, children: [
        badgeCell(badges, thumb: lightThumb),
        const SizedBox(width: 8),
        badgeCell(badges, thumb: darkThumb),
      ])));
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('badge-golden')), matchesGoldenFile('goldens/$name.png'));
    });
  }

  testWidgets('golden: compact cells show the first indicator and the duration', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final everything = badgeCombinations['everything']!;
    await tester.pumpWidget(badgeApp(Row(mainAxisSize: MainAxisSize.min, children: [
      badgeCell(everything, thumb: lightThumb, width: 96, height: 96),
      const SizedBox(width: 8),
      badgeCell(everything, thumb: darkThumb, width: 96, height: 96),
      const SizedBox(width: 8),
      badgeCell(everything, thumb: darkThumb, width: 64, height: 64),
    ])));
    expect(tester.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('badge-golden')), matchesGoldenFile('goldens/compact.png'));
  });
}
