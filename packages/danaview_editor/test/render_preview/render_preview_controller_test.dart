// OWNER: UX-44
//
// RenderPreviewController against API-01's FakeEditorEngine and CORE-37's real cache index on an
// in-memory file system (BUILD_PLAN UX-44 acceptance):
//
// * an edit inside a rendered range removes it from setRenderedRanges before the new plan plays
//   (the engine drops it on the patch; the controller's resend never brings it back), and an undo
//   finds the old render again;
// * Auto renders only when idle (5 s) and charging on minimal/low, never on mid/high, never with
//   Manual;
// * the manual action works on every tier (selection/loop span, marker range, whole timeline);
// * jobs cancel on playback, on an edit inside their range, on export start and on memory pressure;
// * `notSupportedOnDevice` keeps live preview;
// * `rangePlanOf` cuts valid preview plans with relative times.

import 'dart:async';

import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _charging = PowerState(charging: true, lowPowerMode: false);
const _onBattery = PowerState(charging: false, lowPowerMode: false);

/// Hash of the range starting at frame [k] of [plan].
String _hashAt(RenderPlan plan, int k) => coverage(plan, const _None(), RenderBudget.forTier(RenderTier.mid))
    .firstWhere((r) => r.range.start == f(k))
    .hash;

final class _None implements RenderCacheLookup {
  const _None();
  @override
  bool contains(String hash) => false;
}

/// Runs [body] in fake time with a fresh engine, store and session on [plan].
void _run(void Function(FakeAsync async, FakeEditorEngine engine, MemoryRenderStore store, FakePreviewSession session) body,
    {RenderPlan? plan}) {
  fakeAsync((async) {
    final engine = FakeEditorEngine();
    final store = MemoryRenderStore();
    late FakePreviewSession session;
    unawaited(openSession(engine, plan ?? basePlan()).then((s) => session = s));
    async.flushMicrotasks();
    body(async, engine, store, session);
    async.flushMicrotasks();
  });
}

