// OWNER: QA-00
//
// ARCH §21.2 scenario 14: a picture-in-picture video overlay added from the Overlay panel, moved,
// scaled and faded in (the Transform panel's and Keyframes panel's commands), then exported: the
// export conforms, the main frame's barcode is intact and the overlay's own barcode reads inside
// its placed rectangle.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_engine/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 14: PiP overlay moved, scaled, faded and exported', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E pip ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;

    await ed.seekFrame(0);
    await ed.invoke(EditorActionId.addOverlay);
    E2eApp.world.engine.picker.queue([E2eMedia.fixture(Fx.clapFlash)]);
    await E2eApp.tapKey(tester, 'overlay.addVideo');
    await ed.waitProject((p) => ed.tracksOf(TrackKind.overlay).any((t) => t.items.isNotEmpty), what: 'the overlay clip', timeout: const Duration(seconds: 60));
    final overlay = ed.tracksOf(TrackKind.overlay).firstWhere((t) => t.items.isNotEmpty).items.single as MediaClip;
    expect(overlay.start, 0);

    // Move to the lower right, scale to 35 %, fade in over the first second.
    ed.apply(SetVisual([overlay.id], const VisualProps(transform: Transform2D(position: Vec2(0.3, 0.25), scale: 0.35))));
    ed.apply(AddKeyframe(KeyframeRef(overlay.id, 'transform.opacity', 0), value: 0.0));
    ed.apply(AddKeyframe(KeyframeRef(overlay.id, 'transform.opacity', 1000000), value: 1.0));
    await ed.waitProject((p) {
      final c = ed.item(overlay.id) as MediaClip;
      return c.visual?.transform.scale == 0.35 && (c.keyframes.byChannel['transform.opacity']?.keys.length ?? 0) == 2;
    }, what: 'the overlay placement and fade');
    await E2eApp.screenshot(tester, 's14_pip');

    final out = await E2eExport.run(ed);
    await E2eExport.expectConformant(out.video, width: 1280, height: 720, duration: ed.project.duration, rate: r, audio: true);
    final f = (await E2eExport.frames(ed, out.video, [r.timeOfFrame(90)])).single;
    expect(f.barcode.index, 90, reason: 'main frame barcode at 3 s');
    // The overlay: 1280x720 * 0.35 = 448x252 centred at (0.8, 0.75) of the canvas.
    final w = (f.width * 0.35).round(), h = (f.height * 0.35).round();
    final x = (f.width * 0.8 - w / 2).round(), y = (f.height * 0.75 - h / 2).round();
    final pip = FrameBarcode.read(f.rgba, width: f.width, height: f.height, region: FrameBarcodeRegion(x, y, w, h));
    expect(pip.index, 90, reason: 'overlay barcode inside its rectangle: $pip');
    // Faded: at frame 5 the overlay is mostly transparent, so its band is not a clean barcode.
    final early = (await E2eExport.frames(ed, out.video, [r.timeOfFrame(5)])).single;
    expect(FrameBarcode.read(early.rgba, width: early.width, height: early.height, region: FrameBarcodeRegion(x, y, w, h)).isReadable, isFalse);
    await ed.close();
  });
}
