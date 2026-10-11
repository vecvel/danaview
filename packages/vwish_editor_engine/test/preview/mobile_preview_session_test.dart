// OWNER: ENG-02
//
// MobilePreviewSession over mocked Pigeon channels (ARCH §12.2, §12.6, §13): plan transport and
// acks, planOutOfSync for PlanSync, clock seq rules, scrub coalescing (<= 1 in flight, latest
// wins), transient coalescing, events and frame size, the remaining calls, and dispose during
// in-flight calls.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';
import 'package:vwish_editor_engine/src/mobile_preview_session.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_channels.dart';
import 'package:vwish_editor_engine/vwish_editor_engine.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../glue/support/mock_engine_host.dart';
import 'support/native_preview_double.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/vwish/editor', supportRoot: '/s/vwish/editor');
const _preview = PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30);
const _api = 'PreviewHostApi';
const _sid = 'p1';

EngineEventMsg _clock(int seq, {int timeUs = 0, bool playing = false, String session = _sid}) => EngineEventMsg(
      kind: EngineEventKindMsg.clock,
      sessionId: session,
      clock: ClockMsg(timeUs: timeUs, playing: playing, rate: playing ? 1 : 0, seq: seq),
    );

EngineEventMsg _event(PreviewEventMsg e) => EngineEventMsg(kind: EngineEventKindMsg.preview, sessionId: _sid, previewEvent: e);

SeekAckMsg _seekAck(int t, int seq) {
  final k = FrameRate.fps30.frameIndexOf(t);
  return SeekAckMsg(requestedUs: t, displayedFrameTimeUs: FrameRate.fps30.timeOfFrame(k), displayedFrame: k, seq: seq);
}

