// OWNER: S1-W
//
// BUILD_PLAN v1.2 §1A, S1 gate "Wiring and legal": the S1 features are reachable in the real app
// (DanaviewApp with the app router) and nothing else of 1.2.0 is:
//
// * Settings shows Settings › Privacy (ST-04) in the privacy slot and no other 1.2.0 section;
// * the speed test is the fallback service by default, asks once before the open network, and the
//   answer shows up in (and is changed from) Settings › Privacy;
// * every 1.2.0 flag is false by default, and the compile-time flags the app reads are only the
//   known v1.1 and 1.2.0 ones, all defaulting to false (S1 adds none: the fallback is consent-gated);
// * Settings with the new section does not overflow at 280-1280 px and text scale 0.85-1.35.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:danaview/app.dart';
import 'package:danaview/router/app_router.dart';
import 'package:danaview_features/danaview_features.dart';
// The 1.2.0 flags are not exported by the features barrel (INT-101 file).
// ignore: implementation_imports
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library_test_utils.dart';
import '../speed_test/speed_test_fakes.dart';

const _consentKey = PrefsSpeedConsentStore.prefsKey;
final Finder _privacySection = find.byKey(const ValueKey('settings-section-privacy'));
final Finder _toggle = find.byKey(const ValueKey('privacy-open-network-speed-test'));

class _App {
  _App(this.tester, this.env, this.container);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;

  GoRouter get router => GoRouter.of(tester.element(find.byType(Navigator).first));

  Future<void> go(String location) async {
    router.go(location);
    await pumpFrames(tester, count: 10);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 10);
    container.dispose();
    await env.dispose();
  }
}

