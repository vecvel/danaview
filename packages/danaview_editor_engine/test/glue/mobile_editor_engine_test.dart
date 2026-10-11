// OWNER: ENG-01
//
// MobileEditorEngine over mocked Pigeon channels (ARCH §12.1, §12.5, §12.6): the M0 placeholder
// plugin (no host API) reports engine_not_available without throwing PlatformExceptions;
// initialize runs once with the Dart roots; capabilities, compatibility, probe, freeBytes,
// trimCaches, openPreview and signals map to and from the Pigeon messages.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show ColorTransfer, FrameRate, MediaKind;
import 'package:danaview_editor_engine/src/mobile_export.dart';
import 'package:danaview_editor_engine/src/mobile_jobs.dart';
import 'package:danaview_editor_engine/src/mobile_media_access.dart';
import 'package:danaview_editor_engine/src/mobile_platform_services.dart';
import 'package:danaview_editor_engine/src/mobile_preview_session.dart';
import 'package:danaview_editor_engine/src/mobile_recorder.dart';
import 'package:danaview_editor_engine/src/pigeon/conversions.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/mock_engine_host.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');
const _media = EngineMedia(uri: 'file:///d/clip.mov', fingerprint: 'qh_1');

const _deviceCaps = EditorCapabilities(
  supported: true,
  tier: DeviceTier.minimal,
  lowMemoryDevice: true,
  h264Encode: true,
  hevcEncode: true,
  hardwareH264: true,
  hardwareHevc: true,
  movContainer: true,
  maxExportSize: Size(1920, 1080),
  maxFpsByHeight: {720: 60, 1080: 30},
  maxConcurrentVideoLayers: 2,
  maxVisualSequences: 3,
  maxTextureSize: 8192,
  maxPreviewLongSide: 640,
  backgroundKind: BackgroundExportKind.paused,
  backgroundGpu: false,
  voiceRecording: true,
  proxiesRecommended: true,
  holdFrame: true,
  fpsUpconversion: false,
  externalDrop: true,
  minSpeed: 0.1,
  maxSpeed: 10,
  maxAudioSpeed: 4,
  maxLutSize: 33,
  planVersions: [1],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late StreamController<Object?> events;

  setUp(() {
    host = MockEngineHost();
    events = host.installEvents();
  });
  tearDown(() => host.dispose());

  group('M0 placeholder plugin (no host API registered)', () {
    test('capabilities report engine_not_available and are cached', () async {
      final engine = MobileEditorEngine(config: _config);
      final caps = await engine.capabilities();
      expect(caps.supported, isFalse);
      expect(caps.unsupportedReason, UnsupportedReasons.engineNotAvailable);
      expect(identical(await engine.capabilities(), caps), isTrue);
      expect(engine.cachedCapabilities, same(caps));
      expect(engine.voiceRecorder, isNull);
      expect(engine.channels.unavailable?.code, EngineErrorCode.notSupportedOnDevice);
    });

    test('compatibility is NotEditable(engine_not_available); other calls fail typed; nothing throws PlatformException', () async {
      final engine = MobileEditorEngine(config: _config);
      final compat = await engine.compatibility('file:///d/a.mp4');
      expect(compat, isA<NotEditable>().having((n) => n.code, 'code', UnsupportedReasons.engineNotAvailable));

      final notSupported = throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.notSupportedOnDevice));
      await expectLater(engine.probe(_media), notSupported);
      await expectLater(engine.openPreview(const PreviewConfig(canvasWidth: 16, canvasHeight: 16, fps: 30)), notSupported);
      await expectLater(engine.freeBytes('/c'), notSupported);
      await engine.trimCaches(CacheTrimLevel.memoryPressure);
    });

    test('the event channel is never listened to without a native engine', () async {
      final engine = MobileEditorEngine(config: _config);
      final sub = engine.signals.listen((_) {});
      await engine.capabilities();
      await pumpEventQueue();
      expect(host.listenCount, 0);
      expect(engine.channels.router.isStarted, isFalse);
      await sub.cancel();
    });
  });

  group('with a native engine', () {
    setUp(() => host.acceptInitialize());

    test('initialize sends the Dart roots once, even for concurrent first calls', () async {
      host
        ..on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(_deviceCaps))
        ..on('EngineHostApi', 'compatibility', (_) => CompatibilityMsg(editable: true))
        ..on('EngineHostApi', 'freeBytes', (_) => 1 << 40);
      final engine = MobileEditorEngine(config: _config);
      await Future.wait<Object?>([engine.capabilities(), engine.compatibility('file:///a.mp4'), engine.freeBytes('/c')]);
      expect(host.count('EngineHostApi', 'initialize'), 1);
      final sent = host.args['EngineHostApi.initialize']!.single.single! as EngineConfigMsg;
      expect((sent.cacheRoot, sent.supportRoot), ('/c/danaview/editor', '/s/danaview/editor'));
      expect(engine.channels.router.isStarted, isTrue);
      expect(host.listenCount, 1);
    });

    test('capabilities map every field (minimal tier, maxVisualSequences, maxTextureSize) and are cached', () async {
      host.on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(_deviceCaps));
      final engine = MobileEditorEngine(config: _config);
      expect(engine.voiceRecorder, isNull, reason: 'unknown before capabilities()');
      final caps = await engine.capabilities();
      expect(caps, _deviceCaps);
      expect(caps.tier, DeviceTier.minimal);
      expect(caps.maxVisualSequences, 3);
      expect(caps.maxTextureSize, 8192);
      await engine.capabilities();
      expect(host.count('EngineHostApi', 'capabilities'), 1);
      expect(engine.voiceRecorder, isA<MobileVoiceRecorder>());
    });

    test('an unsupported device keeps its native reason; voiceRecorder stays null without voiceRecording', () async {
      host.on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(EditorCapabilities.unsupported(UnsupportedReasons.gles3Missing)));
      final engine = MobileEditorEngine(config: _config);
      final caps = await engine.capabilities();
      expect(caps.supported, isFalse);
      expect(caps.unsupportedReason, UnsupportedReasons.gles3Missing);
      expect(engine.voiceRecorder, isNull);
    });

    test('a failed initialize surfaces typed and is retried by the next call', () async {
      var attempts = 0;
      host
        ..on('EngineHostApi', 'initialize', (_) {
          if (attempts++ == 0) throw PlatformException(code: 'io', message: 'mkdir failed');
          return null;
        })
        ..on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(_deviceCaps));
      final engine = MobileEditorEngine(config: _config);
      await expectLater(engine.capabilities(), throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.io)));
      expect(engine.cachedCapabilities, isNull);
      expect((await engine.capabilities()).supported, isTrue);
      expect(attempts, 2);
    });

    test('compatibility maps Editable and NotEditable(code, message)', () async {
      host.on(
          'EngineHostApi',
          'compatibility',
          (args) => args.single == 'file:///ok.mp4'
              ? CompatibilityMsg(editable: true)
              : CompatibilityMsg(editable: false, code: 'container_unsupported_ios', message: 'Matroska'));
      final engine = MobileEditorEngine(config: _config);
      expect(await engine.compatibility('file:///ok.mp4'), isA<Editable>());
      final no = await engine.compatibility('file:///x.mkv');
      expect(no,
          isA<NotEditable>().having((n) => n.code, 'code', 'container_unsupported_ios').having((n) => n.message, 'message', 'Matroska'));
    });

    test('probe sends the resolved media and maps the probe', () async {
      host.on(
        'EngineHostApi',
        'probe',
        (_) => ProbeMsg(
          kind: MediaKindMsg.video,
          durationUs: 8000000,
          hasVideo: true,
          hasAudio: true,
          width: 1080,
          height: 1920,
          rotation: 90,
          nominalFrameRate: 30,
          nominalFps: 29.97,
          variableFrameRate: false,
          container: 'mov',
          videoCodec: 'hevc',
          audioCodec: 'aac',
          audioStreams: 1,
          channels: 2,
          sampleRate: 48000,
          bitDepth: 10,
          transfer: ColorTransferMsg.hlg,
          sizeBytes: 4096,
          editable: true,
          issues: ['hdr_tone_mapped'],
        ),
      );
      final engine = MobileEditorEngine(config: _config);
      final probe = await engine.probe(_media.copyWith(isProxy: true));
      final sent = host.args['EngineHostApi.probe']!.single.single! as ResolvedMediaMsg;
      expect((sent.uri, sent.fingerprint, sent.isProxy), ('file:///d/clip.mov', 'qh_1', true));
      expect(probe.kind, MediaKind.video);
      expect(probe.duration, 8000000);
      expect(probe.rotation, 90);
      expect(probe.nominalFrameRate, FrameRate.fps30);
      expect(probe.transfer, ColorTransfer.hlg);
      expect(probe.bitDepth, 10);
      expect(probe.issues, ['hdr_tone_mapped']);
    });

    test('freeBytes and trimCaches reach native; trimCaches surfaces real failures', () async {
      host
        ..on('EngineHostApi', 'freeBytes', (args) => args.single == '/c' ? 123 : 0)
        ..on('EngineHostApi', 'trimCaches', (_) => null);
      final engine = MobileEditorEngine(config: _config);
      expect(await engine.freeBytes('/c'), 123);
      await engine.trimCaches(CacheTrimLevel.clearAll);
      expect(host.args['EngineHostApi.trimCaches']!.single, [CacheTrimLevelMsg.clearAll]);

      host.fail('EngineHostApi', 'trimCaches', 'busy');
      await expectLater(
          engine.trimCaches(CacheTrimLevel.clearAll), throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.busy)));
    });

    test('openPreview sends the config and wraps the native session', () async {
      host.on('PreviewHostApi', 'open', (_) => PreviewOpenedMsg(sessionId: 'p1', textureId: 7));
      final engine = MobileEditorEngine(config: _config);
      final session = await engine.openPreview(
        const PreviewConfig(canvasWidth: 1080, canvasHeight: 1920, fps: 30, quality: PreviewQuality.half, useProxies: false),
      );
      expect(session, isA<MobilePreviewSession>());
      final sent = host.args['PreviewHostApi.open']!.single.single! as PreviewConfigMsg;
      expect(
          (sent.canvasWidth, sent.canvasHeight, sent.fps, sent.quality, sent.useProxies), (1080, 1920, 30, PreviewQualityMsg.half, false));
    });

    test('openPreview failures are typed (planInvalid, gpuUnavailable)', () async {
      host.fail('PreviewHostApi', 'open', 'gpuUnavailable', details: {'retryable': true});
      final engine = MobileEditorEngine(config: _config);
      await expectLater(
        engine.openPreview(const PreviewConfig(canvasWidth: 16, canvasHeight: 16, fps: 30)),
        throwsA(
            isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.gpuUnavailable).having((f) => f.retryable, 'retryable', true)),
      );
    });

    test('signals arrive from the event channel (memory warning, thermal); malformed ones are dropped', () async {
      host.on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(_deviceCaps));
      final engine = MobileEditorEngine(config: _config);
      final got = <EngineSignal>[];
      engine.signals.listen(got.add);
      await engine.capabilities();
      events
        ..add(EngineEventMsg(kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.memoryWarning)))
        ..add(EngineEventMsg(kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.thermal)))
        ..add(EngineEventMsg(
            kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.thermal, thermalLevel: ThermalLevelMsg.serious)));
      await pumpEventQueue();
      expect(got, hasLength(2));
      expect(got[0], isA<MemoryWarningSignal>());
      expect(got[1], isA<ThermalSignal>().having((s) => s.level, 'level', ThermalLevel.serious));
    });

    test('preview events for a session are demultiplexed through the real event channel', () async {
      final engine = MobileEditorEngine(config: _config);
      await engine.channels.ensureInitialized();
      final got = <EngineEventMsg>[];
      engine.channels.router.session('p1').listen(got.add);
      events
        ..add(EngineEventMsg(
            kind: EngineEventKindMsg.preview,
            sessionId: 'p1',
            previewEvent: PreviewEventMsg(kind: PreviewEventKindMsg.firstFrame, width: 540, height: 960)))
        ..add(EngineEventMsg(
            kind: EngineEventKindMsg.preview, sessionId: 'p2', previewEvent: PreviewEventMsg(kind: PreviewEventKindMsg.stalled)))
        ..add(EngineEventMsg(
            kind: EngineEventKindMsg.preview,
            sessionId: 'p1',
            previewEvent: PreviewEventMsg(
                kind: PreviewEventKindMsg.failed,
                failure: FailureMsg(code: 'decoderInitFailed', message: '', itemId: 'it_1', retryable: true))));
      await pumpEventQueue();
      expect(got, hasLength(2));
      expect(previewEventFromMsg(got[0].previewEvent!), isA<PreviewFirstFrame>());
      expect(frameSizeFromMsg(got[0].previewEvent!), const Size(540, 960));
      final failed = previewEventFromMsg(got[1].previewEvent!)! as PreviewFailedEvent;
      expect(failed.failure.code, EngineErrorCode.decoderInitFailed);
      expect(failed.failure.itemId, 'it_1');
    });
  });

  test('services are the mobile_* implementations (D-33 placeholders until ENG-02/03/04)', () {
    final engine = MobileEditorEngine(config: _config);
    expect(engine.thumbnails, isA<MobileThumbnailSource>());
    expect(engine.waveforms, isA<MobileWaveformSource>());
    expect(engine.jobs, isA<MobileMediaJobs>());
    expect(engine.exporter, isA<MobileExportService>());
    expect(engine.picker, isA<MobileMediaPicker>());
    expect(engine.files, isA<MobileFileHandoff>());
    expect(engine.access, isA<MobileMediaAccess>());
    expect(engine.background, isA<MobileBackgroundWorkGuard>());
    expect(engine.drops, isA<MobileExternalDropTarget>());
    expect(identical(engine.jobs, engine.jobs), isTrue);
    expect(engine.config, _config);
  });
}
