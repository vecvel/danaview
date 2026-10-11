// OWNER: ENG-02
//
// A mocked native preview for MobilePreviewSession tests (ARCH §12.2, §12.6): answers every
// `PreviewHostApi` channel on the test messenger with the real Pigeon codec, backed by the API's
// `FakePreviewSession` (which implements the §12.2 normative semantics). Plans, patches and
// transients are decoded from the UTF-8 JSON bytes exactly as a native engine would; fake
// `EngineFailure`s become native `FlutterError`s (`PlatformException(code: EngineErrorCode.name)`);
// the fake's clock and lifecycle events are pushed through the real EngineEventsApi event channel.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:danaview_editor_core/model.dart' show ItemId, TimeRange;
import 'package:danaview_editor_engine/src/pigeon/conversions.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../glue/support/mock_engine_host.dart';

const String _api = 'PreviewHostApi';

/// Native preview sessions backed by [FakePreviewSession]s.
final class NativePreviewDouble {
  /// Installs the handlers on [host]; events go to [events] (from `host.installEvents()`).
  NativePreviewDouble(this.host, this.events) {
    host
      ..acceptInitialize()
      ..on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(fakeDefaultCapabilities))
      ..on(_api, 'open', (args) {
        final msg = args[0]! as PreviewConfigMsg;
        final id = 'ps${++_opened}';
        final fake = FakePreviewSession(
          textureId: 100 + _opened,
          config: PreviewConfig(
            canvasWidth: msg.canvasWidth,
            canvasHeight: msg.canvasHeight,
            fps: msg.fps,
            quality: previewQualityFromMsg(msg.quality),
            useProxies: msg.useProxies,
          ),
        );
        sessions[id] = fake;
        _subs.add(fake.clock.listen((c) => events.add(EngineEventMsg(
              kind: EngineEventKindMsg.clock,
              sessionId: id,
              clock: ClockMsg(timeUs: c.time, playing: c.playing, rate: c.rate, seq: c.seq),
            ))));
        _subs.add(fake.events.listen((e) => events.add(EngineEventMsg(kind: EngineEventKindMsg.preview, sessionId: id, previewEvent: _eventMsg(e, fake)))));
        return PreviewOpenedMsg(sessionId: id, textureId: fake.textureId);
      })
      ..on(_api, 'setPlan', (a) async => _ack(await _guard(() => _s(a).setPlan(PlanTransport.decodePlan(a[1]! as Uint8List)))))
      ..on(_api, 'applyPatch', (a) async => _ack(await _guard(() => _s(a).applyPatch(PlanTransport.decodePatch(a[1]! as Uint8List)))))
      ..on(_api, 'setTransient', (a) {
        _s(a).setTransient(ItemId(a[1]! as String), PlanTransport.decodeTransient(a[2]! as Uint8List));
        return null;
      })
      ..on(_api, 'clearTransient', (a) {
        _s(a).clearTransient(ItemId(a[1]! as String));
        return null;
      })
      ..on(_api, 'play', (a) async {
        final loop = a[1] as LoopMsg?;
        final s = _s(a);
        await s.play(loop: loop == null ? null : TimeRange(loop.startUs, loop.endUs));
        return s.seq;
      })
      ..on(_api, 'pause', (a) async {
        final s = _s(a);
        await s.pause();
        return s.seq;
      })
      ..on(_api, 'seek', (a) async {
        final ack = await _s(a).seek(a[1]! as int, kind: (a[2]! as bool) ? SeekKind.exact : SeekKind.scrub);
        return SeekAckMsg(requestedUs: ack.requested, displayedFrameTimeUs: ack.displayedFrameTime, displayedFrame: ack.displayedFrame, seq: ack.seq);
      })
      ..on(_api, 'setQuality', (a) => _s(a).setQuality(previewQualityFromMsg(a[1]! as PreviewQualityMsg)))
      ..on(_api, 'setUseProxies', (a) => _s(a).setUseProxies(a[1]! as bool))
      ..on(_api, 'setEditingMode', (a) {
        final m = a[1]! as EditingModeMsg;
        return _s(a).setEditingMode(switch (m.kind) {
          EditingModeKindMsg.normal => PreviewEditingMode.normal,
          EditingModeKindMsg.cropSource => CropSourceMode(ItemId(m.itemId!)),
          EditingModeKindMsg.matte => MatteMode(ItemId(m.itemId!)),
        });
      })
      ..on(_api, 'showSourceFrame', (a) => _s(a).showSourceFrame(mediaFromMsg(a[1]! as ResolvedMediaMsg), a[2]! as int))
      ..on(_api, 'sampleColor', (a) async {
        final c = await _s(a).sampleColor(ItemId(a[1]! as String), Offset(a[2]! as double, a[3]! as double));
        return c == null ? null : ColorMsg(red: c.r, green: c.g, blue: c.b, alpha: c.a);
      })
      ..on(_api, 'renderLookStills', (a) => _s(a).renderLookStills(ItemId(a[1]! as String), const [], heightPx: a[3]! as int).then((_) => [
            for (final _ in a[2]! as List<Object?>) Uint8List.fromList([0xFF, 0xD8])
          ]))
      ..on(_api, 'refresh', (a) => _s(a).refresh())
      ..on(_api, 'debugCaptureFrame', (a) => _s(a).debugCaptureFrame())
      ..on(_api, 'dispose', (a) async {
        disposed.add(a[0]! as String);
        await sessions[a[0]]?.dispose();
        return null;
      });
  }

  /// The mocked host.
  final MockEngineHost host;

  /// The event channel sink.
  final StreamController<Object?> events;

  /// Fake sessions by native session id.
  final Map<String, FakePreviewSession> sessions = {};

  /// Session ids `dispose` was called for, in order.
  final List<String> disposed = [];

  int _opened = 0;
  final List<StreamSubscription<Object?>> _subs = [];

  FakePreviewSession _s(List<Object?> args) {
    final s = sessions[args[0]];
    if (s == null) throw PlatformException(code: EngineErrorCode.internal.name, message: 'unknown session');
    return s;
  }

  static PlanAckMsg _ack(PlanAck a) => PlanAckMsg(rev: a.rev, structural: a.structural, applyMs: a.applyMs);

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on EngineFailure catch (f) {
      throw PlatformException(code: f.code.name, message: f.debugDetail, details: {'retryable': f.retryable});
    }
  }

  static PreviewEventMsg _eventMsg(PreviewEvent e, FakePreviewSession s) {
    final size = s.frameSize.value;
    return switch (e) {
      PreviewFirstFrame() => PreviewEventMsg(kind: PreviewEventKindMsg.firstFrame, width: size?.width.round(), height: size?.height.round()),
      PreviewStalled() => PreviewEventMsg(kind: PreviewEventKindMsg.stalled),
      PreviewRecovered() => PreviewEventMsg(kind: PreviewEventKindMsg.recovered),
      PreviewDegraded(:final quality) => PreviewEventMsg(kind: PreviewEventKindMsg.degraded, quality: previewQualityToMsg(quality)),
      PreviewSurfaceLost() => PreviewEventMsg(kind: PreviewEventKindMsg.surfaceLost),
      PreviewFailedEvent(:final failure) => PreviewEventMsg(
          kind: PreviewEventKindMsg.failed,
          failure: FailureMsg(code: failure.code.name, message: failure.debugDetail, retryable: failure.retryable),
        ),
    };
  }

  /// Stops forwarding fake events.
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
  }
}

