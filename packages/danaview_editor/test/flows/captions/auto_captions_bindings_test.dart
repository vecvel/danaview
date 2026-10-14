// OWNER: UX-37
//
// The `autoCaptions` action binding (ARCH §17.6, D-31): bound once; hidden unless
// DANAVIEW_AUTO_CAPTIONS is on and the service offers a tier on this device; enabled once the
// project has opened; it opens the sheet, and from a clip's context menu it preselects "This clip".

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/bindings/auto_captions_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_controller.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'captions_rig.dart';

WidgetActionContext _ctx(WidgetTester tester, CaptionsRig rig, {EditorActionSource source = EditorActionSource.button}) =>
    WidgetActionContext.container(
      projectId: rig.id,
      context: tester.element(find.byKey(const ValueKey('rig-open'))),
      container: rig.harness.containerOf(tester),
      source: source,
    );

EditorActionRegistry _registry(WidgetTester tester, CaptionsRig rig) => rig.harness.containerOf(tester).read(editorActionRegistryProvider);

void main() {
  tearDown(() => EditorFlags.debugAutoCaptionsOverride = null);

  test('autoCaptions is bound once, by this file', () {
    expect(autoCaptionsBindings.map((b) => b.id), [EditorActionId.autoCaptions]);
    expect(identical(autoCaptionsBindings, autoCaptionsBindings), isTrue);
    final sources = editorBindingSources.where((s) => s.bindings().any((b) => b.id == EditorActionId.autoCaptions));
    expect(sources.map((s) => s.file), ['auto_captions_bindings']);
  });

  testWidgets('hidden unless the flag is on and a tier is offered', (tester) async {
    final rig = CaptionsRig();
    await rig.pump(tester);
    final spec = _registry(tester, rig).spec(EditorActionId.autoCaptions);
    EditorFlags.debugAutoCaptionsOverride = false;
    expect(spec.isVisible(_ctx(tester, rig)), isFalse);
    EditorFlags.debugAutoCaptionsOverride = true;
    expect(spec.isVisible(_ctx(tester, rig)), isTrue);
    expect(spec.isEnabled(_ctx(tester, rig)), isTrue);
    rig.transcription.is64Bit = false;
    expect(spec.isVisible(_ctx(tester, rig)), isFalse, reason: 'no tier offered on this device');
  });

  testWidgets('invoking opens the sheet', (tester) async {
    EditorFlags.debugAutoCaptionsOverride = true;
    final rig = CaptionsRig();
    await rig.pump(tester);
    expect(_registry(tester, rig).invoke(EditorActionId.autoCaptions, _ctx(tester, rig)), EditorActionResult.ran);
    await rig.pumpSome(tester);
    expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
    expect(rig.harness.containerOf(tester).read(autoCaptionsControllerProvider(rig.id)).draft.scope, CaptionsScopeKind.wholeVideo);
  });

  testWidgets('from a clip context menu the sheet preselects This clip', (tester) async {
    EditorFlags.debugAutoCaptionsOverride = true;
    final rig = CaptionsRig();
    await rig.pump(tester);
    rig.editor.select(Cap.clip);
    await tester.pump();
    _registry(tester, rig).invoke(EditorActionId.autoCaptions, _ctx(tester, rig, source: EditorActionSource.contextMenu));
    await rig.pumpSome(tester);
    final state = rig.harness.containerOf(tester).read(autoCaptionsControllerProvider(rig.id));
    expect(state.selection, [Cap.clip]);
    expect(state.draft.scope, CaptionsScopeKind.selection);
    expect(find.text('This clip'), findsOneWidget);
    final c = rig.harness.containerOf(tester).read(autoCaptionsControllerProvider(rig.id).notifier);
    expect(c.request().scope, isA<ClipScope>());
  });
}
