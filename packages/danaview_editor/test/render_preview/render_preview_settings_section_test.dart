// OWNER: UX-44
//
// The Render preview settings section (ARCH §17.10, D-45): Auto/Manual with the tier default
// (unset -> tier default, explicit wins, written to `editor.renderPreview`), the one-line
// trade-off, and "Clear rendered previews" (size, confirmation, clears `renders/`).

import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_tier_defaults.dart';
import 'package:danaview_editor/src/app/strings/render_preview_strings.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/settings/render_preview_settings_section.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'support.dart';

const _hash = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

EditorTestHarness _harness({DeviceTier tier = DeviceTier.mid, EditorPrefs? prefs, RenderPreviewStore? store}) => EditorTestHarness(
      engine: FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: tier)),
      prefs: prefs,
      overrides: [if (store != null) renderPreviewStoreProvider.overrideWithValue(store)],
    );

Widget _page() => const Scaffold(
      backgroundColor: DanaviewColors.background,
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: RenderPreviewSettingsSection(),
      ),
    );

RenderPreviewSetting _shown(WidgetTester tester) =>
    tester.widget<DanaviewSegmentedControl<RenderPreviewSetting>>(find.byKey(const ValueKey('render-preview-setting'))).value;

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('render-preview-setting')), matching: find.text(label)));
  await tester.pumpAndSettle();
}

String _hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('render-preview-hint'))).data!;

Future<MemoryRenderStore> _storeWithRender() async {
  final store = MemoryRenderStore();
  await store.open();
  await store.put(_hash, store.stagingPathFor(_hash));
  return store;
}

void main() {
  testWidgets('minimal/low: unset shows Auto as recommended; choosing Manual stores it', (tester) async {
    for (final tier in [DeviceTier.minimal, DeviceTier.low]) {
      final backend = MemoryEditorPrefsBackend();
      final h = _harness(tier: tier, prefs: EditorPrefs(backend));
      await h.pumpApp(tester, _page());
      await tester.pumpAndSettle();
      expect(_shown(tester), RenderPreviewSetting.auto, reason: tier.name);
      expect(_hint(tester), RenderPreviewStrings.settingHint(RenderPreviewSetting.auto, isDefault: true));
      expect(find.text(RenderPreviewStrings.settingDescription), findsOneWidget);

      await _choose(tester, 'Manual');
      expect(backend.values[RenderPreviewPrefKeys.renderPreview], 'manual');
      expect(_shown(tester), RenderPreviewSetting.manual);
      expect(_hint(tester), RenderPreviewStrings.settingHint(RenderPreviewSetting.manual, isDefault: false));
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('mid/high: unset shows Manual; Auto explains nothing renders automatically', (tester) async {
    for (final tier in [DeviceTier.mid, DeviceTier.high]) {
      final backend = MemoryEditorPrefsBackend();
      final h = _harness(tier: tier, prefs: EditorPrefs(backend));
      await h.pumpApp(tester, _page());
      await tester.pumpAndSettle();
      expect(_shown(tester), RenderPreviewSetting.manual, reason: tier.name);
      expect(_hint(tester), RenderPreviewStrings.settingHint(RenderPreviewSetting.manual, isDefault: true));
      await _choose(tester, 'Auto');
      expect(backend.values[RenderPreviewPrefKeys.renderPreview], 'auto');
      expect(_hint(tester), RenderPreviewStrings.autoNotOnThisDevice);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an explicit preference wins over the tier default', (tester) async {
    final h = _harness(tier: DeviceTier.low, prefs: EditorPrefs.memory({RenderPreviewPrefKeys.renderPreview: 'manual'}));
    await h.pumpApp(tester, _page());
    await tester.pumpAndSettle();
    expect(_shown(tester), RenderPreviewSetting.manual);
  });

  testWidgets('without a render cache there is no clear row', (tester) async {
    final h = _harness();
    await h.pumpApp(tester, _page());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('render-preview-clear')), findsNothing);
  });

  testWidgets('Clear rendered previews shows the size and clears renders/ after confirming', (tester) async {
    final store = await _storeWithRender();
    final h = _harness(store: store);
    await h.pumpApp(tester, _page());
    await tester.pumpAndSettle();
    final size = tester.widget<Text>(find.byKey(const ValueKey('render-preview-size'))).data!;
    expect(size, endsWith('rendered'));

    await tester.tap(find.byKey(const ValueKey('render-preview-clear-button')));
    await tester.pumpAndSettle();
    expect(find.text(RenderPreviewStrings.clearConfirmTitle), findsOneWidget);
    await tester.tap(find.text(RenderPreviewStrings.clear).last);
    await tester.pumpAndSettle();
    expect(store.memory.filePaths.where((p) => p.endsWith('.mp4')), isEmpty);
    expect(tester.widget<Text>(find.byKey(const ValueKey('render-preview-size'))).data, RenderPreviewStrings.clearSubtitle(0));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling the confirmation keeps the renders', (tester) async {
    final store = await _storeWithRender();
    final h = _harness(store: store);
    await h.pumpApp(tester, _page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('render-preview-clear-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.memory.filePaths.where((p) => p.endsWith('$_hash.mp4')), hasLength(1));
  });

  testWidgets('owner UI rules hold', (tester) async {
    final store = await _storeWithRender();
    final h = _harness(store: store);
    await h.pumpApp(tester, _page());
    await tester.pumpAndSettle();
    expectOwnerUiRules(tester);
  });
}
