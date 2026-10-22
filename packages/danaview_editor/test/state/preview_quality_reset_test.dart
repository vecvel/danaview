// OWNER: FIX-QA05-D11
//
// QA-05 D11 (Dart side): when playback stops, both engines return the quality governor to the
// requested quality and report it as the step to full (`degraded(full)`, then `recovered`; ARCH
// §13.2). The editor must then read the preview as ready again, so a paused preview never keeps
// the "Preview ¼" badge or stays `degraded`. The engine behaviour itself is covered by the native
// tests (iOS RunnerTests QualityGovernorTests / PreviewSessionTests; the Android lane's own).

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show PreviewDegraded, PreviewFailedEvent, EngineErrorCode, EngineFailure, PreviewQuality, PreviewRecovered;

import '../flows/tasks/tasks_rig.dart';

void main() {
  testWidgets('degraded during playback, then paused + recovered -> ready', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.ready);
    final session = rig.engine.sessions.last;

    await rig.real(() async => rig.playhead.play());
    session.emitEvent(const PreviewDegraded(PreviewQuality.half));
    session.emitEvent(const PreviewDegraded(PreviewQuality.quarter));
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.degraded);
    expect(rig.state.preview.quality, PreviewQuality.quarter);

    // Pause: the engine resets the governor and reports the step to full plus RECOVERED.
    await rig.real(() async => rig.playhead.pause());
    expect(rig.engine.calls, contains('preview.pause'));
    session.emitEvent(const PreviewDegraded(PreviewQuality.full));
    session.emitEvent(const PreviewRecovered());
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.ready, reason: 'a paused preview is never left degraded');
    expect(rig.state.preview.quality, PreviewQuality.full);
    await rig.finish();
  });

  testWidgets('RECOVERED alone after a pause also reads as ready', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    final session = rig.engine.sessions.last;
    await rig.real(() async => rig.playhead.play());
    session.emitEvent(const PreviewDegraded(PreviewQuality.quarter));
    await rig.settle();
    await rig.real(() async => rig.playhead.pause());
    session.emitEvent(const PreviewRecovered());
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.ready);
    await rig.finish();
  });

  testWidgets('the reset after a pause does not hide a stopped preview', (tester) async {
    final rig = await TasksRig.pump(tester, readTasks: false);
    await rig.settle();
    final session = rig.engine.sessions.last;
    await rig.real(() async => rig.playhead.play());
    session.emitEvent(const PreviewDegraded(PreviewQuality.quarter));
    session.emitEvent(PreviewFailedEvent(EngineFailure.of(EngineErrorCode.internal, debugDetail: 'x')));
    await rig.settle();
    await rig.real(() async => rig.playhead.pause());
    session.emitEvent(const PreviewDegraded(PreviewQuality.full));
    session.emitEvent(const PreviewRecovered());
    await rig.settle();
    expect(rig.state.preview.phase, PreviewPhase.failed, reason: '"Restart preview" stays');
    await rig.finish();
  });
}
