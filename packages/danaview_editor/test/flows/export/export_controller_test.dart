// OWNER: UX-39
//
// ExportController (ARCH §14.1, ux.md §11): the pre-checks in order, presets and capability gating,
// the remembered settings, storage and first-export notice, sprite pre-pass, compile and preflight,
// progress and ETA, cancel, completion and handoff (Photos, Files, Share), "Keep a copy" through
// DocumentsExportWriter, side files, failures and their fallbacks, reattach, and cleanup.

import 'dart:async';

import 'package:flutter/painting.dart' show Size;
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import 'export_rig.dart';

/// Runs until [done] or fails: lets the fakes' microtasks run.
Future<T> _until<T extends ExportUiState>(ExportRig rig, ExportController c, {int turns = 40}) async {
  for (var i = 0; i < turns; i++) {
    if (c.state is T) return c.state as T;
    await rig.settle(1);
  }
  fail('expected ${T.toString()}, state is ${c.state.runtimeType}');
}

Future<ExportController> _ready(ExportRig rig) async {
  final container = rig.container();
  await rig.openEditor(container);
  final c = rig.controllerIn(container);
  final r = await c.prepare();
  expect(r, ExportPrepare.ready, reason: 'state ${c.state.runtimeType}');
  return c;
}

/// Starts and runs to the first running job.
Future<FakeExportJob> _run(ExportRig rig, ExportController c) async {
  await c.start();
  await _until<ExportUiRunning>(rig, c);
  return rig.started.last;
}

