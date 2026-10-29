// OWNER: HOM-05
//
// BUILD_PLAN HOM-05, ARCH v1.2 §1.5 / V2-32: with DANAVIEW_FILES_HOME off the Home renders the
// flag-off tree (no tabs, the header scrolling with the sections). The goldens in goldens/ were
// regenerated for the Cinema B Home (DESIGN_SYSTEM §10, owner-approved 2026-10-28); the tab shell
// must leave them pixel-equal at four widths (phone, iPad portrait, desktop).

import 'package:danaview_features/danaview_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import 'home_shell_support.dart';

void main() {
  for (final width in [320.0, 402.0, 820.0, 1280.0]) {
    testWidgets('flag off: the 1.1 Home is pixel-equal at ${width.toInt()} px', (tester) async {
      useFilesHome(false);
      useSurface(tester, TestSurface(Size(width, 1400), 1.0, padding: const EdgeInsets.only(top: 20)));
      final env = await LibraryTestEnv.create();
      await seedFixedLibrary(env);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(
          onOpenPlayer: () {},
          onOpenFolder: (_) {},
          onOpenPlaylist: (_) {},
          onOpenSettings: () {},
          onOpenEditor: () {},
        ),
      ));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(DanaviewHomeScreen), matchesGoldenFile('goldens/flag_off_${width.toInt()}.png'));
      await finishHome(tester, env);
    });
  }
}