Future<_App> _pumpApp(WidgetTester tester, {List<Override> overrides = const [], double textScale = 1.0}) async {
  final env = await LibraryTestEnv.create();
  final container = ProviderContainer(overrides: [...env.overrides, ...overrides]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return _App(tester, env, container);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpFrames(tester, count: 8);
  expect(tester.takeException(), isNull);
}

bool _switchOn(WidgetTester tester) => tester.widget<DanaviewSwitchRow>(_toggle).value;

void main() {
  group('S1 flag set: identical to 1.1 by default', () {
    test('every 1.2.0 flag defaults to false', () {
      expect(
        [FeatureFlags.filesHome, FeatureFlags.photoEditor, FeatureFlags.beauty, FeatureFlags.aiStudio],
        everyElement(isFalse),
      );
    });

    test('the app reads only the known compile-time flags, each defaulting to false', () {
      const known = {
        'DANAVIEW_EDITOR',
        'DANAVIEW_AUTO_CAPTIONS',
        'DANAVIEW_FILES_HOME',
        'DANAVIEW_PHOTO_EDITOR',
        'DANAVIEW_BEAUTY',
        'DANAVIEW_AI_STUDIO',
      };
      final define = RegExp(r"bool\.fromEnvironment\(\s*'([A-Za-z0-9_.]+)'\s*(,[^)]*)?\)");
      final roots = [Directory('lib'), ...Directory('packages').listSync().whereType<Directory>().map((d) => Directory('${d.path}/lib'))];
      final found = <String, String>{};
      for (final root in roots.where((d) => d.existsSync())) {
        for (final file in root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
          for (final m in define.allMatches(file.readAsStringSync())) {
            final name = m.group(1)!;
            if (name.startsWith('dart.')) continue;
            found[name] = file.path;
            expect(m.group(2), anyOf(isNull, contains('defaultValue: false')), reason: '$name in ${file.path} must default to false');
          }
        }
      }
      expect(found.keys.toSet().difference(known), isEmpty, reason: 'an unknown flag: $found');
    });

    test('the app hands Settings exactly the S1 section (privacy)', () {
      expect(appSettingsSections.ordered.map((e) => e.$1), [SettingsSectionSlot.privacy]);
      expect(appSettingsSections.libraryStorage, isNull, reason: 'HOM-17 joins with S2');
      expect(appSettingsSections.searchIndex, isNull, reason: 'INT-103 joins with S7');
    });
  });

  group('the speed-test fallback in the app', () {
    testWidgets('the default speed-test service is the fallback coordinator', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester);
      expect(app.container.read(speedTestServiceProvider), isA<FallbackSpeedTestService>());
      await app.dispose();
    });

    testWidgets('Settings › Privacy shows after Tools; the speed test asks once; the answer shows in Settings',
        (tester) async {
      // Tall enough that every Settings row is laid out, so the order can be measured.
      useSurface(tester, const TestSurface(Size(390, 2400), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)));
      final scenario = SpeedScenario.defaultBusy();
      final app = await _pumpApp(tester, overrides: [speedTestServiceProvider.overrideWithValue(scenario.service())]);

      await app.go('/settings');
      expect(find.byType(DanaviewSettingsScreen), findsOneWidget);
      expect(_privacySection, findsOneWidget);
      expect(find.byKey(const ValueKey('settings-section-libraryStorage')), findsNothing);
      expect(find.byKey(const ValueKey('settings-section-searchIndex')), findsNothing);
      await tester.ensureVisible(_toggle);
      await pumpFrames(tester);
      expect(find.text(PrivacySettingsSection.title), findsOneWidget);
      expect(_switchOn(tester), isFalse);
      expect(find.textContaining(PrivacySettingsSection.unaskedNote), findsOneWidget);
      expect(
        tester.getTopLeft(_privacySection).dy,
        greaterThan(tester.getTopLeft(find.text('Storage & history')).dy),
        reason: 'the section follows the Tools group',
      );

      // Settings › Speed test, as in 1.1; the default servers are busy, so the prompt shows.
      await tester.ensureVisible(find.text('Speed test'));
      await pumpFrames(tester);
      await _tap(tester, find.text('Speed test'));
      expect(find.byType(DanaviewSpeedTestScreen), findsOneWidget);
      expect(app.router.state.uri.toString(), settingsLocation(SettingsDestination.speedTest));
      await _tap(tester, find.text('Start test'));
      expect(find.byType(SpeedConsentSheet), findsOneWidget);
      expect(scenario.open.calls, isEmpty, reason: 'nothing reaches the open network before the answer');
      await _tap(tester, find.text(SpeedConsentCopy.accept));
      expect(find.byType(SpeedConsentSheet), findsNothing);
      expect(scenario.open.calls, isNotEmpty);
      expect(app.env.prefs.getString(_consentKey), startsWith('accepted:'));

      // Back in Settings the toggle shows the answer; turning it off revokes it.
      app.router.pop();
      await pumpFrames(tester, count: 10);
      expect(find.byType(DanaviewSettingsScreen), findsOneWidget);
      await tester.ensureVisible(_toggle);
      await pumpFrames(tester);
      expect(_switchOn(tester), isTrue);
      await _tap(tester, _toggle);
      expect(_switchOn(tester), isFalse);
      expect(app.env.prefs.getString(_consentKey), 'declined');

      // Declined: the next run never asks and never uses the open network.
      final before = scenario.open.calls.length;
      await _tap(tester, find.text('Speed test'));
      await _tap(tester, find.text('Start test'));
      expect(find.byType(SpeedConsentSheet), findsNothing);
      expect(scenario.open.calls.length, before);
      await app.dispose();
    });

    testWidgets('the default servers answering: no prompt, as in 1.1', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final scenario = SpeedScenario.defaultHealthy();
      final app = await _pumpApp(tester, overrides: [speedTestServiceProvider.overrideWithValue(scenario.service())]);
      await app.go(settingsLocation(SettingsDestination.speedTest));
      await _tap(tester, find.text('Start test'));
      expect(find.byType(SpeedConsentSheet), findsNothing);
      expect(scenario.open.calls, isEmpty);
      expect(find.text('Test again'), findsOneWidget);
      expect(app.env.prefs.getString(_consentKey), isNull);
      await app.dispose();
    });
  });

  group('Settings with the S1 section fits', () {
    for (final width in [280.0, 375.0, 1280.0]) {
      for (final scale in [0.85, 1.35]) {
        testWidgets('${width.toInt()} px @${scale}x', (tester) async {
          useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 640), scale));
          final app = await _pumpApp(tester, textScale: scale);
          await app.go('/settings');
          expect(tester.takeException(), isNull);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 40; i++) {
            final position = tester.state<ScrollableState>(scrollable).position;
            if (position.pixels >= position.maxScrollExtent) break;
            await tester.drag(scrollable, const Offset(0, -300));
            await tester.pump(const Duration(milliseconds: 100));
            expect(tester.takeException(), isNull);
          }
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await pumpFrames(tester);
          await tester.scrollUntilVisible(_toggle, 200, scrollable: scrollable);
          await pumpFrames(tester);
          expect(_toggle.hitTestable(), findsOneWidget, reason: 'the toggle is reachable');
          expect(MediaQuery.textScalerOf(tester.element(_toggle)).scale(10), closeTo(10 * scale, 0.01));
          expect(tester.getSize(_toggle).height, greaterThanOrEqualTo(44));
          await app.dispose();
        });
      }
    }
  });
}
