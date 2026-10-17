// OWNER: INT-07
//
// The INT-07 additions on the API-01 fake and contract kit: materializePick (the core
// PickMaterializer), localized export notification texts (engine-wide config and per start), and
// the recording state with the preview mute while recording.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show MediaOrigin;
import 'package:danaview_editor_core/store.dart' show PickMaterializer, StoreFailure, StoreFailureKind;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

const _work = '/fake/cache/danaview/editor/work';

IntegrationContractProbe _probe(FakeEditorEngine engine) => IntegrationContractProbe(
      workDirectory: _work,
      temporaryCopyPath: '$_work/drops/u1/clip.mp4',
      recordingOutputPath: '/fake/support/danaview/editor/projects/p/assets/recordings/kit.wav',
      previewMuted: (s) => (s as FakePreviewSession).audioMuted,
    );

/// A recorder that never reports its state (a broken engine for the kit).
final class _SilentRecorder implements VoiceRecorder {
  _SilentRecorder(this.inner);
  final FakeVoiceRecorder inner;

  @override
  Future<bool> isRecording() async => false;

  @override
  Stream<bool> get recordingChanged => const Stream.empty();

  @override
  Future<RecordingSession> start({required String outputPath}) => inner.start(outputPath: outputPath);

  @override
  Future<MicPermission> permission() => inner.permission();

  @override
  Future<MicPermission> requestPermission() => inner.requestPermission();

  @override
  Future<void> openSystemSettings() => inner.openSystemSettings();
}

/// The fake with a broken recorder.
final class _BrokenEngine implements EditorEngine {
  _BrokenEngine(this.inner);
  final FakeEditorEngine inner;

  @override
  VoiceRecorder? get voiceRecorder => _SilentRecorder(inner.recorder);
  @override
  Future<EditorCapabilities> capabilities() => inner.capabilities();
  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => inner.compatibility(pathOrUri);
  @override
  Future<MediaProbe> probe(EngineMedia media) => inner.probe(media);
  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => inner.openPreview(config);
  @override
  ThumbnailSource get thumbnails => inner.thumbnails;
  @override
  WaveformSource get waveforms => inner.waveforms;
  @override
  MediaJobs get jobs => inner.jobs;
  @override
  ExportService get exporter => inner.exporter;
  @override
  MediaPicker get picker => inner.picker;
  @override
  FileHandoff get files => inner.files;
  @override
  MediaAccess get access => inner.access;
  @override
  BackgroundWorkGuard get background => inner.background;
  @override
  ExternalDropTarget get drops => inner.drops;
  @override
  Future<int> freeBytes(String path) => inner.freeBytes(path);
  @override
  Stream<EngineSignal> get signals => inner.signals;
  @override
  Future<void> trimCaches(CacheTrimLevel level) => inner.trimCaches(level);
}