/// An [EditorEngine] whose capabilities and preview are [mobile] (over mocked channels) and whose
/// jobs and export are [fake] (ENG-03/ENG-04 own their mocked-channel kits): lets the API-01
/// contract kit exercise MobilePreviewSession end to end.
final class PreviewOverMobileEngine implements EditorEngine {
  /// Creates the engine.
  PreviewOverMobileEngine(this.mobile, this.fake);

  /// The engine under test.
  final EditorEngine mobile;

  /// Stand-in for the non-preview services.
  final FakeEditorEngine fake;

  @override
  Future<EditorCapabilities> capabilities() => mobile.capabilities();

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => mobile.openPreview(config);

  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => fake.compatibility(pathOrUri);

  @override
  Future<MediaProbe> probe(EngineMedia media) => fake.probe(media);

  @override
  ThumbnailSource get thumbnails => fake.thumbnails;

  @override
  WaveformSource get waveforms => fake.waveforms;

  @override
  MediaJobs get jobs => fake.jobs;

  @override
  ExportService get exporter => fake.exporter;

  @override
  VoiceRecorder? get voiceRecorder => fake.voiceRecorder;

  @override
  MediaPicker get picker => fake.picker;

  @override
  FileHandoff get files => fake.files;

  @override
  MediaAccess get access => fake.access;

  @override
  BackgroundWorkGuard get background => fake.background;

  @override
  ExternalDropTarget get drops => fake.drops;

  @override
  Future<int> freeBytes(String path) => fake.freeBytes(path);

  @override
  Stream<EngineSignal> get signals => fake.signals;

  @override
  Future<void> trimCaches(CacheTrimLevel level) => fake.trimCaches(level);
}