/// A plan of [n] solid layers (above PlanTransport.isolateThreshold for n > 256).
RenderPlan _bigPlan(int n, {int rev = 1}) {
  final dur = FrameRate.fps30.timeOfFrame(90);
  return RenderPlan(
    rev: rev,
    target: PlanTarget.preview,
    canvas: const PlanCanvas(w: 64, h: 36, fps: 30),
    durUs: dur,
    layers: [
      for (var i = 0; i < n; i++)
        PlanLayer(id: 'it_big${i.toString().padLeft(8, '0')}#tx0', z: 15 + i, t0: 0, t1: dur, kind: PlanLayerKind.solid, color: 0xFF000000 + i),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late StreamController<Object?> events;
  late EngineChannels channels;

  setUp(() async {
    host = MockEngineHost();
    events = host.installEvents();
    host.acceptInitialize();
    channels = EngineChannels(config: _config);
    await channels.ensureInitialized();
  });
  tearDown(() async {
    await channels.dispose();
    host.dispose();
  });

  MobilePreviewSession open({Duration? transientInterval}) =>
      MobilePreviewSession(channels: channels, config: _preview, sessionId: _sid, textureId: 7, transientInterval: transientInterval);

  group('plans and patches', () {
    test('setPlan sends UTF-8 PlanJson bytes and maps the ack', () async {
      host.on(_api, 'setPlan', (a) => PlanAckMsg(rev: PlanTransport.decodePlan(a[1]! as Uint8List).rev, structural: true, applyMs: 12));
      final session = open();
      expect(session.textureId, 7);
      final plan = contractKitPlan(rev: 4);
      final ack = await session.setPlan(plan);
      expect((ack.rev, ack.structural, ack.applyMs), (4, true, 12));
      final sent = host.args['$_api.setPlan']!.single;
      expect(sent[0], _sid);
      expect(sent[1], PlanJson.encodePlanBytes(plan));
      await session.dispose();
    });

    test('a large plan is encoded in an isolate and never overtaken by a later small patch', () async {
      final received = <String>[];
      host
        ..on(_api, 'setPlan', (a) {
          final p = PlanTransport.decodePlan(a[1]! as Uint8List);
          received.add('plan ${p.rev} ${p.layers.length}');
          return PlanAckMsg(rev: p.rev, structural: true, applyMs: 1);
        })
        ..on(_api, 'applyPatch', (a) {
          final p = PlanTransport.decodePatch(a[1]! as Uint8List);
          received.add('patch ${p.from}->${p.to}');
          return PlanAckMsg(rev: p.to, structural: false, applyMs: 1);
        });
      final session = open();
      final big = _bigPlan(PlanTransport.isolateThreshold + 44, rev: 3);
      final plan = session.setPlan(big);
      final patch = session.applyPatch(contractKitPatch(3));
      expect((await plan).rev, 3);
      expect((await patch).rev, 4);
      expect(received, ['plan 3 300', 'patch 3->4']);
      await session.dispose();
    });

    test('native planOutOfSync surfaces as EngineFailure(planOutOfSync); later sends still run', () async {
      host
        ..fail(_api, 'applyPatch', 'planOutOfSync', message: 'from 5 != 1')
        ..on(_api, 'setPlan', (a) => PlanAckMsg(rev: 2, structural: true, applyMs: 3));
      final session = open();
      await expectLater(
        session.applyPatch(RenderPlanPatch(from: 5, to: 6)),
        throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.planOutOfSync)),
      );
      expect((await session.setPlan(contractKitPlan(rev: 2))).rev, 2);
      await session.dispose();
    });

    test('an ack for another revision is planOutOfSync; a malformed ack is internal', () async {
      host
        ..on(_api, 'applyPatch', (_) => PlanAckMsg(rev: 9, structural: false, applyMs: 0))
        ..on(_api, 'setPlan', (_) => PlanAckMsg(rev: 1, structural: true, applyMs: -4));
      final session = open();
      await expectLater(
        session.applyPatch(contractKitPatch(1)),
        throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.planOutOfSync)),
      );
      await expectLater(
        session.setPlan(contractKitPlan()),
        throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.internal)),
      );
      await session.dispose();
    });

    test('PlanSync recovers a planOutOfSync patch with one full plan through the session', () async {
      final double = NativePreviewDouble(host, events);
      final engine = MobileEditorEngine.withChannels(channels);
      final session = await engine.openPreview(_preview);
      final fake = double.sessions.values.single;
      final plans = <int, RenderPlan>{
        1: contractKitPlan(rev: 1),
        2: contractKitPlan(rev: 2).copyWithLayers(),
      };
      final sync = PlanSync(session, compile: (p) async => plans[p.timeline.revision]!);
      sync.schedule(_emptyProject(1));
      await sync.flush();
      expect(fake.plan!.rev, 1);
      // The native engine lost the revision (e.g. it rebuilt after a surface loss).
      fake.plan = contractKitPlan(rev: 40);
      sync.schedule(_emptyProject(2));
      await sync.flush();
      expect(sync.stats.outOfSyncRecoveries, 1);
      expect(host.calls.where((c) => c.startsWith('$_api.applyPatch') || c.startsWith('$_api.setPlan')),
          ['$_api.setPlan', '$_api.applyPatch', '$_api.setPlan']);
      expect(fake.plan!.rev, 2);
      expect(sync.currentStatus, PlanSyncStatus.idle);
      await sync.dispose();
      await session.dispose();
      await double.dispose();
    });
  });

  group('clock seq rules', () {
    test('samples older than the last command seq, or going backwards, are dropped', () async {
      host
        ..on(_api, 'play', (_) => 3)
        ..on(_api, 'pause', (_) => 6);
      final session = open();
      final got = <PreviewClock>[];
      session.clock.listen(got.add);
      await session.play();
      expect(session.lastCommandSeq, 3);
      events
        ..add(_clock(2)) // predates play: dropped
        ..add(_clock(3, playing: true, timeUs: 33333))
        ..add(_clock(5, playing: true, timeUs: 66667))
        ..add(_clock(4, playing: true, timeUs: 100000)); // backwards: dropped
      await pumpEventQueue();
      expect(got.map((c) => c.seq), [3, 5]);
      await session.pause();
      events
        ..add(_clock(5, playing: true, timeUs: 133333)) // late playing sample after pause: dropped
        ..add(_clock(6, timeUs: 133333));
      await pumpEventQueue();
      expect(got.map((c) => (c.seq, c.playing)), [(3, true), (5, true), (6, false)]);
      expect(got.last.time, 133333);
      await session.dispose();
    });

    test('seek acks advance the seq; the latest sample before the first listener is replayed', () async {
      host.on(_api, 'seek', (a) => _seekAck(a[1]! as int, 8));
      final session = open();
      final ack = await session.seek(FrameRate.fps30.timeOfFrame(31) + 10);
      expect((ack.displayedFrame, ack.seq, ack.requested), (31, 8, FrameRate.fps30.timeOfFrame(31) + 10));
      events
        ..add(_clock(7))
        ..add(_clock(8, timeUs: FrameRate.fps30.timeOfFrame(31)))
        ..add(_clock(8, timeUs: FrameRate.fps30.timeOfFrame(31), session: 'other'));
      await pumpEventQueue();
      final got = <PreviewClock>[];
      session.clock.listen(got.add);
      await pumpEventQueue();
      expect(got.map((c) => (c.seq, c.time)), [(8, FrameRate.fps30.timeOfFrame(31))]);
      await session.dispose();
    });
  });

  group('seeks', () {
    test('at most one scrub in flight; scrubs requested meanwhile collapse to the latest', () async {
      final replies = <Completer<SeekAckMsg>>[];
      var seq = 0;
      host.on(_api, 'seek', (a) {
        final c = Completer<SeekAckMsg>();
        replies.add(c);
        final t = a[1]! as int;
        final s = ++seq;
        return c.future.then((_) => _seekAck(t, s));
      });
      final session = open();
      final f1 = session.seek(100000, kind: SeekKind.scrub);
      final f2 = session.seek(200000, kind: SeekKind.scrub);
      final f3 = session.seek(300000, kind: SeekKind.scrub);
      await pumpEventQueue();
      expect(host.args['$_api.seek']!.map((a) => (a[1], a[2])), [(100000, false)]);
      replies[0].complete(SeekAckMsg(requestedUs: 0, displayedFrameTimeUs: 0, displayedFrame: 0, seq: 0));
      await pumpEventQueue();
      expect(host.args['$_api.seek']!.map((a) => (a[1], a[2])), [(100000, false), (300000, false)]);
      replies[1].complete(SeekAckMsg(requestedUs: 0, displayedFrameTimeUs: 0, displayedFrame: 0, seq: 0));
      final a1 = await f1, a2 = await f2, a3 = await f3;
      expect((a1.requested, a1.seq), (100000, 1));
      expect((a2.requested, a2.seq), (300000, 2));
      expect((a3.requested, a3.seq), (300000, 2));
      expect(session.lastCommandSeq, 2);
      await session.dispose();
    });

    test('an exact seek is sent at once and supersedes a pending scrub', () async {
      final replies = <Completer<void>>[];
      var seq = 0;
      host.on(_api, 'seek', (a) {
        final c = Completer<void>();
        replies.add(c);
        final t = a[1]! as int;
        final s = ++seq;
        return c.future.then((_) => _seekAck(t, s));
      });
      final session = open();
      final scrub = session.seek(100000, kind: SeekKind.scrub);
      final dropped = session.seek(200000, kind: SeekKind.scrub);
      final exact = session.seek(400000);
      await pumpEventQueue();
      expect(host.args['$_api.seek']!.map((a) => (a[1], a[2])), [(100000, false), (400000, true)]);
      for (final r in replies) {
        r.complete();
      }
      expect((await scrub).requested, 100000);
      expect((await exact).requested, 400000);
      expect((await dropped).requested, 400000);
      await pumpEventQueue();
      expect(host.count(_api, 'seek'), 2);
      await session.dispose();
    });

    test('play drops a pending scrub (its waiters get the in-flight ack)', () async {
      final gate = Completer<void>();
      host
        ..on(_api, 'seek', (a) => gate.future.then((_) => _seekAck(a[1]! as int, 1)))
        ..on(_api, 'play', (_) => 2);
      final session = open();
      final scrub = session.seek(100000, kind: SeekKind.scrub);
      final dropped = session.seek(200000, kind: SeekKind.scrub);
      await session.play(loop: const TimeRange(0, 1000000));
      final loop = host.args['$_api.play']!.single[1]! as LoopMsg;
      expect((loop.startUs, loop.endUs), (0, 1000000));
      gate.complete();
      expect((await scrub).requested, 100000);
      expect((await dropped).requested, 100000);
      await pumpEventQueue();
      expect(host.count(_api, 'seek'), 1);
      expect(session.lastCommandSeq, 2);
      await session.dispose();
    });

    test('a failed scrub fails its waiters and the next pending scrub still runs', () async {
      var n = 0;
      final gate = Completer<void>();
      host.on(_api, 'seek', (a) async {
        if (++n == 1) {
          await gate.future;
          throw PlatformException(code: 'decodeFailed');
        }
        return _seekAck(a[1]! as int, n);
      });
      final session = open();
      final first = session.seek(100000, kind: SeekKind.scrub);
      final second = session.seek(200000, kind: SeekKind.scrub);
      await pumpEventQueue();
      gate.complete();
      await expectLater(first, throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.decodeFailed)));
      expect((await second).requested, 200000);
      await session.dispose();
    });
  });

  group('transients', () {
    test('coalesced per item to one per frame: leading send, then the latest value', () async {
      final sent = <(String, double?)>[];
      host
        ..on(_api, 'setTransient', (a) {
          final t = PlanTransport.decodeTransient(a[2]! as Uint8List);
          sent.add((a[1]! as String, t.layers.single.xf?.op));
          return null;
        })
        ..on(_api, 'clearTransient', (a) => null);
      final session = open(transientInterval: const Duration(milliseconds: 40));
      PlanTransient tr(String item, double op) => PlanTransient(item: item, layers: [TransientLayer(id: '$item#tx0', xf: PlanTransform(op: op))]);
      for (var i = 1; i <= 5; i++) {
        session.setTransient(const ItemId('it_a'), tr('it_a', i / 10));
      }
      session.setTransient(const ItemId('it_b'), tr('it_b', 0.9));
      await pumpEventQueue();
      expect(sent, [('it_a', 0.1), ('it_b', 0.9)]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sent, [('it_a', 0.1), ('it_b', 0.9), ('it_a', 0.5)]);

      // clearTransient drops a pending transient of that item.
      session.setTransient(const ItemId('it_b'), tr('it_b', 0.2));
      session.setTransient(const ItemId('it_b'), tr('it_b', 0.3));
      session.clearTransient(const ItemId('it_b'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent.last, ('it_b', 0.2));
      expect(host.args['$_api.clearTransient']!.single, [_sid, 'it_b']);
      await session.dispose();
    });

    test('transient failures are ignored (fire-and-forget)', () async {
      host.fail(_api, 'setTransient', 'internal');
      final session = open();
      session.setTransient(const ItemId('it_a'), PlanTransient(item: 'it_a', layers: const []));
      await pumpEventQueue();
      expect(host.count(_api, 'setTransient'), 1);
      await session.dispose();
    });
  });

  group('events and frame size', () {
    test('lifecycle events map to PreviewEvents; size events update frameSize; early events are replayed', () async {
      final session = open();
      expect(session.frameSize.value, isNull);
      events
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.firstFrame, width: 540, height: 960)))
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.stalled)))
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.recovered)))
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.frameSize, width: 270, height: 480)))
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.degraded, quality: PreviewQualityMsg.half)))
        ..add(_event(PreviewEventMsg(kind: PreviewEventKindMsg.surfaceLost)))
        ..add(_event(PreviewEventMsg(
            kind: PreviewEventKindMsg.failed, failure: FailureMsg(code: 'gpuUnavailable', message: 'x', retryable: true))))
        ..add(EngineEventMsg(
            kind: EngineEventKindMsg.failure,
            sessionId: _sid,
            failure: FailureMsg(code: 'mediaOffline', message: '', mediaFingerprint: 'qh_1', retryable: false)));
      await pumpEventQueue();
      expect(session.frameSize.value, const Size(270, 480));
      final got = <PreviewEvent>[];
      session.events.listen(got.add);
      await pumpEventQueue();
      expect(got.map((e) => e.runtimeType), [
        PreviewFirstFrame,
        PreviewStalled,
        PreviewRecovered,
        PreviewDegraded,
        PreviewSurfaceLost,
        PreviewFailedEvent,
        PreviewFailedEvent,
      ]);
      expect((got[3] as PreviewDegraded).quality, PreviewQuality.half);
      expect((got[5] as PreviewFailedEvent).failure.code, EngineErrorCode.gpuUnavailable);
      expect((got[6] as PreviewFailedEvent).failure.mediaFingerprint, 'qh_1');
      await session.dispose();
    });
  });

  group('other calls', () {
    test('quality, proxies, editing modes, source frames, colour, looks, refresh, capture', () async {
      final double = NativePreviewDouble(host, events);
      final engine = MobileEditorEngine.withChannels(channels);
      final session = await engine.openPreview(_preview);
      final fake = double.sessions.values.single;
      await session.setPlan(contractKitPlan());
      await session.setQuality(PreviewQuality.quarter);
      await session.setUseProxies(false);
      await session.setEditingMode(const CropSourceMode(ItemId(contractKitItem)));
      expect((fake.quality, fake.useProxies, (fake.mode as CropSourceMode).item), (PreviewQuality.quarter, false, contractKitItem));
      await session.setEditingMode(const MatteMode(ItemId(contractKitItem)));
      expect(fake.mode, isA<MatteMode>());
      await session.setEditingMode(PreviewEditingMode.normal);
      expect(fake.mode, isA<NormalPreviewMode>());
      await session.showSourceFrame(const EngineMedia(uri: 'file:///d/clip.mov', fingerprint: 'qh_1'), 1234);
      expect((fake.sourceFrame!.$1.fingerprint, fake.sourceFrame!.$2), ('qh_1', 1234));
      fake.sampledColor = const Color(0xFF336699);
      final c = await session.sampleColor(const ItemId(contractKitItem), const Offset(0.25, 0.75));
      expect(c!.toARGB32(), 0xFF336699);
      expect(host.args['$_api.sampleColor']!.single.sublist(1), [contractKitItem, 0.25, 0.75]);
      final stills = await session.renderLookStills(
        const ItemId(contractKitItem),
        const [LookSpec(id: 'warm', lutUri: 'file:///l/warm.vlut', lutSize: 33), LookSpec(id: 'cool', lutUri: 'file:///l/cool.vlut', lutSize: 33, intensity: 0.5)],
        heightPx: 96,
      );
      expect(stills, hasLength(2));
      final looks = host.args['$_api.renderLookStills']!.single[2]! as List<Object?>;
      expect([for (final l in looks.cast<LookSpecMsg>()) (l.id, l.lutSize, l.intensity)], [('warm', 33, 1.0), ('cool', 33, 0.5)]);
      await session.refresh();
      expect((await session.debugCaptureFrame()).length, 64 * 36 * 4);
      await pumpEventQueue();
      expect(session.frameSize.value, const Size(64, 36));
      await session.dispose();
      await double.dispose();
    });

    test('sampleColor answers null; native errors are typed', () async {
      host
        ..on(_api, 'sampleColor', (_) => null)
        ..fail(_api, 'refresh', 'surfaceLost', details: {'retryable': true})
        ..fail(_api, 'setQuality', 'somethingNew', message: 'at /var/mobile/x.mov');
      final session = open();
      expect(await session.sampleColor(const ItemId('it_x'), Offset.zero), isNull);
      await expectLater(session.refresh(),
          throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.surfaceLost).having((f) => f.retryable, 'r', true)));
      await expectLater(
          session.setQuality(PreviewQuality.full),
          throwsA(isA<EngineError>()
              .having((f) => f.code, 'code', EngineErrorCode.internal)
              .having((f) => f.debugDetail, 'detail', isNot(contains('/var/mobile')))));
      await session.dispose();
    });
  });

  group('dispose', () {
    test('during in-flight calls: every pending call fails with EngineCancelled; late replies and events are dropped', () async {
      final gate = Completer<void>();
      host
        ..on(_api, 'setPlan', (_) => gate.future.then((_) => PlanAckMsg(rev: 1, structural: true, applyMs: 0)))
        ..on(_api, 'seek', (a) => gate.future.then((_) => _seekAck(a[1]! as int, 1)))
        ..on(_api, 'sampleColor', (_) => gate.future.then((_) => ColorMsg(red: 1, green: 0, blue: 0, alpha: 1)))
        ..on(_api, 'setTransient', (_) => null)
        ..on(_api, 'dispose', (_) => null);
      final session = open();
      final clock = <PreviewClock>[];
      var clockDone = false;
      session.clock.listen(clock.add, onDone: () => clockDone = true);
      final plan = session.setPlan(contractKitPlan());
      final patch = session.applyPatch(contractKitPatch(1)); // queued behind the plan
      final scrub = session.seek(100000, kind: SeekKind.scrub);
      final pendingScrub = session.seek(200000, kind: SeekKind.scrub);
      final color = session.sampleColor(const ItemId('it_x'), Offset.zero);
      await pumpEventQueue();
      final cancelled = [
        for (final f in <Future<Object?>>[plan, patch, scrub, pendingScrub, color]) expectLater(f, throwsA(isA<EngineCancelled>())),
      ];

      final d1 = session.dispose();
      final d2 = session.dispose();
      expect(identical(d1, d2), isTrue);
      await d1;
      expect(session.isDisposed, isTrue);
      await Future.wait(cancelled);
      expect(host.count(_api, 'dispose'), 1);
      expect(host.args['$_api.dispose']!.single, [_sid]);

      gate.complete();
      events.add(_clock(9));
      await pumpEventQueue();
      expect(clock, isEmpty);
      expect(clockDone, isTrue);
      expect(host.count(_api, 'applyPatch'), 0);
      expect(host.count(_api, 'seek'), 1);

      await expectLater(session.pause(), throwsA(isA<EngineCancelled>()));
      await expectLater(session.seek(0), throwsA(isA<EngineCancelled>()));
      await expectLater(session.setPlan(contractKitPlan()), throwsA(isA<EngineCancelled>()));
      session.setTransient(const ItemId('it_x'), PlanTransient(item: 'it_x', layers: const []));
      session.clearTransient(const ItemId('it_x'));
      await session.dispose();
      await pumpEventQueue();
      expect(host.count(_api, 'setTransient'), 0);
      expect(host.count(_api, 'clearTransient'), 0);
      expect(host.count(_api, 'dispose'), 1);
    });

    test('a native dispose failure does not escape; a reopened id routes again', () async {
      host.fail(_api, 'dispose', 'internal');
      final session = open();
      await session.dispose();
      final again = open();
      final got = <PreviewClock>[];
      again.clock.listen(got.add);
      events.add(_clock(1));
      await pumpEventQueue();
      expect(got, hasLength(1));
      await again.dispose();
    });
  });
}

EditProject _emptyProject(int revision) => EditProject(
      id: const ProjectId('pr_eng02'),
      meta: ProjectMeta(name: 'eng02', createdAt: DateTime.utc(2026, 10, 11), updatedAt: DateTime.utc(2026, 10, 11)),
      timeline: Timeline(settings: const ProjectSettings(), revision: revision, tracks: const []),
      pool: MediaPool(const {}),
    );

extension on RenderPlan {
  /// This plan plus the kit patch's second solid layer (a structural change).
  RenderPlan copyWithLayers() => RenderPlan(
        rev: rev,
        target: target,
        canvas: canvas,
        durUs: durUs,
        layers: [...layers, ...contractKitPatch(rev - 1).layers.upsert],
      );
}
