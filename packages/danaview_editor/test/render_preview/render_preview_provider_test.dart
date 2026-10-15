// OWNER: UX-44
//
// renderPreviewControllerProvider wiring inside a real editor session (EditorTestHarness with the
// fake engine): the controller follows the session's applied plan and preview session, the
// `editor.renderPreview` preference with the tier default, playback, and engine memory warnings.

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/editor_tier_defaults.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'support.dart';

void main() {
  testWidgets('the provider follows the session, the preference and playback', (tester) async {
    final store = MemoryRenderStore();
    final h = EditorTestHarness(
      engine: FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: DeviceTier.low)),
      overrides: [renderPreviewStoreProvider.overrideWithValue(store)],
    );
    final id = await h.pumpEditor(tester);
    await tester.pumpAndSettle();
    final container = h.containerOf(tester);
    final sub = container.listen(renderPreviewControllerProvider(id), (_, __) {});
    final controller = sub.read();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.value.available, isTrue);
    expect(controller.tier, RenderTier.low);
    expect(controller.value.setting, RenderPreviewSetting.auto, reason: 'tier default on low');
    expect(controller.plan, isNotNull, reason: 'the applied plan of the open session');

    await EditorTierDefaults.setRenderPreview(h.prefs, RenderPreviewSetting.manual);
    await tester.pump();
    expect(controller.value.setting, RenderPreviewSetting.manual);

    final transport = container.read(transportProvider(id));
    await transport.play();
    await tester.pump();
    expect(controller.value.suspended, transport.playing.value);
    await transport.pause();
    await tester.pump();
    expect(controller.value.suspended, isFalse);

    h.engine.emitSignal(const MemoryWarningSignal());
    await tester.pump();
    expect(controller.value.busy, isFalse);

    sub.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
