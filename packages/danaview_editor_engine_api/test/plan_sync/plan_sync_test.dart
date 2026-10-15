// OWNER: API-02
//
// PlanSync against FakeEditorEngine (BUILD_PLAN API-02): coalescing (100 schedules → ≤ 2
// compiles), the planOutOfSync → full-plan retry, a double failure surfacing PreviewFailed,
// transient rate limiting and dropping, and revisions that never regress after undo.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support.dart';

RenderPlan compiled(EditProject p) => compilePlan(p, PlanTarget.preview, resolverOf(p),
        options: CompileOptions(stages: standardLoweringStages()))
    .plan;

/// The plan content without `rev`/`req` (what the engine renders).
RenderPlan content(RenderPlan p) => RenderPlan(
    rev: 0, target: p.target, canvas: p.canvas, durUs: p.durUs, assets: p.assets, layers: p.layers, audio: p.audio);

void main() {
  group('scheduling', () {
    test('first plan is sent whole, a param edit as a patch; acks and status are reported', () async {
      final (engine, s) = await openFake();
      final compiler = CountingCompiler();
      final sync = PlanSync(s, compile: compiler.call);
      final statuses = <PlanSyncStatus>[];
      sync.status.listen(statuses.add);

      final p0 = project(revision: 5);
      sync.schedule(p0);
      expect(sync.busy, isTrue);
      await sync.flush();
      expect(engine.calls.where((c) => c == 'preview.setPlan'), hasLength(1));
      expect(s.plan!.rev, 5);
      expect(sync.lastAck!.rev, 5);
      expect(sync.lastAck!.structural, isTrue);
      expect(statuses, [PlanSyncStatus.compiling, PlanSyncStatus.applying, PlanSyncStatus.idle]);

      final p1 = withOpacity(p0, 1, 0.5, revision: 6);
      sync.schedule(p1);
      await sync.flush();
      expect(engine.calls.where((c) => c == 'preview.applyPatch'), hasLength(1));
      expect(sync.lastAck!.rev, 6);
      expect(sync.lastAck!.structural, isFalse, reason: 'opacity is a param-only change');
      expect(content(s.plan!), content(compiled(p1)));
      expect(sync.appliedPlan!.rev, 6);
      expect(sync.currentStatus, PlanSyncStatus.idle);
      await sync.dispose();
    });

    test('100 synchronous schedules cost one compile; the latest project wins', () async {
      final (_, s) = await openFake();
      final compiler = CountingCompiler();
      final sync = PlanSync(s, compile: compiler.call);
      var p = project(revision: 1);
      for (var i = 0; i < 100; i++) {
        p = withOpacity(p, 0, (i + 1) / 100, revision: 2 + i);
        sync.schedule(p);
      }
      await sync.flush();
      expect(compiler.calls, lessThanOrEqualTo(2));
      expect(compiler.calls, 1);
      expect(s.plan!.rev, 101);
      expect(content(s.plan!), content(compiled(p)));
    });

    test('100 schedules while a compile is in flight cost <= 2 compiles (latest wins)', () async {
      final (engine, s) = await openFake();
      final compiler = GatedCompiler();
      final sync = PlanSync(s, compile: compiler.call);
      var p = project(revision: 1);
      sync.schedule(p);
      await pumpMicrotasks();
      expect(compiler.calls, 1, reason: 'at most one compile in flight');
      for (var i = 0; i < 100; i++) {
        p = withOpacity(p, i % 3, (i + 1) / 100, revision: 2 + i);
        sync.schedule(p);
        await pumpMicrotasks();
        expect(compiler.inFlight, hasLength(1));
      }
      compiler.release(); // the superseded result is discarded
      await pumpMicrotasks();
      expect(sync.stats.discarded, 1);
      expect(compiler.calls, 2);
      compiler.release();
      await sync.flush();
      expect(compiler.calls, lessThanOrEqualTo(2));
      expect(engine.calls.where((c) => c == 'preview.setPlan'), hasLength(1));
      expect(s.plan!.rev, 101);
      expect(content(s.plan!), content(compiled(p)));
    });

    test('a stream of edits still reaches the screen (a stale result is discarded at most once in a row)', () async {
      final (_, s) = await openFake();
      final compiler = GatedCompiler();
      final sync = PlanSync(s, compile: compiler.call);
      var p = project(revision: 1);
      sync.schedule(p);
      for (var i = 0; i < 4; i++) {
        await pumpMicrotasks();
        p = withOpacity(p, 0, (i + 1) / 10, revision: 2 + i);
        sync.schedule(p);
        compiler.release();
        await pumpMicrotasks();
      }
      expect(s.plan, isNotNull, reason: 'compiles kept being superseded, yet a plan was applied');
      expect(sync.stats.discarded, lessThanOrEqualTo(2));
      while (compiler.inFlight.isNotEmpty) {
        compiler.release();
        await pumpMicrotasks();
      }
      await sync.flush();
      expect(content(s.plan!), content(compiled(p)));
    });

    test('an unchanged plan is not sent again', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final p = project(revision: 3);
      sync.schedule(p);
      await sync.flush();
      // A view or marker-only change: new stamp, same render content.
      sync.schedule(p.copyWith(timeline: p.timeline.copyWith(revision: 4)));
      await sync.flush();
      expect(sync.stats.emptyDiffs, 1);
      expect(engine.calls.where((c) => c.startsWith('preview.')), ['preview.setPlan']);
      expect(s.plan!.rev, 3);
      // The next real change still patches from the engine's revision.
      sync.schedule(withOpacity(p, 2, 0.2, revision: 5));
      await sync.flush();
      expect(engine.calls.last, 'preview.applyPatch');
      expect(s.plan!.rev, 5);
    });
  });

  group('failures', () {
    test('planOutOfSync from a patch resends the full plan once', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final events = <PreviewEvent>[];
      sync.events.listen(events.add);
      final p0 = project(revision: 1);
      sync.schedule(p0);
      await sync.flush();
      // The engine lost its state (e.g. a surface rebuild): its revision no longer matches.
      s.plan = s.plan!.copyWith(rev: 77);
      final p1 = withOpacity(p0, 0, 0.3, revision: 2);
      sync.schedule(p1);
      await sync.flush();
      expect(engine.calls.where((c) => c.startsWith('preview.')),
          ['preview.setPlan', 'preview.applyPatch', 'preview.setPlan']);
      expect(sync.stats.outOfSyncRecoveries, 1);
      expect(events, isEmpty);
      expect(sync.currentStatus, PlanSyncStatus.idle);
      expect(s.plan!.rev, 2);
      expect(content(s.plan!), content(compiled(p1)));
      // Back in sync: the next edit is a patch again.
      sync.schedule(withOpacity(p1, 1, 0.4, revision: 3));
      await sync.flush();
      expect(engine.calls.last, 'preview.applyPatch');
    });

    test('a second failure surfaces PreviewFailed; the next schedule recovers with a full plan', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final events = <PreviewEvent>[];
      sync.events.listen(events.add);
      final statuses = <PlanSyncStatus>[];
      sync.status.listen(statuses.add);
      final p0 = project(revision: 1);
      sync.schedule(p0);
      await sync.flush();

      engine.failNext['preview.applyPatch'] = EngineFailure.of(EngineErrorCode.planOutOfSync);
      engine.failNext['preview.setPlan'] = EngineFailure.of(EngineErrorCode.gpuUnavailable);
      final p1 = withOpacity(p0, 0, 0.3, revision: 2);
      sync.schedule(p1);
      await sync.flush();
      expect(events, hasLength(1));
      expect((events.single as PreviewFailedEvent).failure.code, EngineErrorCode.gpuUnavailable);
      expect(sync.currentStatus, PlanSyncStatus.failed);
      expect(statuses.last, PlanSyncStatus.failed);
      expect(sync.lastFailure!.code, EngineErrorCode.gpuUnavailable);
      expect(sync.appliedPlan, isNull, reason: 'engine state unknown after a failed setPlan');

      final p2 = withOpacity(p1, 1, 0.6, revision: 3);
      sync.schedule(p2);
      await sync.flush();
      expect(engine.calls.last, 'preview.setPlan');
      expect(sync.currentStatus, PlanSyncStatus.idle);
      expect(sync.lastFailure, isNull);
      expect(content(s.plan!), content(compiled(p2)));
      expect(events, hasLength(1));
    });

    test('resync() ("Restart preview") sends the latest full plan', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final p = project(revision: 1);
      sync.schedule(p);
      await sync.flush();
      sync.resync();
      await sync.flush();
      expect(engine.calls.where((c) => c == 'preview.setPlan'), hasLength(2));
      expect(s.plan!.rev, greaterThan(1), reason: 'a resent plan never reuses a sent revision');
    });

    test('a non-sync patch failure fails without resending; the engine keeps the base', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final events = <PreviewEvent>[];
      sync.events.listen(events.add);
      final p0 = project(revision: 1);
      sync.schedule(p0);
      await sync.flush();
      engine.failNext['preview.applyPatch'] = EngineFailure.of(EngineErrorCode.planInvalid);
      sync.schedule(withOpacity(p0, 0, 0.3, revision: 2));
      await sync.flush();
      expect(events.single, isA<PreviewFailedEvent>());
      expect(engine.calls.where((c) => c == 'preview.setPlan'), hasLength(1));
      expect(sync.appliedPlan!.rev, 1);
    });

    test('a compile that throws is reported as PreviewFailed(internal)', () async {
      final (_, s) = await openFake();
      final sync = PlanSync(s, compile: (_) async => throw StateError('bug'));
      final events = <PreviewEvent>[];
      sync.events.listen(events.add);
      sync.schedule(project());
      await sync.flush();
      expect((events.single as PreviewFailedEvent).failure.code, EngineErrorCode.internal);
      expect(sync.currentStatus, PlanSyncStatus.failed);
    });
  });

  group('revisions', () {
    test('revision ordering never regresses after undo/redo (session stamps)', () async {
      final (_, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final session = EditSession(project(revision: 1), ids: SeededIdGenerator(7), clock: () => when);
      final acks = <int>[];
      Future<void> push() async {
        sync.schedule(session.project);
        await sync.flush();
        acks.add(sync.lastAck!.rev);
        expect(content(s.plan!), content(compiled(session.project)), reason: 'engine shows the session state');
      }

      await push();
      session.apply(SetVisual([clipId(0)], const VisualProps(transform: Transform2D(opacity: 0.5))));
      await push();
      session.apply(TrimItem(clipId(2), TrimEdge.end, FrameRate.fps30.timeOfFrame(80)));
      await push();
      session.undo();
      await push();
      session.undo();
      await push();
      session.redo();
      await push();
      session.apply(SetVisual([clipId(1)], const VisualProps(transform: Transform2D(opacity: 0.25))));
      await push();
      for (var i = 1; i < acks.length; i++) {
        expect(acks[i], greaterThan(acks[i - 1]), reason: 'acks $acks');
      }
      expect(sync.stats.restamped, 0, reason: 'session stamps are already monotonic');
    });

    test('a stale project (older stamp) is re-stamped above every sent revision', () async {
      final (engine, s) = await openFake();
      final sync = PlanSync(s, compile: CountingCompiler().call);
      final old = project(revision: 10);
      final newer = withOpacity(old, 0, 0.5, revision: 11);
      sync.schedule(newer);
      await sync.flush();
      sync.schedule(old); // e.g. a snapshot restored with its old stamp
      await sync.flush();
      expect(sync.stats.restamped, 1);
      expect(engine.calls.last, 'preview.applyPatch');
      expect(s.plan!.rev, 12);
      expect(content(s.plan!), content(compiled(old)));
    });
  });

  group('transients', () {
    test('rate limited to <= 60 Hz, newest per item wins', () async {
      final (engine, s) = await openFake();
      final clock = ManualClock();
      final sync = PlanSync(s, compile: CountingCompiler().call, clock: clock);
      final p = project(revision: 1);
      sync.schedule(p);
      await sync.flush();
      final sent = <PlanTransient>[];
      // A 120 Hz input device for 500 ms.
      for (var i = 0; i < 60; i++) {
        final t = transientOf(p, 1, (i + 1) / 60);
        sync.sendTransient(clipId(1), t);
        sent.add(t);
        clock.advance(const Duration(microseconds: 8333));
      }
      clock.advance(const Duration(milliseconds: 50));
      final setCalls = engine.calls.where((c) => c == 'preview.setTransient').length;
      // 500 ms at 60 Hz: at most 31 flushes (the first one is immediate).
      expect(setCalls, lessThanOrEqualTo(31));
      expect(setCalls, greaterThanOrEqualTo(25));
      expect(sync.stats.transientsCoalesced, 60 - setCalls);
      expect(s.transients[clipId(1)], sent.last, reason: 'the newest transient is delivered');
      expect(s.plan!.rev, 1, reason: 'transients never touch the revision');
    });

    test('two items share one flush', () async {
      final (_, s) = await openFake();
      final clock = ManualClock();
      final sync = PlanSync(s, compile: CountingCompiler().call, clock: clock);
      final p = project(revision: 1);
      sync.schedule(p);
      await sync.flush();
      sync.sendTransient(clipId(0), transientOf(p, 0, 0.1));
      sync.sendTransient(clipId(1), transientOf(p, 1, 0.2));
      sync.sendTransient(clipId(2), transientOf(p, 2, 0.3));
      expect(s.transients.keys, [clipId(0)]);
      clock.advance(const Duration(milliseconds: 17));
      expect(s.transients.keys.toSet(), {clipId(0), clipId(1), clipId(2)});
      expect(sync.stats.transientFlushes, 2);
    });

    test('dropTransientsFor: the pending transient is discarded; the engine one is cleared after the commit applies', () async {
      final (engine, s) = await openFake();
      final clock = ManualClock();
      final sync = PlanSync(s, compile: CountingCompiler().call, clock: clock);
      final p = project(revision: 1);
      sync.schedule(p);
      await sync.flush();
      sync.sendTransient(clipId(0), transientOf(p, 0, 0.1)); // flushed at once
      sync.sendTransient(clipId(0), transientOf(p, 0, 0.2)); // pending
      // Commit of the gesture.
      sync.schedule(withOpacity(p, 0, 0.2, revision: 2));
      sync.dropTransientsFor(clipId(0));
      clock.advance(const Duration(milliseconds: 40));
      await sync.flush();
      expect(engine.calls.where((c) => c == 'preview.setTransient'), hasLength(1));
      final applied = engine.calls.lastIndexOf('preview.applyPatch');
      final cleared = engine.calls.lastIndexOf('preview.clearTransient');
      expect(cleared, greaterThan(applied), reason: 'cleared only after the commit is on screen');
      expect(s.transients, isEmpty);
      expect(sync.stats.transientsDropped, 1);

      // Idle: cleared at once.
      sync.dropTransientsFor(clipId(1));
      expect(engine.calls.last, 'preview.clearTransient');
    });

    test('dropped while the item has a structural change in flight', () async {
      final (fakeEngine, fake) = await openFake();
      final s = _GatedSession(fake);
      final clock = ManualClock();
      final sync = PlanSync(s, compile: CountingCompiler().call, clock: clock);
      final p0 = project(revision: 1);
      sync.schedule(p0);
      await sync.flush();
      // Structural commit on clip 2 (trimmed shorter), param-only nothing else.
      final out = applyCommand(p0, TrimItem(clipId(2), TrimEdge.end, FrameRate.fps30.timeOfFrame(80)),
          EditContext(ids: SeededIdGenerator(1), now: when));
      final p1 = out.project.copyWith(timeline: out.project.timeline.copyWith(revision: 2));
      s.gate = Completer<void>();
      sync.schedule(p1);
      await pumpMicrotasks();
      expect(sync.structuralPendingItems, {clipId(2)});
      sync.sendTransient(clipId(2), transientOf(p1, 2, 0.5));
      clock.advance(const Duration(milliseconds: 20));
      sync.sendTransient(clipId(0), transientOf(p1, 0, 0.5));
      clock.advance(const Duration(milliseconds: 20));
      expect(fake.transients.keys, [clipId(0)]);
      expect(sync.stats.transientsDropped, 1);
      s.gate!.complete();
      await sync.flush();
      expect(sync.structuralPendingItems, isEmpty);
      sync.sendTransient(clipId(2), transientOf(p1, 2, 0.5));
      clock.advance(const Duration(milliseconds: 20));
      expect(fake.transients.keys.toSet(), {clipId(0), clipId(2)});
      expect(fakeEngine.calls.where((c) => c == 'preview.applyPatch'), hasLength(1));
    });

    test('dispose stops scheduling and pending transients', () async {
      final (engine, s) = await openFake();
      final clock = ManualClock();
      final sync = PlanSync(s, compile: CountingCompiler().call, clock: clock);
      final p = project(revision: 1);
      sync.schedule(p);
      await sync.flush();
      sync.sendTransient(clipId(0), transientOf(p, 0, 0.1));
      sync.sendTransient(clipId(0), transientOf(p, 0, 0.2));
      await sync.dispose();
      clock.advance(const Duration(milliseconds: 40));
      sync.schedule(withOpacity(p, 0, 0.9, revision: 2));
      await pumpMicrotasks();
      expect(engine.calls.where((c) => c == 'preview.setTransient'), hasLength(1));
      expect(engine.calls.where((c) => c == 'preview.applyPatch'), isEmpty);
      await sync.flush();
    });
  });

  group('PreviewPlanCompiler', () {
    test('a cold compile above the threshold runs in an isolate; later compiles use the memo', () async {
      final compiler = PreviewPlanCompiler(resolver: resolverOf, isolateThreshold: 4);
      final big = project(n: 8, revision: 1);
      final a = await compiler(big);
      expect(compiler.isolateCompiles, 1);
      expect(a, compiled(big));
      final b = await compiler(withOpacity(big, 3, 0.5, revision: 2));
      expect(compiler.isolateCompiles, 1);
      expect(content(b), content(compiled(withOpacity(big, 3, 0.5, revision: 2))));
      compiler.reset();
      await compiler(big);
      expect(compiler.isolateCompiles, 2);
    });

    test('small projects compile inline', () async {
      final compiler = PreviewPlanCompiler(resolver: resolverOf);
      final p = project(revision: 1);
      expect(await compiler(p), compiled(p));
      expect(compiler.isolateCompiles, 0);
      expect(PreviewPlanCompiler.itemCountOf(p), 3);
    });

    test('drives PlanSync end to end', () async {
      final (_, s) = await openFake();
      final sync = PlanSync(s, compile: PreviewPlanCompiler(resolver: resolverOf).call);
      final p = project(revision: 1);
      sync.schedule(p);
      sync.schedule(withOpacity(p, 0, 0.5, revision: 2));
      await sync.flush();
      expect(content(s.plan!), content(compiled(withOpacity(p, 0, 0.5, revision: 2))));
    });
  });
}

Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);