void main() {
  group('pre-checks (ux.md §11.1)', () {
    test('an empty timeline is reported and the sheet does not open', () async {
      final rig = ExportRig(project: (repo) => exportProject(repo, empty: true));
      final container = rig.container();
      await rig.openEditor(container);
      final c = rig.controllerIn(container);
      expect(await c.prepare(), ExportPrepare.emptyTimeline);
      expect(c.state, isA<ExportUiIdle>());
    });

    test('missing media asks to relink and counts the files', () async {
      final rig = ExportRig();
      rig.offline.add(const MediaId('md_a'));
      final container = rig.container();
      await rig.openEditor(container);
      final c = rig.controllerIn(container);
      expect(await c.prepare(), ExportPrepare.needsRelink);
      expect((c.state as ExportUiNeedsRelink).count, 1);
    });

    test('media the editor knows is missing blocks the export even if the plan resolves it', () async {
      final rig = ExportRig();
      final container = rig.container();
      final editor = await rig.openEditor(container);
      editor.setMediaHealth(MediaHealth(missing: {const MediaId('md_a'), const MediaId('md_x')}, relinkRequired: true));
      final c = rig.controllerIn(container);
      expect(await c.prepare(), ExportPrepare.needsRelink);
      expect((c.state as ExportUiNeedsRelink).count, 2);
    });

    test('pending reverse and freeze jobs wait with progress and continue by themselves', () async {
      final rig = ExportRig();
      rig.blockWith = PlanRequirements(pendingReverse: const ['it_1'], pendingStill: const ['md_s']);
      final container = rig.container();
      final editor = await rig.openEditor(container);
      final c = rig.controllerIn(container);
      expect(await c.prepare(), ExportPrepare.waiting);
      expect((c.state as ExportUiWaiting).count, 2);

      editor.setTasks(const [EditorTaskInfo(id: 'j1', kind: EditorTaskKind.reverse, label: 'Reversing a clip', progress: 0.25)]);
      await rig.settle();
      expect((c.state as ExportUiWaiting).progress, 0.25);

      rig.blockWith = PlanRequirements(pendingReverse: const ['it_1']);
      editor.setTasks(const [EditorTaskInfo(id: 'j1', kind: EditorTaskKind.reverse, label: 'Reversing a clip', progress: 0.5)]);
      await rig.settle();
      expect((c.state as ExportUiWaiting).count, 1);

      rig.blockWith = null;
      editor.setTasks(const []);
      await _until<ExportUiSetup>(rig, c);
    });

    test('a project that is not open fails cleanly', () async {
      final rig = ExportRig();
      final container = rig.container();
      final c = rig.controllerIn(container);
      expect(await c.prepare(), ExportPrepare.failed);
      expect((c.state as ExportUiFailed).failure, isA<UnknownFailure>());
    });
  });

  group('presets and settings (ARCH §14.1 table)', () {
    ({int w, int h, int fps, VideoCodec codec, int video, int audio}) enc(ExportController c) {
      final e = (c.state as ExportUiSetup).resolved.encode;
      return (w: e.width, h: e.height, fps: e.fps, codec: e.codec, video: e.videoBitrate, audio: e.audioBitrate);
    }

    test('every preset resolves to its row of the table for a 16:9 30 fps project', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      var e = enc(c);
      expect((e.w, e.h, e.fps, e.codec, e.video, e.audio), (1920, 1080, 30, VideoCodec.h264, 8000000, 192000));
      c.selectPreset(ExportPresetId.youtubeShorts);
      e = enc(c);
      expect((e.w, e.h, e.fps, e.video, e.audio), (1080, 1920, 30, 8000000, 192000));
      c.selectPreset(ExportPresetId.instagramReels);
      e = enc(c);
      expect((e.w, e.h, e.fps, e.video, e.audio), (1080, 1920, 30, 8000000, 128000));
      c.selectPreset(ExportPresetId.instagramFeed);
      e = enc(c);
      expect((e.w, e.h, e.fps, e.video, e.audio), (1080, 1350, 30, 6000000, 128000));
      c.selectPreset(ExportPresetId.tiktok);
      e = enc(c);
      expect((e.w, e.h, e.fps, e.video, e.audio), (1080, 1920, 30, 8000000, 128000));
    });

    test('YouTube 4K is offered only when the device and the source reach 2160p', () async {
      final low = await _ready(ExportRig());
      expect((low.state as ExportUiSetup).limits.offer4kPreset, isFalse);

      final deviceOnly = await _ready(ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160))));
      expect((deviceOnly.state as ExportUiSetup).limits.offer4kPreset, isFalse, reason: 'the source is 1080p');

      final both = ExportRig(project: (repo) => exportProject(repo, video4k: true), caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)));
      final c = await _ready(both);
      expect((c.state as ExportUiSetup).limits.offer4kPreset, isTrue);
      c.selectPreset(ExportPresetId.youtube4k);
      final e = (c.state as ExportUiSetup).resolved.encode;
      expect((e.width, e.height, e.codec), (3840, 2160, VideoCodec.hevc));
      expect(e.audioBitrate, 256000);
    });

    test('Custom starts from what the preset resolved to and its lists follow the capabilities', () async {
      final c = await _ready(ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160), hevcEncode: true, movContainer: true)));
      c.selectPreset(ExportPresetId.custom);
      final s = c.state as ExportUiSetup;
      expect(s.draft.settings.shortSide, 1080);
      expect(s.draft.settings.fps, isNull, reason: 'Match project is the default');
      expect(s.limits.shortSides, [720, 1080, 1440, 2160]);
      expect(s.limits.fpsOptions(1080), [24, 25, 30, 48, 50, 60], reason: 'Custom fps list includes 48');
      expect(s.limits.fpsOptions(2160), [24, 25, 30], reason: 'maxFpsByHeight caps 4K at 30');
      expect(s.limits.canHevc, isTrue);
      expect(s.limits.canMov, isTrue);

      final low = await _ready(ExportRig(caps: rigCaps.copyWith(hevcEncode: false)));
      (low.state as ExportUiSetup);
      expect((low.state as ExportUiSetup).limits.canHevc, isFalse);
      expect((low.state as ExportUiSetup).limits.canMov, isFalse);
      expect((low.state as ExportUiSetup).limits.shortSides, [720, 1080]);
    });

    test('choosing a smaller resolution drops a frame rate the new size cannot do', () async {
      final c = await _ready(ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160))));
      c.selectPreset(ExportPresetId.custom);
      c.updateSettings((s) => s.copyWith(fps: 60));
      expect((c.state as ExportUiSetup).draft.settings.fps, 60);
      c.updateSettings((s) => s.copyWith(shortSide: 2160));
      expect((c.state as ExportUiSetup).draft.settings.fps, isNull);
    });

    test('custom values change the encode settings and the estimate', () async {
      final c = await _ready(ExportRig(caps: rigCaps.copyWith(movContainer: true)));
      c.selectPreset(ExportPresetId.custom);
      final before = (c.state as ExportUiSetup).resolved.estimatedBytes;
      c.updateSettings((s) => s.copyWith(
            container: ExportContainer.mov,
            codec: VideoCodec.hevc,
            fps: 48,
            quality: ExportQuality.high,
            videoBitrateMbps: 20.0,
            audioBitrateKbps: 256,
          ));
      final e = (c.state as ExportUiSetup).resolved.encode;
      expect((e.container, e.codec, e.fps, e.videoBitrate, e.audioBitrate), (ExportContainer.mov, VideoCodec.hevc, 48, 20000000, 256000));
      expect((c.state as ExportUiSetup).resolved.estimatedBytes, greaterThan(before));
    });

    test('an aspect mismatch is a notice that names the project and output ratio; nothing is cropped', () async {
      final c = await _ready(ExportRig());
      c.selectPreset(ExportPresetId.tiktok);
      final s = c.state as ExportUiSetup;
      final notice = s.resolved.notices.singleWhere((n) => n.code == ExportNoticeCode.aspectMismatch);
      expect(notice.suggestedAspect, AspectRatio.portrait9x16);
      expect(s.projectAspect, AspectRatio.landscape16x9);
    });

    test('captions: burn-in follows the track default, per-track switches and side files are kept in the settings', () async {
      final c = await _ready(ExportRig());
      final s = c.state as ExportUiSetup;
      expect(s.subtitleTracks.single.name, 'Captions (Spanish)');
      expect(s.subtitleTracks.single.language, 'es');
      expect(s.subtitleTracks.single.cueCount, 2);
      expect(s.subtitleTracks.single.burnIn, isTrue);
      final track = s.subtitleTracks.single.id;
      c.setBurnIn(track, false);
      expect((c.state as ExportUiSetup).subtitleTracks.single.burnIn, isFalse);
      expect((c.state as ExportUiSetup).draft.settings.burnInSubtitles[track], isFalse);
      c.setSideFile(SideFileFormat.srt, true);
      c.setSideFile(SideFileFormat.vtt, true);
      c.setSideFile(SideFileFormat.vtt, false);
      expect((c.state as ExportUiSetup).draft.settings.sideFiles, {SideFileFormat.srt});
    });

    test('the last-used settings are remembered per project', () async {
      final rig = ExportRig();
      final first = await _ready(rig);
      first.selectPreset(ExportPresetId.custom);
      first.updateSettings((s) => s.copyWith(fps: 25, quality: ExportQuality.maximum));
      first.setDestination(ExportDestination.files);
      first.setKeepCopy(true);
      final stored = rig.harness.prefs.readString(ExportController.draftKey(rig.id));
      expect(stored, isNotNull);

      final again = ExportRig(overrides: const []);
      // A new session on the same prefs: copy the stored value to the other rig's prefs.
      await again.harness.prefs.writeString(ExportController.draftKey(again.id), stored);
      final c = await _ready(again);
      final s = c.state as ExportUiSetup;
      expect(s.draft.settings.preset, ExportPresetId.custom);
      expect(s.draft.settings.fps, 25);
      expect(s.draft.settings.quality, ExportQuality.maximum);
      expect(s.draft.destination, ExportDestination.files);
      expect(s.draft.keepCopy, isTrue);
    });

    test('remembered settings the device cannot do fall back to what it offers', () async {
      final rig = ExportRig(caps: rigCaps.copyWith(hevcEncode: false));
      await rig.harness.prefs.writeString(
        ExportController.draftKey(rig.id),
        ExportDraft(settings: ExportSettings(preset: ExportPresetId.youtube4k, codec: VideoCodec.hevc, container: ExportContainer.mov, shortSide: 2160)).toJsonString(),
      );
      final c = await _ready(rig);
      final s = c.state as ExportUiSetup;
      expect(s.draft.settings.preset, ExportPresetId.youtube);
      expect(s.draft.settings.codec, VideoCodec.h264);
      expect(s.draft.settings.container, ExportContainer.mp4);
      expect(s.draft.settings.shortSide, 1080);
    });

    test('a malformed remembered value is ignored', () async {
      final rig = ExportRig();
      await rig.harness.prefs.writeString(ExportController.draftKey(rig.id), '{not json');
      final c = await _ready(rig);
      expect((c.state as ExportUiSetup).draft.settings.preset, ExportPresetId.youtube);
    });
  });

  group('starting an export', () {
    test('not enough free space blocks the start and says how much is needed (ux.md §11.1 check 4)', () async {
      final rig = ExportRig();
      rig.fake.freeBytesValue = 1000;
      final c = await _ready(rig);
      await c.start();
      final s = c.state as ExportUiSetup;
      expect(s.issue!.kind, ExportIssueKind.lowStorage);
      expect(s.issue!.freeBytes, 1000);
      expect(s.issue!.neededBytes, s.resolved.estimatedBytes);
      expect(rig.started, isEmpty);
    });

    test('iOS adds one 10 s segment to the space it needs (ARCH §14.1 step 1)', () async {
      final ios = ExportRig(platform: TargetPlatform.iOS);
      ios.fake.freeBytesValue = 1000;
      final c = await _ready(ios);
      await c.start();
      final s = c.state as ExportUiSetup;
      expect(s.issue!.neededBytes, s.resolved.estimatedBytes + (s.resolved.encode.videoBitrate * 10 / 8).round());
    });

    test('lowering the resolution from the storage notice picks the next smaller size', () async {
      final rig = ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)));
      rig.fake.freeBytesValue = 1000;
      final c = await _ready(rig);
      await c.start();
      c.lowerResolution();
      final s = c.state as ExportUiSetup;
      expect(s.draft.settings.preset, ExportPresetId.custom);
      expect(s.draft.settings.shortSide, 720);
      expect(s.issue, isNull);
    });

    test('the first export shows the background notice; Android explains notifications and asks in context', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      await c.start();
      final notice = c.state as ExportUiNotice;
      expect(notice.kind, BackgroundExportKind.foregroundService);
      expect(notice.explainNotifications, isTrue);
      expect(rig.started, isEmpty);

      await c.confirmNotice();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.harness.prefs.exportBackgroundNoticeShown, isTrue);
      expect(rig.harness.prefs.exportNotificationPermissionAsked, isTrue);
      expect(rig.started, hasLength(1));
    });

    test('the notice is shown only once', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      await c.start();
      await c.confirmNotice();
      await _until<ExportUiRunning>(rig, c);
      rig.started.single.report(0.1);
      await c.cancel();
      await rig.settle();
      await c.prepare();
      await c.start();
      await _until<ExportUiRunning>(rig, c);
    });

    test('iPhone gets the notice without notification talk; iPad "continued" gets none', () async {
      final iphone = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.paused));
      final a = await _ready(iphone);
      await a.start();
      final notice = a.state as ExportUiNotice;
      expect(notice.kind, BackgroundExportKind.paused);
      expect(notice.explainNotifications, isFalse);

      final ipad = ExportRig(platform: TargetPlatform.iOS, caps: rigCaps.copyWith(backgroundKind: BackgroundExportKind.continued));
      final b = await _ready(ipad);
      await b.start();
      await _until<ExportUiRunning>(ipad, b);
    });

    test('Back from the notice returns to the setup', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      await c.start();
      c.backToSetup();
      expect(c.state, isA<ExportUiSetup>());
    });

    Future<ExportController> readyNoNotice(ExportRig rig) async {
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      return _ready(rig);
    }

    test('text and burned captions go through the sprite pre-pass and into the plan; the same list reaches compileExport', () async {
      final rig = ExportRig();
      final c = await readyNoNotice(rig);
      await c.start();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.sprites.runs, hasLength(1));
      final kinds = rig.sprites.runs.single;
      expect(kinds.length, greaterThanOrEqualTo(3), reason: 'one text item and two cues');
      final (input, result) = rig.compiles.last;
      expect(input.spriteRequests, same(kinds), reason: 'compileExport gets the list the pre-pass used');
      expect(input.manifest.files.keys.toSet(), {for (final r in kinds) r.key});
      final ready = result as ExportReady;
      expect(ready.plan.target, PlanTarget.export);
      expect((ready.plan.canvas.w, ready.plan.canvas.h), (1920, 1080));
      expect(ready.plan.assets.keys.where((k) => k.startsWith('sp_')), isNotEmpty, reason: 'sprite assets are in the plan');
      expect(ready.plan.assets.values.every((a) => a.proxyUri == null), isTrue, reason: 'export plans never carry proxies');
    });

    test('Preparing reports pre-pass progress and Cancel returns to the setup without starting', () async {
      final rig = ExportRig();
      rig.sprites.gate = Completer<void>();
      final c = await readyNoNotice(rig);
      final starting = c.start();
      await rig.settle();
      expect(c.state, isA<ExportUiPreparing>());
      expect((c.state as ExportUiPreparing).fraction, 0.5);
      await c.cancel();
      expect((c.state as ExportUiPreparing).cancelling, isTrue);
      rig.sprites.gate!.complete();
      await starting;
      await rig.settle();
      expect(c.state, isA<ExportUiSetup>());
      expect(rig.started, isEmpty);
    });

    test('the output is an export-<token> file in the work folder; the engine gets the resolved settings and the destination hand-off', () async {
      final rig = ExportRig();
      final c = await readyNoNotice(rig);
      final job = await _run(rig, c);
      expect(job.outputPath, '${rig.workDir}/export-t0.mp4');
      expect(rig.exporter.lastWhenDetached, ExportDetachedHandoff.saveToGallery);
      expect(rig.wakelock, [true], reason: 'the screen stays awake while it runs');
    });

    test('Files and Share keep the finished file for later when no listener is attached (D-39)', () async {
      final rig = ExportRig();
      final c = await readyNoNotice(rig);
      c.setDestination(ExportDestination.files);
      await _run(rig, c);
      expect(rig.exporter.lastWhenDetached, ExportDetachedHandoff.keepForLater);
    });

    test('preflight warnings (software encoder) ask before starting; Export anyway starts; Change settings returns', () async {
      final rig = ExportRig();
      rig.exporter.preflightResult = const ExportPreflight(ok: true, warnings: [ExportWarning('softwareEncoder'), ExportWarning('backgroundPauses')]);
      final c = await readyNoNotice(rig);
      await c.start();
      final w = c.state as ExportUiWarnings;
      expect([for (final x in w.warnings) x.code], ['softwareEncoder']);
      expect(rig.started, isEmpty);
      c.backToSetup();
      expect(c.state, isA<ExportUiSetup>());
      await c.start();
      await c.confirmWarnings();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.started, hasLength(1));
    });

    test('a preflight refusal is an encoder size failure with the lower-resolution fallback', () async {
      final rig = ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)));
      rig.exporter.preflightResult = const ExportPreflight(ok: false, maxHeightForPlan: 1080);
      final c = await readyNoNotice(rig);
      c.selectPreset(ExportPresetId.custom);
      c.updateSettings((s) => s.copyWith(shortSide: 2160));
      await c.start();
      expect((c.state as ExportUiFailed).failure, const ExportFailed(ExportFailureKind.encoderSizeLimit));
      expect(rig.started, isEmpty);
      c.lowerResolution();
      expect((c.state as ExportUiSetup).draft.settings.shortSide, 1080, reason: 'the largest size the plan can encode');
    });

    test('media that goes offline between the check and the start sends the user to relink', () async {
      final rig = ExportRig();
      final c = await readyNoNotice(rig);
      rig.offline.add(const MediaId('md_a'));
      await c.start();
      expect(c.state, isA<ExportUiNeedsRelink>());
      expect(rig.started, isEmpty);
    });
  });

  group('progress', () {
    test('Running follows the engine: fraction, phase, frames and backgrounded flags', () async {
      final rig = ExportRig();
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      final job = await _run(rig, c);
      job.report(0.4, phase: ExportPhase.rendering, backgrounded: true);
      await rig.settle();
      var r = c.state as ExportUiRunning;
      expect((r.fraction, r.phase, r.backgrounded, r.pausedInBackground), (0.4, ExportPhase.rendering, true, false));
      expect(r.backgroundKind, BackgroundExportKind.foregroundService);
      job.report(0.95, phase: ExportPhase.finishing);
      await rig.settle();
      r = c.state as ExportUiRunning;
      expect(r.phase, ExportPhase.finishing);
    });

    test('the ETA appears after three samples and not while paused in the background', () async {
      final rig = ExportRig();
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      final job = await _run(rig, c);
      job.report(0.1);
      await rig.settle();
      rig.clock.advance(const Duration(seconds: 10));
      job.report(0.2);
      await rig.settle();
      expect((c.state as ExportUiRunning).eta, isNull, reason: 'two samples are not enough');
      rig.clock.advance(const Duration(seconds: 10));
      job.report(0.3);
      await rig.settle();
      final eta = (c.state as ExportUiRunning).eta!;
      expect(eta.inSeconds, inInclusiveRange(69, 71), reason: '0.7 left at 0.01 per second');
      job.report(0.31, pausedInBackground: true);
      await rig.settle();
      final paused = c.state as ExportUiRunning;
      expect(paused.pausedInBackground, isTrue);
      expect(paused.eta, isNull);
    });
  });

  group('cancel', () {
    test('Cancel stops the job, ends in Cancelled and releases the wakelock', () async {
      final rig = ExportRig();
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      final job = await _run(rig, c);
      final cancelling = c.cancel();
      expect(c.state, isA<ExportUiCancelling>());
      await cancelling;
      await _until<ExportUiCancelled>(rig, c);
      expect(job.cancelled, isTrue);
      expect(rig.wakelock, [true, false]);
    });

  });

  group('completion and handoff (ARCH §14.1 step 6)', () {
    Future<(ExportRig, ExportController, FakeExportJob)> running({
      TargetPlatform platform = TargetPlatform.android,
      List<SideFileFormat> sides = const [],
      bool keep = false,
      ExportDestination destination = ExportDestination.photos,
    }) async {
      final rig = ExportRig(platform: platform);
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      c.setDestination(destination);
      c.setKeepCopy(keep);
      for (final f in sides) {
        c.setSideFile(f, true);
      }
      final job = await _run(rig, c);
      return (rig, c, job);
    }

    test('Photos / Gallery is the default: saved, nothing else touched, the temp file stays until Done and is then deleted', () async {
      final (rig, c, job) = await running();
      await rig.finish(job);
      final done = c.state as ExportUiCompleted;
      expect(done.handoff, ExportHandoffStatus.saved);
      expect(done.savedToLibrary, isTrue);
      expect(rig.scripted.kinds, ['photos']);
      expect(done.fileName, 'My video.mp4');
      expect(done.busy, isFalse);
      expect(rig.wakelock, [true, false]);
      expect(rig.mem.peek(job.outputPath), isNotNull, reason: 'Share and Save to Files still need it');
      await c.done();
      expect(rig.mem.peek(job.outputPath), isNull, reason: 'temp file deleted by OwnedFileDeleter');
    });

    test('Files and Share hand the file to the system sheets; a closed sheet leaves it unsaved with the choices open', () async {
      var (rig, c, job) = await running(destination: ExportDestination.files);
      rig.scripted.outcomes['files'] = FileHandoffOutcome.cancelled;
      await rig.finish(job);
      var done = c.state as ExportUiCompleted;
      expect(done.handoff, ExportHandoffStatus.notSaved);
      expect(rig.scripted.names, ['My video.mp4']);
      rig.scripted.outcomes['files'] = FileHandoffOutcome.done;
      await c.saveToFiles();
      done = c.state as ExportUiCompleted;
      expect(done.handoff, ExportHandoffStatus.saved);
      expect(done.destination, ExportDestination.files);
      await c.share();
      await c.saveToLibrary();
      expect(rig.scripted.kinds, ['files', 'files', 'share', 'photos']);
      expect((c.state as ExportUiCompleted).savedToLibrary, isTrue);

      (rig, c, job) = await running(destination: ExportDestination.share);
      await rig.finish(job);
      expect(rig.scripted.kinds, ['share']);
      expect((c.state as ExportUiCompleted).handoff, ExportHandoffStatus.saved);
    });

    test('a refused Photos permission is explained and the other destinations stay open', () async {
      final (rig, c, job) = await running();
      rig.scripted.outcomes['photos'] = FileHandoffOutcome.denied;
      await rig.finish(job);
      final done = c.state as ExportUiCompleted;
      expect(done.handoff, ExportHandoffStatus.denied);
      expect(done.handoffFailure, const PermissionDenied(EditorPermission.photosAdd));
      expect(done.savedToLibrary, isFalse);
    });

    test('"Keep a copy" with a same-named file in Documents/Exports leaves it untouched and creates "<name> (2).mp4"', () async {
      final (rig, c, job) = await running(keep: true);
      rig.mem.putFile('/mem/documents/Exports/My video.mp4', [1, 2, 3]);
      await rig.finish(job, bytes: 777);
      final done = c.state as ExportUiCompleted;
      expect(done.keptCopyName, 'My video (2).mp4');
      expect(done.playablePath, '/mem/documents/Exports/My video (2).mp4');
      expect(rig.mem.peek('/mem/documents/Exports/My video.mp4'), [1, 2, 3], reason: 'the pre-existing file is untouched');
      expect(rig.mem.peek('/mem/documents/Exports/My video (2).mp4')!.length, 777);
      await c.done();
      expect(rig.mem.peek(job.outputPath), isNull, reason: 'the temp file is deleted');
      expect(rig.mem.peek('/mem/documents/Exports/My video (2).mp4'), isNotNull, reason: 'the kept copy stays');
    });

    test('"Keep a copy" without a conflict uses the plain name; a failure to copy never loses the export', () async {
      final (rig, c, job) = await running(keep: true);
      await rig.finish(job);
      expect((c.state as ExportUiCompleted).keptCopyName, 'My video.mp4');
      expect(rig.mem.peek('/mem/documents/Exports/My video.mp4'), isNotNull);

      final (rig2, c2, job2) = await running(keep: true);
      rig2.mem.mkdirs('/mem/documents/Exports');
      // The export file does not exist on disk: the copy fails, the hand-off still happened.
      job2.finish();
      await rig2.settle();
      final done = c2.state as ExportUiCompleted;
      expect(done.keepCopyFailed, isTrue);
      expect(done.keptCopyName, isNull);
      expect(done.handoff, ExportHandoffStatus.saved);
    });

    test('SRT and VTT side files are written next to the export, parse back to the same cues and can be kept and saved', () async {
      final (rig, c, job) = await running(sides: [SideFileFormat.srt, SideFileFormat.vtt], keep: true);
      await rig.finish(job);
      final done = c.state as ExportUiCompleted;
      expect(done.sideFiles.map((f) => f.name), ['My video.es.srt', 'My video.es.vtt']);
      for (final f in done.sideFiles) {
        final parsed = SubtitleCodec.parse(rig.mem.peek(f.path)!, hint: f.format == SideFileFormat.srt ? SubtitleFormat.srt : SubtitleFormat.vtt);
        expect(parsed.issues, isEmpty);
        expect([for (final cue in parsed.cues) cue.text], ['Cue 0', 'Cue 1']);
        expect([for (final cue in parsed.cues) cue.startUs], [0, 2 * s]);
        expect(rig.mem.peek('/mem/documents/Exports/${f.name}'), isNotNull, reason: 'kept next to the video copy');
      }
      await c.saveSideFile(0);
      expect(rig.scripted.names.last, 'My video.es.srt');
      expect((c.state as ExportUiCompleted).sideFiles.first.saved, isTrue);
      await c.done();
      for (final f in done.sideFiles) {
        expect(rig.mem.peek(f.path), isNull, reason: 'temporary caption files are deleted too');
      }
    });

    test('Play in Danaview is a router callback: the kept copy when there is one', () async {
      final (rig, c, job) = await running(keep: true);
      await rig.finish(job);
      await c.play();
      expect(rig.host.played, ['/mem/documents/Exports/My video.mp4']);
      final (rig2, c2, job2) = await running();
      await rig2.finish(job2);
      await c2.play();
      expect(rig2.host.played, [job2.outputPath]);
    });

    test('the temp file is deleted when the controller goes away without Done', () async {
      final (rig, c, job) = await running();
      await rig.finish(job);
      expect(rig.mem.peek(job.outputPath), isNotNull);
      rig.disposeContainers();
      await rig.settle();
      expect(rig.mem.peek(job.outputPath), isNull);
    });
  });

  group('failures and their fallbacks (ARCH §14.1, §19)', () {
    Future<(ExportRig, ExportController, FakeExportJob)> running() async {
      final rig = ExportRig();
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      c.selectPreset(ExportPresetId.custom);
      c.updateSettings((s) => s.copyWith(codec: VideoCodec.hevc));
      final job = await _run(rig, c);
      return (rig, c, job);
    }

    test('every engine failure maps to an ExportFailed kind; the wakelock is released', () async {
      final cases = {
        EngineErrorCode.encoderUnavailable: ExportFailureKind.encoderUnavailable,
        EngineErrorCode.encoderSizeLimit: ExportFailureKind.encoderSizeLimit,
        EngineErrorCode.diskFull: ExportFailureKind.diskFull,
        EngineErrorCode.interrupted: ExportFailureKind.interrupted,
        EngineErrorCode.permissionDenied: ExportFailureKind.destinationDenied,
        EngineErrorCode.encodingFailed: ExportFailureKind.unknown,
      };
      for (final e in cases.entries) {
        final (rig, c, job) = await running();
        job.fail(EngineFailure.of(e.key));
        await rig.settle();
        expect((c.state as ExportUiFailed).failure, ExportFailed(e.value), reason: e.key.name);
        expect(rig.wakelock, [true, false]);
      }
    });

    test('"Copy details" carries the failure code and the settings, never paths', () async {
      final (rig, c, job) = await running();
      job.fail(EngineFailure.of(EngineErrorCode.encoderUnavailable));
      await rig.settle();
      final details = (c.state as ExportUiFailed).details;
      expect(details, startsWith('Danaview export: exportFailed.encoderUnavailable'));
      expect(details, contains('1920x1080'));
      expect(details, contains('hevc'));
      expect(details, isNot(contains('/')));
      expect(details, isNot(contains('My video')));
    });

    test('"Export with H.264" restarts the same settings with H.264', () async {
      final (rig, c, job) = await running();
      job.fail(EngineFailure.of(EngineErrorCode.encoderUnavailable));
      await rig.settle();
      await c.exportWithH264();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.started, hasLength(2));
    });

    test('"Try again" runs the same setup again', () async {
      final (rig, c, job) = await running();
      job.fail(EngineFailure.of(EngineErrorCode.encodingFailed));
      await rig.settle();
      await c.retry();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.started, hasLength(2));
    });

    test('a preset becomes its Custom equivalent when a fallback changes it', () async {
      final rig = ExportRig(caps: rigCaps.copyWith(maxExportSize: const Size(3840, 2160)), project: (r) => exportProject(r, video4k: true));
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      c.selectPreset(ExportPresetId.youtube4k);
      final job = await _run(rig, c);
      job.fail(EngineFailure.of(EngineErrorCode.encoderUnavailable));
      await rig.settle();
      await c.exportWithH264();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.started, hasLength(2));
      final draft = ExportDraft.tryParse(rig.harness.prefs.readString(ExportController.draftKey(rig.id)))!;
      expect(draft.settings.preset, ExportPresetId.custom);
      expect((draft.settings.codec, draft.settings.shortSide), (VideoCodec.h264, 2160));
    });

    test('Back to settings returns to the setup after a failure', () async {
      final (rig, c, job) = await running();
      job.fail(EngineFailure.of(EngineErrorCode.encodingFailed));
      await rig.settle();
      c.backToSetup();
      expect(c.state, isA<ExportUiSetup>());
    });

    test('an engine that refuses to start fails visibly', () async {
      final rig = ExportRig();
      await rig.harness.prefs.markExportBackgroundNoticeShown();
      final c = await _ready(rig);
      rig.fake.failNext['exporter.start'] = EngineFailure.of(EngineErrorCode.diskFull);
      await c.start();
      await rig.settle();
      expect((c.state as ExportUiFailed).failure, const ExportFailed(ExportFailureKind.diskFull));
    });
  });

  group('reattach (D-22, D-39)', () {
    test('nothing running: nothing to show', () async {
      final rig = ExportRig();
      final container = rig.container();
      final c = rig.controllerIn(container);
      expect(await c.reattach(), ExportReattach.none);
      expect(c.state, isA<ExportUiIdle>());
    });

    test('a running export shows its progress again and finishes through the same path', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      final job = FakeExportJob('export-9', '${rig.workDir}/export-9.mp4', 5 * s);
      rig.exporter.records.add(ExportRunning(job));
      expect(await c.reattach(), ExportReattach.running);
      job.report(0.6);
      await rig.settle();
      expect((c.state as ExportUiRunning).fraction, 0.6);
      await rig.finish(job);
      expect(c.state, isA<ExportUiCompleted>());
    });

    test('a resumable iOS export offers Resume and continues from where it stopped', () async {
      final rig = ExportRig(platform: TargetPlatform.iOS);
      final c = await _ready(rig);
      rig.exporter.records.add(const ExportResumable('export-7', doneFraction: 0.4));
      expect(await c.reattach(), ExportReattach.resumable);
      final s = c.state as ExportUiInterrupted;
      expect((s.canResume, s.doneFraction), (true, 0.4));
      await c.resume();
      await _until<ExportUiRunning>(rig, c);
      expect(rig.fake.calls, contains('exporter.resume'));
    });

    test('an interrupted export is a one-shot notice: acknowledging consumes it; Start again returns to the setup', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      rig.exporter.records.add(const ExportInterrupted('export-3'));
      expect(await c.reattach(), ExportReattach.interrupted);
      expect((c.state as ExportUiInterrupted).canResume, isFalse);
      await c.acknowledgeRecord();
      expect(rig.exporter.records, isEmpty);
      expect(await c.reattach(), ExportReattach.none);

      rig.exporter.records.add(const ExportInterrupted('export-4'));
      await c.reattach();
      await c.startAgain();
      expect(c.state, isA<ExportUiSetup>());
      expect(rig.exporter.records, isEmpty);
    });

    test('an export that finished while away is a one-shot card: Share, Save to Files, Delete and Done', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      final path = '${rig.workDir}/export-5.mp4';
      rig.writeOutput(path);
      rig.exporter.records.add(ExportCompletedWhileDetached(
        'export-5',
        result: ExportResult(path: path, bytes: 1234, duration: 5 * s, videoEncoderName: 'x', hardwareEncoder: true),
        savedToGallery: true,
      ));
      expect(await c.reattach(), ExportReattach.finished);
      final card = c.state as ExportUiFinishedAway;
      expect((card.savedToGallery, card.result != null), (true, true));
      await c.shareFinished();
      await c.saveFinishedToFiles();
      expect(rig.scripted.kinds, ['share', 'files']);
      expect(rig.exporter.records, isNotEmpty, reason: 'not consumed until the card is dismissed');
      await c.deleteFinished();
      expect(rig.mem.peek(path), isNull);
      expect(rig.exporter.records, isEmpty);
    });

    test('a detached export that only exists in the gallery has nothing to share and is consumed on Done', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      rig.exporter.records.add(const ExportCompletedWhileDetached('export-6', savedToGallery: true));
      await c.reattach();
      await c.shareFinished();
      expect(rig.scripted.calls, isEmpty);
      await c.acknowledgeRecord();
      expect(rig.exporter.records, isEmpty);
    });

    test('records are shown in order of importance: running, resumable, finished, interrupted', () async {
      final rig = ExportRig();
      final c = await _ready(rig);
      rig.exporter.records
        ..add(const ExportInterrupted('a'))
        ..add(const ExportCompletedWhileDetached('b', savedToGallery: true))
        ..add(const ExportResumable('c', doneFraction: 0.2));
      expect(await c.reattach(), ExportReattach.resumable);
    });
  });
}
