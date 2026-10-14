// OWNER: UX-34
//
// The voiceover action binding (ARCH §17.6, ux.md §10.5): `recordVoiceover` is bound once, by the
// voiceover file; it is shown only when the engine has a voice recorder, enabled while the project
// accepts edits and is not read-only (with the reason otherwise), and opens the voiceover panel.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/voiceover_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/voiceover_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/voiceover_panel.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';

import 'voiceover_rig.dart';

void main() {
  test('recordVoiceover is bound exactly once, by the voiceover file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'voiceover_bindings');
    expect(source.owner, 'UX-34');
    expect(source.bindings().map((b) => b.id), [EditorActionId.recordVoiceover]);
    expect(identical(source.bindings(), source.bindings()), isTrue);
    expect(identical(voiceoverBindings, source.bindings()), isTrue);
    final merged = mergeEditorActionBindings();
    expect(merged[EditorActionId.recordVoiceover], same(source.bindings().single));
  });

  Future<(VoiceoverRig, EditorActionRegistry, WidgetActionContext)> setUp(WidgetTester tester,
      {bool voiceRecording = true, bool readOnly = false}) async {
    final rig = await VoiceoverRig.pump(tester, open: false, voiceRecording: voiceRecording, readOnly: readOnly);
    final registry = rig.container.read(editorActionRegistryProvider);
    final ctx = WidgetActionContext.container(
      projectId: rig.id,
      context: tester.element(find.byType(RegionFrame)),
      container: rig.container,
      source: EditorActionSource.toolTile,
    );
    return (rig, registry, ctx);
  }

  void testVo(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
        await body(tester);
        await tester.pump(const Duration(seconds: 3));
      });

  testVo('visible and enabled with a recorder: opens the voiceover panel', (tester) async {
    final (rig, registry, ctx) = await setUp(tester);
    final spec = registry.spec(EditorActionId.recordVoiceover);
    expect(spec.isVisible(ctx), isTrue);
    expect(spec.isEnabled(ctx), isTrue);
    expect(registry.invoke(EditorActionId.recordVoiceover, ctx), EditorActionResult.ran);
    await rig.settle();
    expect(rig.state.inspector, const VoiceoverInspector());
    expect(find.byType(VoiceoverPanel), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('voiceover.record')), findsOneWidget);
  });

  testVo('hidden when the engine has no voice recorder', (tester) async {
    final (rig, registry, ctx) = await setUp(tester, voiceRecording: false);
    final spec = registry.spec(EditorActionId.recordVoiceover);
    expect(spec.isVisible(ctx), isFalse);
    expect(spec.isEnabled(ctx), isFalse);
    expect(spec.disabledReason(ctx), VoiceoverStrings.unavailable);
    expect(registry.invoke(EditorActionId.recordVoiceover, ctx), EditorActionResult.hidden);
    expect(rig.state.inspector, isNull);
  });

  testVo('disabled on a read-only project, with the reason', (tester) async {
    final (rig, registry, ctx) = await setUp(tester, readOnly: true);
    final spec = registry.spec(EditorActionId.recordVoiceover);
    expect(spec.isVisible(ctx), isTrue);
    expect(spec.isEnabled(ctx), isFalse);
    expect(spec.disabledReason(ctx), VoiceoverStrings.readOnly);
    registry.invoke(EditorActionId.recordVoiceover, ctx);
    await rig.settle();
    expect(rig.state.inspector, isNull);
  });
}
