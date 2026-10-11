// OWNER: API-01
//
// FakeEditorEngine behaviour that UI and controller tests rely on: deterministic clock, exact-seek
// acks, patches with revision checks, failure injection, scripted jobs and exports, call log.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

const _media = ResolvedMedia(uri: 'file:///m.mp4', fingerprint: 'fp');
const _settings = EncodeSettings(width: 1280, height: 720, fps: 30, videoBitrate: 4000000);

Future<FakePreviewSession> _open(FakeEditorEngine e, {bool plan = true}) async {
  final s = await e.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30)) as FakePreviewSession;
  if (plan) {
    await s.setPlan(contractKitPlan());
  }
  return s;
}

Matcher _failure(EngineErrorCode code) => isA<EngineFailure>().having((f) => f.code, 'code', code);

void main() {
  group('preview session', () {
    test('texture ids are unique per session and frameSize follows the plan', () async {
      final e = FakeEditorEngine();
      final a = await _open(e, plan: false);
      final b = await _open(e, plan: false);
      expect(a.textureId, isNot(b.textureId));
      expect(a.frameSize.value, isNull);
      await a.setPlan(contractKitPlan());
      expect(a.frameSize.value, const Size(64, 36));
    });

    test('first plan raises firstFrame once', () async {
      final e = FakeEditorEngine();
      final s = await _open(e, plan: false);
      final events = <PreviewEvent>[];
      s.events.listen(events.add);
      await s.setPlan(contractKitPlan());
      await s.setPlan(contractKitPlan(rev: 2));
      await pumpEventQueue();
      expect(events.whereType<PreviewFirstFrame>(), hasLength(1));
    });

    test('exact seeks land on the frame grid of the plan (gridFps, D-35)', () async {
      final s = await _open(FakeEditorEngine());
      final ack = await s.seek(contractKitGrid.timeOfFrame(7) + 5);
      expect(ack.displayedFrame, 7);
      expect(ack.displayedFrameTime, contractKitGrid.timeOfFrame(7));
      expect((await s.seek(-100)).displayedFrame, 0);
    });

    test('the clock is deterministic: it moves only through advanceFrames', () async {
      final s = await _open(FakeEditorEngine());
      final samples = <PreviewClock>[];
      s.clock.listen(samples.add);
      await s.play();
      s.advanceFrames(3);
      await pumpEventQueue();
      expect(samples.last.time, contractKitGrid.timeOfFrame(3));
      expect(samples.last.playing, isTrue);
      expect(samples.last.rate, 1);
      await s.pause();
      s.advanceFrames(10); // paused: no movement
      await pumpEventQueue();
      expect(samples.last.playing, isFalse);
      expect(samples.last.rate, 0);
      expect(samples.last.time, contractKitGrid.timeOfFrame(3));
      expect(samples.map((c) => c.seq).toList(), [1, 1, 2]);
    });

    test('playback loops inside the loop range and stops at the plan end', () async {
      final s = await _open(FakeEditorEngine());
      final loop = TimeRange(contractKitGrid.timeOfFrame(10), contractKitGrid.timeOfFrame(20));
      await s.seek(contractKitGrid.timeOfFrame(18));
      await s.play(loop: loop);
      s.advanceFrames(4);
      expect(s.time, contractKitGrid.timeOfFrame(12));

      await s.seek(contractKitGrid.timeOfFrame(88));
      await s.play();
      final before = s.seq;
      s.advanceFrames(10);
      expect(s.playing, isFalse);
      expect(s.time, contractKitGrid.timeOfFrame(89));
      expect(s.seq, before + 1, reason: 'reaching the end is a state change with a new seq');
    });

    test('patches check `from`, bump the revision and classify structural changes', () async {
      final s = await _open(FakeEditorEngine());
      final ack = await s.applyPatch(contractKitPatch(1));
      expect(ack.rev, 2);
      expect(ack.structural, isTrue);
      expect(s.plan!.layers.map((l) => l.id), ['it_kit00000001#tx0', 'it_kit00000002#tx0']);

      final recolor = PlanLayer(id: 'it_kit00000002#tx0', z: 16, t0: 0, t1: s.plan!.durUs, kind: PlanLayerKind.solid, color: 0xFF00FF00);
      final soft = await s.applyPatch(RenderPlanPatch(from: 2, to: 3, layers: PatchSet<PlanLayer>(upsert: [recolor])));
      expect(soft.structural, isFalse, reason: 'a colour change keeps the composition');
      expect(s.plan!.rev, 3);

      await expectLater(s.applyPatch(RenderPlanPatch(from: 1, to: 2)), throwsA(_failure(EngineErrorCode.planOutOfSync)));
      expect(s.plan!.rev, 3, reason: 'a rejected patch changes nothing');

      final removed =
          await s.applyPatch(RenderPlanPatch(from: 3, to: 4, layers: PatchSet<PlanLayer>(remove: const ['it_kit00000002#tx0'])));
      expect(removed.structural, isTrue);
      expect(s.plan!.layers, hasLength(1));
    });

    test('patch before any plan is out of sync', () async {
      final s = await _open(FakeEditorEngine(), plan: false);
      await expectLater(s.applyPatch(RenderPlanPatch(from: 0, to: 1)), throwsA(_failure(EngineErrorCode.planOutOfSync)));
    });

    test('transients never change the revision and die with a plan or a touching patch', () async {
      final s = await _open(FakeEditorEngine());
      final t = PlanTransient(item: 'it_kit00000002', layers: const [TransientLayer(id: 'it_kit00000002#tx0', xf: PlanTransform(op: 0.5))]);
      s.setTransient(const ItemId('it_kit00000002'), t);
      expect(s.plan!.rev, 1);
      expect(s.transients, hasLength(1));
      await s.applyPatch(contractKitPatch(1)); // touches it_kit00000002
      expect(s.transients, isEmpty);

      s.setTransient(const ItemId('it_kit00000002'), t);
      s.clearTransient(const ItemId('it_kit00000002'));
      expect(s.transients, isEmpty);
      s.setTransient(const ItemId('it_kit00000002'), t);
      await s.setPlan(contractKitPlan(rev: 5));
      expect(s.transients, isEmpty);
    });

    test('invalid plans are rejected with planInvalid like a native engine', () async {
      final s = await _open(FakeEditorEngine(), plan: false);
      final bad = RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: const PlanCanvas(w: 64, h: 36, fps: 30),
        durUs: 1000, // off the 30 fps grid
        layers: const [],
      );
      await expectLater(s.setPlan(bad), throwsA(_failure(EngineErrorCode.planInvalid)));
      expect(s.plan, isNull);
    });

    test('modes, quality, proxies, source frames and looks are recorded', () async {
      final e = FakeEditorEngine();
      final s = await _open(e);
      await s.setEditingMode(const CropSourceMode(ItemId('it_x')));
      await s.setQuality(PreviewQuality.half);
      await s.setUseProxies(false);
      await s.showSourceFrame(_media, 1234);
      expect(s.mode, isA<CropSourceMode>());
      expect(s.quality, PreviewQuality.half);
      expect(s.useProxies, isFalse);
      expect(s.sourceFrame, (_media, 1234));
      await s.seek(0);
      expect(s.sourceFrame, isNull, reason: 'cleared by seek');
      expect(await s.sampleColor(const ItemId('it_x'), const Offset(0.5, 0.5)), isNotNull);
      const look = LookSpec(id: 'a', lutUri: 'file:///a.vlut', lutSize: 17);
      expect(await s.renderLookStills(const ItemId('it_x'), const [look], heightPx: 90), hasLength(1));
      expect((await s.debugCaptureFrame()).length, 64 * 36 * 4);
      expect(e.calls, containsAllInOrder(['openPreview', 'preview.setPlan', 'preview.setEditingMode', 'preview.setQuality']));
    });

    test('dispose closes the streams and marks the session', () async {
      final s = await _open(FakeEditorEngine());
      var done = false;
      s.clock.listen((_) {}, onDone: () => done = true);
      await s.dispose();
      await pumpEventQueue();
      expect(s.disposed, isTrue);
      expect(done, isTrue);
    });
  });

  group('failure injection and call log', () {
    test('failNext fires once per method name, across sessions and services', () async {
      final e = FakeEditorEngine();
      e.failNext['probe'] = EngineFailure.of(EngineErrorCode.decoderInitFailed);
      await expectLater(e.probe(_media), throwsA(_failure(EngineErrorCode.decoderInitFailed)));
      await expectLater(e.probe(_media), throwsA(_failure(EngineErrorCode.mediaOffline)));

      final s = await _open(e);
      e.failNext['preview.seek'] = EngineFailure.of(EngineErrorCode.surfaceLost, retryable: true);
      await expectLater(s.seek(0), throwsA(isA<EngineError>().having((f) => f.retryable, 'retryable', isTrue)));
      expect((await s.seek(0)).displayedFrame, 0);

      e.failNext['exporter.start'] = EngineFailure.of(EngineErrorCode.diskFull);
      await expectLater(
        e.exporter.start(contractKitPlan(), _settings, outputPath: '/o.mp4', title: 't'),
        throwsA(_failure(EngineErrorCode.diskFull)),
      );
      expect(e.exporter.started, isEmpty);

      e.failNext['picker.pick'] = EngineFailure.of(EngineErrorCode.permissionDenied);
      await expectLater(
        e.picker.pick(const MediaPickRequest(source: MediaPickSource.photos, kinds: {MediaPickKind.video})),
        throwsA(_failure(EngineErrorCode.permissionDenied)),
      );
    });

    test('job-creating calls deliver the injected failure through the job', () async {
      final e = FakeEditorEngine();
      e.failNext['jobs.proxy'] = EngineFailure.of(EngineErrorCode.encodingFailed);
      final job = e.jobs.proxy(_media);
      await expectLater(job.result, throwsA(_failure(EngineErrorCode.encodingFailed)));

      e.failNext['thumbnails.request'] = EngineFailure.of(EngineErrorCode.decodeFailed);
      final h = e.thumbnails.request(
        const ThumbnailRequest(media: _media, intervalMs: 1000, tileIndex: 0, heightPx: 90),
        priority: ThumbPriority.visible,
      );
      await expectLater(h.result, throwsA(_failure(EngineErrorCode.decodeFailed)));
    });

    test('capabilities, compatibility and probes are scriptable', () async {
      final e = FakeEditorEngine(
        probes: {'file:///m.mp4': MediaProbe(kind: MediaKind.video, duration: 1000000)},
        compatibilityByPath: {'/bad.mkv': const NotEditable('container_unsupported_ios')},
      );
      expect((await e.capabilities()).supported, isTrue);
      expect(await e.compatibility('/ok.mp4'), isA<Editable>());
      expect((await e.compatibility('/bad.mkv') as NotEditable).code, 'container_unsupported_ios');
      expect((await e.probe(_media)).duration, 1000000);
      e.caps = e.caps.copyWith(voiceRecording: false);
      expect(e.voiceRecorder, isNull);
      e.caps = e.caps.copyWith(voiceRecording: true);
      expect(e.voiceRecorder, isNotNull);
    });

    test('signals, cache trims and free space', () async {
      final e = FakeEditorEngine()..freeBytesValue = 5;
      final signals = <EngineSignal>[];
      e.signals.listen(signals.add);
      e.emitSignal(const MemoryWarningSignal());
      e.emitSignal(const ThermalSignal(ThermalLevel.serious));
      await e.trimCaches(CacheTrimLevel.clearAll);
      await pumpEventQueue();
      expect(signals.map((s) => s.runtimeType), [MemoryWarningSignal, ThermalSignal]);
      expect(await e.freeBytes('/x'), 5);
      expect(e.calls, contains('trimCaches.clearAll'));
    });
  });

  group('jobs, exports and platform services', () {
    test('jobs progress and complete when the test drives them; cancel completes with EngineCancelled', () async {
      final e = FakeEditorEngine();
      final job = e.jobs.proxy(_media);
      final progress = <double>[];
      job.progress.listen(progress.add);
      final fake = e.jobs.created.single;
      fake.report(0.25);
      fake.report(0.5);
      job.setPriority(JobPriority.background);
      expect(fake.priority, JobPriority.background);
      fake.complete(const GeneratedAsset(path: '/p.mp4', sizeBytes: 3));
      expect(await job.result, isA<GeneratedAsset>());
      await pumpEventQueue();
      expect(progress, [0.25, 0.5, 1.0]);

      final job2 = e.jobs.reverse(_media, TimeRange(0, 1000), outputPath: '/r.mp4');
      job2.cancel();
      await expectLater(job2.result, throwsA(isA<EngineCancelled>()));
      expect(e.jobs.created.last.cancelled, isTrue);
      expect(e.jobs.proxyStatus(_media), ProxyStatus.none);
      e.jobs.proxyStates['fp'] = ProxyStatus.ready;
      expect(e.jobs.proxyStatus(_media), ProxyStatus.ready);
    });

    test('waveforms complete at once; thumbnails can be cancelled before they resolve', () async {
      final e = FakeEditorEngine();
      expect((await e.waveforms.peaks(_media).result).pairsPerSecond, 200);
      final h = e.thumbnails.request(
        const ThumbnailRequest(media: _media, intervalMs: 500, tileIndex: 2, heightPx: 90),
        priority: ThumbPriority.prefetch,
      ) as FakeThumbnailHandle;
      h.cancel();
      await expectLater(h.result, throwsA(isA<EngineCancelled>()));
      expect(h.cancelled, isTrue);
      final ok = e.thumbnails.request(
        const ThumbnailRequest(media: _media, intervalMs: 500, tileIndex: 0, heightPx: 90),
        priority: ThumbPriority.visible,
      );
      final tile = await ok.result;
      expect(tile.frames, 8);
      ok.cancel(); // no-op when done
      expect(e.thumbnails.priorities, [ThumbPriority.prefetch, ThumbPriority.visible]);
    });

    test('export: progress, finish, reattach listing, cancel and preflight', () async {
      final e = FakeEditorEngine();
      final job = await e.exporter.start(contractKitPlan(), _settings, outputPath: '/fake/cache/danaview/editor/work/e.mp4', title: 'Trip');
      final fake = e.exporter.started.single;
      final progress = <ExportProgress>[];
      job.progress.listen(progress.add);
      fake.report(0.5, pausedInBackground: true, backgrounded: true);
      final running = (await e.exporter.activeJobs()).single as ExportRunning;
      expect(running.job, same(job));
      fake.finish();
      final result = await job.result;
      expect(result.path, '/fake/cache/danaview/editor/work/e.mp4');
      expect(result.duration, contractKitPlan().durUs);
      await pumpEventQueue();
      expect(progress.single.pausedInBackground, isTrue);
      expect(await e.exporter.activeJobs(), isEmpty, reason: 'finished jobs leave the running list');

      final j2 = await e.exporter.start(contractKitPlan(), _settings, outputPath: '/o2.mp4', title: 'x');
      await j2.cancel();
      await expectLater(j2.result, throwsA(isA<EngineCancelled>()));
      expect(e.exporter.started.last.cancelled, isTrue);

      e.exporter.preflightResult = const ExportPreflight(ok: false, maxHeightForPlan: 720, warnings: [ExportWarning('layersVsResolution')]);
      final pre = await e.exporter.preflight(contractKitPlan(), _settings);
      expect(pre.ok, isFalse);
      expect(pre.warnings.single.code, 'layersVsResolution');
      await expectLater(e.exporter.resume('nope'), throwsA(_failure(EngineErrorCode.notSupportedOnDevice)));
    });

    test('one-shot records are consumed; resumable and running ones are not', () async {
      final e = FakeEditorEngine();
      e.exporter.records.addAll(const [
        ExportInterrupted('a'),
        ExportCompletedWhileDetached('b', savedToGallery: true, savedUri: 'ph://1'),
        ExportResumable('c', doneFraction: 0.5),
      ]);
      await e.exporter.consumeJobRecord('a');
      await e.exporter.consumeJobRecord('b');
      await e.exporter.consumeJobRecord('c'); // not one-shot: stays
      expect((await e.exporter.activeJobs()).map((r) => r.jobId), ['c']);
    });

    test('recorder: permission flow, levels, interruptions and stop', () async {
      final e = FakeEditorEngine();
      final r = e.voiceRecorder! as FakeVoiceRecorder;
      r.permissionState = MicPermission.undetermined;
      r.permissionAfterRequest = MicPermission.denied;
      expect(await r.permission(), MicPermission.undetermined);
      await expectLater(r.start(outputPath: '/a.wav'), throwsA(_failure(EngineErrorCode.permissionDenied)));
      expect(await r.requestPermission(), MicPermission.denied);
      r.permissionState = MicPermission.granted;
      final s = await r.start(outputPath: '/a.wav') as FakeRecordingSession;
      final levels = <double>[];
      final interruptions = <RecordingInterruption>[];
      s.levels.listen(levels.add);
      s.interruptions.listen(interruptions.add);
      s.emitLevel(0.3);
      s.interrupt(RecordingInterruption.routeChanged);
      await pumpEventQueue();
      expect(levels, [0.3]);
      expect(interruptions, [RecordingInterruption.routeChanged]);
      final asset = await s.stop();
      expect(asset.path, '/a.wav');
      expect(asset.startLatencyUs, greaterThan(0));
      expect(r.sessions, hasLength(1));
    });

    test('picker returns scripted picks once; handoff, background guard and drops work', () async {
      final e = FakeEditorEngine();
      e.picker.nextPicks = const [PickedMedia(uri: 'file:///a.mp4', displayName: 'a', isTemporaryCopy: true)];
      const req = MediaPickRequest(source: MediaPickSource.photos, kinds: {MediaPickKind.video});
      expect(await e.picker.pick(req), hasLength(1));
      expect(await e.picker.pick(req), isEmpty);
      expect(e.picker.requests, hasLength(2));

      expect((await e.files.saveToPhotos('/x.mp4')).savedUri, isNotNull);
      await e.files.saveToFiles('/x.mp4', 'x');
      await e.files.share('/x.mp4');
      expect(e.files.log, ['photos', 'files', 'share']);

      final lease = (await e.background.acquire(title: 'Exporting', progress: const Stream<double>.empty()))!;
      expect(e.background.held, {lease.id});
      await lease.release();
      expect(e.background.held, isEmpty);

      final drops = <ExternalDrop>[];
      e.drops.drops.listen(drops.add);
      e.drops.simulateDrop(const ExternalDrop(items: [], position: Offset(1, 2))); // disabled: ignored
      await e.drops.setEnabled(true);
      e.drops.simulateDrop(const ExternalDrop(items: [], position: Offset(3, 4)));
      await pumpEventQueue();
      expect(drops.map((d) => d.position), [const Offset(3, 4)]);
    });

    test('media access: resolve, stat, missing files and notification permission', () async {
      final e = FakeEditorEngine();
      const loc = FileLocator('/fake/a.mp4');
      final r = await e.access.resolve(loc);
      expect(r.uri, 'file:///fake/a.mp4');
      expect(await e.access.quickHash(loc), r.fingerprint);
      expect(await e.access.stat(loc), isNotNull);
      e.access.missing.add(r.uri);
      await expectLater(
        e.access.resolve(loc),
        throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.notFound)),
      );
      expect(await e.access.stat(loc), isNull);
      expect(await e.access.requestNotificationPermission(), isTrue);
      expect(await e.access.remainingGrantBudget(), 500);
    });
  });

  group('capabilities', () {
    test('copyWith replaces any field and can clear the reason; equality and hash cover every field', () {
      final a = EditorCapabilities.unsupported(UnsupportedReasons.androidTooOld);
      expect(a.copyWith(unsupportedReason: null).unsupportedReason, isNull);
      expect(a.copyWith().unsupportedReason, UnsupportedReasons.androidTooOld);
      const base = EditorCapabilities(supported: true);
      final variants = <EditorCapabilities>[
        base.copyWith(tier: DeviceTier.high),
        base.copyWith(h264Encode: false),
        base.copyWith(hardwareH264: false),
        base.copyWith(hardwareHevc: true),
        base.copyWith(maxExportSize: const Size(3840, 2160)),
        base.copyWith(maxFpsByHeight: const {1080: 30}),
        base.copyWith(maxPreviewLongSide: 1280),
        base.copyWith(backgroundGpu: true),
        base.copyWith(proxiesRecommended: true),
        base.copyWith(holdFrame: false),
        base.copyWith(fpsUpconversion: false),
        base.copyWith(minSpeed: 0.2),
        base.copyWith(maxSpeed: 8),
        base.copyWith(maxAudioSpeed: 2),
        base.copyWith(maxLutSize: 33),
        base.copyWith(planVersions: const [1, 2]),
        base.copyWith(maxVisualSequences: 8),
      ];
      for (final v in variants) {
        expect(v, isNot(base));
      }
      expect(base.copyWith(), base);
      expect(base.copyWith().hashCode, base.hashCode);
      expect(
        const EditorCapabilities(supported: true, maxFpsByHeight: {1080: 60, 2160: 30}).hashCode,
        const EditorCapabilities(supported: true, maxFpsByHeight: {2160: 30, 1080: 60}).hashCode,
      );
    });

    test('unsupported capabilities name the reason and disable everything', () {
      final c = EditorCapabilities.unsupported(UnsupportedReasons.engineNotAvailable);
      expect(c.supported, isFalse);
      expect(c.maxConcurrentVideoLayers, 0);
      expect(c.planVersions, isEmpty);
      expect(c.voiceRecording, isFalse);
    });
  });

  testWidgets('FakeTexturePlaceholder paints a stable colour per texture id and sizes itself', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: FakeTexturePlaceholder(textureId: 101, size: Size(64, 36))),
      ),
    );
    expect(tester.getSize(find.byType(FakeTexturePlaceholder)), const Size(64, 36));
    expect(find.bySemanticsLabel('Preview texture 101'), findsOneWidget);
    expect(FakeTexturePlaceholder.colorOf(101), FakeTexturePlaceholder.colorOf(101));
    expect(FakeTexturePlaceholder.colorOf(101), isNot(FakeTexturePlaceholder.colorOf(102)));
  });

  test('failure and config value types', () {
    expect(EngineFailure.of(EngineErrorCode.io).toString(), 'EngineFailure(io)');
    expect(EngineFailure.of(EngineErrorCode.io, debugDetail: 'x').toString(), 'EngineFailure(io: x)');
    const a = EditorEngineConfig(cacheRoot: 'a', supportRoot: 'b');
    const b = EditorEngineConfig(cacheRoot: 'a', supportRoot: 'b');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('placeholders throw UnimplementedError until their owners land (D-33)', () {
    expect(() => PlanTransport.encodeTransient(PlanTransient(item: 'x', layers: const [])), throwsUnimplementedError);
    expect(() => RenderMath.notImplemented, throwsUnimplementedError);
    expect(() => const ReferenceRenderer().renderFrame(contractKitPlan(), 0), throwsUnimplementedError);
    expect(() => const ReferenceAudioMixer().mix(contractKitPlan(), 0, 1), throwsUnimplementedError);
    expect(() => TextLayoutEngine(fontResolver: (_) => 'Figtree').layout(const {}), throwsUnimplementedError);
    expect(() => VspriteCodec.decode(Uint8List(0)), throwsUnimplementedError);
  });
}
