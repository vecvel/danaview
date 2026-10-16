// OWNER: QA-04
//
// Editor-side ARCH §18.2 rows with the API-01 fake engine (the Dart half of each row; the native
// half is measured by packages/danaview_editor_engine/example/integration_test/perf_engine_test.dart
// and the report adds the two):
//
//   ui.editorOpen200      editor open → first preview frame, 200 items (UX-08's
//                         `EditorPerfMarks.editorOpenToFirstFrame`: repository open, session,
//                         first plan compile, PlanSync, first frame event) ≤ 2.5 / 1.5 s
//   ui.heap1000           Dart heap (used + external, after a GC) with 1,000 items open
//                         ≤ 180 / 150 MB
//   ui.autosaveBlock1000  main-isolate block of an autosave at 1,000 items: the incremental
//                         `ProjectJsonCodec.encodeBytes` the repository runs after a one-clip
//                         edit (CORE-27) plus the controller's request ≤ 2 / 1 ms (p90)
//   ui.commit.property    `EditorController.apply` → patch handed to the preview session
//   ui.commit.structural  (UI half of "commit → preview shows a property / structural edit")
//
//   cd packages/danaview_editor
//   flutter test integration_test/perf/editor_open_perf_test.dart -d flutter-tester

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/debug/debug.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/codec.dart' show ProjectJsonCodec;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../test/support/editor_test_harness.dart';
import 'perf_support.dart';

/// Pumps the editor on [project] and waits until it is ready with a plan on the fake session.
Future<(EditorTestHarness, ProjectId)> _openEditor(WidgetTester tester, EditProject project) async {
  final h = EditorTestHarness(engine: FakeEditorEngine(validatePlans: false));
  final id = h.repository.seed(project);
  await h.pumpEditor(tester, projectId: id);
  final ready = await pumpUntil(tester, () {
    final s = h.engine.sessions;
    return s.isNotEmpty && s.last.plan != null && h.containerOf(tester).read(editorControllerProvider(id)).phase == EditorPhase.ready;
  }, timeout: const Duration(seconds: 60));
  expect(ready, isTrue, reason: 'editor ready with a plan');
  return (h, id);
}

/// Wall time until the fake session has received [calls] more `preview.applyPatch` or
/// `preview.setPlan` calls than [before], pumping frames meanwhile.
Future<double> _untilPlanCall(WidgetTester tester, FakeEditorEngine engine, int before) async {
  final sw = Stopwatch()..start();
  int count() => engine.calls.where((c) => c == 'preview.applyPatch' || c == 'preview.setPlan').length;
  while (count() <= before) {
    if (sw.elapsed > const Duration(seconds: 20)) fail('no plan call within 20 s');
    await tester.pump();
    if (count() <= before) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  }
  return sw.elapsedMicroseconds / 1000;
}

