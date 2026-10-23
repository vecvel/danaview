// OWNER: INT-101
//
// BUILD_PLAN v1.2 INT-101: the Settings section slots (privacy ST-04, library storage HOM-17, search
// index INT-103) are optional builders. With none set Settings is the 1.1 screen; each set builder
// adds its section after the Tools group, in slot order, without overflow at 280-1280 px and text
// scale 0.85-1.35.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_features/danaview_features.dart';

import '../../library_test_utils.dart';

Widget _section(String title) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    );

void main() {
  test('SettingsSections: empty by default, ordered privacy, library storage, search index', () {
    expect(const SettingsSections().isEmpty, isTrue);
    expect(const SettingsSections(), const SettingsSections());
    Widget a(BuildContext c) => const SizedBox();
    Widget b(BuildContext c) => const SizedBox();
    final all = SettingsSections(searchIndex: a, privacy: b, libraryStorage: a);
    expect(all.ordered.map((e) => e.$1), SettingsSectionSlot.values);
    expect(all[SettingsSectionSlot.privacy], b);
    expect(SettingsSections(searchIndex: a).ordered.single.$1, SettingsSectionSlot.searchIndex);
    expect(SettingsSections(privacy: a), SettingsSections(privacy: a));
    expect(SettingsSections(privacy: a).hashCode, SettingsSections(privacy: a).hashCode);
    expect(SettingsSections(privacy: a), isNot(SettingsSections(privacy: b)));
  });

  testWidgets('no slots: the 1.1 Settings screen', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(libraryTestApp(env, DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {})));
    await pumpFrames(tester);
    for (final slot in SettingsSectionSlot.values) {
      expect(find.byKey(ValueKey('settings-section-${slot.name}')), findsNothing);
    }
    expect(find.text('Speed test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await env.dispose();
  });

  const textScales = [0.85, 1.0, 1.35];
  const widths = [280.0, 375.0, 1280.0];
  for (final width in widths) {
    for (final scale in textScales) {
      testWidgets('slots render after Tools in order at ${width.toInt()} px @${scale}x', (tester) async {
        // Tall enough that every row is laid out without scrolling.
        tester.view.physicalSize = Size(width, 3200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final env = await LibraryTestEnv.create();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewSettingsScreen(
            onBack: () {},
            onNavigate: (_) {},
            sections: SettingsSections(
              privacy: (_) => _section('Privacy slot with a long title that wraps on narrow phones'),
              libraryStorage: (_) => _section('Library storage slot'),
              searchIndex: (_) => _section('Search index slot'),
            ),
          ),
          textScale: scale,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        final keys = [for (final slot in SettingsSectionSlot.values) find.byKey(ValueKey('settings-section-${slot.name}'))];
        for (final k in keys) {
          expect(k, findsOneWidget);
        }
        final storageY = tester.getTopLeft(find.text('Storage & history')).dy;
        final privacyY = tester.getTopLeft(keys[0]).dy;
        expect(privacyY, greaterThan(storageY), reason: 'sections follow the Tools group');
        expect(tester.getTopLeft(keys[1]).dy, greaterThan(privacyY));
        expect(tester.getTopLeft(keys[2]).dy, greaterThan(tester.getTopLeft(keys[1]).dy));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      });
    }
  }
}
