// OWNER: UX-11
//
// The track action bindings: `addTrack` opens the add-track sheet, `laneHeight` cycles the lane
// height (Compact, Normal, Large), both are disabled when the project can't be edited, and the file
// merges with the other binding files without a duplicate id.

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/track_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/track_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart' show TrackKind;


import 'track_test_support.dart';

void main() {
  test('the file binds exactly addTrack and laneHeight, and merges without duplicates', () {
    expect({for (final b in trackBindings) b.id}, {EditorActionId.addTrack, EditorActionId.laneHeight});
    final merged = mergeEditorActionBindings();
    expect(merged.containsKey(EditorActionId.addTrack), isTrue);
    expect(merged.containsKey(EditorActionId.laneHeight), isTrue);
    expect(editorBindingSources.any((s) => s.file == 'track_bindings' && s.owner == 'UX-11'), isTrue);
  });

  test('the lane height cycle is Compact, Normal, Large, Compact', () {
    expect(nextLaneHeight(LaneHeightPreset.compact), LaneHeightPreset.normal);
    expect(nextLaneHeight(LaneHeightPreset.normal), LaneHeightPreset.large);
    expect(nextLaneHeight(LaneHeightPreset.large), LaneHeightPreset.compact);
  });

  testWidgets('laneHeight cycles the timeline lane height through the registry', (tester) async {
    late BuildContext context;
    final rig = await pumpTrackRig(tester, (id) => Material(child: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    final registry = EditorActionRegistry(bindings: mergeEditorActionBindings());
    WidgetActionContext ctx() => WidgetActionContext.container(projectId: rig.id, context: context, container: rig.container);
    expect(rig.state.modes.laneHeight, LaneHeightPreset.normal);
    expect(registry.invoke(EditorActionId.laneHeight, ctx()), EditorActionResult.ran);
    expect(rig.state.modes.laneHeight, LaneHeightPreset.large);
    registry.invoke(EditorActionId.laneHeight, ctx());
    expect(rig.state.modes.laneHeight, LaneHeightPreset.compact);
    registry.invoke(EditorActionId.laneHeight, ctx());
    expect(rig.state.modes.laneHeight, LaneHeightPreset.normal);
    expect(rig.state.history.position, 0, reason: 'lane height is a mode, not an edit');
  });

  testWidgets('addTrack opens the add-track sheet', (tester) async {
    late BuildContext context;
    final rig = await pumpTrackRig(tester, (id) => Material(child: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    final registry = EditorActionRegistry(bindings: mergeEditorActionBindings());
    final ctx = WidgetActionContext.container(projectId: rig.id, context: context, container: rig.container);
    expect(registry.invoke(EditorActionId.addTrack, ctx), EditorActionResult.ran);
    await tester.pumpAndSettle();
    expect(find.text(TrackStrings.addSheetTitle), findsOneWidget);
    expect(find.text(TrackStrings.addTrack(TrackKind.audio)), findsOneWidget);
    await tester.tap(find.text(TrackStrings.addTrack(TrackKind.audio)));
    await tester.pumpAndSettle();
    expect(rig.project.tracks.where((t) => t.kind == TrackKind.audio), hasLength(3));
  });

  testWidgets('addTrack is disabled while the editor is not ready', (tester) async {
    late BuildContext context;
    final rig = await pumpTrackRig(tester, (id) => Material(child: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    await tester.runAsync(() => rig.rig.controller.close());
    final registry = EditorActionRegistry(bindings: mergeEditorActionBindings());
    final ctx = WidgetActionContext.container(projectId: rig.id, context: context, container: rig.container);
    expect(registry.spec(EditorActionId.addTrack).isEnabled(ctx), isFalse);
    expect(registry.spec(EditorActionId.addTrack).disabledReason(ctx), TrackStrings.notEditable);
  });
}
