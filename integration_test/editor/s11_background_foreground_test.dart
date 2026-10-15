// OWNER: QA-00
//
// ARCH §21.2 scenario 11: background and foreground during playback. The host driver sends the
// app to the background for 3 s and brings it back (simctl launch of another app and of Danaview /
// adb input keyevent HOME and am start); one second after the return the preview must show a real
// frame (a readable barcode, not black).

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 11: background/foreground during playback, no black frame after 1 s', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E background ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    await ed.seekFrame(10);
    await ed.transport.play();
    await ed.waitPlaying(true);
    await E2eApp.pumpUntil(tester, () => ed.playheadFrame >= 20, what: 'playback to advance');

    final ack = await E2eHandshake.request(tester, 'background', args: {'seconds': 3});
    expect(ack.ok, isTrue, reason: '$ack');
    await E2eApp.pumpUntil(tester, () => ed.state.preview.phase.name != 'starting', what: 'the preview after resume');
    // The spec's measurement: one second after the app is back.
    final back = DateTime.now();
    await E2eApp.pumpUntil(tester, () => DateTime.now().difference(back) >= const Duration(seconds: 1), what: '1 s after foreground');
    final frame = await ed.capture();
    expect(frame.meanLuma, greaterThan(20), reason: 'black frame after resume');
    expect(frame.barcode.isReadable, isTrue, reason: '${frame.barcode}');
    await E2eApp.screenshot(tester, 's11_after_resume');
    await ed.transport.pause();
    await ed.close();
  }, skip: !E2eHandshake.available);
}
