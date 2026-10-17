// OWNER: INT-07
//
// The INT-07 engine interface additions over mocked Pigeon channels: `materializePick`
// (PlatformHostApi), the localized export notification texts (`initialize` and `ExportHostApi.start`)
// and the recording state (`RecorderHostApi.isRecording` and the engine-wide `recordingChanged`
// event). Without a native engine every new call fails like the other calls of its service.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show MediaOrigin;
import 'package:danaview_editor_core/store.dart' show OwnershipViolation, PickMaterializer, StoreFailure, StoreFailureKind;
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine/src/mobile_media_access.dart';
import 'package:danaview_editor_engine/src/mobile_recorder.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import 'support/mock_engine_host.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');
const _work = '/c/danaview/editor/work';
const _settings = EncodeSettings(width: 1280, height: 720, fps: 30, videoBitrate: 5000000);

Matcher _kind(MediaAccessFailureKind k) => throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', k));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late StreamController<Object?> events;

  setUp(() {
    host = MockEngineHost();
    events = host.installEvents();
  });
  tearDown(() => host.dispose());

  group('with a native engine', () {
    setUp(() => host.acceptInitialize());

    group('materializePick', () {
      test('sends the URI and the normalized directory and returns the native copy path', () async {
        host.on('PlatformHostApi', 'materializePick', (args) => '${args[1]}/u1/clip.mp4');
        final engine = MobileEditorEngine(config: _config);
        final PickMaterializer m = engine.access.materializePick;
        final path = await m(const PickedMedia(uri: 'content://media/42', displayName: 'clip.mp4'), '$_work/picks/');
        expect(path, '$_work/picks/u1/clip.mp4');
        expect(host.args['PlatformHostApi.materializePick']!.single, ['content://media/42', '$_work/picks']);
      });

      test('a temporary copy under work/ comes back without a native call', () async {
        final engine = MobileEditorEngine(config: _config);
        const pick = PickedMedia(uri: 'file://$_work/drops/u/a.mov', displayName: 'a.mov', origin: MediaOrigin.drop, isTemporaryCopy: true);
        expect(await engine.access.materializePick(pick, '$_work/picks'), '$_work/drops/u/a.mov');
        expect(host.calls, isNot(contains('PlatformHostApi.materializePick')));
      });

      test('a directory outside work/ is refused before native and reported as a violation', () async {
        final violations = <OwnershipViolation>[];
        final engine = MobileEditorEngine(config: _config);
        (engine.access as MobileMediaAccess).onViolation = violations.add;
        const pick = PickedMedia(uri: 'content://media/1', displayName: 'a.mp4');
        expect(() => engine.access.materializePick(pick, '/c/danaview/editor/media'), _kind(MediaAccessFailureKind.outsideEditorRoots));
        expect(() => engine.access.materializePick(pick, '$_work/../media'), _kind(MediaAccessFailureKind.outsideEditorRoots));
        expect(() => engine.access.materializePick(pick, 'work/picks'), _kind(MediaAccessFailureKind.outsideEditorRoots));
        await pumpEventQueue();
        expect(violations, hasLength(3));
        expect(host.calls, isNot(contains('PlatformHostApi.materializePick')));
      });

      test('native failures map like the media access port; diskFull becomes StoreFailure', () async {
        final engine = MobileEditorEngine(config: _config);
        const pick = PickedMedia(uri: 'content://media/1', displayName: 'a.mp4');
        Future<String> run() => engine.access.materializePick(pick, '$_work/picks');
        host.fail('PlatformHostApi', 'materializePick', 'mediaOffline');
        await expectLater(run(), throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.notFound)));
        host.fail('PlatformHostApi', 'materializePick', 'permissionDenied');
        await expectLater(run(), throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.accessLost)));
        host.fail('PlatformHostApi', 'materializePick', 'notSupportedOnDevice');
        await expectLater(run(), throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.io)));
        host.fail('PlatformHostApi', 'materializePick', 'diskFull');
        await expectLater(run(), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.diskFull)));
      });
    });

    group('export notification texts', () {
      test('initialize carries the config texts', () async {
        host.on('EngineHostApi', 'capabilities', (_) => null);
        const config = EditorEngineConfig(
          cacheRoot: '/c/danaview/editor',
          supportRoot: '/s/danaview/editor',
          exportNotificationTexts: ExportNotificationTexts(cancel: 'Abbrechen', exportingProgress: 'Export · {percent} %'),
        );
        final engine = MobileEditorEngine(config: config);
        await engine.channels.ensureInitialized();
        final msg = host.args['EngineHostApi.initialize']!.single.single! as EngineConfigMsg;
        expect(msg.cacheRoot, '/c/danaview/editor');
        expect(msg.exportTexts!.cancel, 'Abbrechen');
        expect(msg.exportTexts!.exportingProgress, 'Export · {percent} %');
        expect(msg.exportTexts!.savedToGallery, 'Saved to Gallery');
      });

      test('start passes per-job texts, or null to keep the engine-wide ones', () async {
        host.on('ExportHostApi', 'start', (_) => 'job-${host.args['ExportHostApi.start']!.length}');
        final engine = MobileEditorEngine(config: _config);
        await engine.exporter.start(contractKitPlan(), _settings, outputPath: '$_work/export-1.mp4', title: 'A');
        await engine.exporter.start(contractKitPlan(), _settings,
            outputPath: '$_work/export-2.mp4', title: 'B', notificationTexts: const ExportNotificationTexts(exporting: 'Exportation'));
        final sent = host.args['ExportHostApi.start']!;
        expect(sent[0][5], isNull);
        final texts = sent[1][5]! as ExportNotificationTextsMsg;
        expect(texts.exporting, 'Exportation');
        expect(texts.more, '+{count} more');
        expect(texts.doneChannelName, 'Finished exports');
      });
    });

    group('recording state', () {
      test('isRecording asks native', () async {
        var recording = false;
        host.on('RecorderHostApi', 'isRecording', (_) => recording);
        final recorder = MobileVoiceRecorder(MobileEditorEngine(config: _config).channels);
        expect(await recorder.isRecording(), isFalse);
        recording = true;
        expect(await recorder.isRecording(), isTrue);
      });

      test('recordingChanged follows the engine-wide recordingChanged events', () async {
        final engine = MobileEditorEngine(config: _config);
        final recorder = MobileVoiceRecorder(engine.channels);
        final changes = <bool>[];
        recorder.recordingChanged.listen(changes.add);
        await engine.channels.ensureInitialized();
        events
          ..add(EngineEventMsg(kind: EngineEventKindMsg.recordingChanged, recording: true))
          ..add(EngineEventMsg(kind: EngineEventKindMsg.recordingChanged)) // no payload: dropped
          ..add(EngineEventMsg(kind: EngineEventKindMsg.recordingChanged, recording: false));
        await pumpEventQueue();
        expect(changes, [true, false]);
      });
    });
  });

  group('without a native engine', () {
    test('the new calls fail like the rest of their service', () async {
      final engine = MobileEditorEngine(config: _config);
      final recorder = MobileVoiceRecorder(engine.channels);
      await expectLater(recorder.isRecording(), throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.notSupportedOnDevice)));
      await expectLater(
        engine.access.materializePick(const PickedMedia(uri: 'content://m/1', displayName: 'a'), '$_work/picks'),
        throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.io)),
      );
      await expectLater(
        engine.exporter.start(contractKitPlan(), _settings,
            outputPath: '$_work/export-1.mp4', title: 'A', notificationTexts: const ExportNotificationTexts()),
        throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.notSupportedOnDevice)),
      );
    });
  });
}
