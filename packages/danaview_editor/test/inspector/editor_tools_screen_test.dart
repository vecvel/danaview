// OWNER: UX-16
//
// The toolbar and the inspector inside the real EditorScreen (scaffold, regions, an opened
// EditorController over FakeEditorEngine): the strip switches to context tools on selection, a
// panel tool opens the dock (compactPortrait) or the side pane, and nothing overflows on the PR
// surfaces.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout_scope.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/toolbar/toolbar_chip.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../support/support.dart';
import 'inspector_rig.dart';

void main() {
  testSurfaces('select, open a panel, close it: tools and inspector in the real screen', (tester, surface) async {
    final repo = FakeProjectRepository();
    final project = inspectorProject(repo);
    final items = RigItems(project);
    final ticker = RigTicker();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
      ],
    );
    await tester.runAsync(() async {
      await harness.pumpEditor(tester, projectId: project.id, surface: surface);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
    final container = harness.containerOf(tester);
    EditorController editor() => container.read(editorControllerProvider(project.id).notifier);
    EditorState state() => container.read(editorControllerProvider(project.id));
    expect(state().phase, EditorPhase.ready);
    expectNoOverflow(tester);

    editor().select(items.textA);
    await tester.pump();
    expect(find.widgetWithText(ToolbarChipView, 'Text'), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);

    editor().openInspector(TextInspector(items.textA, tab: TextPanelTab.style));
    await tester.pump();
    await tester.pump();
    final spec = tester.widget<EditorLayoutScope>(find.byType(EditorLayoutScope)).spec;
    if (spec.kind == EditorLayoutKind.compactPortrait) {
      expect(find.byType(InspectorDock), findsOneWidget);
      expect(find.byType(InspectorHost), findsNothing);
    } else {
      expect(find.byType(InspectorHost), findsOneWidget);
    }
    expect(find.byType(InspectorHeader), findsOneWidget);
    expectNoOverflow(tester);
    expectOwnerUiRules(tester);

    await tester.tap(find.byTooltip(InspectorStrings.back));
    await tester.pump();
    await tester.pump();
    expect(state().inspector, isNull);
    expect(state().selection.primary, items.textA);
    expectNoOverflow(tester);
  });
}
