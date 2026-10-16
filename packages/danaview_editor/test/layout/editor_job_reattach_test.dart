// OWNER: FIX-JOB-RESUME
//
// The real EditorScreen over the real EditorController: on open it reattaches to a pending export
// or reports it exactly once (ARCH §14.1, D-22, D-39), and pending reverse / freeze / proxy jobs
// are re-queued with no user action (QA-05 D3).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/flows/export/export_state.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorPhase;
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart' show planCompilerPortProvider;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show ExportInterrupted;
import 'package:danaview_editor_engine_api/testing.dart';

import '../flows/tasks/tasks_rig.dart' show allOnline, rigAsset, rigClip, tasksProject, TaskIds;
import '../support/support.dart';

const int _s = microsPerSecond;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int _activeJobsCalls(FakeEditorEngine engine) => engine.calls.where((c) => c == 'exporter.activeJobs').length;

Finder get _sheet => find.byKey(const ValueKey('export-sheet'));

/// A harness whose project has one video clip (so the editor opens ready with something on it).
(EditorTestHarness, ProjectId) _harness({FakeEditorEngine? engine, EditProject Function(ProjectId id)? project}) {
  final repo = FakeProjectRepository();
  final id = repo.seedEmpty('Reattach').id;
  repo.seed(project?.call(id) ?? tasksProject(id));
  final h = EditorTestHarness(
    engine: engine ?? FakeEditorEngine(validatePlans: false),
    repository: repo,
    overrides: [planCompilerPortProvider.overrideWithValue(allOnline)],
  );
  return (h, id);
}

void main() {
  group('export reattach on open', () {
    testWidgets('an interrupted export is reported once; closing the notice consumes it', (tester) async {
      final (h, id) = _harness();
      h.engine.exporter.records.add(const ExportInterrupted('job-killed'));
      await h.pumpEditor(tester, projectId: id);
      await _settle(tester);
      final container = h.containerOf(tester);
      expect(container.read(editorControllerProvider(id)).phase, EditorPhase.ready);
      expect(_activeJobsCalls(h.engine), 1, reason: 'looked up once on open');
      expect(_sheet, findsOneWidget);
      expect(container.read(exportControllerProvider(id)), isA<ExportUiInterrupted>());

      await tester.tap(find.byKey(const ValueKey('export-interrupted-close')));
      await _settle(tester);
      expect(_sheet, findsNothing);
      expect(h.engine.exporter.records, isEmpty, reason: 'the one-shot record is consumed');

      // Nothing else asks again while the editor stays open.
      await _settle(tester);
      expect(_activeJobsCalls(h.engine), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reopened editor finds nothing after the record was consumed', (tester) async {
      final (h, id) = _harness();
      h.engine.exporter.records.add(const ExportInterrupted('job-killed'));
      await h.pumpEditor(tester, projectId: id);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('export-interrupted-close')));
      await _settle(tester);

      // A new app (as after a relaunch) over the same engine and store.
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await h.pumpEditor(tester, projectId: id);
      await _settle(tester);
      expect(_activeJobsCalls(h.engine), 2);
      expect(_sheet, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no pending export: no sheet', (tester) async {
      final (h, id) = _harness();
      await h.pumpEditor(tester, projectId: id);
      await _settle(tester);
      expect(_activeJobsCalls(h.engine), 1);
      expect(_sheet, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('background jobs on open', () {
    testWidgets('a pending reverse rendition left by a process death resumes when the screen opens', (tester) async {
      final spec = ReversedSpec(TaskIds.videoMedia, const TimeRange(3 * _s, 19 * _s), sourceQuickHash: 'md_video'.padRight(40, '0'));
      final (h, id) = _harness(
        project: (id) => tasksProject(
          id,
          video: rigClip('it_video', 'md_video', 0, 12 * _s, sourceIn: 5 * _s, reversed: true),
          extraAssets: [rigAsset('md_rev', MediaKind.video, status: const PendingStatus('reverse-before-kill'), derived: spec)],
        ),
      );
      await h.pumpEditor(tester, projectId: id);
      await _settle(tester);
      final reverse = [for (final j in h.engine.jobs.created) if (j.id.startsWith('reverse-')) j];
      expect(reverse, hasLength(1));
      final state = h.containerOf(tester).read(editorControllerProvider(id));
      expect(state.project!.pool[const MediaId('md_rev')]!.status, PendingStatus(reverse.single.id));
      expect(state.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });
}
