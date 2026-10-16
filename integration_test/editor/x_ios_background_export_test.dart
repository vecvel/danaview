// OWNER: QA-00
//
// iOS platform extra (ARCH §21.2): backgrounding mid-export ends with `pausedInBackground`; on
// return the export resumes from its last segment and the result passes conformance. The host
// sends the app to the background for 20 s once the export is past 10 %. On a simulator the
// encoder is not taken away in the background, so a run that never pauses is reported, not failed
// (the encoder loss itself is verified on real iPhones in IOS-01/IOS-13).

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:danaview_editor/src/editor/flows/export/export_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS: background mid-export pauses, resumes from the last segment, conforms', (tester) async {
    await E2eApp.launch(tester);
    // 32 s of video so the export spans several 10 s segments.
    final ed = await E2eEditor.createProject(
      tester,
      name: 'E2E bg export ${DateTime.now().millisecondsSinceEpoch % 100000}',
      media: [for (var i = 0; i < 4; i++) E2eMedia.fixture(Fx.toneUnderVideo, as: 'e2e-bg-$i.mp4')],
    );
    final handoffs = E2eApp.world.engine.files.records.length;
    final settings = await E2eExport.start(ed, configure: (s) => s.copyWith(shortSide: 1080));
    await E2eApp.pumpUntil(
      tester,
      () {
        final s = E2eExport.state(ed);
        if (s is ExportUiNotice) E2eExport.controller(ed).confirmNotice();
        // The simulator encodes in software, which the setup warns about first (ux.md §11.1).
        if (s is ExportUiWarnings) E2eExport.controller(ed).confirmWarnings();
        return s is ExportUiRunning && s.fraction > 0.1;
      },
      what: 'the export to pass 10 %',
      timeout: const Duration(minutes: 2),
    );
    final ack = await E2eHandshake.request(tester, 'background', args: {'seconds': 20});
    expect(ack.ok, isTrue);
    var paused = false;
    final out = await E2eExport.finish(
      ed,
      settings,
      handoffs: handoffs,
      timeout: const Duration(minutes: 10),
      observe: (s) {
        if (s is ExportUiRunning && s.pausedInBackground) paused = true;
      },
    );
    // ignore: avoid_print
    print('DV_E2E_REPORT ios-bg-export pausedInBackground observed: $paused');
    await E2eExport.expectConformant(out.video, width: 1920, height: 1080, duration: ed.project.duration, rate: ed.rate);
    expect(settings.shortSide, 1080);
    await ed.close();
  }, skip: !Platform.isIOS || !E2eHandshake.available);
}
