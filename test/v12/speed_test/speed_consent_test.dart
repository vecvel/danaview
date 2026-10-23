// OWNER: ST-04
//
// The speed test's open-network prompt, its remembered answer and Settings › Privacy (V2-402),
// neutral copy (V2-405), the details-row notes (V2-404), the one consent call site (V2-23, rule 28)
// and the layout matrix (280–1280 px × text scale 0.85–1.35).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library_test_utils.dart';
import 'speed_test_fakes.dart';

const _consentKey = PrefsSpeedConsentStore.prefsKey;

/// Provider names that must never reach the speed-test UI (D-ST5).
final RegExp brandPattern = RegExp(r'cloudflare|m-?lab\b|measurement[ -]?lab|measurementlab|ndt ?7?\b', caseSensitive: false);

/// Every string the widget tree shows.
List<String> shownStrings(WidgetTester tester) => [
      for (final widget in tester.allWidgets)
        if (widget is Text)
          widget.data ?? widget.textSpan?.toPlainText() ?? ''
        else if (widget is RichText)
          widget.text.toPlainText(),
    ];

void expectNoBrand(WidgetTester tester) {
  for (final text in shownStrings(tester)) {
    expect(brandPattern.hasMatch(text), isFalse, reason: 'shows a provider name: "$text"');
  }
  expect(find.bySemanticsLabel(brandPattern), findsNothing, reason: 'a semantics label names a provider');
}

Widget _screenApp(LibraryTestEnv env, SpeedScenario scenario, {double textScale = 1.0, TargetPlatform? platform}) {
  return libraryTestApp(
    env,
    DanaviewSpeedTestScreen(onBack: () {}),
    textScale: textScale,
    platform: platform ?? TargetPlatform.iOS,
    overrides: [speedTestServiceProvider.overrideWithValue(scenario.service())],
  );
}

Widget _privacyApp(LibraryTestEnv env, {double textScale = 1.0}) {
  return libraryTestApp(
    env,
    Scaffold(
      backgroundColor: DanaviewColors.background,
      body: ListView(padding: const EdgeInsets.all(16), children: const [PrivacySettingsSection()]),
    ),
    textScale: textScale,
  );
}

Future<void> _tapStart(WidgetTester tester) async {
  final start = find.text('Start test');
  await tester.ensureVisible(start);
  await tester.pump();
  await tester.tap(start);
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
}

Future<void> _tapAgain(WidgetTester tester) async {
  final again = find.byWidgetPredicate((w) => w is Text && (w.data == 'Test again' || w.data == 'Try again'));
  await tester.ensureVisible(again);
  await tester.pump();
  await tester.tap(again);
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
}

