// OWNER: ENG-03
//
// MobileMediaJobs and MobileWaveformSource over mocked channels (ARCH §12.3, §15): request
// fields per kind, default priorities, progress from events, typed results (incl.
// extractSpeechAudio), result-kind mismatches, failure events, cancel races (before and after the
// startJob reply, after completion), setPriority, events racing the startJob reply, and the
// proxyStatus cache.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show TimeRange;
import 'package:danaview_editor_engine/src/mobile_jobs.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/services_harness.dart';

JobResultMsg _assetResult(JobKindMsg kind, String path) =>
    JobResultMsg(kind: kind, asset: GeneratedAssetMsg(path: path, sizeBytes: 2048, durationUs: kind == JobKindMsg.freeze ? null : 4000000));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  late MobileMediaJobs jobs;
  late List<JobRequestMsg> started;
  Completer<String>? gate;
  var nativeN = 0;

  setUp(() {
    h = ServicesHarness();
    jobs = MobileMediaJobs(h.channels);
    started = [];
    gate = null;
    nativeN = 0;
    h.host
      ..on('JobsHostApi', 'startJob', (args) {
        started.add(args.single! as JobRequestMsg);
        final g = gate;
        return g != null ? g.future : 'n${nativeN++}';
      })
      ..on('JobsHostApi', 'cancelJob', (_) => null)
      ..on('JobsHostApi', 'setJobPriority', (_) => null)
      ..on('JobsHostApi', 'proxyStatus', (_) => ProxyStatusMsg.ready);
  });
  tearDown(() => h.dispose());

  group('requests', () {
    test('each kind sends its fields and default priority', () async {
      jobs.proxy(servicesMedia);
      jobs.reverse(servicesMedia, const TimeRange(1000000, 3000000), outputPath: '/s/danaview/editor/derived/r.mp4');
      jobs.freezeFrame(servicesMedia, 1500000, outputPath: '/s/danaview/editor/projects/p/assets/f.png');
      jobs.extractSpeechAudio(const SpeechAudioJobRequest(
          media: servicesMedia, range: TimeRange(0, 10000000), outputPath: '/s/danaview/speech/work/a.wav', audioStream: 1));
      MobileWaveformSource(h.channels).peaks(servicesMedia, audioStream: 2);
      await pumpEventQueue();
      expect(started.map((r) => r.kind),
          [JobKindMsg.proxy, JobKindMsg.reverse, JobKindMsg.freeze, JobKindMsg.speechAudio, JobKindMsg.waveform]);
      expect(started.map((r) => r.priority), [
        JobPriorityMsg.background,
        JobPriorityMsg.interactive,
        JobPriorityMsg.interactive,
        JobPriorityMsg.normal,
        JobPriorityMsg.normal
      ]);
      expect(started.every((r) => r.media.uri == 'file:///d/clip.mov' && r.media.fingerprint == 'qh_1'), isTrue);
      final rev = started[1];
      expect((rev.sourceStartUs, rev.sourceEndUs, rev.outputPath), (1000000, 3000000, '/s/danaview/editor/derived/r.mp4'));
      final fr = started[2];
      expect((fr.sourceTimeUs, fr.outputPath), (1500000, '/s/danaview/editor/projects/p/assets/f.png'));
      final sp = started[3];
      expect((sp.sourceStartUs, sp.sourceEndUs, sp.outputPath, sp.audioStream), (0, 10000000, '/s/danaview/speech/work/a.wav', 1));
      expect(started[4].audioStream, 2);
      expect(started[0].outputPath, isNull, reason: 'the proxy path is chosen natively (ARCH §9.5)');
    });

    test('job ids are available synchronously and unique; the native id is kept separately', () async {
      final a = jobs.proxy(servicesMedia) as MobileMediaJob<GeneratedAsset>;
      final b = jobs.proxy(servicesMedia) as MobileMediaJob<GeneratedAsset>;
      expect(a.id, isNotEmpty);
      expect(a.id, isNot(b.id));
      expect(a.nativeId, isNull);
      await pumpEventQueue();
      expect((a.nativeId, b.nativeId), ('n0', 'n1'));
    });
  });

  group('progress and results', () {
    test('progress is forwarded (clamped) and a typed GeneratedAsset completes the job', () async {
      final job = jobs.reverse(servicesMedia, const TimeRange(0, 4000000), outputPath: '/s/danaview/editor/derived/r.mp4');
      final progress = <double>[];
      job.progress.listen(progress.add);
      await pumpEventQueue();
      await h.emit(progressEvent('n0', 0.25));
      await h.emit(progressEvent('n0', 1.7));
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.reverse, '/s/danaview/editor/derived/r.mp4')));
      final asset = await job.result;
      expect((asset.path, asset.sizeBytes, asset.duration), ('/s/danaview/editor/derived/r.mp4', 2048, 4000000));
      expect(progress, [0.25, 1.0]);
    });

    test('a final progress of 1 is added on success when native did not send it; the stream closes', () async {
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/x.png');
      final progress = <double>[];
      var closed = false;
      job.progress.listen(progress.add, onDone: () => closed = true);
      await pumpEventQueue();
      await h.emit(progressEvent('n0', 0.5));
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.freeze, '/x.png')));
      expect((await job.result).duration, isNull);
      expect(progress, [0.5, 1.0]);
      expect(closed, isTrue);
    });

    test('waveform peaks are typed int8 pairs', () async {
      final job = MobileWaveformSource(h.channels).peaks(servicesMedia);
      await pumpEventQueue();
      final id = (job as MobileMediaJob<WaveformPeaks>).nativeId!;
      await h.emit(doneEvent(
          id,
          JobResultMsg(
            kind: JobKindMsg.waveform,
            peaks: WaveformPeaksMsg(minMax: Uint8List.fromList([0x80, 0x7F, 0xFF, 0x01]), durationUs: 20000, pairsPerSecond: 200),
          )));
      final peaks = await job.result;
      expect(peaks.minMax, [-128, 127, -1, 1]);
      expect((peaks.duration, peaks.pairsPerSecond), (20000, 200));
    });

    test('extractSpeechAudio results are typed ExtractedSpeechAudio', () async {
      final job = jobs.extractSpeechAudio(
          const SpeechAudioJobRequest(media: servicesMedia, range: TimeRange(0, 2000000), outputPath: '/s/danaview/speech/work/a.wav'));
      await pumpEventQueue();
      await h.emit(doneEvent(
          'n0',
          JobResultMsg(
            kind: JobKindMsg.speechAudio,
            speech: ExtractedSpeechAudioMsg(
                path: '/s/danaview/speech/work/a.wav',
                frames: 32000,
                durationUs: 2000000,
                sourceChannels: 6,
                sourceSampleRate: 48000,
                codec: 'aac'),
          )));
      final speech = await job.result;
      expect((speech.path, speech.frames, speech.duration, speech.sourceChannels, speech.sourceSampleRate, speech.codec),
          ('/s/danaview/speech/work/a.wav', 32000, 2000000, 6, 48000, 'aac'));
      expect(started.single.audioStream, isNull);
    });

    test('a result of the wrong kind or without its payload is internal', () async {
      final a = jobs.proxy(servicesMedia);
      final b = jobs.extractSpeechAudio(const SpeechAudioJobRequest(media: servicesMedia, range: TimeRange(0, 1), outputPath: '/a.wav'));
      await pumpEventQueue();
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.reverse, '/p.mp4')));
      await h.emit(doneEvent('n1', JobResultMsg(kind: JobKindMsg.speechAudio)));
      await expectLater(a.result, throwsEngineError(EngineErrorCode.internal));
      await expectLater(b.result, throwsEngineError(EngineErrorCode.internal));
    });

    test('a failure event completes the job with the typed failure and closes progress', () async {
      final job = jobs.reverse(servicesMedia, const TimeRange(0, 1), outputPath: '/r.mp4');
      var closed = false;
      job.progress.listen((_) {}, onDone: () => closed = true);
      await pumpEventQueue();
      await h.emit(failureEvent('n0', 'diskFull', retryable: true, message: 'no space for /var/mobile/x'));
      await expectLater(
        job.result,
        throwsA(isA<EngineError>()
            .having((e) => e.code, 'code', EngineErrorCode.diskFull)
            .having((e) => e.retryable, 'retryable', true)
            .having((e) => e.debugDetail, 'detail', isNot(contains('/var')))),
      );
      expect(closed, isTrue);
    });

    test('a startJob error completes the job typed', () async {
      h.host.fail('JobsHostApi', 'startJob', 'busy', details: {'retryable': true});
      final job = jobs.proxy(servicesMedia);
      await expectLater(job.result, throwsEngineError(EngineErrorCode.busy));
    });

    test('events that arrive before the startJob reply are delivered (router buffer)', () async {
      gate = Completer<String>();
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/f.png');
      final progress = <double>[];
      job.progress.listen(progress.add);
      await pumpEventQueue();
      await h.emit(progressEvent('early', 0.4));
      await h.emit(doneEvent('early', _assetResult(JobKindMsg.freeze, '/f.png')));
      gate!.complete('early');
      expect((await job.result).path, '/f.png');
      expect(progress, [0.4, 1.0]);
    });

    test('a closed event stream without a terminal event fails the job as interrupted', () async {
      final job = jobs.proxy(servicesMedia);
      await pumpEventQueue();
      await h.channels.router.dispose();
      await expectLater(job.result, throwsEngineError(EngineErrorCode.interrupted));
    });
  });

  group('cancel', () {
    test('cancel after the native id: cancelJob is sent, the result is EngineCancelled, late events are dropped', () async {
      final job = jobs.reverse(servicesMedia, const TimeRange(0, 1), outputPath: '/r.mp4') as MobileMediaJob<GeneratedAsset>;
      await pumpEventQueue();
      job.cancel();
      job.cancel(); // idempotent
      await expectLater(job.result, throwsEngineCancelled);
      await pumpEventQueue();
      expect(h.argsOf('JobsHostApi', 'cancelJob'), [
        ['n0']
      ]);
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.reverse, '/r.mp4')));
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('cancel before the startJob reply sends cancelJob as soon as the native id arrives', () async {
      gate = Completer<String>();
      final job = jobs.proxy(servicesMedia);
      await pumpEventQueue();
      job.cancel();
      await expectLater(job.result, throwsEngineCancelled);
      expect(h.host.count('JobsHostApi', 'cancelJob'), 0);
      gate!.complete('late');
      await pumpEventQueue();
      expect(h.argsOf('JobsHostApi', 'cancelJob'), [
        ['late']
      ]);
      await h.emit(doneEvent('late', _assetResult(JobKindMsg.proxy, '/p.mp4')));
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('cancel before the call even left Dart still cancels natively', () async {
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/f.png');
      job.cancel();
      await expectLater(job.result, throwsEngineCancelled);
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'startJob'), 1);
      expect(h.host.count('JobsHostApi', 'cancelJob'), 1);
    });

    test('cancel after completion is a no-op', () async {
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/f.png');
      await pumpEventQueue();
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.freeze, '/f.png')));
      expect((await job.result).path, '/f.png');
      job.cancel();
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'cancelJob'), 0);
      expect((await job.result).path, '/f.png');
    });

    test('a native cancelled failure (e.g. the job was cancelled natively) completes with EngineCancelled', () async {
      final job = jobs.proxy(servicesMedia);
      await pumpEventQueue();
      await h.emit(failureEvent('n0', 'cancelled'));
      await expectLater(job.result, throwsEngineCancelled);
    });

    test('a failure racing a cancel: the first one wins', () async {
      final job = jobs.proxy(servicesMedia);
      await pumpEventQueue();
      h.events.add(failureEvent('n0', 'decodeFailed'));
      job.cancel();
      await pumpEventQueue();
      await expectLater(job.result, throwsEngineCancelled);
    });
  });

  group('priority', () {
    test('setPriority is forwarded once the native id is known; the latest value wins; no-ops are not sent', () async {
      gate = Completer<String>();
      final job = jobs.proxy(servicesMedia);
      job.setPriority(JobPriority.normal);
      job.setPriority(JobPriority.interactive);
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'setJobPriority'), 0);
      gate!.complete('p1');
      await pumpEventQueue();
      expect(h.argsOf('JobsHostApi', 'setJobPriority'), [
        ['p1', JobPriorityMsg.interactive]
      ]);
      job.setPriority(JobPriority.interactive);
      job.setPriority(JobPriority.background);
      await pumpEventQueue();
      expect(h.argsOf('JobsHostApi', 'setJobPriority').last, ['p1', JobPriorityMsg.background]);
      expect(h.host.count('JobsHostApi', 'setJobPriority'), 2);
    });

    test('changing back to the requested priority before the reply sends nothing', () async {
      gate = Completer<String>();
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/f.png');
      job.setPriority(JobPriority.background);
      job.setPriority(JobPriority.interactive);
      gate!.complete('f1');
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'setJobPriority'), 0);
    });

    test('setPriority after completion is ignored', () async {
      final job = jobs.freezeFrame(servicesMedia, 0, outputPath: '/f.png');
      await pumpEventQueue();
      job.cancel();
      job.setPriority(JobPriority.background);
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'setJobPriority'), 0);
    });
  });

  group('proxyStatus', () {
    test('the first query answers from the cache and refreshes from native in the background', () async {
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.none);
      await pumpEventQueue();
      expect(h.argsOf('JobsHostApi', 'proxyStatus'), [
        ['qh_1']
      ]);
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.ready);
      expect(h.host.count('JobsHostApi', 'proxyStatus'), 1);
    });

    test('proxy jobs drive the cache: queued, running, ready / failed / none after cancel', () async {
      h.host.on('JobsHostApi', 'proxyStatus', (_) => ProxyStatusMsg.noProxy);
      final job = jobs.proxy(servicesMedia);
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.queued);
      await pumpEventQueue();
      expect(h.host.count('JobsHostApi', 'proxyStatus'), 0, reason: 'a local job is fresher than native');
      await h.emit(progressEvent('n0', 0.1));
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.running);
      await h.emit(doneEvent('n0', _assetResult(JobKindMsg.proxy, '/c/danaview/editor/proxies/qh_1-540.mp4')));
      await job.result;
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.ready);

      const other = EngineMedia(uri: 'file:///d/b.mov', fingerprint: 'qh_2');
      final failing = jobs.proxy(other);
      await pumpEventQueue();
      await h.emit(failureEvent('n1', 'encodingFailed'));
      await expectLater(failing.result, throwsEngineError(EngineErrorCode.encodingFailed));
      expect(jobs.proxyStatus(other), ProxyStatus.failed);

      const third = EngineMedia(uri: 'file:///d/c.mov', fingerprint: 'qh_3');
      jobs.proxy(third).cancel();
      expect(jobs.proxyStatus(third), ProxyStatus.none);
    });

    test('refreshProxyStatus maps every native state', () async {
      for (final (msg, status) in [
        (ProxyStatusMsg.noProxy, ProxyStatus.none),
        (ProxyStatusMsg.queued, ProxyStatus.queued),
        (ProxyStatusMsg.running, ProxyStatus.running),
        (ProxyStatusMsg.ready, ProxyStatus.ready),
        (ProxyStatusMsg.failed, ProxyStatus.failed),
      ]) {
        h.host.on('JobsHostApi', 'proxyStatus', (_) => msg);
        expect(await jobs.refreshProxyStatus(servicesMedia), status);
        expect(jobs.proxyStatus(servicesMedia), status);
      }
    });

    test('a failed refresh is retried by the next query', () async {
      h.host.on('JobsHostApi', 'proxyStatus', (_) => throw PlatformException(code: 'io'));
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.none);
      await pumpEventQueue();
      h.host.on('JobsHostApi', 'proxyStatus', (_) => ProxyStatusMsg.running);
      jobs.proxyStatus(servicesMedia);
      await pumpEventQueue();
      expect(jobs.proxyStatus(servicesMedia), ProxyStatus.running);
    });
  });
}
