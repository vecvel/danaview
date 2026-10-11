// OWNER: UX-25
//
// The speed action binding (ARCH §17.6, ux.md §10.3): `speed` is bound once, is enabled for a
// video or audio clip on an unlocked track while the project accepts edits, says why otherwise, and
// opens the speed panel on the selected clip; the context tool tile runs it.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/speed_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/speed_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SelectMode;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';

import '../../support/support.dart';
import 'speed_rig.dart';

void main() {
  test('speed is bound exactly once and no other id is bound by the speed file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'speed_bindings');
    expect(source.owner, 'UX-25');
    expect(source.bindings().map((b) => b.id), [EditorActionId.speed]);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    expect(mergeEditorActionBindings()[EditorActionId.speed], same(source.bindings().single));
  });

  group('enablement and the handler', () {
    late SpeedRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester) async {
      rig = await SpeedRig.pump(tester, open: null);
      registry = rig.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.container,
        source: EditorActionSource.toolTile,
      );
    }

    EditorActionSpec spec() => registry.spec(EditorActionId.speed);

    testWidgets('enabled for a video clip: runs by opening the panel on that clip', (tester) async {
      await setUpRig(tester);
      rig.editor.select(SpeedIds.video);
      await tester.pump();
      expect(spec().isBound, isTrue);
      expect(spec().isVisible(ctx), isTrue);
      expect(spec().isEnabled(ctx), isTrue);
      expect(spec().label, 'Speed');
      expect(registry.invoke(EditorActionId.speed, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.state.inspector, const SpeedInspector(SpeedIds.video));
      expect(find.byType(SpeedPanel), findsOneWidget);
    });

    testWidgets('enabled for an audio clip, and targets the primary selected item', (tester) async {
      await setUpRig(tester);
      rig.editor
        ..select(SpeedIds.video)
        ..select(SpeedIds.audio, mode: SelectMode.extend);
      await tester.pump();
      expect(rig.state.selection.primary, SpeedIds.audio);
      expect(spec().isEnabled(ctx), isTrue);
      registry.invoke(EditorActionId.speed, ctx);
      expect(rig.state.inspector, const SpeedInspector(SpeedIds.audio));
    });

    testWidgets('disabled with nothing selected: the reason asks for a clip', (tester) async {
      await setUpRig(tester);
      expect(spec().isEnabled(ctx), isFalse);
      expect(spec().disabledReason(ctx), SpeedStrings.selectClip);
      expect(registry.invoke(EditorActionId.speed, ctx), EditorActionResult.disabled);
      expect(rig.state.inspector, isNull);
    });

    testWidgets('disabled for an image (no speed)', (tester) async {
      await setUpRig(tester);
      rig.editor.select(SpeedIds.image);
      await tester.pump();
      expect(spec().isEnabled(ctx), isFalse);
      expect(spec().disabledReason(ctx), SpeedStrings.selectClip);
    });

    testWidgets('disabled on a locked track, with that reason', (tester) async {
      await setUpRig(tester);
      rig.editor.select(SpeedIds.locked);
      await tester.pump();
      expect(spec().isEnabled(ctx), isFalse);
      expect(spec().disabledReason(ctx), SpeedStrings.actionTrackLocked);
    });
  });

  testWidgets('the Speed tile of the context tools opens the panel', (tester) async {
    final rig = await SpeedRig.pump(tester, open: null);
    rig.editor.select(SpeedIds.video);
    await tester.pump();
    await tester.pump();
    expect(find.byType(SpeedPanel), findsNothing);
    await tester.tap(find.text('Speed'));
    await tester.pump();
    await tester.pump();
    expect(rig.state.inspector, const SpeedInspector(SpeedIds.video));
    expect(find.byType(SpeedPanel), findsOneWidget);
    expectNoOverflow(tester);
  });
}