Future<void> _answer(WidgetTester tester, String choice) async {
  final button = find.text(choice);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await pumpFrames(tester, count: 8);
  expect(tester.takeException(), isNull);
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

final Finder _sheet = find.byType(SpeedConsentSheet);
final Finder _calmFailure = find.text("Couldn't reach a test server");
final Finder _openNote = find.byKey(const ValueKey('speed-note-openNetwork'));
final Finder _twoServersNote = find.byKey(const ValueKey('speed-note-measuredOnTwoServers'));

bool _switchOn(WidgetTester tester) => tester
    .widget<DanaviewSwitchRow>(find.byKey(const ValueKey('privacy-open-network-speed-test')))
    .value;

void main() {
  group('open-network prompt', () {
    testWidgets('first run asks once, runs on the open network after "Run on open network", remembers it',
        (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);
      expect(env.prefs.getString(_consentKey), isNull);

      await _tapStart(tester);
      expect(_sheet, findsOneWidget);
      expect(find.text(SpeedConsentCopy.body), findsOneWidget);
      expect(find.text('Run on open network'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(scenario.open.calls, isEmpty, reason: 'nothing is sent to the open network before the answer');
      expectNoBrand(tester);

      await _answer(tester, 'Run on open network');
      expect(_sheet, findsNothing);
      expect(find.text('Test again'), findsOneWidget);
      expect(scenario.open.calls, isNotEmpty);
      expect(_openNote, findsOneWidget);
      expect(find.textContaining('Open network: measured over a single connection'), findsOneWidget);
      expect(find.textContaining('Tested against a nearby server'), findsOneWidget);
      expect(env.prefs.getString(_consentKey), startsWith('accepted:'));
      expectNoBrand(tester);

      // Remembered: the next run asks nothing.
      final before = scenario.open.calls.length;
      await _tapAgain(tester);
      expect(_sheet, findsNothing);
      expect(scenario.open.calls.length, greaterThan(before));
      expect(find.text('Test again'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('a remembered "Run on open network" runs without asking', (tester) async {
      useSurface(tester, const TestSurface(Size(402, 874), 1.0));
      final env = await LibraryTestEnv.create();
      await env.prefs.setString(_consentKey, 'accepted:1760000000000');
      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);

      await _tapStart(tester);
      expect(_sheet, findsNothing);
      expect(scenario.open.calls, isNotEmpty);
      expect(scenario.lastTicket?.acceptedAt, DateTime.fromMillisecondsSinceEpoch(1760000000000));
      expect(_openNote, findsOneWidget);
      expect(_twoServersNote, findsNothing);
      await _finish(tester, env);
    });

    testWidgets('"Not now" gives the calm failure, is remembered, and the next run never asks', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.35));
      final env = await LibraryTestEnv.create();
      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario, textScale: 1.35));
      await pumpFrames(tester);

      await _tapStart(tester);
      expect(_sheet, findsOneWidget);
      await _answer(tester, 'Not now');
      expect(_calmFailure, findsOneWidget);
      expect(find.textContaining('Try again in a minute.'), findsOneWidget);
      expect(find.textContaining('Settings › Privacy'), findsOneWidget);
      expect(find.text("The test didn't finish"), findsNothing);
      expect(env.prefs.getString(_consentKey), 'declined');
      expect(scenario.open.calls, isEmpty);
      expectNoBrand(tester);

      await _tapAgain(tester);
      expect(_sheet, findsNothing);
      expect(_calmFailure, findsOneWidget);
      expect(scenario.open.calls, isEmpty);
      await _finish(tester, env);
    });

    testWidgets('dismissing the prompt is "Not now" for this run only', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);

      await _tapStart(tester);
      expect(_sheet, findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await pumpFrames(tester, count: 8);
      expect(_sheet, findsNothing);
      expect(_calmFailure, findsOneWidget);
      expect(env.prefs.getString(_consentKey), isNull);

      await _tapAgain(tester);
      expect(_sheet, findsOneWidget, reason: 'never answered, so asked again');
      await _answer(tester, 'Not now');
      await _finish(tester, env);
    });

    testWidgets('the default servers answering never shows the prompt or a note', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      final scenario = SpeedScenario.defaultHealthy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);
      expect(find.textContaining('a nearby test server'), findsOneWidget);

      await _tapStart(tester);
      expect(_sheet, findsNothing);
      expect(scenario.open.calls, isEmpty);
      expect(_openNote, findsNothing);
      expect(_twoServersNote, findsNothing);
      expect(find.textContaining('Tested against a nearby server'), findsOneWidget);
      expect(find.textContaining('Frankfurt (FRA)'), findsOneWidget);
      expect(env.prefs.getString(_consentKey), isNull);
      expectNoBrand(tester);
      await _finish(tester, env);
    });

    testWidgets('upload on another server notes "measured on two servers"', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 800), 1.0));
      final env = await LibraryTestEnv.create();
      await env.prefs.setString(_consentKey, 'accepted:1760000000000');
      final scenario = SpeedScenario.uploadBusy();
      await tester.pumpWidget(_screenApp(env, scenario, platform: TargetPlatform.macOS));
      await pumpFrames(tester);

      await _tapStart(tester);
      expect(_twoServersNote, findsOneWidget);
      expect(_openNote, findsOneWidget);
      expect(find.textContaining('Measured on two servers'), findsOneWidget);
      expectNoBrand(tester);
      await _finish(tester, env);
    });
  });

  group('Settings › Privacy', () {
    testWidgets('shows the remembered answer and turning it off revokes consent', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      await env.prefs.setString(_consentKey, 'accepted:1760000000000');
      await tester.pumpWidget(_privacyApp(env));
      await pumpFrames(tester);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text(PrivacySettingsSection.title), findsOneWidget);
      expect(_switchOn(tester), isTrue);
      expect(find.bySemanticsLabel(RegExp(PrivacySettingsSection.title)), findsWidgets);
      expectNoBrand(tester);

      await tester.tap(find.text(PrivacySettingsSection.title));
      await pumpFrames(tester);
      expect(_switchOn(tester), isFalse);
      expect(env.prefs.getString(_consentKey), 'declined');
      await tester.pumpWidget(const SizedBox());

      // Revoked: the speed test no longer uses the open network and does not ask.
      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);
      await _tapStart(tester);
      expect(_sheet, findsNothing);
      expect(_calmFailure, findsOneWidget);
      expect(scenario.open.calls, isEmpty);
      await _finish(tester, env);
    });

    testWidgets('never asked: off, with a note; turning it on is consent', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(_privacyApp(env));
      await pumpFrames(tester);
      expect(_switchOn(tester), isFalse);
      expect(find.textContaining(PrivacySettingsSection.unaskedNote), findsOneWidget);

      await tester.tap(find.text(PrivacySettingsSection.title));
      await pumpFrames(tester);
      expect(_switchOn(tester), isTrue);
      expect(env.prefs.getString(_consentKey), startsWith('accepted:'));
      expect(find.textContaining(PrivacySettingsSection.unaskedNote), findsNothing);
      await tester.pumpWidget(const SizedBox());

      final scenario = SpeedScenario.defaultBusy();
      await tester.pumpWidget(_screenApp(env, scenario));
      await pumpFrames(tester);
      await _tapStart(tester);
      expect(_sheet, findsNothing);
      expect(_openNote, findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('a declined answer can be turned back on', (tester) async {
      useSurface(tester, const TestSurface(Size(375, 667), 1.0));
      final env = await LibraryTestEnv.create();
      await env.prefs.setString(_consentKey, 'declined');
      await tester.pumpWidget(_privacyApp(env));
      await pumpFrames(tester);
      expect(_switchOn(tester), isFalse);
      expect(find.textContaining(PrivacySettingsSection.unaskedNote), findsNothing);
      await tester.tap(find.text(PrivacySettingsSection.title));
      await pumpFrames(tester);
      expect(env.prefs.getString(_consentKey), startsWith('accepted:'));
      await _finish(tester, env);
    });
  });

  group('remembered answer', () {
    test('round-trips through the prefs value, and unreadable values mean "never asked"', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1760000000000);
      for (final answer in [SpeedConsentAnswer.unasked, SpeedConsentAnswer.declined, SpeedConsentAnswer.accepted(at)]) {
        expect(PrefsSpeedConsentStore.decode(PrefsSpeedConsentStore.encode(answer)), answer);
      }
      for (final junk in ['', 'yes', 'accepted:', 'accepted:soon', 'Declined']) {
        expect(PrefsSpeedConsentStore.decode(junk), SpeedConsentAnswer.unasked, reason: junk);
      }
      expect(PrefsSpeedConsentStore.prefsKey, 'speed.mlabConsent');
    });
  });

  group('layout matrix', () {
    final surfaces = <TestSurface>[
      for (final scale in [0.85, 1.0, 1.35])
        for (final size in const [
          Size(280, 653),
          Size(320, 568),
          Size(375, 667),
          Size(768, 1024),
          Size(874, 402),
          Size(1024, 768),
          Size(1280, 800),
        ])
          TestSurface(size, scale),
    ];
    for (final surface in surfaces) {
      testWidgets('prompt, notes, calm failure and Settings › Privacy fit at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        final platform = surface.size.width >= 1000 ? TargetPlatform.macOS : TargetPlatform.iOS;

        // Prompt, then a result with both notes.
        final scenario = SpeedScenario.uploadBusy(defaultBusyLatency: false);
        await tester.pumpWidget(_screenApp(env, scenario, textScale: surface.textScale, platform: platform));
        await pumpFrames(tester);
        await _scrollThrough(tester);
        await _tapStart(tester);
        expect(_sheet, findsOneWidget);
        expectNoBrand(tester);
        await _answer(tester, 'Run on open network');
        expect(_twoServersNote, findsOneWidget);
        expect(_openNote, findsOneWidget);
        await _scrollThrough(tester);
        expectNoBrand(tester);
        await tester.pumpWidget(const SizedBox());

        // Calm failure.
        await env.prefs.setString(_consentKey, 'declined');
        await tester.pumpWidget(_screenApp(env, SpeedScenario.defaultBusy(), textScale: surface.textScale, platform: platform));
        await pumpFrames(tester);
        await _tapStart(tester);
        expect(_calmFailure, findsOneWidget);
        await _scrollThrough(tester);
        await tester.pumpWidget(const SizedBox());

        // Settings › Privacy.
        await tester.pumpWidget(_privacyApp(env, textScale: surface.textScale));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byKey(const ValueKey('privacy-open-network-speed-test'))).height,
            greaterThanOrEqualTo(44));
        await _finish(tester, env);
      });
    }

    testWidgets('prompt buttons are at least 44 px tall and labelled', (tester) async {
      useSurface(tester, const TestSurface(Size(280, 653), 0.85));
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(_screenApp(env, SpeedScenario.defaultBusy(), textScale: 0.85));
      await pumpFrames(tester);
      await _tapStart(tester);
      for (final label in ['Run on open network', 'Not now']) {
        final button = find.ancestor(of: find.text(label), matching: find.byType(DanaviewButton));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44), reason: label);
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
      await _answer(tester, 'Not now');
      await _finish(tester, env);
    });

    test('the copy reads with enough contrast on the dark UI', () {
      for (final (fg, bg) in [
        (DanaviewColors.textMuted, DanaviewColors.background),
        (DanaviewColors.textMuted, DanaviewColors.surface),
        (DanaviewColors.textMuted, DanaviewColors.surfaceElevated),
        (DanaviewColors.textSecondary, DanaviewColors.surfaceElevated),
        (DanaviewColors.textPrimary, DanaviewColors.surfaceElevated),
      ]) {
        expect(DanaviewColors.contrastRatio(fg, bg), greaterThanOrEqualTo(4.5), reason: '$fg on $bg');
      }
    });
  });

  group('source rules', () {
    final root = Directory.current.path;
    String read(String path) => File('$root/$path').readAsStringSync();

    const speedTestUi = [
      'packages/danaview_features/lib/src/tools/danaview_speed_test_screen.dart',
      'packages/danaview_features/lib/src/tools/speed_consent_sheet.dart',
      'packages/danaview_features/lib/src/tools/speed_gauge.dart',
      'packages/danaview_features/lib/src/tools/network_format.dart',
      'packages/danaview_features/lib/src/tools/network_tool_providers.dart',
      'packages/danaview_features/lib/src/more/settings_sections/privacy_section.dart',
    ];

    test('no provider name in any speed-test widget string', () {
      // Single- and double-quoted literals, adjacent parts included.
      final literal = RegExp(r"""'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|'''[\s\S]*?'''""");
      for (final path in speedTestUi) {
        final lines = read(path).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('//') || line.startsWith('import ') || line.startsWith('export ')) continue;
          for (final m in literal.allMatches(lines[i])) {
            expect(brandPattern.hasMatch(m[0]!), isFalse, reason: '$path:${i + 1}: ${m[0]}');
          }
        }
      }
    });

    test('OpenNetworkConsent.accepted( is called only in speed_consent_sheet.dart (V2-23, rule 28)', () {
      const site = 'packages/danaview_features/lib/src/tools/speed_consent_sheet.dart';
      const declaration = 'packages/danaview_data/lib/src/network/speed/mlab_ndt7_provider.dart';
      final call = RegExp(r'(?<![A-Za-z0-9_$])OpenNetworkConsent\s*\.\s*accepted\s*\(');
      final declares = RegExp(r'factory\s+OpenNetworkConsent\s*\.\s*accepted\s*\(');
      final dirs = [
        Directory('$root/lib'),
        for (final pkg in Directory('$root/packages').listSync().whereType<Directory>()) Directory('${pkg.path}/lib'),
      ];
      final offenders = <String>[];
      var siteCalls = 0;
      for (final dir in dirs.where((d) => d.existsSync())) {
        for (final file in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
          // Repo-relative with '/' on every host: on Windows `file.path` carries backslashes (FIX-S1Q-A1).
          final rel = file.path.substring(root.length + 1).replaceAll(Platform.pathSeparator, '/');
          final code = file
              .readAsStringSync()
              .split('\n')
              .map((l) => l.trimLeft().startsWith('//') ? '' : l)
              .join('\n');
          final calls = call.allMatches(code).length - (rel == declaration ? declares.allMatches(code).length : 0);
          if (rel == site) {
            siteCalls = calls;
          } else if (calls > 0) {
            offenders.add(rel);
          }
        }
      }
      expect(offenders, isEmpty);
      expect(siteCalls, greaterThan(0), reason: 'the sheet is the call site');
    });
  });
}
