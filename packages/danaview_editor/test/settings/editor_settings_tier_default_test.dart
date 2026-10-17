// OWNER: FIX-UX44-HOOKS
//
// The Editor settings screen's UX-44 hooks (D-45, ARCH §17.10): the proxy row shows the device
// tier's default when the user never set `editor.proxyMedia` (Always on minimal/low, Auto on
// mid/high) and its hint marks that default; an explicit preference wins; the Render preview
// section is mounted in the screen's second slot.

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/app/strings/settings_strings.dart';
import 'package:danaview_editor/src/settings/render_preview_settings_section.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

ProxyMediaMode _proxyShown(WidgetTester tester) => tester
    .widget<DanaviewSegmentedControl<ProxyMediaMode>>(find.descendant(
      of: find.byKey(const ValueKey('editor-settings-proxy')),
      matching: find.byType(DanaviewSegmentedControl<ProxyMediaMode>),
    ))
    .value;

Future<void> _pump(WidgetTester tester, DeviceTier tier, {Map<String, Object> stored = const {}}) async {
  final h = EditorTestHarness(
    engine: FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: tier)),
    prefs: EditorPrefs.memory(stored),
  );
  await h.pumpApp(tester, EditorSettingsScreen(key: UniqueKey(), onBack: () {}));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('minimal/low: unset proxy pref shows Always, marked as the tier default', (tester) async {
    for (final tier in [DeviceTier.minimal, DeviceTier.low]) {
      await _pump(tester, tier);
      expect(_proxyShown(tester), ProxyMediaMode.always, reason: tier.name);
      expect(find.textContaining('Recommended for this device.'), findsOneWidget, reason: tier.name);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('mid/high: unset proxy pref shows Auto with its recommended hint', (tester) async {
    for (final tier in [DeviceTier.mid, DeviceTier.high]) {
      await _pump(tester, tier);
      expect(_proxyShown(tester), ProxyMediaMode.auto, reason: tier.name);
      expect(find.text(SettingsStrings.proxyHint(ProxyMediaMode.auto)), findsOneWidget, reason: tier.name);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an explicit proxy preference wins over the tier default', (tester) async {
    await _pump(tester, DeviceTier.low, stored: {EditorPrefKeys.proxyMedia: 'off'});
    expect(_proxyShown(tester), ProxyMediaMode.off);
    expect(find.textContaining('Recommended for this device.'), findsNothing);
  });

  testWidgets('the Render preview section is mounted in the second slot', (tester) async {
    await _pump(tester, DeviceTier.mid);
    final section = find.byType(RenderPreviewSettingsSection);
    await tester.scrollUntilVisible(section, 120, scrollable: find.byType(Scrollable).first);
    expect(section, findsOneWidget);
  });
}
