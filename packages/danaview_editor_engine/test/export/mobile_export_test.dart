// OWNER: ENG-04
//
// MobileExportService over mocked channels (ARCH §12.4, §14, D-22, D-39): preflight, start
// arguments, progress mapping (<= 4 Hz through the router), results, cancel, failure codes,
// reattach after a hot restart, and the one-shot interrupted / resumable / completedWhileDetached
// records (each reported exactly once per activeJobs() call and never after consumeJobRecord).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/event_router.dart' show EventRateLimits;
import 'package:danaview_editor_engine/src/mobile_export.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_channels.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/native_export.dart';

const _settings = EncodeSettings(codec: VideoCodec.hevc, container: ExportContainer.mov, width: 1920, height: 1080, fps: 30, videoBitrate: 8000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  late NativeExport native;
  late MobileExportService service;

  setUp(() {
    h = ServicesHarness();
    native = NativeExport(h.host);
    service = MobileExportService(h.channels);
  });
  tearDown(() => h.dispose());

  Future<MobileExportJob> startJob({ExportDetachedHandoff? whenDetached}) async {
    final job = whenDetached == null
        ? await service.start(contractKitPlan(), _settings, outputPath: '/c/danaview/editor/work/export-x.mov', title: 'My film')
        : await service.start(contractKitPlan(), _settings,
            outputPath: '/c/danaview/editor/work/export-x.mov', title: 'My film', whenDetached: whenDetached);
    return job as MobileExportJob;
  }

  group('preflight', () {
    test('sends the plan bytes and settings and maps ok, maxHeightForPlan and warnings', () async {
      native.preflightReply = ExportPreflightMsg(ok: false, maxHeightForPlan: 1440, warnings: [
        ExportWarningMsg(code: 'softwareEncoder', message: 'software H.264'),
        ExportWarningMsg(code: 'hevcUnavailable', message: ''),
        ExportWarningMsg(code: 'backgroundPauses', message: ''),
        ExportWarningMsg(code: 'layersVsResolution', message: ''),
        ExportWarningMsg(code: 'portraitRefused', message: ''),
      ]);
      final pre = await service.preflight(contractKitPlan(), _settings);
      expect(pre.ok, isFalse);
      expect(pre.maxHeightForPlan, 1440);
      expect(pre.warnings.map((w) => w.code), ['softwareEncoder', 'hevcUnavailable', 'backgroundPauses', 'layersVsResolution', 'portraitRefused']);
      expect(pre.warnings.first.message, 'software H.264');

      final args = h.argsOf('ExportHostApi', 'preflight').single;
      expect(args[0], await PlanTransport.encodePlan(contractKitPlan()));
      final s = args[1]! as EncodeSettingsMsg;
      expect([s.codec, s.container, s.width, s.height, s.fps, s.videoBitrate, s.stripLocation],
          [VideoCodecMsg.hevc, ExportContainerMsg.mov, 1920, 1080, 30, 8000000, true]);
    });

    test('a native error maps to an EngineFailure', () async {
      h.host.fail('ExportHostApi', 'preflight', 'planInvalid', message: 'bad plan');
      await expectLater(service.preflight(contractKitPlan(), _settings), throwsEngineError(EngineErrorCode.planInvalid));
    });
  });

  group('start', () {
    test('passes outputPath, title and whenDetached (default saveToGallery)', () async {
      final a = await startJob();
      final b = await startJob(whenDetached: ExportDetachedHandoff.keepForLater);
      expect(a.id, 'exp-0');
      expect(b.id, 'exp-1');
      final calls = h.argsOf('ExportHostApi', 'start');
      expect(calls[0][0], isA<Uint8List>());
      expect(calls[0].sublist(2), ['/c/danaview/editor/work/export-x.mov', 'My film', DetachedHandoffMsg.saveToGallery]);
      expect(calls[1][4], DetachedHandoffMsg.keepForLater);
    });

    test('native start failures map to EngineFailure codes', () async {
      for (final (code, expected) in [
        ('diskFull', EngineErrorCode.diskFull),
        ('encoderUnavailable', EngineErrorCode.encoderUnavailable),
        ('encoderSizeLimit', EngineErrorCode.encoderSizeLimit),
        ('busy', EngineErrorCode.busy),
        ('somethingNew', EngineErrorCode.internal),
      ]) {
        h.host.fail('ExportHostApi', 'start', code, message: 'no');
        await expectLater(startJob(), throwsEngineError(expected), reason: code);
      }
    });
  });

  group('progress and result', () {
    test('exportProgress maps phase, fraction, frames, background flags and warnings; jobDone completes', () async {
      final job = await startJob();
      final seen = <ExportProgress>[];
      job.progress.listen(seen.add);
      await h.emit(exportProgressEvent(job.id, phase: ExportPhaseMsg.preparing, fraction: 0));
      await h.emit(exportProgressEvent(job.id, fraction: 0.25, framesDone: 22, framesTotal: 90));
      await h.emit(exportProgressEvent(job.id,
          fraction: 0.5, framesDone: 45, framesTotal: 90, backgrounded: true, pausedInBackground: true,
          warnings: [ExportWarningMsg(code: 'fallbackApplied', message: 'h264')]));
      await h.emit(exportProgressEvent(job.id, phase: ExportPhaseMsg.finishing, fraction: 1.4, framesDone: 90, framesTotal: 90));
      await h.emit(exportDoneEvent(job.id));

      expect(seen.map((p) => p.phase), [ExportPhase.preparing, ExportPhase.rendering, ExportPhase.rendering, ExportPhase.finishing]);
      expect(seen.map((p) => p.fraction), [0, 0.25, 0.5, 1.0], reason: 'fractions are clamped to 0..1');
      expect(seen[1].framesDone, 22);
      expect(seen[1].framesTotal, 90);
      expect(seen[2].backgrounded, isTrue);
      expect(seen[2].pausedInBackground, isTrue);
      expect(seen[2].warnings.single.code, 'fallbackApplied');
      expect(job.lastProgress?.phase, ExportPhase.finishing);

      final r = await job.result;
      expect(r.path, '/c/danaview/editor/work/export-exp-0.mp4');
      expect(r.bytes, 4242);
      expect(r.duration, 3000000);
      expect(r.videoEncoderName, 'com.apple.videotoolbox.h264');
      expect(r.hardwareEncoder, isTrue);
      expect(job.isDone, isTrue);
    });

    test('events racing the start reply are delivered to the job', () async {
      native.onStart = (id) async {
        h.events
          ..add(exportProgressEvent(id, phase: ExportPhaseMsg.preparing))
          ..add(exportProgressEvent(id, fraction: 0.1));
        await pumpEventQueue();
      };
      final job = await startJob();
      final seen = <ExportProgress>[];
      job.progress.listen(seen.add);
      await pumpEventQueue();
      expect(seen.map((p) => p.fraction), [0, 0.1]);
    });

    test('a jobDone without an export result is internal', () async {
      final job = await startJob();
      await h.emit(doneEvent(job.id, JobResultMsg(kind: JobKindMsg.proxy)));
      await expectLater(job.result, throwsEngineError(EngineErrorCode.internal));
    });

    test('failure events map to their codes; cancelled is EngineCancelled', () async {
      for (final (code, expected) in [
        ('encoderSizeLimit', EngineErrorCode.encoderSizeLimit),
        ('encoderUnavailable', EngineErrorCode.encoderUnavailable),
        ('encodingFailed', EngineErrorCode.encodingFailed),
        ('diskFull', EngineErrorCode.diskFull),
        ('mediaOffline', EngineErrorCode.mediaOffline),
        ('permissionDenied', EngineErrorCode.permissionDenied),
        ('decodeFailed', EngineErrorCode.decodeFailed),
        ('gpuUnavailable', EngineErrorCode.gpuUnavailable),
        ('interrupted', EngineErrorCode.interrupted),
        ('unknownCode', EngineErrorCode.internal),
      ]) {
        final job = await startJob();
        final done = expectLater(job.progress, emitsDone);
        await h.emit(failureEvent(job.id, code, retryable: code == 'interrupted'));
        await expectLater(
          job.result,
          throwsA(isA<EngineError>()
              .having((e) => e.code, 'code', expected)
              .having((e) => e.retryable, 'retryable', code == 'interrupted')),
          reason: code,
        );
        await done;
      }
      final job = await startJob();
      await h.emit(failureEvent(job.id, 'cancelled'));
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('a route closed without a terminal event is a retryable interrupted failure', () async {
      final job = await startJob();
      h.channels.router.release(job.id);
      await expectLater(
        job.result,
        throwsA(isA<EngineError>().having((e) => e.code, 'code', EngineErrorCode.interrupted).having((e) => e.retryable, 'retryable', true)),
      );
    });

    test('progress is limited to 4 Hz by the router; phase changes pass at once and the last sample is kept', () async {
      var now = Duration.zero;
      final channels = EngineChannels(config: servicesConfig, limits: const EventRateLimits(), now: () => now);
      addTearDown(channels.dispose);
      final svc = MobileExportService(channels);
      final job = await svc.start(contractKitPlan(), _settings, outputPath: '/o.mp4', title: 't');
      final seen = <ExportProgress>[];
      job.progress.listen(seen.add);
      await h.emit(exportProgressEvent(job.id, phase: ExportPhaseMsg.preparing));
      for (var i = 1; i <= 10; i++) {
        now = Duration(milliseconds: 10 * i);
        await h.emit(exportProgressEvent(job.id, fraction: i / 100));
      }
      // preparing → rendering is a state change and passes; the rest coalesce to the latest.
      expect(seen.map((p) => p.fraction), [0, 0.01]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(seen.map((p) => p.fraction), [0, 0.01, 0.1]);
    });
  });

  group('cancel', () {
    test('completes with EngineCancelled at once, sends cancel once, drops late events', () async {
      final job = await startJob();
      final seen = <ExportProgress>[];
      job.progress.listen(seen.add);
      final result = job.result;
      final c1 = job.cancel();
      final c2 = job.cancel();
      await expectLater(result, throwsEngineCancelled);
      await Future.wait([c1, c2]);
      await job.cancel();
      expect(h.argsOf('ExportHostApi', 'cancel'), [
        ['exp-0']
      ]);
      await h.emit(exportProgressEvent(job.id, fraction: 0.9));
      await h.emit(exportDoneEvent(job.id));
      expect(seen, isEmpty);
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('a cancelled job is not reported as running even while the native store lags', () async {
      native.keepCancelledRecords = true;
      final job = await startJob();
      await job.cancel();
      expect(native.records.keys, contains(job.id));
      expect(await service.activeJobs(), isEmpty);
    });

    test('a failing native cancel still ends the job with EngineCancelled', () async {
      native.cancelFails = true;
      final job = await startJob();
      await job.cancel();
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('cancel after completion does nothing', () async {
      final job = await startJob();
      await h.emit(exportDoneEvent(job.id));
      await job.result;
      await job.cancel();
      expect(h.argsOf('ExportHostApi', 'cancel'), isEmpty);
    });
  });

  group('activeJobs: reattach', () {
    test('a job started here is reported as ExportRunning with the same job object', () async {
      final job = await startJob();
      final a = await service.activeJobs();
      final b = await service.activeJobs();
      expect(a.single, isA<ExportRunning>());
      expect((a.single as ExportRunning).job, same(job));
      expect((b.single as ExportRunning).job, same(job));
    });

    test('after a hot restart running jobs are reattached over the router and finish', () async {
      native.records['exp-old'] = ExportJobRecordMsg(jobId: 'exp-old', state: ExportJobStateKindMsg.running, savedToGallery: false);
      // A fresh service (new isolate): nothing local is known.
      final states = await service.activeJobs();
      final running = states.single as ExportRunning;
      expect(running.jobId, 'exp-old');
      final job = running.job;
      expect((await service.activeJobs()).single, isA<ExportRunning>().having((r) => r.job, 'job', same(job)));
      final seen = <double>[];
      job.progress.listen((p) => seen.add(p.fraction));
      await h.emit(exportProgressEvent('exp-old', fraction: 0.7));
      await h.emit(exportDoneEvent('exp-old'));
      expect(seen, [0.7]);
      expect((await job.result).path, '/c/danaview/editor/work/export-exp-old.mp4');
      // Finished here: a lagging native running record is not reported again.
      expect(await service.activeJobs(), isEmpty);
      // The reattached job can be cancelled like any other.
      native.records['exp-old2'] = ExportJobRecordMsg(jobId: 'exp-old2', state: ExportJobStateKindMsg.running, savedToGallery: false);
      final other = ((await service.activeJobs()).single as ExportRunning).job;
      await other.cancel();
      await expectLater(other.result, throwsEngineCancelled);
      expect(h.argsOf('ExportHostApi', 'cancel').last, ['exp-old2']);
    });

    test('duplicate native records yield one state per job id', () async {
      native.records['exp-a'] = ExportJobRecordMsg(jobId: 'exp-a', state: ExportJobStateKindMsg.running, savedToGallery: false);
      native.extraRecords
        ..add(ExportJobRecordMsg(jobId: 'exp-a', state: ExportJobStateKindMsg.running, savedToGallery: false))
        ..add(ExportJobRecordMsg(jobId: 'exp-i', state: ExportJobStateKindMsg.interrupted, savedToGallery: false))
        ..add(ExportJobRecordMsg(jobId: 'exp-i', state: ExportJobStateKindMsg.interrupted, savedToGallery: false))
        ..add(ExportJobRecordMsg(jobId: '', state: ExportJobStateKindMsg.interrupted, savedToGallery: false));
      final states = await service.activeJobs();
      expect(states.map((s) => s.jobId), ['exp-a', 'exp-i']);
    });
  });

  group('activeJobs: one-shot records', () {
    test('interrupted is reported once per call until consumed, then never again', () async {
      native.keepConsumedRecords = true; // the native store lags: Dart still never reports it again.
      native.records['exp-i'] = ExportJobRecordMsg(jobId: 'exp-i', state: ExportJobStateKindMsg.interrupted, savedToGallery: false);
      expect((await service.activeJobs()).single, isA<ExportInterrupted>().having((s) => s.jobId, 'jobId', 'exp-i'));
      expect((await service.activeJobs()).whereType<ExportInterrupted>(), hasLength(1));
      await service.consumeJobRecord('exp-i');
      expect(h.argsOf('ExportHostApi', 'consumeJobRecord'), [
        ['exp-i']
      ]);
      expect(await service.activeJobs(), isEmpty);
    });

    test('an interrupted record for a live job ends that job (retryable interrupted)', () async {
      final job = await startJob();
      native.records[job.id] = ExportJobRecordMsg(jobId: job.id, state: ExportJobStateKindMsg.interrupted, savedToGallery: false);
      final states = await service.activeJobs();
      expect(states.single, isA<ExportInterrupted>());
      await expectLater(
        job.result,
        throwsA(isA<EngineError>().having((e) => e.code, 'code', EngineErrorCode.interrupted).having((e) => e.retryable, 'retryable', true)),
      );
    });

    test('completedWhileDetached carries result, gallery flag, uri and settings; reported until consumed', () async {
      native.records['exp-d'] = ExportJobRecordMsg(
        jobId: 'exp-d',
        state: ExportJobStateKindMsg.completedWhileDetached,
        result: exportResultMsg('exp-d'),
        savedToGallery: true,
        savedUri: 'content://media/external/video/media/7',
        settings: EncodeSettingsMsg(
          container: ExportContainerMsg.mp4,
          codec: VideoCodecMsg.h264,
          width: 1080,
          height: 1920,
          fps: 30,
          videoBitrate: 8000000,
          audioBitrate: 128000,
          audioSampleRate: 48000,
          audioChannels: 2,
          keyframeIntervalMs: 2000,
          stripLocation: true,
        ),
      );
      final s = (await service.activeJobs()).single as ExportCompletedWhileDetached;
      expect(s.jobId, 'exp-d');
      expect(s.result?.path, '/c/danaview/editor/work/export-exp-d.mp4');
      expect(s.savedToGallery, isTrue);
      expect(s.savedUri, 'content://media/external/video/media/7');
      expect(s.settings?.height, 1920);
      expect((await service.activeJobs()).whereType<ExportCompletedWhileDetached>(), hasLength(1));
      await service.consumeJobRecord('exp-d');
      expect(await service.activeJobs(), isEmpty);
    });

    test('a completedWhileDetached record without a kept file has a null result', () async {
      native.records['exp-g'] =
          ExportJobRecordMsg(jobId: 'exp-g', state: ExportJobStateKindMsg.completedWhileDetached, savedToGallery: true);
      final s = (await service.activeJobs()).single as ExportCompletedWhileDetached;
      expect(s.result, isNull);
      expect(s.savedToGallery, isTrue);
    });
  });

  group('resumable and resume (iOS, D-22)', () {
    test('resumable maps doneFraction (clamped) and is reported once per call', () async {
      native.records['exp-r'] = ExportJobRecordMsg(jobId: 'exp-r', state: ExportJobStateKindMsg.resumable, doneFraction: 0.42, savedToGallery: false);
      native.records['exp-s'] = ExportJobRecordMsg(jobId: 'exp-s', state: ExportJobStateKindMsg.resumable, doneFraction: 3, savedToGallery: false);
      native.extraRecords.add(ExportJobRecordMsg(jobId: 'exp-r', state: ExportJobStateKindMsg.resumable, doneFraction: 0.1, savedToGallery: false));
      final states = (await service.activeJobs()).cast<ExportResumable>();
      expect(states.map((s) => (s.jobId, s.doneFraction)), [('exp-r', 0.42), ('exp-s', 1.0)]);
    });

    test('resume re-attaches to the job id and runs to completion', () async {
      native.records['exp-r'] = ExportJobRecordMsg(jobId: 'exp-r', state: ExportJobStateKindMsg.resumable, doneFraction: 0.5, savedToGallery: false);
      final job = await service.resume('exp-r');
      expect(job.id, 'exp-r');
      expect(h.argsOf('ExportHostApi', 'resume'), [
        ['exp-r']
      ]);
      expect((await service.activeJobs()).single, isA<ExportRunning>().having((r) => r.job, 'job', same(job)));
      final seen = <double>[];
      job.progress.listen((p) => seen.add(p.fraction));
      await h.emit(exportProgressEvent('exp-r', fraction: 0.6));
      await h.emit(exportDoneEvent('exp-r'));
      expect(seen, [0.6]);
      expect((await job.result).bytes, 4242);
    });

    test('a live job native reports as resumable ends interrupted and can be resumed under the same id', () async {
      final job = await startJob();
      native.records[job.id] = ExportJobRecordMsg(jobId: job.id, state: ExportJobStateKindMsg.resumable, doneFraction: 0.3, savedToGallery: false);
      final states = await service.activeJobs();
      expect(states.single, isA<ExportResumable>().having((s) => s.doneFraction, 'doneFraction', 0.3));
      await expectLater(job.result, throwsEngineError(EngineErrorCode.interrupted));

      final resumed = await service.resume(job.id);
      expect(resumed, isNot(same(job)));
      expect(resumed.id, job.id);
      final seen = <double>[];
      resumed.progress.listen((p) => seen.add(p.fraction));
      await h.emit(exportProgressEvent(job.id, fraction: 0.8));
      await h.emit(exportDoneEvent(job.id));
      expect(seen, [0.8]);
      expect((await resumed.result).path, '/c/danaview/editor/work/export-${job.id}.mp4');
    });

    test('resume of a live job returns it without a native call', () async {
      final job = await startJob();
      expect(await service.resume(job.id), same(job));
      expect(h.argsOf('ExportHostApi', 'resume'), isEmpty);
    });

    test('resume of an unknown job maps the native error (notSupportedOnDevice)', () async {
      await expectLater(service.resume('nope'), throwsEngineError(EngineErrorCode.notSupportedOnDevice));
    });
  });

  test('MobileEditorEngine.exporter is the mobile export service', () {
    final engine = MobileEditorEngine(config: servicesConfig, limits: noRateLimits);
    expect(engine.exporter, isA<MobileExportService>());
  });
}
