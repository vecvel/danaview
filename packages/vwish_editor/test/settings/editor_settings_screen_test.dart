// OWNER: UX-04
//
// The Editor settings screen (ARCH §17.10, ux.md §4.8): every setting is written to its `editor.`
// preference the moment it changes (in memory and through SharedPreferences), the screen reflects
// stored values, the Auto captions slot (UX-38) appears only with VWISH_AUTO_CAPTIONS, and the
// screen has no overflow and follows the owner UI rules on the surface matrix.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vwish_editor/src/settings/captions_settings_section.dart';
import 'package:vwish_editor/vwish_editor.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';

Finder _inSetting(String key, Finder matching) => find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

Future<void> _tapIn(WidgetTester tester, String key, String label) async {
  final target = _inSetting(key, find.text(label));
  await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

T _segmentValue<T>(WidgetTester tester, String key) =>
    tester.widget<VwishSegmentedControl<T>>(_inSetting(key, find.byType(VwishSegmentedControl<T>))).value;

/// Every widget [finder] finds lies within the screen width (the list scrolls vertically).
void _expectWithinWidth(WidgetTester tester, Finder finder) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byElementPredicate((e) => identical(e, element)));
    expect(rect.left >= -0.01 && rect.right <= width + 0.01, isTrue, reason: '$rect exceeds the width $width');
  }
}

/// Scrolls the settings list to the end, checking for overflow after every step.
Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 30; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 50));
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  }
}

void main() {
  tearDown(() => EditorFlags.debugAutoCaptionsOverride = null);

  group('EditorSettingsScreen', () {
    testWidgets('shows the defaults and every section', (tester) async {
      final h = EditorTestHarness();
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      expect(find.text('Video editor'), findsOneWidget);
      expect(_segmentValue<ProxyMediaMode>(tester, 'editor-settings-proxy'), ProxyMediaMode.auto);
      expect(_segmentValue<PreviewQualityPreference>(tester, 'editor-settings-preview-quality'), PreviewQualityPreference.auto);
      expect(find.text('Recommended: proxies are made only for media that needs them.'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('editor-settings-aspect')), 120, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('editor-settings-center-playhead'))).value, isTrue);
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('editor-settings-snapping-haptics'))).value, isTrue);
      expect(_segmentValue<NewProjectAspect>(tester, 'editor-settings-aspect'), NewProjectAspect.matchFirstClip);
      expectNoOverflow(tester);
    });

    testWidgets('every change is written to its editor. key at once', (tester) async {
      final backend = MemoryEditorPrefsBackend();
      final h = EditorTestHarness(prefs: EditorPrefs(backend));
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));

      await _tapIn(tester, 'editor-settings-proxy', 'Always');
      expect(backend.values[EditorPrefKeys.proxyMedia], 'always');
      expect(find.text('Every video gets a proxy. Uses more storage.'), findsOneWidget);

      await _tapIn(tester, 'editor-settings-preview-quality', 'Half');
      expect(backend.values[EditorPrefKeys.previewQuality], 'half');

      await _tapKey(tester, 'editor-settings-center-playhead');
      expect(backend.values[EditorPrefKeys.centerPlayheadOnTouch], isFalse);

      await _tapKey(tester, 'editor-settings-snapping-haptics');
      expect(backend.values[EditorPrefKeys.snappingHaptics], isFalse);

      await _tapIn(tester, 'editor-settings-aspect', '9:16');
      expect(backend.values[EditorPrefKeys.newProjectAspect], 'portrait9x16');

      // Only editor keys were written.
      expect(backend.keys.every(EditorPrefKeys.isEditorKey), isTrue);
      // The screen reflects the new values.
      expect(_segmentValue<ProxyMediaMode>(tester, 'editor-settings-proxy'), ProxyMediaMode.always);
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('editor-settings-snapping-haptics'))).value, isFalse);
    });

    testWidgets('stored values are shown when the screen opens', (tester) async {
      final prefs = EditorPrefs.memory({
        EditorPrefKeys.proxyMedia: 'off',
        EditorPrefKeys.previewQuality: 'full',
        EditorPrefKeys.centerPlayheadOnTouch: false,
        EditorPrefKeys.newProjectAspect: 'square',
      });
      final h = EditorTestHarness(prefs: prefs);
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      expect(_segmentValue<ProxyMediaMode>(tester, 'editor-settings-proxy'), ProxyMediaMode.off);
      expect(find.text('Large videos may play back slowly while editing.'), findsOneWidget);
      expect(_segmentValue<PreviewQualityPreference>(tester, 'editor-settings-preview-quality'), PreviewQualityPreference.full);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('editor-settings-aspect')), 120, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('editor-settings-center-playhead'))).value, isFalse);
      expect(_segmentValue<NewProjectAspect>(tester, 'editor-settings-aspect'), NewProjectAspect.square);
    });

    testWidgets('changes persist through SharedPreferences', (tester) async {
      SharedPreferences.setMockInitialValues({'player.unrelated': 3});
      final prefs = await EditorPrefs.load();
      final h = EditorTestHarness(prefs: prefs);
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      await _tapIn(tester, 'editor-settings-proxy', 'Off');
      await _tapKey(tester, 'editor-settings-snapping-haptics');
      await _tapIn(tester, 'editor-settings-aspect', '4:5');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(EditorPrefKeys.proxyMedia), 'off');
      expect(stored.getBool(EditorPrefKeys.snappingHaptics), isFalse);
      expect(stored.getString(EditorPrefKeys.newProjectAspect), 'portrait4x5');
      expect(stored.getInt('player.unrelated'), 3);

      // A fresh load (next app start) sees the same values.
      final reloaded = await EditorPrefs.load();
      expect(reloaded.proxyMedia, ProxyMediaMode.off);
      expect(reloaded.snappingHaptics, isFalse);
      expect(reloaded.newProjectAspect, NewProjectAspect.portrait4x5);
    });

    testWidgets('back goes through the router callback', (tester) async {
      var back = 0;
      final h = EditorTestHarness();
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () => back++));
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
      await tester.pump();
      expect(back, 1);
    });

    testWidgets('the Auto captions section is a slot shown only with VWISH_AUTO_CAPTIONS', (tester) async {
      final h = EditorTestHarness();
      EditorFlags.debugAutoCaptionsOverride = false;
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('editor-settings-aspect')), 120, scrollable: find.byType(Scrollable).first);
      expect(find.byType(CaptionsSettingsSection), findsNothing);

      EditorFlags.debugAutoCaptionsOverride = true;
      await h.pumpApp(tester, EditorSettingsScreen(key: UniqueKey(), onBack: () {}));
      await tester.scrollUntilVisible(find.byType(CaptionsSettingsSection), 120, scrollable: find.byType(Scrollable).first);
      expect(find.byType(CaptionsSettingsSection), findsOneWidget);
    });

    for (final captions in [false, true]) {
      testSurfaces('no overflow while scrolling (captions ${captions ? 'on' : 'off'})', (tester, surface) async {
        EditorFlags.debugAutoCaptionsOverride = captions;
        final h = EditorTestHarness(prefs: EditorPrefs.memory({EditorPrefKeys.proxyMedia: 'always'}));
        await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}), surface: surface);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        _expectWithinWidth(tester, find.byType(VwishSegmentedControl<ProxyMediaMode>));
        await _scrollThrough(tester);
      });
    }
  });
}