void main() {
  group('contract kit', () {
    test('FakeEditorEngine passes the INT-07 cases', () async {
      final engine = FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(voiceRecording: true));
      expect(await checkEngineContract(engine, integration: _probe(engine)), isEmpty);
    });

    test('the kit catches a recorder that never reports its state', () async {
      final engine = FakeEditorEngine();
      final v = await checkEngineContract(_BrokenEngine(engine), integration: _probe(engine));
      expect(v, containsAll(<String>[
        'isRecording() must be true while a recording captures',
        'recordingChanged must emit true when a recording starts',
      ]));
    });

    test('the kit catches a preview that stays audible while recording', () async {
      final engine = FakeEditorEngine();
      final v = await checkEngineContract(engine,
          integration: IntegrationContractProbe(
            recordingOutputPath: '/fake/support/danaview/editor/kit.wav',
            previewMuted: (_) => false,
          ));
      expect(v, ['preview sessions must be muted while a recording captures']);
    });
  });

  group('materializePick', () {
    test('copies a content:// pick into a work/ directory and records it', () async {
      final engine = FakeEditorEngine();
      const pick = PickedMedia(uri: 'content://media/42', displayName: 'Beach day.mp4');
      final path = await engine.access.materializePick(pick, '$_work/picks/a');
      expect(path, '$_work/picks/a/m0/Beach day.mp4');
      expect(engine.access.materialized, [path]);
    });

    test('can be passed as the core PickMaterializer', () async {
      final engine = FakeEditorEngine();
      final PickMaterializer m = engine.access.materializePick;
      expect(await m(const PickedMedia(uri: 'content://x/1', displayName: 'a/b.mp4'), '$_work/picks/b/'), '$_work/picks/b/m0/a_b.mp4');
    });

    test('returns a temporary copy under work/ as is', () async {
      final engine = FakeEditorEngine();
      const pick = PickedMedia(uri: '$_work/drops/u/a.mov', displayName: 'a.mov', origin: MediaOrigin.drop, isTemporaryCopy: true);
      expect(await engine.access.materializePick(pick, '$_work/picks/c'), '$_work/drops/u/a.mov');
      expect(engine.access.materialized, isEmpty);
    });

    test('fails like the media access port: outside work/, missing picks, unknown schemes, disk full', () async {
      final engine = FakeEditorEngine();
      const pick = PickedMedia(uri: 'content://media/1', displayName: 'a.mp4');
      Matcher kind(MediaAccessFailureKind k) => throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', k));
      expect(() => engine.access.materializePick(pick, '/fake/cache/danaview/editor/media'), kind(MediaAccessFailureKind.outsideEditorRoots));
      expect(() => engine.access.materializePick(pick, '$_work/../media'), kind(MediaAccessFailureKind.outsideEditorRoots));
      engine.access.missing.add('content://media/1');
      expect(() => engine.access.materializePick(pick, '$_work/picks/d'), kind(MediaAccessFailureKind.notFound));
      expect(() => engine.access.materializePick(const PickedMedia(uri: 'ph://asset/1', displayName: 'x'), '$_work/picks/d'),
          kind(MediaAccessFailureKind.io));
      engine.access.materializeFailure = const StoreFailure(StoreFailureKind.diskFull, 'x');
      expect(() => engine.access.materializePick(const PickedMedia(uri: 'content://m/2', displayName: 'x'), '$_work/picks/e'),
          throwsA(isA<StoreFailure>()));
    });
  });

  group('export notification texts', () {
    test('defaults are the engine English texts and take part in equality', () {
      const t = ExportNotificationTexts();
      expect(t.all, hasLength(14));
      expect(t.exportingProgress, contains('{percent}'));
      expect(t.workingProgress, contains('{percent}'));
      expect(t.more, contains('{count}'));
      expect(const ExportNotificationTexts(cancel: 'Abbrechen'), isNot(t));
      expect(const ExportNotificationTexts(cancel: 'Abbrechen'), const ExportNotificationTexts(cancel: 'Abbrechen'));
      expect(const ExportNotificationTexts(cancel: 'Abbrechen').hashCode, const ExportNotificationTexts(cancel: 'Abbrechen').hashCode);
    });

    test('the engine config carries them', () {
      const a = EditorEngineConfig(cacheRoot: 'c', supportRoot: 's');
      const b = EditorEngineConfig(cacheRoot: 'c', supportRoot: 's', exportNotificationTexts: ExportNotificationTexts(cancel: 'Annuler'));
      expect(a.exportNotificationTexts, const ExportNotificationTexts());
      expect(a, isNot(b));
      expect(b.exportNotificationTexts.cancel, 'Annuler');
    });

    test('the fake records the texts of each start', () async {
      final engine = FakeEditorEngine();
      const settings = EncodeSettings(width: 1280, height: 720, fps: 30, videoBitrate: 5000000);
      await engine.exporter.start(contractKitPlan(), settings, outputPath: '$_work/export-1.mp4', title: 'A');
      await engine.exporter.start(contractKitPlan(), settings,
          outputPath: '$_work/export-2.mp4', title: 'B', notificationTexts: const ExportNotificationTexts(exporting: 'Exportation'));
      expect(engine.exporter.notificationTexts, [null, const ExportNotificationTexts(exporting: 'Exportation')]);
    });
  });

  group('recording state', () {
    test('isRecording and recordingChanged follow start, stop, cancel and interruptions', () async {
      final engine = FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(voiceRecording: true));
      final rec = engine.voiceRecorder!;
      final changes = <bool>[];
      rec.recordingChanged.listen(changes.add);
      expect(await rec.isRecording(), isFalse);

      final a = await rec.start(outputPath: '/fake/support/danaview/editor/a.wav');
      expect(await rec.isRecording(), isTrue);
      expect(() => rec.start(outputPath: '/fake/support/danaview/editor/b.wav'),
          throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.busy)));
      await a.stop();
      expect(await rec.isRecording(), isFalse);

      final b = await rec.start(outputPath: '/fake/support/danaview/editor/b.wav') as FakeRecordingSession;
      b.interrupt(RecordingInterruption.routeChanged);
      expect(await rec.isRecording(), isFalse);
      await b.stop(); // after an interruption: no second change

      final c = await rec.start(outputPath: '/fake/support/danaview/editor/c.wav');
      await c.cancel();
      expect(changes, [true, false, true, false, true, false]);
      expect(engine.calls.where((c) => c == 'recorder.isRecording'), hasLength(4));
    });

    test('preview sessions are muted while a recording captures, including ones opened meanwhile', () async {
      final engine = FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(voiceRecording: true));
      const config = PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30);
      final before = await engine.openPreview(config) as FakePreviewSession;
      expect(before.audioMuted, isFalse);
      final rec = await engine.voiceRecorder!.start(outputPath: '/fake/support/danaview/editor/a.wav');
      final during = await engine.openPreview(config) as FakePreviewSession;
      expect([before.audioMuted, during.audioMuted], [true, true]);
      await rec.stop();
      expect([before.audioMuted, during.audioMuted], [false, false]);
    });
  });
}
