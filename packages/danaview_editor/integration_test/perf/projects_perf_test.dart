// OWNER: QA-04
//
// ARCH §18.2 "Projects screen first paint (40 projects)" ≤ 400 ms (low) / ≤ 250 ms (mid): the
// UX-05 `EditorPerfMarks.projectsFirstPaint` span (screen state created → first frame with the
// project grid) over 40 seeded projects, five cold mounts, p90.
//
//   cd packages/danaview_editor
//   flutter test integration_test/perf/projects_perf_test.dart -d flutter-tester      # host check
//   (device lab: see docs/v1.1/editor/qa/QA-04-performance.md, profile build from the app host)

import 'package:danaview_editor/src/debug/debug.dart';
import 'package:danaview_editor/src/projects/projects_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../test/support/editor_test_harness.dart';
import 'perf_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Projects first paint with 40 projects', (tester) async {
    enablePerfHooks();
    final ms = <num>[];
    for (var run = 0; run < 5; run++) {
      final h = EditorTestHarness();
      for (var i = 0; i < 40; i++) {
        h.repository.seed(perfProject(items: 6, id: 'pr_p${run}_$i', name: 'Trip ${i + 1}', seed: i));
      }
      EditorPerfHooks.clear();
      await h.pumpApp(tester, ProjectsScreen(onBack: () {}, onOpenProject: (_, {initialPlayhead}) {}));
      final painted = await pumpUntil(tester, () => EditorPerfHooks.samplesOf(EditorPerfMarks.projectsFirstPaint).isNotEmpty);
      expect(painted, isTrue, reason: 'first paint mark recorded (run $run)');
      final sample = EditorPerfHooks.samplesOf(EditorPerfMarks.projectsFirstPaint).single;
      expect(sample.args['projects'], 40);
      ms.add(sample.elapsed.inMicroseconds / 1000);
      // Unmount before the next cold mount.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
    UiBudgets.projectsFirstPaint.check(percentile(ms, 90), {'p50': percentile(ms, 50).toStringAsFixed(1), 'runs': ms.length});
  });
}
