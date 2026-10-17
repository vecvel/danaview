// OWNER: QA-00
//
// Android platform extras (ARCH §21.2, D-39), each a pair of phases run by tool/e2e_host.sh on the
// Windows lane (QA-02):
//
//   fgs / fgs-check       the export keeps running in the foreground service after the activity is
//                         destroyed; relaunching shows the "finished" card and the video is in the
//                         Gallery (Movies/Danaview);
//   cancel                Cancel in the export notification cancels the export;
//   swipe / swipe-check   swiping the app from recents mid-export: the video still lands in the
//                         Gallery and a "finished" card shows on relaunch;
//   death / death-check   process death mid-export leaves exactly one `interrupted` record.
//
// The first phase of each pair starts the export with "Save to Gallery" (the real MediaStore add)
// and hands the app to the host; the -check phase relaunches and asks the export controller to
// reattach (what the editor does when it opens).

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

const String _phase = E2eConfig.phase;

Future<E2eEditor> _startLongExport(WidgetTester tester, String tag) async {
  await E2eApp.launch(tester);
  E2eApp.world.engine.files.realPhotos = true;
  final ed = await E2eEditor.createProject(
    tester,
    name: 'E2E android $tag ${DateTime.now().millisecondsSinceEpoch % 100000}',
    media: [for (var i = 0; i < 4; i++) E2eMedia.fixture(Fx.toneUnderVideo, as: 'e2e-and-$i.mp4')],
  );
  await E2eExport.start(ed, configure: (s) => s.copyWith(shortSide: 1080), destination: ExportDestination.photos);
  await E2eApp.pumpUntil(
    tester,
    () {
      final s = E2eExport.state(ed);
      if (s is ExportUiNotice) E2eExport.controller(ed).confirmNotice();
      if (s is ExportUiWarnings) E2eExport.controller(ed).confirmWarnings();
      return s is ExportUiRunning && s.fraction > 0.05;
    },
    what: 'the export to run',
    timeout: const Duration(minutes: 2),
  );
  E2eHandshake.saveState('android-$tag', {'project': ed.id.value});
  return ed;
}

Future<(E2eEditor, ExportReattach)> _reattach(WidgetTester tester, String tag) async {
  final saved = E2eHandshake.loadState('android-$tag');
  expect(saved, isNotNull, reason: 'run phase "$tag" first');
  await E2eApp.launch(tester);
  final ed = await E2eEditor.openFromProjects(tester, ProjectId(saved!['project']! as String));
  final ExportReattach found;
  if (E2eExport.state(ed) is ExportUiFinishedAway || E2eExport.state(ed) is ExportUiInterrupted) {
    found = E2eExport.state(ed) is ExportUiFinishedAway ? ExportReattach.finished : ExportReattach.interrupted;
  } else {
    found = await E2eApp.pumpWhile(tester, E2eExport.controller(ed).reattach(), what: 'reattach');
  }
  return (ed, found);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = Platform.isAndroid && E2eHandshake.available;

  testWidgets('Android: export continues in the FGS with the activity destroyed', (tester) async {
    await _startLongExport(tester, 'fgs');
    await E2eHandshake.requestAndDie(tester, 'destroyActivity');
  }, skip: !android || _phase != 'fgs');

  for (final tag in ['fgs', 'swipe']) {
    testWidgets('Android: after "$tag" the relaunch shows the finished card, video in the Gallery', (tester) async {
      final (ed, found) = await _reattach(tester, tag);
      // The export may still be finishing in the service when the app comes back.
      var result = found;
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (result == ExportReattach.running && DateTime.now().isBefore(deadline)) {
        await E2eApp.pumpUntil(tester, () => E2eExport.state(ed) is! ExportUiRunning, what: 'the export to finish', timeout: const Duration(minutes: 5));
        result = E2eExport.state(ed) is ExportUiCompleted ? ExportReattach.finished : await E2eExport.controller(ed).reattach();
      }
      expect(result, ExportReattach.finished);
      final s = E2eExport.state(ed);
      if (s is ExportUiFinishedAway) {
        expect(s.savedToGallery, isTrue, reason: 'the service saved the video to the Gallery');
        expect(s.failed, isFalse);
      }
      await E2eApp.screenshot(tester, 'android_${tag}_finished_card');
    }, skip: !android || _phase != '$tag-check');
  }

  testWidgets('Android: Cancel in the export notification cancels it', (tester) async {
    final ed = await _startLongExport(tester, 'cancel');
    final ack = await E2eHandshake.request(tester, 'tapNotificationCancel');
    expect(ack.ok, isTrue, reason: '$ack');
    await E2eApp.pumpUntil(tester, () => E2eExport.state(ed) is ExportUiCancelled, what: 'the cancelled export', timeout: const Duration(seconds: 30));
    final jobs = await E2eApp.world.engine.exporter.activeJobs();
    expect(jobs.whereType<ExportRunning>(), isEmpty);
  }, skip: !android || _phase != 'cancel');

  testWidgets('Android: swipe from recents mid-export', (tester) async {
    await _startLongExport(tester, 'swipe');
    await E2eHandshake.requestAndDie(tester, 'swipeFromRecents');
  }, skip: !android || _phase != 'swipe');

  testWidgets('Android: process death mid-export', (tester) async {
    await _startLongExport(tester, 'death');
    await E2eHandshake.requestAndDie(tester, 'kill');
  }, skip: !android || _phase != 'death');

  testWidgets('Android: process death leaves exactly one interrupted record', (tester) async {
    await E2eApp.launch(tester);
    // Before anything reattaches (the notice consumes the record).
    final jobs = await E2eApp.world.engine.exporter.activeJobs();
    expect(jobs.whereType<ExportInterrupted>(), hasLength(1), reason: 'records: $jobs');
    expect(jobs.whereType<ExportRunning>(), isEmpty);
    final (_, found) = await _reattach(tester, 'death');
    expect(found, ExportReattach.interrupted);
  }, skip: !android || _phase != 'death-check');
}
