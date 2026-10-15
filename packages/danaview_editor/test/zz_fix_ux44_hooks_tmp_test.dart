// Temporary verification of FIX-UX44-HOOKS (deleted after the run).

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/app/editor_bootstrap.dart';
import 'package:danaview_editor/src/editor/actions/bindings/render_preview_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor/src/settings/render_preview_settings_section.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';

void main() {
  test('id, binding and meta', () {
    expect(EditorActionId.renderPreview.group, EditorActionGroup.tools);
    expect(renderPreviewActionId, EditorActionId.renderPreview);
    final merged = mergeEditorActionBindings();
    expect(merged[EditorActionId.renderPreview], isNotNull);
    final meta = editorActionMeta(EditorActionId.renderPreview);
    expect(meta.combos.single.key, LogicalKeyboardKey.keyR);
    expect(meta.combos.single.command, isTrue);
    final ripple = editorActionMeta(EditorActionId.toggleRipple);
    expect(ripple.combos.single.key, LogicalKeyboardKey.keyR);
    expect(ripple.combos.single.command, isFalse);
  });

  test('cache folders include renders', () {
    expect(EditorCacheCleaner.folders, contains('renders'));
  });

  test('bootstrap overrides the render store with a tier-bounded index', () async {
    const roots = StoreRoots(support: '/app/support', cache: '/app/cache', documents: '/app/documents');
    for (final (tier, limit) in [(DeviceTier.low, 512), (DeviceTier.high, 1024)]) {
      final engine = FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: tier));
      final runtime = await EditorBootstrap.createRuntime(
        engine: engine,
        roots: roots,
        prefs: EditorPrefs.memory(),
        fs: MemoryStoreFs(),
        startGc: false,
        listenToLifecycle: false,
        useIsolates: false,
      );
      expect(runtime.renderPreview.index.limitBytes, limit * 1024 * 1024);
      expect(EditorBootstrap.overridesFor(runtime), hasLength(greaterThan(6)));
      await runtime.dispose();
    }
  });

  for (final (tier, mode, hint) in [
    (DeviceTier.low, ProxyMediaMode.always, 'Every video gets a proxy. Uses more storage. Recommended for this device.'),
    (DeviceTier.mid, ProxyMediaMode.auto, 'Recommended: proxies are made only for media that needs them.'),
  ]) {
    testWidgets('settings: proxy tier default on ${tier.name} and render section mounted', (tester) async {
      final h = EditorTestHarness(engine: FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: tier)));
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<DanaviewSegmentedControl<ProxyMediaMode>>(find.descendant(
                  of: find.byKey(const ValueKey('editor-settings-proxy')), matching: find.byType(DanaviewSegmentedControl<ProxyMediaMode>)))
              .value,
          mode);
      expect(find.text(hint), findsOneWidget);
      await tester.scrollUntilVisible(find.byType(RenderPreviewSettingsSection), 200, scrollable: find.byType(Scrollable).first);
      expect(find.byType(RenderPreviewSettingsSection), findsOneWidget);
      expectNoOverflow(tester);
    });
  }

  test('store provider default is null', () {
    expect(IndexRenderPreviewStore, isNotNull);
  });
}