int _planCalls(FakeEditorEngine e) => e.calls.where((c) => c == 'preview.applyPatch' || c == 'preview.setPlan').length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor open -> first preview frame with 200 items', (tester) async {
    enablePerfHooks();
    final project = perfProject(items: 200);
    expect(itemCountOf(project), 200);
    final ms = <num>[];
    for (var run = 0; run < 5; run++) {
      EditorPerfHooks.clear();
      await _openEditor(tester, perfProject(items: 200, id: 'pr_open$run'));
      final done = await pumpUntil(tester, () => EditorPerfHooks.samplesOf(EditorPerfMarks.editorOpenToFirstFrame).isNotEmpty);
      expect(done, isTrue, reason: 'open span ended on the first frame');
      ms.add(EditorPerfHooks.samplesOf(EditorPerfMarks.editorOpenToFirstFrame).single.elapsed.inMicroseconds / 1000);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
    }
    UiBudgets.editorOpen.check(percentile(ms, 90), {
      'p50': percentile(ms, 50).toStringAsFixed(1),
      'runs': ms.length,
      'note': 'Dart half with the fake engine; add preview.firstFrame200 of the engine suite',
    });
  });

  testWidgets('1,000 items open: Dart heap, autosave block, commit -> patch', (tester) async {
    final project = perfProject(items: 1000);
    expect(itemCountOf(project), 1000);
    final before = await dartHeapAfterGc();
    final (h, id) = await _openEditor(tester, project);
    await tester.pump(const Duration(milliseconds: 200));

    // ---- Dart heap ----
    final heap = await dartHeapAfterGc();
    if (heap != null) {
      UiBudgets.heap1000.check(heap.heapMb + heap.externalMb, {
        'usedMb': heap.heapMb.toStringAsFixed(1),
        'externalMb': heap.externalMb.toStringAsFixed(1),
        if (before != null) 'beforeOpenMb': (before.heapMb + before.externalMb).toStringAsFixed(1),
        if (before != null) 'deltaMb': (heap.heapMb + heap.externalMb - before.heapMb - before.externalMb).toStringAsFixed(1),
        'source': 'vm_service after GC',
      });
    } else {
      qa04('ui.heap1000', {'value': 'n/a', 'rssMb': rssMb().toStringAsFixed(1), 'note': 'VM service unavailable in this build'});
    }

    final container = h.containerOf(tester);
    final controller = container.read(editorControllerProvider(id).notifier);
    final main = container.read(editorControllerProvider(id)).project!.tracks.firstWhere((t) => t.isMain);
    final clips = main.items.whereType<MediaClip>().toList();

    // ---- autosave block: the incremental body encode after a one-clip edit + the request ----
    final codec = ProjectJsonCodec();
    var saved = container.read(editorControllerProvider(id)).project!;
    codec.encodeBytes(saved); // warm the incremental cache, as the open repository has
    final blockMs = <num>[];
    for (var i = 0; i < 30; i++) {
      final c = clips[(i * 37) % clips.length];
      final v = c.visual ?? VisualProps.neutral;
      final result = controller.apply(SetVisual([c.id], v.copyWith(transform: v.transform.copyWith(opacity: 0.5 + (i % 5) / 10))));
      expect(result.applied, isTrue, reason: '$result');
      saved = container.read(editorControllerProvider(id)).project!;
      final sw = Stopwatch()..start();
      codec.encodeBytes(saved);
      blockMs.add(sw.elapsedMicroseconds / 1000);
      await tester.pump();
    }
    UiBudgets.autosaveBlock.check(percentile(blockMs, 90), {'p50': percentile(blockMs, 50).toStringAsFixed(3), 'n': blockMs.length});
    await tester.pump(const Duration(milliseconds: 300));

    // ---- commit -> patch handed to the preview session ----
    final propMs = <num>[];
    for (var i = 0; i < 15; i++) {
      final c = clips[(i * 53 + 11) % clips.length];
      final v = c.visual ?? VisualProps.neutral;
      final n = _planCalls(h.engine);
      final sw = Stopwatch()..start();
      controller.apply(SetVisual([c.id], v.copyWith(transform: v.transform.copyWith(opacity: 0.3 + (i % 6) / 10))));
      await _untilPlanCall(tester, h.engine, n);
      propMs.add(sw.elapsedMicroseconds / 1000);
    }
    UiBudgets.commitProperty.check(percentile(propMs, 90),
        {'p50': percentile(propMs, 50).toStringAsFixed(2), 'n': propMs.length, 'note': 'UI half; add preview.commitProperty of the engine suite'});

    final structMs = <num>[];
    final rate = FrameRate.fps30;
    for (var i = 0; i < 10; i++) {
      final c = clips[(i * 41 + 7) % clips.length];
      final at = rate.quantize(c.start + c.duration ~/ 2);
      final n = _planCalls(h.engine);
      final sw = Stopwatch()..start();
      final r = controller.apply(SplitItems({c.id}, at));
      expect(r.applied, isTrue, reason: '$r');
      await _untilPlanCall(tester, h.engine, n);
      structMs.add(sw.elapsedMicroseconds / 1000);
    }
    UiBudgets.commitStructural.check(percentile(structMs, 90),
        {'p50': percentile(structMs, 50).toStringAsFixed(2), 'n': structMs.length, 'note': 'UI half; add preview.structural of the engine suite'});
    expect(h.engine.sessions.last.plan, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
