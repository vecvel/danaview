// OWNER: FIX-QA05-D5
//
// QA-05 re-run D6 (Dart side): after a background the preview must come back. A preview that
// stopped (an engine failure event) while PlanSync stayed idle used to stay `failed` after the
// return, because only a PlanSync status change left `failed`; a quality step (`degraded`) could
// also hide a stopped preview. The device check (2 s background on the iOS simulator under load)
// stays with QA-05.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EngineErrorCode, EngineFailure, PreviewDegraded, PreviewFailedEvent, PreviewQuality, PreviewRecovered;

import '../flows/tasks/tasks_rig.dart';

int _fullPlans(TasksRig rig) => rig.engine.calls.where((c) => c == 'preview.setPlan').length;

void main() {
  testWidgets('a preview that stopped while the app was away restarts on resume', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.ready);
    final plans = _fullPlans(rig);

    rig.engine.sessions.last.emitEvent(PreviewFailedEvent(EngineFailure.of(EngineErrorCode.internal, debugDetail: 'decoder lost')));
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.failed);

    await rig.real(() async => rig.editor.onAppResumed());
    expect(_fullPlans(rig), plans + 1, reason: 'the full plan is sent again, as "Restart preview" does');
    expect(rig.state.preview.phase, PreviewPhase.ready, reason: 'the applied plan brings the preview back');
    await rig.finish();
  });

  testWidgets('a resume with a live preview only redraws (no plan resend)', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    final plans = _fullPlans(rig);
    await rig.real(() async => rig.editor.onAppResumed());
    expect(_fullPlans(rig), plans);
    expect(rig.engine.calls, contains('preview.refresh'));
    expect(rig.state.preview.phase, PreviewPhase.ready);
    await rig.finish();
  });

  testWidgets('a quality step does not hide a stopped preview', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    final session = rig.engine.sessions.last;
    session.emitEvent(PreviewFailedEvent(EngineFailure.of(EngineErrorCode.internal, debugDetail: 'x')));
    await rig.settle();
    session.emitEvent(const PreviewDegraded(PreviewQuality.half));
    session.emitEvent(const PreviewRecovered());
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.failed, reason: '"Restart preview" stays');
    await rig.finish();
  });

  testWidgets('a degraded (live) preview is not restarted on resume', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    rig.engine.sessions.last.emitEvent(const PreviewDegraded(PreviewQuality.half));
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.degraded);
    final plans = _fullPlans(rig);
    await rig.real(() async => rig.editor.onAppResumed());
    expect(_fullPlans(rig), plans);
    expect(rig.state.preview.phase, PreviewPhase.degraded, reason: 'it steps back up on its own during playback');
    await rig.finish();
  });
}
