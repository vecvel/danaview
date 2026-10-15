// OWNER: UX-44
//
// EditorTierDefaults (BUILD_PLAN UX-44 acceptance: tier-default tests): an unset preference reads
// the tier default (`editor.proxyMedia` Always on minimal/low, Auto on mid/high;
// `editor.renderPreview` Auto on minimal/low, Manual on mid/high), an explicit preference wins,
// an unreadable one falls back, and the provider follows the engine's capabilities.

import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/editor_tier_defaults.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const expected = {
    DeviceTier.minimal: (ProxyMediaMode.always, RenderPreviewSetting.auto),
    DeviceTier.low: (ProxyMediaMode.always, RenderPreviewSetting.auto),
    DeviceTier.mid: (ProxyMediaMode.auto, RenderPreviewSetting.manual),
    DeviceTier.high: (ProxyMediaMode.auto, RenderPreviewSetting.manual),
  };

  for (final MapEntry(key: tier, value: (proxy, render)) in expected.entries) {
    group(tier.name, () {
      final defaults = EditorTierDefaults(tier);

      test('unset preferences read the tier default', () {
        final prefs = EditorPrefs.memory();
        expect(defaults.proxyMedia, proxy);
        expect(defaults.renderPreview, render);
        expect(defaults.effectiveProxyMedia(prefs), proxy);
        expect(defaults.effectiveRenderPreview(prefs), render);
        expect(EditorTierDefaults.storedProxyMedia(prefs), isNull);
        expect(EditorTierDefaults.storedRenderPreview(prefs), isNull);
      });

      test('an explicit preference wins', () async {
        for (final mode in ProxyMediaMode.values) {
          final prefs = EditorPrefs.memory();
          await prefs.setProxyMedia(mode);
          expect(defaults.effectiveProxyMedia(prefs), mode);
        }
        for (final setting in RenderPreviewSetting.values) {
          final prefs = EditorPrefs.memory();
          await EditorTierDefaults.setRenderPreview(prefs, setting);
          expect(prefs.readString(RenderPreviewPrefKeys.renderPreview), setting.name);
          expect(defaults.effectiveRenderPreview(prefs), setting);
          await EditorTierDefaults.setRenderPreview(prefs, null);
          expect(defaults.effectiveRenderPreview(prefs), render, reason: 'reset returns to the tier default');
        }
      });

      test('an unreadable preference falls back to the tier default', () {
        final prefs = EditorPrefs.memory({
          EditorPrefKeys.proxyMedia: 'sometimes',
          RenderPreviewPrefKeys.renderPreview: 42,
        });
        expect(defaults.effectiveProxyMedia(prefs), proxy);
        expect(defaults.effectiveRenderPreview(prefs), render);
      });

      test('render tier mapping', () {
        expect(defaults.renderTier.name, tier.name);
        expect(defaults.isConstrained, tier == DeviceTier.minimal || tier == DeviceTier.low);
      });
    });
  }

  test('the provider uses the mid-tier defaults until capabilities arrive, then the device tier', () async {
    final engine = FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: DeviceTier.low));
    final container = ProviderContainer(overrides: [
      editorEngineProvider.overrideWithValue(engine),
      editorPrefsProvider.overrideWithValue(EditorPrefs.memory()),
    ]);
    addTearDown(container.dispose);
    expect(container.read(editorTierDefaultsProvider), EditorTierDefaults.fallback);
    await container.read(editorCapabilitiesProvider.future);
    expect(container.read(editorTierDefaultsProvider), const EditorTierDefaults(DeviceTier.low));
    expect(container.read(editorTierDefaultsProvider).effectiveProxyMedia(container.read(editorPrefsProvider)), ProxyMediaMode.always);
  });
}