void main() {
  group('rendered ranges follow the plan', () {
    test('an edit inside a rendered range removes it from setRenderedRanges before the new plan plays', () {
      _run((async, engine, store, session) {
        final p1 = basePlan();
        final c = controllerFor(engine, store: store, setting: RenderPreviewSetting.manual)..attach(session);
        unawaited(c.planChanged(p1));
        async.flushMicrotasks();
        expect(session.renderedRanges, isEmpty, reason: 'nothing rendered yet');

        late RenderRequestOutcome outcome;
        unawaited(c.render(const RenderTarget.timeline()).then((o) => outcome = o));
        async.flushMicrotasks();
        expect(outcome, RenderRequestOutcome.started);
        final b1 = _hashAt(p1, 30), c1 = _hashAt(p1, 90);
        expect(store.puts.toSet(), {b1, c1}, reason: 'the two heavy ranges were rendered');
        expect(hashesOf(session.renderedRanges), {b1, c1});
        expect(session.renderedRanges.map((r) => r.range), [TimeRange(f(30), f(60)), TimeRange(f(90), f(120))]);
        expect(session.renderedRanges.every((r) => r.uri.startsWith('file:///mem/cache/danaview/editor/renders/')), isTrue);

        // The edit moves B (inside [30,60) only). The patch reaches the engine first.
        final p2 = editedPlan();
        unawaited(session.applyPatch(diffPlans(p1, p2)));
        async.flushMicrotasks();
        expect(hashesOf(session.renderedRanges), {c1}, reason: 'the engine dropped the touched range on the patch');
        expect(hashesOf(session.droppedRanges), contains(b1));

        // The controller's resend after the plan was applied keeps only valid entries.
        unawaited(c.planChanged(p2));
        async.flushMicrotasks();
        expect(hashesOf(session.renderedRanges), {c1});
        final current = rangeHashes(p2).toSet();
        expect(session.renderedRanges.every((r) => current.contains(r.hash)), isTrue);
        final b = c.value.ranges.firstWhere((r) => r.range.start == f(30));
        expect(b.state, RangeState.heavyUnrendered);
        expect(c.value.ranges.firstWhere((r) => r.range.start == f(90)).state, RangeState.rendered);

        // Undo: the old range comes back with its old hash and its render plays again.
        final p3 = basePlan(rev: 3);
        unawaited(session.applyPatch(diffPlans(p2, p3)));
        unawaited(c.planChanged(p3));
        async.flushMicrotasks();
        expect(hashesOf(session.renderedRanges), {b1, c1});
        expect(store.puts, hasLength(2), reason: 'no new render was needed after the undo');
        c.dispose();
      });
    });

    test('a setPlan (restart) gets every valid range back', () {
      _run((async, engine, store, session) {
        final p1 = basePlan();
        final c = controllerFor(engine, store: store)..attach(session);
        unawaited(c.planChanged(p1));
        unawaited(c.render(const RenderTarget.timeline()));
        async.flushMicrotasks();
        unawaited(session.setPlan(basePlan(rev: 5)));
        async.flushMicrotasks();
        expect(session.renderedRanges, isEmpty);
        unawaited(c.planChanged(basePlan(rev: 5)));
        async.flushMicrotasks();
        expect(session.renderedRanges, hasLength(2));
        c.dispose();
      });
    });
  });

  group('Auto policy (idle 5 s and charging)', () {
    for (final tier in [RenderTier.minimal, RenderTier.low]) {
      test('${tier.name}: renders only while idle and charging', () {
        _run((async, engine, store, session) {
          engine.background.setPowerState(_onBattery);
          final c = controllerFor(engine, store: store, tier: tier)..attach(session);
          expect(c.value.setting, RenderPreviewSetting.auto, reason: 'tier default');
          unawaited(c.planChanged(basePlan()));
          async.elapse(const Duration(seconds: 30));
          expect(engine.jobs.renderRequests, isEmpty, reason: 'idle but not charging');

          engine.background.setPowerState(_charging);
          async.flushMicrotasks();
          expect(engine.jobs.renderRequests, hasLength(2), reason: 'idle and charging: both heavy ranges render');
          expect(engine.jobs.created.where((j) => j.id.startsWith('renderPreview')).every((j) => j.priority == JobPriority.background), isTrue);
          expect(c.value.ranges.where((r) => r.state == RangeState.rendered), hasLength(2));
          expect(c.value.ranges.where((r) => r.state == RangeState.notNeeded), hasLength(2), reason: 'light ranges are never auto-rendered');
          c.dispose();
        });
      });

      test('${tier.name}: waits for 5 s without an edit, playback or job', () {
        _run((async, engine, store, session) {
          engine.background.setPowerState(_charging);
          final c = controllerFor(engine, store: store, tier: tier)..attach(session);
          unawaited(c.planChanged(basePlan()));
          async.elapse(const Duration(seconds: 3));
          c.jobActivity();
          async.elapse(const Duration(seconds: 4));
          expect(engine.jobs.renderRequests, isEmpty, reason: 'a job ran 4 s ago');
          unawaited(c.planChanged(editedPlan()));
          async.elapse(const Duration(seconds: 4));
          expect(engine.jobs.renderRequests, isEmpty, reason: 'an edit 4 s ago');
          c.playingChanged(true);
          async.elapse(const Duration(seconds: 20));
          expect(engine.jobs.renderRequests, isEmpty, reason: 'playing');
          c.playingChanged(false);
          async.elapse(const Duration(milliseconds: 4900));
          expect(engine.jobs.renderRequests, isEmpty);
          async.elapse(const Duration(milliseconds: 200));
          expect(engine.jobs.renderRequests, isNotEmpty, reason: 'idle for 5 s and charging');
          c.dispose();
        });
      });

      test('${tier.name}: Manual never renders automatically', () {
        _run((async, engine, store, session) {
          engine.background.setPowerState(_charging);
          final c = controllerFor(engine, store: store, tier: tier, setting: RenderPreviewSetting.manual)..attach(session);
          unawaited(c.planChanged(basePlan()));
          async.elapse(const Duration(minutes: 1));
          expect(engine.jobs.renderRequests, isEmpty);
          c.dispose();
        });
      });
    }

    for (final tier in [RenderTier.mid, RenderTier.high]) {
      test('${tier.name}: never renders automatically, even with Auto chosen', () {
        _run((async, engine, store, session) {
          engine.background.setPowerState(_charging);
          for (final setting in [null, RenderPreviewSetting.auto]) {
            final c = controllerFor(engine, store: store, tier: tier, setting: setting)..attach(session);
            unawaited(c.planChanged(basePlan()));
            async.elapse(const Duration(minutes: 1));
            expect(engine.jobs.renderRequests, isEmpty, reason: 'setting $setting');
            c.dispose();
          }
        });
      });
    }

    test('a failed automatic render is not retried this session', () {
      _run((async, engine, store, session) {
        engine.background.setPowerState(_charging);
        engine.failNext['jobs.renderPreview'] = EngineFailure.of(EngineErrorCode.encodingFailed);
        final c = controllerFor(engine, store: store, tier: RenderTier.low)..attach(session);
        unawaited(c.planChanged(basePlan()));
        async.elapse(const Duration(seconds: 6));
        expect(engine.jobs.renderRequests, hasLength(2), reason: 'the first failed, the second rendered');
        c.jobActivity();
        async.elapse(const Duration(seconds: 6));
        expect(engine.jobs.renderRequests, hasLength(2));
        c.dispose();
      });
    });
  });

  group('the manual action works on every tier', () {
    for (final tier in RenderTier.values) {
      test(tier.name, () {
        _run((async, engine, store, session) {
          final c = controllerFor(engine, store: store, tier: tier)..attach(session);
          final plan = basePlan();
          unawaited(c.planChanged(plan));
          async.flushMicrotasks();

          // A marker range.
          late RenderRequestOutcome outcome;
          unawaited(c.render(RenderTarget.range(TimeRange(f(30), f(60)))).then((o) => outcome = o));
          async.flushMicrotasks();
          expect(outcome, RenderRequestOutcome.started);
          expect(store.puts, [_hashAt(plan, 30)]);
          expect(engine.jobs.created.last.priority, JobPriority.normal);

          // Again: already rendered.
          unawaited(c.render(RenderTarget.range(TimeRange(f(30), f(60)))).then((o) => outcome = o));
          async.flushMicrotasks();
          expect(outcome, RenderRequestOutcome.alreadyRendered);

          // A selection span renders every range in it, light ones too.
          unawaited(c.render(RenderTarget.selection(TimeRange(f(0), f(20)))).then((o) => outcome = o));
          async.flushMicrotasks();
          expect(outcome, RenderRequestOutcome.started);
          expect(store.puts.last, _hashAt(plan, 0));

          // The whole timeline renders what needs it.
          unawaited(c.render(const RenderTarget.timeline()).then((o) => outcome = o));
          async.flushMicrotasks();
          expect(store.puts.toSet(), {_hashAt(plan, 30), _hashAt(plan, 0), _hashAt(plan, 90)});
          expect(hashesOf(session.renderedRanges), store.puts.toSet());
          c.dispose();
        });
      });
    }

    test('a light timeline has nothing to render; no store means unavailable', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        unawaited(c.planChanged(lightPlan()));
        async.flushMicrotasks();
        late RenderRequestOutcome outcome;
        unawaited(c.render(const RenderTarget.timeline()).then((o) => outcome = o));
        async.flushMicrotasks();
        expect(outcome, RenderRequestOutcome.nothingToRender);
        c.dispose();

        final none = controllerFor(engine)..attach(session);
        unawaited(none.planChanged(basePlan()));
        unawaited(none.render(const RenderTarget.timeline()).then((o) => outcome = o));
        async.flushMicrotasks();
        expect(outcome, RenderRequestOutcome.unavailable);
        expect(none.value.available, isFalse);
        none.dispose();
      }, plan: lightPlan());
    });

    test('the done notice follows the last manual render', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        final notices = <RenderPreviewNotice>[];
        c.notices.listen(notices.add);
        unawaited(c.planChanged(basePlan()));
        unawaited(c.render(const RenderTarget.timeline()));
        async.flushMicrotasks();
        expect(notices, [RenderPreviewNotice.done]);
        c.dispose();
      });
    });
  });

  group('jobs cancel', () {
    void startHeld(FakeAsync async, FakeEditorEngine engine, RenderPreviewController c, {TimeRange? span}) {
      engine.jobs.holdRenders = true;
      unawaited(c.planChanged(basePlan()));
      async.flushMicrotasks();
      unawaited(c.render(span == null ? const RenderTarget.timeline() : RenderTarget.range(span)));
      async.flushMicrotasks();
      expect(c.value.active, isNotNull);
    }

    FakeMediaJob<Object?> lastJob(FakeEditorEngine engine) => engine.jobs.created.last;

    test('on playback start (a manual render resumes after)', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        startHeld(async, engine, c);
        final job = lastJob(engine);
        final hash = c.value.active!.hash;
        c.playingChanged(true);
        async.flushMicrotasks();
        expect(job.cancelled, isTrue);
        expect(engine.jobs.files, isEmpty, reason: 'cancel deletes the partial output');
        expect(c.value.active, isNull);
        expect(c.value.queued.first, hash, reason: 'a manual render goes back to the head of the queue');
        expect(c.value.suspended, isTrue);
        c.playingChanged(false);
        async.flushMicrotasks();
        expect(c.value.active?.hash, hash);
        expect(lastJob(engine), isNot(same(job)));
        c.dispose();
      });
    });

    test('on an automatic render when playback starts', () {
      _run((async, engine, store, session) {
        engine.background.setPowerState(_charging);
        engine.jobs.holdRenders = true;
        final c = controllerFor(engine, store: store, tier: RenderTier.minimal)..attach(session);
        unawaited(c.planChanged(basePlan()));
        async.elapse(const Duration(seconds: 6));
        final job = lastJob(engine);
        expect(c.value.active?.manual, isFalse);
        c.playingChanged(true);
        async.flushMicrotasks();
        expect(job.cancelled, isTrue);
        expect(c.value.queued, isEmpty);
        c.dispose();
      });
    });

    test('on an edit inside the range (not on an edit elsewhere)', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        startHeld(async, engine, c, span: TimeRange(f(90), f(120)));
        final job = lastJob(engine);
        // Editing B ([30,60)) leaves C's render running.
        unawaited(c.planChanged(editedPlan()));
        async.flushMicrotasks();
        expect(job.cancelled, isFalse);
        // Editing C cancels it.
        final p3 = planOf([
          media('it_a#v0', 0, 120, 'a'),
          media('it_b#v0', 30, 60, 'b', z: 1, fx: chroma, xf: const PlanTransform(s: 0.5)),
          media('it_c#v0', 90, 120, 'c', z: 2, fx: chroma, xf: const PlanTransform(r: 10)),
        ], rev: 3);
        unawaited(c.planChanged(p3));
        async.flushMicrotasks();
        expect(job.cancelled, isTrue);
        expect(c.value.active, isNull);
        expect(c.value.queued, isEmpty, reason: 'the old range no longer exists');
        c.dispose();
      });
    });

    test('on export start, and the action waits for the export', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        startHeld(async, engine, c);
        final job = lastJob(engine);
        c.exportChanged(true);
        async.flushMicrotasks();
        expect(job.cancelled, isTrue);
        expect(c.blockedReason, RenderRequestOutcome.exportRunning);
        late RenderRequestOutcome outcome;
        unawaited(c.render(const RenderTarget.timeline()).then((o) => outcome = o));
        async.flushMicrotasks();
        expect(outcome, RenderRequestOutcome.exportRunning);
        c.exportChanged(false);
        async.flushMicrotasks();
        expect(c.value.active, isNotNull, reason: 'the manual render resumes after the export');
        c.dispose();
      });
    });

    test('on memory pressure (queue emptied, cache trimmed)', () {
      _run((async, engine, store, session) {
        final c = controllerFor(engine, store: store)..attach(session);
        startHeld(async, engine, c);
        final job = lastJob(engine);
        expect(c.value.queued, hasLength(1));
        unawaited(c.memoryPressure());
        async.flushMicrotasks();
        expect(job.cancelled, isTrue);
        expect(c.value.busy, isFalse);
        c.dispose();
      });
    });
  });

  test('notSupportedOnDevice keeps live preview for the session', () {
    _run((async, engine, store, session) {
      engine.failNext['jobs.renderPreview'] = EngineFailure.of(EngineErrorCode.notSupportedOnDevice);
      final c = controllerFor(engine, store: store)..attach(session);
      final notices = <RenderPreviewNotice>[];
      c.notices.listen(notices.add);
      unawaited(c.planChanged(basePlan()));
      unawaited(c.render(const RenderTarget.timeline()));
      async.flushMicrotasks();
      expect(c.value.unsupported, isTrue);
      expect(engine.jobs.renderRequests, hasLength(1), reason: 'no further attempts');
      expect(notices, [RenderPreviewNotice.unsupported]);
      expect(session.renderedRanges, isEmpty);
      late RenderRequestOutcome outcome;
      unawaited(c.render(const RenderTarget.timeline()).then((o) => outcome = o));
      async.flushMicrotasks();
      expect(outcome, RenderRequestOutcome.unsupported);
      c.dispose();
    });
  });

  test('clearRendered empties renders/ and the session set', () {
    _run((async, engine, store, session) {
      final c = controllerFor(engine, store: store)..attach(session);
      unawaited(c.planChanged(basePlan()));
      unawaited(c.render(const RenderTarget.timeline()));
      async.flushMicrotasks();
      late int before;
      unawaited(c.renderedBytes().then((b) => before = b));
      async.flushMicrotasks();
      expect(before, greaterThanOrEqualTo(2 * MemoryRenderStore.renderBytes));
      unawaited(c.clearRendered());
      async.flushMicrotasks();
      expect(session.renderedRanges, isEmpty);
      expect(store.memory.filePaths.where((p) => p.contains('/renders/')), isEmpty);
      expect(c.value.ranges.where((r) => r.state == RangeState.rendered), isEmpty);
      c.dispose();
    });
  });

  group('rangePlanOf', () {
    test('cuts every range into a valid preview plan with relative times', () {
      final plan = basePlan();
      for (final range in splitRanges(plan)) {
        final cut = rangePlanOf(plan, range);
        expect(PlanValidator.validate(cut), isEmpty, reason: '$range');
        expect(cut.target, PlanTarget.preview);
        expect(cut.durUs, grid.timeOfFrame(grid.frameIndexOf(range.end) - grid.frameIndexOf(range.start)));
        expect(cut.audio, isEmpty);
        expect(cut.layers.every((l) => l.t0 >= 0 && l.t1 <= cut.durUs), isTrue);
      }
      final b = rangePlanOf(plan, PlanRange(f(30), f(60)));
      expect(b.layers.map((l) => l.id), ['it_a#v0', 'it_b#v0']);
      final a = b.layers.first;
      expect(a.map.single.s0, f(30), reason: 'the background continues from source frame 30');
      expect(b.assets.keys.toSet(), {'a', 'b'});
    });

    test('clips keyframes to the range', () {
      final plan = planOf([
        media('it_a#v0', 0, 60, 'a', anim: {
          'xf.op': [AnimKey(f(0), 0), AnimKey(f(60), 1)],
        }),
      ]);
      final cut = rangePlanOf(plan, PlanRange(f(30), f(60)));
      expect(PlanValidator.validate(cut), isEmpty);
      final keys = cut.layers.single.anim['xf.op']!;
      expect(keys.first.tUs, 0);
      expect(keys.first.v, closeTo(0.5, 0.01));
      expect(keys.last.v, closeTo(1, 1e-9));
    });
  });
}
