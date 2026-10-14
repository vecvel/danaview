// OWNER: UX-23
//
// The transform action bindings (ARCH §17.6): transform, crop, mask and resetTransform are bound once
// by UX-23, are enabled for the items whose panels support them on unlocked tracks, say why
// otherwise, open their panels on the selected item, and resetTransform runs ResetTransform as one
// history entry.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetProperty;

import '../../inspector/inspector_rig.dart' show RegionFrame;
import 'transform_rig.dart';

void main() {
  test('the four transform ids are bound exactly once by the transform file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'transform_bindings');
    expect(source.owner, 'UX-23');
    expect(source.bindings().map((b) => b.id),
        [EditorActionId.transform, EditorActionId.crop, EditorActionId.mask, EditorActionId.resetTransform]);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    expect(identical(source.bindings(), source.bindings()), isTrue);
  });

  group('enablement and handlers', () {
    late TransformRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester, {bool lockMain = false}) async {
      rig = await TransformRig.pump(tester, project: (repo) => transformProject(repo, lockMain: lockMain));
      registry = rig.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.container,
        source: EditorActionSource.toolTile,
      );
    }

    testWidgets('a video clip: transform, crop and mask open their panels', (tester) async {
      await setUpRig(tester);
      rig.editor.select(Ids.a);
      await tester.pump();
      for (final (id, route) in [
        (EditorActionId.transform, const TransformInspector(Ids.a) as InspectorRoute),
        (EditorActionId.crop, const CropInspector(Ids.a)),
        (EditorActionId.mask, const MaskInspector(Ids.a)),
      ]) {
        expect(registry.spec(id).isEnabled(ctx), isTrue, reason: id.name);
        expect(registry.invoke(id, ctx), EditorActionResult.ran);
        await tester.pump();
        expect(rig.state.inspector, route);
      }
    });

    testWidgets('a text item: transform only; crop and mask say why', (tester) async {
      await setUpRig(tester);
      rig.editor.select(Ids.text);
      await tester.pump();
      expect(registry.spec(EditorActionId.transform).isEnabled(ctx), isTrue);
      expect(registry.spec(EditorActionId.crop).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.crop).disabledReason(ctx), 'Select a video or photo clip first');
      expect(registry.spec(EditorActionId.mask).isEnabled(ctx), isFalse);
    });

    testWidgets('nothing selected and locked tracks are disabled with a reason', (tester) async {
      await setUpRig(tester, lockMain: true);
      expect(registry.spec(EditorActionId.transform).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.transform).disabledReason(ctx), 'Select a clip or text first');
      rig.editor.select(Ids.a);
      await tester.pump();
      expect(registry.spec(EditorActionId.crop).isEnabled(ctx), isFalse);
      expect(registry.spec(EditorActionId.crop).disabledReason(ctx), 'This track is locked');
      expect(registry.invoke(EditorActionId.resetTransform, ctx), EditorActionResult.disabled);
    });

    testWidgets('resetTransform runs ResetTransform as one entry', (tester) async {
      await setUpRig(tester);
      rig.editor.select(Ids.overlay);
      rig.editor.apply(SetProperty<double>([Ids.overlay], PropertyKeys.scale, 2, at: 0));
      await tester.pump();
      final before = rig.entries;
      expect(registry.invoke(EditorActionId.resetTransform, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.visual(Ids.overlay).transform, Transform2D.identity);
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, 'Reset transform');
    });
  });
}
