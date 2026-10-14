// OWNER: UX-26
//
// The keyframe action bindings (ARCH §17.6, ux.md §9.2, §10.11): `keyframes` and
// `keyframeAtPlayhead` are bound once by UX-26; `keyframes` opens the panel on the selected clip or
// text (or the item of the selected keyframe); `keyframeAtPlayhead` toggles keys at the playhead in
// one history entry (the selected key's property, else the animated properties, else the transform
// or, for audio, the volume); both explain themselves when disabled.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/keyframe_strings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/actions/bindings/keyframe_bindings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/keyframes_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SelectMode;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/support.dart';
import 'keyframes_rig.dart';

void main() {
  test('keyframes and keyframeAtPlayhead are bound exactly once, by the keyframe file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'keyframe_bindings');
    expect(source.owner, 'UX-26');
    expect(source.bindings().map((b) => b.id), [EditorActionId.keyframes, EditorActionId.keyframeAtPlayhead]);
    expect(identical(source.bindings(), keyframeBindings), isTrue);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    expect(mergeEditorActionBindings()[EditorActionId.keyframes], same(source.bindings().first));
    expect(mergeEditorActionBindings()[EditorActionId.keyframeAtPlayhead], same(source.bindings().last));
  });

  group('pure: what "Keyframe at playhead" keys', () {
    final project = keyframesProject(const ProjectId('p'));
    TimelineItem item(ItemId id) => project.index.item(id)!;

    test('the selected key\'s property first, then the animated properties', () {
      expect(KeyframeCommands.atPlayheadKeys(item(KfIds.video), project.pool, selected: PropertyKeys.exposure), [PropertyKeys.exposure]);
      expect(KeyframeCommands.atPlayheadKeys(item(KfIds.video), project.pool), [PropertyKeys.opacity, PropertyKeys.exposure]);
    });

    test('an item with no keys: position, scale, rotation, opacity; audio: its volume', () {
      expect(KeyframeCommands.atPlayheadKeys(item(KfIds.plain), project.pool), KeyframeCommands.defaultKeys);
      expect(KeyframeCommands.atPlayheadKeys(item(KfIds.text), project.pool), KeyframeCommands.defaultKeys);
      final silentAudio = (item(KfIds.audio) as MediaClip).copyWith(keyframes: KeyframeSet.empty);
      expect(KeyframeCommands.atPlayheadKeys(silentAudio, project.pool), [PropertyKeys.volume]);
    });
  });

  group('enablement and the handlers', () {
    late KfRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester, {TimeUs at = 0}) async {
      rig = await KfRig.pump(tester, open: null, at: at);
      registry = rig.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.container,
        source: EditorActionSource.toolTile,
      );
    }

    EditorActionSpec spec(EditorActionId id) => registry.spec(id);

    testWidgets('keyframes opens the panel on the selected clip', (tester) async {
      await setUpRig(tester);
      rig.editor.select(KfIds.video);
      await tester.pump();
      expect(spec(EditorActionId.keyframes).isBound, isTrue);
      expect(spec(EditorActionId.keyframes).isEnabled(ctx), isTrue);
      expect(spec(EditorActionId.keyframes).label, 'Keyframes');
      expect(registry.invoke(EditorActionId.keyframes, ctx), EditorActionResult.ran);
      await tester.pump();
      await tester.pump();
      expect(rig.state.inspector, const KeyframesInspector(KfIds.video));
      expect(find.byType(KeyframesPanel), findsOneWidget);
    });

    testWidgets('keyframes opens on the item of a selected keyframe, with its card', (tester) async {
      await setUpRig(tester);
      rig.editor.selectKeyframe(const KeyframeRef(KfIds.video, 'transform.opacity', 1 * s));
      await tester.pump();
      expect(registry.invoke(EditorActionId.keyframes, ctx), EditorActionResult.ran);
      await tester.pump();
      await tester.pump();
      expect(rig.state.inspector, const KeyframesInspector(KfIds.video));
      expect(find.text(KeyframeStrings.selectedTitle('Opacity', 2, 3)), findsOneWidget);
    });

    testWidgets('keyframes works for a text item', (tester) async {
      await setUpRig(tester);
      rig.editor.select(KfIds.text);
      await tester.pump();
      expect(registry.invoke(EditorActionId.keyframes, ctx), EditorActionResult.ran);
      expect(rig.state.inspector, const KeyframesInspector(KfIds.text));
    });

    testWidgets('disabled with nothing or several items selected: the reason asks for one item', (tester) async {
      await setUpRig(tester);
      for (final id in [EditorActionId.keyframes, EditorActionId.keyframeAtPlayhead]) {
        expect(spec(id).isEnabled(ctx), isFalse);
        expect(spec(id).disabledReason(ctx), KeyframeStrings.selectItem);
      }
      rig.editor
        ..select(KfIds.video)
        ..select(KfIds.audio, mode: SelectMode.extend);
      await tester.pump();
      expect(spec(EditorActionId.keyframes).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.keyframes).disabledReason(ctx), KeyframeStrings.selectItem);
      expect(registry.invoke(EditorActionId.keyframes, ctx), EditorActionResult.disabled);
      expect(rig.state.inspector, isNull);
    });

    testWidgets('disabled on a locked track, with that reason', (tester) async {
      await setUpRig(tester, at: 1 * s);
      rig.editor.select(KfIds.locked);
      await tester.pump();
      for (final id in [EditorActionId.keyframes, EditorActionId.keyframeAtPlayhead]) {
        expect(spec(id).isEnabled(ctx), isFalse);
        expect(spec(id).disabledReason(ctx), KeyframeStrings.actionTrackLocked);
      }
    });

    testWidgets('keyframeAtPlayhead needs the playhead over the item, and says so', (tester) async {
      await setUpRig(tester, at: 1 * s);
      rig.editor.select(KfIds.plain);
      await tester.pump();
      expect(spec(EditorActionId.keyframes).isEnabled(ctx), isTrue, reason: 'the panel opens anywhere');
      expect(spec(EditorActionId.keyframeAtPlayhead).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.keyframeAtPlayhead).disabledReason(ctx), KeyframeStrings.playheadOutside);
      expect(registry.invoke(EditorActionId.keyframeAtPlayhead, ctx), EditorActionResult.disabled);
    });

    testWidgets('keyframeAtPlayhead on a clip with no keys keys the transform in one entry, then removes it', (tester) async {
      await setUpRig(tester, at: 7 * s);
      rig.editor.select(KfIds.plain);
      await tester.pump();
      expect(spec(EditorActionId.keyframeAtPlayhead).isEnabled(ctx), isTrue);
      final before = rig.entries;
      expect(registry.invoke(EditorActionId.keyframeAtPlayhead, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(KeyframeCommands.animated(rig.item(KfIds.plain)), KeyframeCommands.defaultKeys);
      for (final k in KeyframeCommands.defaultKeys) {
        expect(rig.keys(KfIds.plain, k), [1 * s], reason: k.id);
      }
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, KeyframeStrings.historyAtPlayhead);
      registry.invoke(EditorActionId.keyframeAtPlayhead, ctx);
      await tester.pump();
      expect(KeyframeCommands.animated(rig.item(KfIds.plain)), isEmpty);
      expect(rig.entries, before + 2);
    });

    testWidgets('keyframeAtPlayhead on an animated clip keys its animated properties', (tester) async {
      await setUpRig(tester, at: frames(45));
      rig.editor.select(KfIds.video);
      await tester.pump();
      registry.invoke(EditorActionId.keyframeAtPlayhead, ctx);
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), contains(frames(45)));
      expect(rig.keys(KfIds.video, PropertyKeys.exposure), contains(frames(45)));
      expect(rig.keys(KfIds.video, PropertyKeys.position), isEmpty);
    });

    testWidgets('keyframeAtPlayhead with a selected key toggles only that property', (tester) async {
      await setUpRig(tester, at: 2 * s);
      rig.editor.selectKeyframe(const KeyframeRef(KfIds.video, 'adjust.exposure', 2 * s));
      await tester.pump();
      registry.invoke(EditorActionId.keyframeAtPlayhead, ctx);
      await tester.pump();
      expect(rig.keys(KfIds.video, PropertyKeys.exposure), [0], reason: 'the key at the playhead is removed');
      expect(rig.keys(KfIds.video, PropertyKeys.opacity), [0, 1 * s, 3 * s]);
    });

    testWidgets('keyframeAtPlayhead on an audio clip keys its volume', (tester) async {
      await setUpRig(tester, at: 2 * s);
      rig.editor.select(KfIds.audio);
      await tester.pump();
      registry.invoke(EditorActionId.keyframeAtPlayhead, ctx);
      await tester.pump();
      expect(rig.keys(KfIds.audio, PropertyKeys.volume), [1 * s, 2 * s, 4 * s]);
    });
  });

  testWidgets('the panel opened by the action has no overflow on the narrowest surface', (tester) async {
    final rig = await KfRig.pump(tester, open: null, surface: SurfaceMatrix.narrowest);
    rig.editor.select(KfIds.video);
    final registry = rig.container.read(editorActionRegistryProvider);
    final ctx = WidgetActionContext.container(
      projectId: rig.id,
      context: tester.element(find.byType(RegionFrame)),
      container: rig.container,
      source: EditorActionSource.toolTile,
    );
    registry.invoke(EditorActionId.keyframes, ctx);
    await tester.pump();
    await tester.pump();
    expect(find.byType(KeyframesPanel), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  });
}
