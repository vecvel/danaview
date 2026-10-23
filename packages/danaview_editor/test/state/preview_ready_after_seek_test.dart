// OWNER: FIX M-22
//
// QA-02 M-22: on a slow emulator the preview's first frame (frame 0, shown once the plan lands)
// arrived before the opening seek to the saved playhead, and the preview already said `ready`.
// A ready preview must show the saved position: `ready` waits for the first frame and the
// opening seek, on open and on "Restart preview".

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/edit_transaction.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/ops.dart' hide MediaUnavailable;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import 'editor_controller_test.dart' show RecordingRepository, textProject;
import 'state_support.dart';

void main() {
  test('the preview stays starting until the opening seek shows the saved frame', () async {
    final repo = RecordingRepository();
    final project = textProject(repo);
    final engine = FakeEditorEngine(validatePlans: false);
    final gate = Completer<void>();
    engine.previewSeekGate = gate.future;
    final rig = ControllerRig(repository: repo, id: project.id, engine: engine);
    final opening = rig.controller.open(initialPlayhead: 2000000);
    await rig.settle();
    expect(rig.preview.plan, isNotNull, reason: 'the plan landed, so the first frame is up');
    expect(rig.controller.state.preview.phase, PreviewPhase.starting, reason: 'the saved frame is not shown yet');

    gate.complete();
    await opening;
    await rig.settle();
    expect(rig.controller.state.preview.phase, PreviewPhase.ready);
    expect(rig.preview.time, project.settings.frameRate.quantize(2000000));
    await rig.controller.close();
  });

  test('"Restart preview" is ready only after its seek', () async {
    final repo = RecordingRepository();
    final project = textProject(repo);
    final engine = FakeEditorEngine(validatePlans: false);
    engine.failNext['openPreview'] = EngineFailure.of(EngineErrorCode.gpuUnavailable);
    final rig = ControllerRig(repository: repo, id: project.id, engine: engine);
    await rig.open(initialPlayhead: 1000000);
    final c = rig.controller;
    expect(c.state.preview.phase, PreviewPhase.failed);
    expect(c.apply(const AddMarker(0)), isA<EditApplied>());

    final gate = Completer<void>();
    engine.previewSeekGate = gate.future;
    final restarting = c.restartPreview();
    await rig.settle();
    expect(c.state.preview.phase, PreviewPhase.starting);

    gate.complete();
    await restarting;
    await rig.settle();
    expect(c.state.preview.phase, PreviewPhase.ready);
    await c.close();
  });
}
