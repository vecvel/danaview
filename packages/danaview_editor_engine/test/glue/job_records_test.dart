// OWNER: ENG-01
//
// Export job records and job results survive the real Pigeon codec (host reply and event
// channel) and map to the engine API types (ARCH §12.4, D-22, D-39): running jobs are reattached,
// resumable, interrupted and completedWhileDetached records decode with their fields.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/pigeon/conversions.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_channels.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/mock_engine_host.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');

EncodeSettingsMsg _settings() => EncodeSettingsMsg(
      container: ExportContainerMsg.mov,
      codec: VideoCodecMsg.hevc,
      width: 1920,
      height: 1080,
      fps: 30,
      videoBitrate: 16000000,
      audioBitrate: 192000,
      audioSampleRate: 48000,
      audioChannels: 2,
      keyframeIntervalMs: 2000,
      stripLocation: true,
    );

final class _ReattachedJob implements ExportJob {
  _ReattachedJob(this.id);

  @override
  final String id;

  @override
  Stream<ExportProgress> get progress => const Stream.empty();

  @override
  Future<ExportResult> get result => Completer<ExportResult>().future;

  @override
  Future<void> cancel() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late EngineChannels channels;

  setUp(() {
    host = MockEngineHost()..acceptInitialize();
    channels = EngineChannels(config: _config);
  });

  tearDown(() async {
    host.dispose();
    await channels.dispose();
  });

  test('activeJobs records decode: running reattaches, resumable / interrupted / completedWhileDetached keep their fields', () async {
    host.on(
        'ExportHostApi',
        'activeJobs',
        (_) => [
              ExportJobRecordMsg(jobId: 'run', state: ExportJobStateKindMsg.running, savedToGallery: false),
              ExportJobRecordMsg(jobId: 'res', state: ExportJobStateKindMsg.resumable, doneFraction: 0.42, savedToGallery: false),
              ExportJobRecordMsg(jobId: 'int', state: ExportJobStateKindMsg.interrupted, savedToGallery: false),
              ExportJobRecordMsg(
                jobId: 'det',
                state: ExportJobStateKindMsg.completedWhileDetached,
                result: ExportResultMsg(
                  path: '/c/danaview/editor/work/export-det.mov',
                  bytes: 123456,
                  durationUs: 8000000,
                  videoEncoderName: 'VTCompressionSession HEVC',
                  hardwareEncoder: true,
                ),
                savedToGallery: true,
                savedUri: 'ph://ABC-123',
                settings: _settings(),
              ),
              ExportJobRecordMsg(
                jobId: 'gal',
                state: ExportJobStateKindMsg.completedWhileDetached,
                savedToGallery: true,
                savedUri: 'content://media/external/video/media/9',
              ),
            ]);

    final records = await channels.invoke(channels.export.activeJobs);
    final reattached = <String>[];
    final states = [
      for (final r in records)
        exportJobStateFromMsg(r, reattach: (id) {
          reattached.add(id);
          return _ReattachedJob(id);
        }),
    ];

    expect(reattached, ['run']);
    expect(states[0], isA<ExportRunning>().having((s) => s.job.id, 'job.id', 'run'));
    expect(states[1], isA<ExportResumable>().having((s) => s.jobId, 'jobId', 'res').having((s) => s.doneFraction, 'doneFraction', 0.42));
    expect(states[2], isA<ExportInterrupted>().having((s) => s.jobId, 'jobId', 'int'));

    final det = states[3] as ExportCompletedWhileDetached;
    expect(det.jobId, 'det');
    expect(det.savedToGallery, isTrue);
    expect(det.savedUri, 'ph://ABC-123');
    expect(det.result!.path, '/c/danaview/editor/work/export-det.mov');
    expect(det.result!.bytes, 123456);
    expect(det.result!.duration, 8000000);
    expect(det.result!.hardwareEncoder, isTrue);
    expect(det.settings!.container, ExportContainer.mov);
    expect(det.settings!.codec, VideoCodec.hevc);
    expect(det.settings!.width, 1920);
    expect(det.settings!.videoBitrate, 16000000);

    final gal = states[4] as ExportCompletedWhileDetached;
    expect(gal.result, isNull, reason: 'only the gallery copy exists');
    expect(gal.savedToGallery, isTrue);
    expect(gal.settings, isNull);
  });

