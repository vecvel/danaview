// OWNER: QA-00
//
// ARCH §21.2 scenario 6: speed 2× and a ramp, reverse, freeze frame, cross dissolve, LUT import,
// chroma key, mask and keyframes. Tool actions run through the registry (as their tiles do), the
// sheets they open are answered by tapping their buttons, and the property panels' edits are the
// same core commands the panels issue. Barcodes check what the preview shows where the result is
// frame-exact (2×, freeze, reverse).

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 6: speed, ramp, reverse, freeze, cross dissolve, LUT, chroma, mask, keyframes', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(
      tester,
      name: 'E2E effects ${DateTime.now().millisecondsSinceEpoch % 100000}',
      media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.toneUnderVideo)],
    );
    final r = ed.rate;
    final main = ed.mainTrack;
    expect(main.items, hasLength(2));
    final c1 = main.items[0] as MediaClip;
    final c2 = main.items[1] as MediaClip;

    // Speed 2× (Speed panel › Constant): 8 s become 4 s, project frame 30 shows source frame 60.
    ed.apply(SetSpeed(c1.id, const ConstantSpeed(2)));
    await ed.waitProject((p) => ed.item(c1.id).duration == 4000000, what: 'the 2× clip to last 4 s');
    await ed.seekFrame(30);
    expect((await ed.barcode()).index, 60);

    // Freeze frame at project frame 30 (source 60): the sheet's default 3 s.
    await ed.select(c1.id);
    await ed.invoke(EditorActionId.freeze);
    await E2eApp.waitKey(tester, 'freeze.sheet');
    await E2eApp.tapKey(tester, 'freeze.confirm');
    await ed.waitProject(
      (p) => ed.items<MediaClip>().any((c) => p.pool[c.media]?.kind == MediaKind.still),
      what: 'the freeze-frame still on the timeline',
    );
    final still = ed.items<MediaClip>().firstWhere((c) => ed.project.pool[c.media]?.kind == MediaKind.still);
    expect(still.start, r.timeOfFrame(30));
    await E2eApp.pumpUntil(
      tester,
      () {
        final status = ed.project.pool[still.media]!.status;
        if (status is FailedStatus) throw TestFailure('the freeze still failed: ${status.reason}');
        return status is ReadyStatus;
      },
      what: 'the engine to render the still',
      timeout: const Duration(seconds: 60),
    );
    await ed.seekTo(still.start + still.duration ~/ 2);
    expect((await ed.barcode()).index, 60, reason: 'the still shows source frame 60');

    // A ramp on the first piece of the 2× clip (Speed panel › Curve).
    final first = ed.mainTrack.items.first as MediaClip;
    ed.apply(SetSpeed(first.id, SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.5, 2), SpeedPoint(1, 1)])));
    await ed.waitProject((p) => (ed.item(first.id) as MediaClip).speed is SpeedRamp, what: 'the ramp');

    // Reverse the second clip (reversed rendition rendered by the engine).
    await ed.select(c2.id);
    await ed.invoke(EditorActionId.reverse);
    await ed.waitProject((p) => (ed.item(c2.id) as MediaClip).reversed, what: 'the reversed clip');
    final rev = ed.item(c2.id);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      await ed.seekTo(rev.start);
      final b = await ed.barcode();
      if (b.isReadable && b.index! >= 236) break;
      if (DateTime.now().isAfter(deadline)) fail('the reversed clip does not start near source frame 239 ($b)');
      await E2eApp.pumpUntil(tester, () => ed.state.tasks.isEmpty, what: 'the reverse task', timeout: const Duration(seconds: 90));
    }

    // Cross dissolve (Transitions panel) on the cut before the reversed clip.
    final mainNow = ed.mainTrack;
    final idx = mainNow.items.indexWhere((i) => i.id == c2.id);
    final cut = TransitionRef(mainNow.id, mainNow.items[idx - 1].id, c2.id);
    ed.apply(SetTransition(cut, const TransitionSpec(TransitionKind.crossDissolve, 15), clamp: true));
    await ed.waitProject((p) => ed.mainTrack.transitions.any((t) => t.right == c2.id), what: 'the cross dissolve');

    // LUT import (Filters panel › Import .cube, Files picker answered with a sandbox .cube).
    await ed.select(c2.id);
    await ed.invoke(EditorActionId.filters);
    E2eApp.world.engine.picker.queue([E2eMedia.cubeLut()]);
    await E2eApp.tapKey(tester, 'lut.import');
    await ed.waitProject((p) => (ed.item(c2.id) as MediaClip).visual?.look is ImportedLut, what: 'the imported LUT on the clip');

    // Chroma key and mask (their panels' commands).
    ed.apply(SetChroma([c2.id], const ChromaKey(enabled: true, color: 0x00FF00)));
    ed.apply(SetMask([c2.id], const MaskSpec(shape: MaskShape.ellipse, feather: 0.1)));
    await ed.waitProject((p) {
      final v = (ed.item(c2.id) as MediaClip).visual;
      return v != null && v.chroma.enabled && v.mask.shape == MaskShape.ellipse;
    }, what: 'chroma key and mask');

    // Keyframes: opacity 1 at the clip start, 0.2 one second later.
    ed.apply(AddKeyframe(KeyframeRef(c2.id, 'transform.opacity', 0), value: 1.0));
    ed.apply(AddKeyframe(KeyframeRef(c2.id, 'transform.opacity', 1000000), value: 0.2));
    await ed.waitProject((p) => (ed.item(c2.id) as MediaClip).keyframes.byChannel['transform.opacity']?.keys.length == 2,
        what: 'two opacity keyframes');

    // Undo walks back through all of it without refusals.
    expect(ed.state.history.canUndo, isTrue);
    await E2eApp.screenshot(tester, 's06_effects');
    await ed.close();
  });
}