/// Delegates to a fake session; `applyPatch` waits for [gate] when set.
final class _GatedSession implements PreviewSession {
  _GatedSession(this.inner);
  final FakePreviewSession inner;
  Completer<void>? gate;

  @override
  Future<PlanAck> applyPatch(RenderPlanPatch patch) async {
    final g = gate;
    if (g != null) await g.future;
    return inner.applyPatch(patch);
  }

  @override
  Future<PlanAck> setPlan(RenderPlan plan) => inner.setPlan(plan);
  @override
  void setTransient(ItemId item, PlanTransient transient) => inner.setTransient(item, transient);
  @override
  void clearTransient(ItemId item) => inner.clearTransient(item);
  @override
  int get textureId => inner.textureId;

  @override
  Future<void> setRenderedRanges(List<RenderedRange> ranges) => inner.setRenderedRanges(ranges);
  @override
  ValueListenable<Size?> get frameSize => inner.frameSize;
  @override
  Future<void> play({TimeRange? loop}) => inner.play(loop: loop);
  @override
  Future<void> pause() => inner.pause();
  @override
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}) => inner.seek(t, kind: kind);
  @override
  Future<void> setQuality(PreviewQuality quality) => inner.setQuality(quality);
  @override
  Future<void> setUseProxies(bool on) => inner.setUseProxies(on);
  @override
  Future<void> setEditingMode(PreviewEditingMode mode) => inner.setEditingMode(mode);
  @override
  Future<void> showSourceFrame(EngineMedia media, TimeUs sourceTime) => inner.showSourceFrame(media, sourceTime);
  @override
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint) => inner.sampleColor(item, normalizedSourcePoint);
  @override
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}) =>
      inner.renderLookStills(item, looks, heightPx: heightPx);
  @override
  Future<void> refresh() => inner.refresh();
  @override
  Future<Uint8List> debugCaptureFrame() => inner.debugCaptureFrame();
  @override
  Stream<PreviewClock> get clock => inner.clock;
  @override
  Stream<PreviewEvent> get events => inner.events;
  @override
  Future<void> dispose() => inner.dispose();
}
