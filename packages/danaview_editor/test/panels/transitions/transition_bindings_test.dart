// OWNER: UX-27
//
// The transition action binding (ARCH §17.6, ux.md §9.1, §10.12): `transitions` is bound once, is
// enabled while some lane has a cut, says "Add at least two clips to use transitions" otherwise, and
// opens the panel for the selected transition's cut, else the main-lane cut nearest the playhead.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/transition_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/transition_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/transitions_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import 'transitions_rig.dart';

void main() {
  tearDown(EditorAnnouncer.instance.reset);

  test('transitions is bound exactly once and no other id is bound by the transition file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'transition_bindings');
    expect(source.owner, 'UX-27');
    expect(source.bindings().map((b) => b.id), [EditorActionId.transitions]);
    expect(() => mergeEditorActionBindings(), returnsNormally);
    expect(mergeEditorActionBindings()[EditorActionId.transitions], same(source.bindings().single));
    expect(identical(transitionBindings, transitionBindings), isTrue);
  });

  test('the target: the selected cut, else the nearest main-lane cut, else another lane', () {
    final p = transitionsProject(const ProjectId('pr_x'));
    expect(transitionTargetIn(p, 0), Cuts.ab);
    expect(transitionTargetIn(p, 7 * s), Cuts.bc);
    expect(transitionTargetIn(p, 13 * s), Cuts.cd);
    expect(transitionTargetIn(p, 2 * s), Cuts.ab, reason: 'the main lane wins over a nearer overlay cut');
    expect(transitionTargetIn(p, 13 * s, selected: Cuts.overlayCut), Cuts.overlayCut);
    expect(transitionTargetIn(p, 13 * s, selected: Cuts.notACut), Cuts.cd, reason: 'a stale selection is ignored');
    expect(transitionTargetIn(transitionsProject(const ProjectId('pr_y'), mainOnlyOneClip: true), 0), isNull);
  });

  group('enablement and the handler', () {
    late TransitionsRig rig;
    late EditorActionRegistry registry;
    late WidgetActionContext ctx;

    Future<void> setUpRig(WidgetTester tester, {bool mainOnlyOneClip = false}) async {
      rig = await TransitionsRig.pump(tester, open: null, mainOnlyOneClip: mainOnlyOneClip);
      registry = rig.container.read(editorActionRegistryProvider);
      ctx = WidgetActionContext.container(
        projectId: rig.id,
        context: tester.element(find.byType(RegionFrame)),
        container: rig.container,
        source: EditorActionSource.toolTile,
      );
    }

    EditorActionSpec spec() => registry.spec(EditorActionId.transitions);

    testWidgets('enabled with cuts: opens the panel for the main-lane cut nearest the playhead and selects it', (tester) async {
      await setUpRig(tester);
      await rig.seek(9 * s);
      expect(spec().isBound, isTrue);
      expect(spec().isEnabled(ctx), isTrue);
      expect(spec().label, 'Transitions');
      expect(registry.invoke(EditorActionId.transitions, ctx), EditorActionResult.ran);
      await tester.pump();
      await rig.settle();
      expect(rig.state.inspector, const TransitionInspector(Cuts.bc));
      expect(rig.state.selection.transition, Cuts.bc);
      expect(find.byType(TransitionsPanel), findsOneWidget);
      await rig.closePanel();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a selected transition wins over the playhead', (tester) async {
      await setUpRig(tester);
      rig.editor.selectTransition(Cuts.overlayCut);
      await tester.pump();
      registry.invoke(EditorActionId.transitions, ctx);
      await tester.pump();
      await rig.settle();
      expect(rig.state.inspector, const TransitionInspector(Cuts.overlayCut));
      await rig.closePanel();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('disabled without a cut, with the reason', (tester) async {
      await setUpRig(tester, mainOnlyOneClip: true);
      expect(spec().isEnabled(ctx), isFalse);
      expect(spec().disabledReason(ctx), TransitionStrings.needTwoClips);
      expect(registry.invoke(EditorActionId.transitions, ctx), EditorActionResult.disabled);
      expect(rig.state.inspector, isNull);
    });
  });
}
