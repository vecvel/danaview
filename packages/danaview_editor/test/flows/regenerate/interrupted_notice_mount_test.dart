// OWNER: FIX-QA07
//
// QA-07 D2: the editor screen itself shows "Auto captions were interrupted. Resume?" when a project
// opens with a resumable captions job (ai.md §8.6, UX-38), with no Captions tool opened first; it
// shows nothing without a job, and nothing (and no error) when Auto captions are not wired.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/flows/captions/interrupted_notice.dart';
import 'package:danaview_editor/src/editor/layout/editor_scaffold.dart';

import '../../support/support.dart';
import 'regenerate_rig.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final notice = find.byKey(const ValueKey('captions-interrupted'));

  for (final surface in SurfaceMatrix.pr) {
    testWidgets('after a simulated kill the editor screen shows the notice on open (${surface.name})', (tester) async {
      final rig = RegenRig();
      rig.install();
      final job = rig.transcription.start(rigRequest(rig.id));
      rig.transcription.interrupt(job as FakeTranscriptionJob);
      await tester.runAsync(rig.settle);

      await rig.harness.pumpEditor(tester, projectId: rig.id, surface: surface);
      await tester.runAsync(rig.settle);
      await _settle(tester);

      expect(find.byType(EditorScaffold), findsOneWidget);
      expect(notice, findsOneWidget);
      expect(find.descendant(of: find.byType(EditorScreen), matching: notice), findsOneWidget);
      expect(find.text(InterruptedCaptionsStrings.title), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-interrupted-resume')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-interrupted-discard')), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);

      // Discard drops it from the editor screen too.
      await tester.tap(find.byKey(const ValueKey('captions-interrupted-discard')));
      await tester.runAsync(rig.settle);
      await _settle(tester);
      expect(notice, findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  }

  testWidgets('no interrupted job: the editor screen shows no notice', (tester) async {
    final rig = RegenRig();
    rig.install();
    await rig.harness.pumpEditor(tester, projectId: rig.id);
    await tester.runAsync(rig.settle);
    await _settle(tester);
    expect(find.byType(EditorScaffold), findsOneWidget);
    expect(notice, findsNothing);
  });

  testWidgets('Auto captions not wired: no notice and no error', (tester) async {
    final rig = RegenRig(overrides: [
      transcriptionServiceProvider.overrideWith((ref) => throw EditorNotConfiguredError('transcriptionServiceProvider')),
    ]);
    await rig.harness.pumpEditor(tester, projectId: rig.id);
    await tester.runAsync(rig.settle);
    await _settle(tester);
    expect(find.byType(EditorScaffold), findsOneWidget);
    expect(find.byType(InterruptedCaptionsBanner), findsOneWidget);
    expect(notice, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