  test('start sends plan bytes, settings, title and whenDetached; resume and consumeJobRecord reach native', () async {
    host
      ..on('ExportHostApi', 'start', (_) => 'job-1')
      ..on('ExportHostApi', 'resume', (args) => args[0])
      ..on('ExportHostApi', 'consumeJobRecord', (_) => null);
    final settings = encodeSettingsToMsg(const EncodeSettings(width: 1280, height: 720, fps: 25, videoBitrate: 8000000));
    final id = await channels.invoke(() => channels.export.start(
          Uint8List.fromList('{"v":1}'.codeUnits),
          settings,
          '/c/danaview/editor/work/export-1.mp4',
          'My project',
          detachedHandoffToMsg(ExportDetachedHandoff.keepForLater),
        ));
    expect(id, 'job-1');
    final sent = host.args['ExportHostApi.start']!.single;
    expect(String.fromCharCodes(sent[0]! as Uint8List), '{"v":1}');
    expect(encodeSettingsFromMsg(sent[1]! as EncodeSettingsMsg).fps, 25);
    expect(sent[3], 'My project');
    expect(sent[4], DetachedHandoffMsg.keepForLater);
    expect(await channels.invoke(() => channels.export.resume('job-1')), 'job-1');
    await channels.invoke(() => channels.export.consumeJobRecord('det'));
    expect(host.args['ExportHostApi.consumeJobRecord']!.single, ['det']);
  });

  test('job results and export progress arrive typed through the event channel', () async {
    final events = host.installEvents();
    await channels.ensureInitialized();
    expect(host.listenCount, 1);

    final waveform = <EngineEventMsg>[];
    final speech = <EngineEventMsg>[];
    final export = <EngineEventMsg>[];
    channels.router.job('w').listen(waveform.add);
    channels.router.job('sp').listen(speech.add);
    channels.router.job('ex').listen(export.add);

    events
      ..add(EngineEventMsg(
        kind: EngineEventKindMsg.jobDone,
        jobId: 'w',
        jobDone: JobResultMsg(
          kind: JobKindMsg.waveform,
          peaks: WaveformPeaksMsg(minMax: Uint8List.fromList([0x80, 0x7f, 0xff, 0x01]), durationUs: 10000, pairsPerSecond: 200),
        ),
      ))
      ..add(EngineEventMsg(
        kind: EngineEventKindMsg.jobDone,
        jobId: 'sp',
        jobDone: JobResultMsg(
          kind: JobKindMsg.speechAudio,
          speech: ExtractedSpeechAudioMsg(
            path: '/s/danaview/speech/work/a.wav',
            frames: 160000,
            durationUs: 10000000,
            sourceChannels: 6,
            sourceSampleRate: 48000,
            codec: 'aac',
          ),
        ),
      ))
      ..add(EngineEventMsg(
        kind: EngineEventKindMsg.exportProgress,
        jobId: 'ex',
        exportProgress: ExportProgressMsg(
          phase: ExportPhaseMsg.rendering,
          fraction: 0.5,
          framesDone: 120,
          framesTotal: 240,
          backgrounded: true,
          pausedInBackground: true,
          warnings: [ExportWarningMsg(code: 'backgroundPauses', message: '')],
        ),
      ))
      ..add(EngineEventMsg(
        kind: EngineEventKindMsg.jobDone,
        jobId: 'ex',
        jobDone: JobResultMsg(
          kind: JobKindMsg.export,
          exportResult: ExportResultMsg(
            path: '/c/danaview/editor/work/export-ex.mp4',
            bytes: 9,
            durationUs: 8000000,
            videoEncoderName: 'c2.qti.avc.encoder',
            hardwareEncoder: true,
          ),
        ),
      ));
    await pumpEventQueue();

    final peaks = waveformPeaksFromMsg(waveform.single.jobDone!.peaks!);
    expect(peaks.minMax, [-128, 127, -1, 1]);
    expect(peaks.pairsPerSecond, 200);

    final wav = extractedSpeechAudioFromMsg(speech.single.jobDone!.speech!);
    expect(wav.frames, 160000);
    expect(wav.sourceChannels, 6);

    final progress = exportProgressFromMsg(export.first.exportProgress!);
    expect(progress.phase, ExportPhase.rendering);
    expect(progress.framesDone, 120);
    expect(progress.pausedInBackground, isTrue);
    expect(progress.warnings.single.code, 'backgroundPauses');
    final result = exportResultFromMsg(export.last.jobDone!.exportResult!);
    expect(result.videoEncoderName, 'c2.qti.avc.encoder');
    expect(result.duration, 8000000);
  });
}
