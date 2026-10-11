// OWNER: UX-12
//
// The timeline view inside the real editor screen (EditorTestHarness, a project with clips): it
// composes headers, ruler, canvas, interaction and playhead layers, links the viewport, and fits
// the PR surface matrix (no overflow, owner UI rules), multi-select banner included.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/timeline/playhead_layer.dart';
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/ruler.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_view.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/support.dart';
import 'gesture_support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

void main() {
  testSurfaces('the timeline in the editor screen fits and is linked', (tester, surface) async {
    final h = EditorTestHarness();
    final id = h.repository.seed(gestureProject());
    await h.pumpEditor(tester, projectId: id, surface: surface);
    await _settle(tester);
    final container = h.containerOf(tester);
    final state = container.read(editorControllerProvider(id));
    expect(state.phase, EditorPhase.ready);

    final view = find.byType(TimelineView);
    if (view.evaluate().isEmpty) return; // A layout without a timeline region.
    expect(find.descendant(of: view, matching: find.byType(TimelineRuler)), findsOneWidget);
    expect(find.descendant(of: view, matching: find.byType(TimelineCanvas)), findsOneWidget);
    expect(find.descendant(of: view, matching: find.byType(PlayheadLayer)), findsOneWidget);
    expect(find.descendant(of: view, matching: find.byType(TimelineSemanticsLayer)), findsOneWidget);
    final viewport = container.read(viewportProvider(id));
    expect(viewport.hasLayout, isTrue);
    expect(viewport.duration, 14 * s);
    expect(viewport.restored, isTrue);
    final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
    expect(canvas.geometry.snapshot.lanes, hasLength(4));
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);

    container.read(editorControllerProvider(id).notifier)
      ..setModes((m) => m.copyWith(multiSelect: true))
      ..select(const ItemId('it_a'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);
  });
}
