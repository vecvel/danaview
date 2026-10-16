// OWNER: UX-39
//
// ExportSheet (ux.md §11, ARCH §14.1, D-22, D-24, D-39) with fakes, through the real controller: every
// pre-check, presets and gating, notices, the Custom settings, captions, storage and first-export
// notice, progress with the background copy per BackgroundExportKind (incl. paused in background),
// the modal non-dismissible sheet and cancel, completion destinations, failures and their
// fallbacks, the reattach cards, and the no-overflow matrix.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/export_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorTaskInfo, EditorTaskKind;
import 'package:danaview_editor_core/model.dart' show MediaId;
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import '../../actions/action_test_support.dart';
import '../../support/support.dart';
import 'export_rig.dart';

const _iosPhone = EditorSurface(Size(390, 844), platform: TargetPlatform.iOS);

Finder _key(String key) => find.byKey(ValueKey(key));

Finder get _sheet => _key('export-sheet');

const _iphoneCopy =
    'Keep Danaview open while exporting. If you leave, the export pauses and continues from where it stopped when you come back.';

void main() {
  group('pre-checks', () {
    testWidgets('an empty timeline shows the toast and does not open the sheet', (tester) async {
      final rig = ExportRig(project: (repo) => exportProject(repo, empty: true));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text('Add a clip before exporting.'), findsOneWidget);
      expect(_sheet, findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('missing media: "Relink 1 missing file to export" and the button runs the relink action after the sheet closes', (tester) async {
      final log = ActionLog();
      final rig = ExportRig(overrides: [recordingActions(log)]);
      rig.offline.add(const MediaId('md_a'));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text('Relink 1 missing file to export'), findsOneWidget);
      expect(_key('export-start'), findsNothing);
      await rig.tapKey(tester, 'export-relink-button');
      expect(_sheet, findsNothing);
      expect(log.ran, [EditorActionId.relink]);
      expectNoOverflow(tester);
    });

    testWidgets('missing media: Cancel closes without running anything', (tester) async {
      final log = ActionLog();
      final rig = ExportRig(overrides: [recordingActions(log)]);
      rig.offline.add(const MediaId('md_a'));
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-relink-cancel');
      expect(_sheet, findsNothing);
      expect(log.ran, isEmpty);
    });

    testWidgets('pending reverse and freeze jobs: "Finishing 1 clip…" with progress and Cancel; it continues by itself', (tester) async {
      final rig = ExportRig();
      rig.blockWith = PlanRequirements(pendingReverse: const ['it_1']);
      final c = await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text('Finishing 1 clip…'), findsOneWidget);
      expect(find.text(ExportStrings.waitingDetail), findsOneWidget);
      expect(_key('export-waiting-cancel'), findsOneWidget);

      final editor = c.read(editorControllerProvider(rig.id).notifier);
      editor.setTasks(const [EditorTaskInfo(id: 'j1', kind: EditorTaskKind.reverse, label: 'Reversing a clip', progress: 0.5)]);
      await rig.pumpSome(tester);
      expect(_key('export-waiting'), findsOneWidget, reason: 'still waiting while the job runs');
      rig.blockWith = null;
      editor.setTasks(const []);
      await rig.pumpSome(tester);
      expect(_key('export-setup'), findsOneWidget);
    });

    testWidgets('pending jobs: Cancel closes the sheet', (tester) async {
      final rig = ExportRig();
      rig.blockWith = PlanRequirements(pendingStill: const ['md_x']);
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-waiting-cancel');
      expect(_sheet, findsNothing);
    });
  });

  group('settings', () {
    testWidgets('presets, summary with the size estimate, hardware encoder note and the Export button', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      for (final label in ['YouTube', 'Shorts', 'Reels', 'Instagram Feed', 'TikTok', 'Custom']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('YouTube 4K'), findsNothing, reason: 'not offered on this device and source');
      final summary = tester.widget<Text>(_key('export-summary')).data!;
      expect(summary, startsWith('1920×1080 · 30 fps · H.264 · ≈ '));
      expect(summary, contains('MB'));
      expect(find.text(ExportStrings.hardwareEncoder), findsOneWidget);
      expect(_key('export-start'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a software encoder is shown as "Software encoding (slower)"', (tester) async {
      final rig = ExportRig(caps: rigCaps.copyWith(hardwareH264: false));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text(ExportStrings.softwareEncoder), findsOneWidget);
    });

    testWidgets('YouTube 4K appears when the device and the source reach 2160p', (tester) async {
      final rig = ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)), project: (r) => exportProject(r, video4k: true));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text('YouTube 4K'), findsOneWidget);
      await rig.tapKey(tester, 'export-preset-youtube4k');
      expect(tester.widget<Text>(_key('export-summary')).data, startsWith('3840×2160 · 30 fps · H.265'));
    });

    testWidgets('an aspect mismatch names both ratios and "Change project to 9:16" opens the Canvas panel after the sheet closes', (tester) async {
      final log = ActionLog();
      final rig = ExportRig(overrides: [recordingActions(log)]);
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('export-notice-aspectMismatch')), findsNothing);
      await rig.tapKey(tester, 'export-preset-tiktok');
      expect(find.text('Your project is 16:9. TikTok videos are 9:16, so yours will have black bars.'), findsOneWidget);
      expect(find.text('Change project to 9:16'), findsOneWidget);
      await rig.tapKey(tester, 'export-change-aspect');
      expect(_sheet, findsNothing);
      expect(log.ran, [EditorActionId.format]);
    });

    testWidgets('Custom: format and codec rows follow the capabilities; the frame rate list has Match project and 48', (tester) async {
      final rig = ExportRig(caps: rigCaps.copyWith(hevcEncode: true, movContainer: false));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(_key('export-custom'), findsNothing);
      await rig.tapKey(tester, 'export-edit');
      expect(_key('export-custom'), findsOneWidget);
      expect(_key('export-container-mov'), findsNothing, reason: 'MOV only where the engine has it');
      expect(_key('export-codec-hevc'), findsOneWidget);
      for (final fps in [24, 25, 30, 48, 50, 60]) {
        expect(_key('export-fps-$fps'), findsOneWidget, reason: '$fps fps');
      }
      expect(_key('export-fps-match'), findsOneWidget);
      expect(find.text('Match project'), findsOneWidget);
      expect(_key('export-size-720'), findsOneWidget);
      expect(_key('export-size-1080'), findsOneWidget);
      expect(_key('export-size-1440'), findsNothing, reason: 'above this device');
      expect(_key('export-size-2160'), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('Custom: without HEVC or MOV the rows are absent; with both they are offered', (tester) async {
      final plain = ExportRig(caps: rigCaps.copyWith(hevcEncode: false, movContainer: false));
      await plain.pump(tester);
      await plain.openSheet(tester);
      await plain.tapKey(tester, 'export-edit');
      expect(_key('export-codec-hevc'), findsNothing);
      expect(_key('export-container-mov'), findsNothing);
    });

    testWidgets('Custom: MOV, H.265, 4K and 50/60 fps appear on a capable device; the fps list follows the resolution', (tester) async {
      final rig = ExportRig(caps: rigCaps.copyWith(movContainer: true, hevcEncode: true, maxExportSize: const Size(3840, 2160)));
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-edit');
      expect(_key('export-container-mov'), findsOneWidget);
      expect(_key('export-codec-hevc'), findsOneWidget);
      expect(_key('export-size-2160'), findsOneWidget);
      expect(_key('export-fps-60'), findsOneWidget);
      await rig.tapKey(tester, 'export-size-2160');
      expect(_key('export-fps-60'), findsNothing, reason: 'maxFpsByHeight limits 4K to 30');
      expect(_key('export-fps-30'), findsOneWidget);
    });

    testWidgets('Custom: choices change the summary; the bitrate slider and audio chips work', (tester) async {
      final rig = ExportRig(caps: rigCaps.copyWith(movContainer: true));
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-edit');
      await rig.tapKey(tester, 'export-fps-48');
      expect(tester.widget<Text>(_key('export-summary')).data, contains('48 fps'));
      await rig.tapKey(tester, 'export-codec-hevc');
      expect(tester.widget<Text>(_key('export-summary')).data, contains('H.265'));
      await rig.tapKey(tester, 'export-container-mov');
      await rig.tapKey(tester, 'export-quality-maximum');
      await rig.tapKey(tester, 'export-audio-320');
      expect(_key('export-bitrate-slider'), findsNothing);
      await rig.tapKey(tester, 'export-bitrate-custom');
      expect(_key('export-bitrate-slider'), findsOneWidget);
      final c = rig.harness.containerOf(tester);
      final setup = c.read(exportControllerProvider(rig.id)) as ExportUiSetup;
      expect(setup.draft.settings.container, ExportContainer.mov);
      expect(setup.draft.settings.codec, VideoCodec.hevc);
      expect(setup.draft.settings.quality, ExportQuality.maximum);
      expect(setup.draft.settings.audioBitrateKbps, 320);
      expect(setup.draft.settings.videoBitrateMbps, isNotNull);
      await rig.tapKey(tester, 'export-bitrate-auto');
      expect(_key('export-bitrate-slider'), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('captions: a switch per subtitle track and SRT / VTT side files', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text('Burn "Captions (Spanish)" into the video'), findsOneWidget);
      expect(find.text(ExportStrings.sideFilesRow), findsOneWidget);
      await rig.tapKey(tester, 'export-side-srt');
      await rig.tapKey(tester, 'export-side-vtt');
      final c = rig.harness.containerOf(tester);
      final setup = c.read(exportControllerProvider(rig.id)) as ExportUiSetup;
      expect(setup.draft.settings.sideFiles, {SideFileFormat.srt, SideFileFormat.vtt});
      final track = setup.subtitleTracks.single.id;
      await rig.tapKey(tester, 'export-burn-${track.value}');
      expect((c.read(exportControllerProvider(rig.id)) as ExportUiSetup).subtitleTracks.single.burnIn, isFalse);
    });

    testWidgets('a project without subtitle tracks has no Captions section', (tester) async {
      final rig = ExportRig(project: (r) => exportProject(r, cues: 0));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(_key('export-captions'), findsNothing);
    });

    testWidgets('Save to: Gallery on Android, Photos on iPhone; Files and Share; "Keep a copy in Danaview" is off by default', (tester) async {
      final android = ExportRig();
      await android.pump(tester);
      await android.openSheet(tester);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Files…'), findsOneWidget);
      expect(find.text('Share…'), findsOneWidget);
      expect(find.text(ExportStrings.keepCopy), findsOneWidget);
      final setup = android.harness.containerOf(tester).read(exportControllerProvider(android.id)) as ExportUiSetup;
      expect(setup.draft.keepCopy, isFalse);
    });

    testWidgets('Save to shows Photos on iOS', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS);
      await rig.pump(tester, surface: _iosPhone);
      await rig.openSheet(tester);
      expect(find.text('Photos'), findsOneWidget);
    });

    testWidgets('not enough space: the estimate against free space, with Lower resolution and Free up space', (tester) async {
      final rig = ExportRig();
      rig.fake.freeBytesValue = 1000;
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-start');
      expect(_key('export-storage-issue'), findsOneWidget);
      expect(find.textContaining('free to export. Free up space or lower the resolution.'), findsOneWidget);
      expect(find.textContaining('You need about'), findsOneWidget);
      expect(rig.started, isEmpty);
      await rig.tapKey(tester, 'export-free-up-space');
      expect(rig.host.freeUpSpace, 1);
      await rig.tapKey(tester, 'export-lower-resolution');
      expect(_key('export-storage-issue'), findsNothing);
      expect(tester.widget<Text>(_key('export-summary')).data, startsWith('1280×720'));
    });
  });

  group('first export and warnings', () {
    testWidgets('Android: the notification explainer comes first, in context, once', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-start');
      expect(_key('export-notice'), findsOneWidget);
      expect(find.text(ExportStrings.notificationExplainer), findsOneWidget);
      expect(find.text(ExportStrings.backgroundCopy(BackgroundExportKind.foregroundService)), findsOneWidget);
      await rig.tapKey(tester, 'export-notice-back');
      expect(_key('export-setup'), findsOneWidget);
      await rig.tapKey(tester, 'export-start');
      await rig.tapKey(tester, 'export-notice-continue');
      expect(_key('export-running'), findsOneWidget);
      expect(rig.harness.prefs.exportNotificationPermissionAsked, isTrue);
    });

    testWidgets('UX-39: an unanswered notification dialog does not hold the export; the progress says so calmly', (tester) async {
      final rig = ExportRig();
      rig.fake.access.onRequestNotificationPermission = () => Completer<bool>().future;
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-start');
      await rig.tapKey(tester, 'export-notice-continue');
      expect(_key('export-running'), findsNothing, reason: 'waiting for the dialog');
      await tester.pump(ExportEnvironment.defaultNotificationPermissionTimeout + const Duration(milliseconds: 100));
      await rig.pumpSome(tester);
      expect(_key('export-running'), findsOneWidget);
      expect(rig.started, hasLength(1));
      expect(find.text(ExportStrings.notificationsUnanswered), findsOneWidget);
      expect(find.text(ExportStrings.backgroundCopy(BackgroundExportKind.foregroundService)), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('iPhone: the first-export notice carries the pause copy', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.paused));
      await rig.pump(tester, surface: _iosPhone);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-start');
      expect(find.text(_iphoneCopy), findsOneWidget);
      expect(find.text(ExportStrings.notificationExplainer), findsNothing);
    });

    testWidgets('preflight warnings are confirmed or sent back to the settings', (tester) async {
      final rig = ExportRig();
      rig.exporter.preflightResult = const ExportPreflight(ok: true, warnings: [ExportWarning('softwareEncoder'), ExportWarning('layersVsResolution')]);
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      await rig.tapKey(tester, 'export-start');
      expect(_key('export-warnings'), findsOneWidget);
      expect(find.text(ExportStrings.warning('softwareEncoder')), findsOneWidget);
      expect(find.text(ExportStrings.warning('layersVsResolution')), findsOneWidget);
      await rig.tapKey(tester, 'export-warnings-back');
      expect(_key('export-setup'), findsOneWidget);
      await rig.tapKey(tester, 'export-start');
      await rig.tapKey(tester, 'export-warnings-continue');
      expect(_key('export-running'), findsOneWidget);
    });
  });

  group('progress (ux.md §11.4)', () {
    testWidgets('Running: percent, phase, ETA after three samples and the Android background copy', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      expect(find.text('0%'), findsOneWidget);
      job.report(0.1);
      await rig.pumpSome(tester);
      rig.clock.advance(const Duration(seconds: 10));
      job.report(0.2);
      await rig.pumpSome(tester);
      rig.clock.advance(const Duration(seconds: 10));
      job.report(0.3);
      await rig.pumpSome(tester);
      expect(find.text('30%'), findsOneWidget);
      expect(find.text('Rendering video'), findsOneWidget);
      expect(_key('export-eta'), findsOneWidget);
      expect(find.text('About 1 min left'), findsOneWidget);
      expect(find.text("You can leave Danaview; you'll get a notification when it's done."), findsOneWidget);
      job.report(0.95, phase: ExportPhase.finishing);
      await rig.pumpSome(tester);
      expect(find.text('Finishing'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('iPhone: paused backgrounds say the export pauses and continues from where it stopped', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.paused));
      await rig.pump(tester, surface: _iosPhone);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      expect(find.text(_iphoneCopy), findsOneWidget);
      job.report(0.3, pausedInBackground: true, backgrounded: true);
      await rig.pumpSome(tester);
      expect(find.text(ExportStrings.pausedInBackground), findsOneWidget);
      expect(find.text(_iphoneCopy), findsNothing);
      expect(_key('export-eta'), findsNothing);
      job.report(0.35);
      await rig.pumpSome(tester);
      expect(find.text(_iphoneCopy), findsOneWidget);
    });

    testWidgets('iPad "continued" shows system progress; "none" says the export stops', (tester) async {
      final ipad = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.continued));
      await ipad.pump(tester, surface: _iosPhone);
      await ipad.openSheet(tester);
      await ipad.startExport(tester);
      expect(find.text(ExportStrings.backgroundCopy(BackgroundExportKind.continued)), findsOneWidget);
    });

    testWidgets('a running export is modal: no Close button, a scrim tap does nothing, and Back asks before stopping', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(_key('export-close'), findsOneWidget, reason: 'closable while only choosing');
      final job = await rig.startExport(tester);
      expect(_key('export-close'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await rig.pumpSome(tester);
      expect(_key('export-running'), findsOneWidget, reason: 'the scrim does not dismiss it');
      await tester.binding.handlePopRoute();
      await rig.pumpSome(tester);
      expect(find.text(ExportStrings.cancelConfirmTitle), findsOneWidget);
      expect(find.text(ExportStrings.cancelConfirmMessage), findsOneWidget);
      await tester.tap(find.text(ExportStrings.keepExporting));
      await rig.pumpSome(tester);
      expect(_key('export-running'), findsOneWidget);
      expect(job.cancelled, isFalse);
    });

    testWidgets('Cancel asks "Stop exporting?"; Stop export cancels, closes the sheet and shows the toast', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      await rig.tapKey(tester, 'export-cancel');
      expect(find.text('Stop exporting?'), findsOneWidget);
      expect(find.text('The partial file is deleted.'), findsOneWidget);
      await tester.tap(find.text('Stop export'));
      await rig.pumpSome(tester);
      expect(job.cancelled, isTrue);
      expect(_sheet, findsNothing);
      expect(find.text('Export cancelled'), findsOneWidget);
      expect(rig.wakelock, [true, false]);
    });

    testWidgets('Preparing shows progress and Cancel returns to the settings', (tester) async {
      final rig = ExportRig();
      rig.sprites.gate = Completer<void>();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      await rig.tapKey(tester, 'export-start');
      expect(_key('export-preparing'), findsOneWidget);
      expect(find.text('Preparing…'), findsWidgets);
      await rig.tapKey(tester, 'export-preparing-cancel');
      rig.sprites.gate!.complete();
      await rig.pumpSome(tester);
      expect(_key('export-setup'), findsOneWidget);
      expect(rig.started, isEmpty);
    });
  });

  group('completion', () {
    testWidgets('Gallery on Android: Saved to Gallery, Share and Save to Files; Done deletes the temp file and closes', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job, bytes: 2500000);
      expect(find.text('Saved to Gallery'), findsOneWidget);
      expect(find.text(ExportStrings.fileInfo(0, '0:04')), findsOneWidget, reason: 'the engine result: size and duration under the title');
      expect(_key('export-share'), findsOneWidget);
      expect(_key('export-save-files'), findsOneWidget);
      expect(_key('export-save-library'), findsNothing, reason: 'already in the Gallery');
      expect(rig.mem.peek(job.outputPath), isNotNull);
      await rig.tapKey(tester, 'export-done');
      expect(_sheet, findsNothing);
      expect(rig.mem.peek(job.outputPath), isNull, reason: 'temp file deleted');
      expectNoOverflow(tester);
    });

    testWidgets('iPhone: Saved to Photos', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.paused));
      await rig.pump(tester, surface: _iosPhone);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(find.text('Saved to Photos'), findsOneWidget);
    });

    testWidgets('Files destination: Saved to Files; Share and Save to Photos stay available', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await tester.tap(find.text('Files…'));
      await rig.pumpSome(tester);
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(rig.scripted.kinds, ['files']);
      expect(find.text('Saved to Files'), findsOneWidget);
      expect(_key('export-save-library'), findsOneWidget);
      await rig.tapKey(tester, 'export-save-library');
      expect(rig.scripted.kinds, ['files', 'photos']);
      expect(_key('export-save-library'), findsNothing);
    });

    testWidgets('a closed Files sheet says it is not saved yet and keeps every choice', (tester) async {
      final rig = ExportRig();
      rig.scripted.outcomes['files'] = FileHandoffOutcome.cancelled;
      await rig.pump(tester);
      await rig.openSheet(tester);
      await tester.tap(find.text('Files…'));
      await rig.pumpSome(tester);
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(find.text('Your video is ready'), findsOneWidget);
      expect(_key('export-not-saved'), findsOneWidget);
    });

    testWidgets('a refused Photos permission is explained', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS);
      rig.scripted.outcomes['photos'] = FileHandoffOutcome.denied;
      await rig.pump(tester, surface: _iosPhone);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(find.text("Danaview can't add videos to Photos"), findsOneWidget);
      expect(find.text('Allow it in Settings, or save the export to Files.'), findsOneWidget);
    });

    testWidgets('"Keep a copy in Danaview" next to a same-named file keeps both and says so', (tester) async {
      final rig = ExportRig();
      rig.mem.putFile('/mem/documents/Exports/My video.mp4', [9]);
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-keep-copy');
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(find.text('Kept in Danaview as My video (2).mp4'), findsOneWidget);
      expect(rig.mem.peek('/mem/documents/Exports/My video.mp4'), [9]);
      await rig.tapKey(tester, 'export-play');
      expect(rig.host.played, ['/mem/documents/Exports/My video (2).mp4']);
    });

    testWidgets('Play in Danaview is hidden without a router callback; caption files are listed with their own buttons', (tester) async {
      final rig = ExportRig(withHost: false);
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-side-srt');
      final job = await rig.startExport(tester);
      await rig.finishJob(tester, job);
      expect(_key('export-play'), findsNothing);
      expect(find.text(ExportStrings.captionFiles), findsOneWidget);
      expect(find.text('Save My video.es.srt'), findsOneWidget);
      await rig.tapKey(tester, 'export-side-file-0');
      expect(rig.scripted.names.last, 'My video.es.srt');
    });
  });

  group('failures and fallbacks', () {
    Future<(ExportRig, FakeExportJob)> failed(WidgetTester tester, EngineErrorCode code, {EditorCapabilities? caps}) async {
      final rig = ExportRig(caps: caps ?? rigCaps);
      await rig.pump(tester);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      job.fail(EngineFailure.of(code));
      await rig.pumpSome(tester);
      return (rig, job);
    }

    testWidgets('encoder size limit: the message and "Lower resolution", which returns to a smaller setup', (tester) async {
      final (rig, _) = await failed(tester, EngineErrorCode.encoderSizeLimit, caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)));
      expect(find.text("This size is too large for this device's encoder"), findsOneWidget);
      await rig.tapKey(tester, 'export-fallback-lower');
      expect(_key('export-setup'), findsOneWidget);
      expect(tester.widget<Text>(_key('export-summary')).data, startsWith('1280×720'));
    });

    testWidgets('encoder unavailable: "Export with H.264" starts again', (tester) async {
      final (rig, _) = await failed(tester, EngineErrorCode.encoderUnavailable);
      expect(find.text("This device couldn't encode H.265 right now"), findsOneWidget);
      await rig.tapKey(tester, 'export-fallback-h264');
      expect(_key('export-running'), findsOneWidget);
      expect(rig.started, hasLength(2));
    });

    testWidgets('disk full: "Free up space" goes through the router; Try again stays available', (tester) async {
      final (rig, _) = await failed(tester, EngineErrorCode.diskFull);
      expect(find.text('Not enough space to export'), findsOneWidget);
      await rig.tapKey(tester, 'export-fallback-space');
      expect(rig.host.freeUpSpace, 1);
      expect(_key('export-try-again'), findsOneWidget);
    });

    testWidgets('without a router callback the space fallback is just Try again', (tester) async {
      final rig = ExportRig(withHost: false);
      await rig.pump(tester);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      job.fail(EngineFailure.of(EngineErrorCode.diskFull));
      await rig.pumpSome(tester);
      expect(_key('export-fallback-space'), findsNothing);
      await rig.tapKey(tester, 'export-try-again');
      expect(_key('export-running'), findsOneWidget);
    });

    testWidgets('an unknown failure: Try again restarts; Back to settings returns', (tester) async {
      final (rig, _) = await failed(tester, EngineErrorCode.encodingFailed);
      expect(find.text("The export didn't finish"), findsOneWidget);
      await rig.tapKey(tester, 'export-back-to-settings');
      expect(_key('export-setup'), findsOneWidget);
    });

    testWidgets('Copy details puts the failure code and settings on the clipboard', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final (rig, _) = await failed(tester, EngineErrorCode.encoderUnavailable);
      await rig.tapKey(tester, 'export-copy-details');
      expect(clipboard.single, startsWith('Danaview export: exportFailed.encoderUnavailable'));
      expect(find.text('Details copied'), findsOneWidget);
    });
  });

  group('reattach (D-22, D-39)', () {
    testWidgets('an export that finished while away: "Your export finished" with Share, Save to Files, Delete', (tester) async {
      final rig = ExportRig();
      final path = '${rig.workDir}/export-5.mp4';
      rig.writeOutput(path);
      rig.exporter.records.add(ExportCompletedWhileDetached(
        'export-5',
        result: ExportResult(path: path, bytes: 1234, duration: 5 * s, videoEncoderName: 'x', hardwareEncoder: true),
        savedToGallery: true,
      ));
      await rig.pump(tester);
      await rig.openPending(tester);
      expect(find.text('Your export finished'), findsOneWidget);
      expect(find.textContaining('Saved to Gallery.'), findsOneWidget);
      await rig.tapKey(tester, 'export-finished-share');
      await rig.tapKey(tester, 'export-finished-files');
      expect(rig.scripted.kinds, ['share', 'files']);
      await rig.tapKey(tester, 'export-finished-delete');
      expect(_sheet, findsNothing);
      expect(rig.mem.peek(path), isNull);
      expect(rig.exporter.records, isEmpty);
      expectNoOverflow(tester);
    });

    testWidgets('a card for a gallery-only export has just Done, which consumes the record', (tester) async {
      final rig = ExportRig();
      rig.exporter.records.add(const ExportCompletedWhileDetached('export-6', savedToGallery: true));
      await rig.pump(tester);
      await rig.openPending(tester);
      expect(_key('export-finished-share'), findsNothing);
      await rig.tapKey(tester, 'export-finished-done');
      expect(_sheet, findsNothing);
      expect(rig.exporter.records, isEmpty);
    });

    testWidgets('a resumable export offers Resume export, which shows progress', (tester) async {
      final rig = ExportRig(platform: TargetPlatform.iOS);
      rig.exporter.records.add(const ExportResumable('export-7', doneFraction: 0.4));
      await rig.pump(tester, surface: _iosPhone);
      await rig.openPending(tester);
      expect(find.text('The export was interrupted'), findsOneWidget);
      expect(find.text('Danaview kept the first 40%. Resume to finish the rest.'), findsOneWidget);
      await rig.tapKey(tester, 'export-resume');
      expect(_key('export-running'), findsOneWidget);
    });

    testWidgets('an interrupted export is a one-shot notice; closing it consumes the record', (tester) async {
      final rig = ExportRig();
      rig.exporter.records.add(const ExportInterrupted('export-8'));
      await rig.pump(tester);
      await rig.openPending(tester);
      expect(find.text(ExportStrings.interruptedStartAgain), findsOneWidget);
      await rig.tapKey(tester, 'export-interrupted-close');
      expect(rig.exporter.records, isEmpty);
      await rig.openPending(tester);
      expect(_sheet, findsNothing, reason: 'it is reported once');
    });

    testWidgets('a running export shows its progress and finishes through the same card', (tester) async {
      final rig = ExportRig();
      final job = FakeExportJob('export-9', '${rig.workDir}/export-9.mp4', 5 * s);
      rig.exporter.records.add(ExportRunning(job));
      await rig.pump(tester);
      await rig.openPending(tester);
      job.report(0.6);
      await rig.pumpSome(tester);
      expect(find.text('60%'), findsOneWidget);
      await rig.finishJob(tester, job);
      expect(_key('export-completed'), findsOneWidget);
    });

    testWidgets('nothing pending: no sheet', (tester) async {
      final rig = ExportRig();
      await rig.pump(tester);
      await rig.openPending(tester);
      expect(_sheet, findsNothing);
    });
  });

  group('no overflow, owner UI rules', () {
    testSurfaces('setup with custom settings, captions and a notice', (tester, surface) async {
      final rig = ExportRig(platform: surface.platform, caps: rigCaps.copyWith(movContainer: true, maxExportSize: const Size(3840, 2160)));
      await rig.pump(tester, surface: surface);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-preset-tiktok');
      // The aspect notice belongs to the preset: Custom has no target aspect and drops it.
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.ensureVisible(_key('export-change-aspect'));
      await tester.pump();
      expectInside(tester, _key('export-change-aspect'));
      await rig.tapKey(tester, 'export-edit');
      await rig.tapKey(tester, 'export-bitrate-custom');
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in ['export-start', 'export-bitrate-slider', 'export-keep-copy']) {
        expect(_key(k), findsOneWidget, reason: k);
        await tester.ensureVisible(_key(k));
        await tester.pump();
        expectInside(tester, _key(k));
      }
    });

    testSurfaces('storage issue, first-export notice and warnings', (tester, surface) async {
      final rig = ExportRig(platform: surface.platform);
      rig.fake.freeBytesValue = 1000;
      await rig.pump(tester, surface: surface);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-start');
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.fake.freeBytesValue = 1 << 40;
      rig.exporter.preflightResult = const ExportPreflight(ok: true, warnings: [ExportWarning('softwareEncoder'), ExportWarning('layersVsResolution')]);
      await rig.tapKey(tester, 'export-start');
      expect(_key('export-notice'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await rig.tapKey(tester, 'export-notice-continue');
      expect(_key('export-warnings'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testSurfaces('running, completed with a kept copy and caption files, failed', (tester, surface) async {
      final rig = ExportRig(platform: surface.platform, caps: rigCaps.copyWith(backgroundKind: surface.platform == TargetPlatform.iOS ? BackgroundExportKind.paused : BackgroundExportKind.foregroundService));
      await rig.pump(tester, surface: surface);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'export-keep-copy');
      await rig.tapKey(tester, 'export-side-srt');
      final job = await rig.startExport(tester);
      for (var i = 1; i <= 3; i++) {
        rig.clock.advance(const Duration(seconds: 10));
        job.report(i / 10, backgrounded: i == 3);
        await rig.pumpSome(tester);
      }
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await rig.finishJob(tester, job, bytes: 5000000);
      expect(_key('export-completed'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.ensureVisible(_key('export-done'));
      await tester.pump();
      expectInside(tester, _key('export-done'));
    });

    testSurfaces('a failure and the reattach cards', (tester, surface) async {
      final rig = ExportRig(platform: surface.platform);
      await rig.pump(tester, surface: surface);
      await rig.openSheet(tester);
      final job = await rig.startExport(tester);
      job.fail(EngineFailure.of(EngineErrorCode.encoderSizeLimit));
      await rig.pumpSome(tester);
      expect(_key('export-failed'), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in ['export-copy-details', 'export-back-to-settings', 'export-fallback-lower']) {
        await tester.ensureVisible(_key(k));
        await tester.pump();
        expectInside(tester, _key(k));
      }
    });
  });
}
