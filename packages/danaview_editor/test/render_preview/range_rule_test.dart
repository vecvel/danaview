// OWNER: UX-44
//
// FIX-RANGE-RULE on the controller side (ARCH §12.2 'Rendered ranges', D-45 'Contract'). Native
// engines see plans, not patches: they drop a rendered range when the difference between two plans
// touches it (CORE-37 `rangeTouched`, replayed natively on the shared vectors), and they bind a
// `setRenderedRanges` list to the plan they hold when the call arrives.
//
// * Parity: on the shared vectors (core's `test/plan/render_cache/vectors/range_touch.json`) the
//   plan-difference rule equals API-01's reference rule `patchTouchesRange` applied to the patch
//   PlanSync actually sends (`diffPlans`), so the fake engine and the native engines drop the same
//   ranges.
// * The controller sends only while the engine holds the plan its list was computed for
//   (`engineHolds`); a render finishing while a touching patch is in flight is deferred, so a
//   stale render is never bound to the newer plan (the counterfactual without the guard binds it).
// * The engine drops ranges whose pixels did not change (a proxy arriving changes an asset); the
//   controller's resend after the applied plan restores exactly the hash-valid set.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String _vectors = '../danaview_editor_core/test/plan/render_cache/vectors/range_touch.json';

String _hashAt(RenderPlan plan, int k) => rangeHash(plan, splitRanges(plan).firstWhere((r) => r.start == f(k)));

int _sends(FakeEditorEngine engine) => engine.calls.where((c) => c == 'preview.setRenderedRanges').length;

void _run(void Function(FakeAsync async, FakeEditorEngine engine, MemoryRenderStore store, FakePreviewSession session) body) {
  fakeAsync((async) {
    final engine = FakeEditorEngine();
    final store = MemoryRenderStore();
    late FakePreviewSession session;
    unawaited(openSession(engine, basePlan()).then((s) => session = s));
    async.flushMicrotasks();
    body(async, engine, store, session);
    async.flushMicrotasks();
  });
}

RenderPreviewController _controller(FakeEditorEngine engine, MemoryRenderStore store, bool Function(RenderPlan)? holds) =>
    RenderPreviewController(
      jobs: engine.jobs,
      power: engine.background,
      store: store,
      tier: RenderTier.mid,
      budget: RenderBudget.forTier(RenderTier.mid),
      setting: () => RenderPreviewSetting.manual,
      engineHolds: holds,
    );

void main() {
  group('parity on the shared vectors', () {
    final doc = jsonDecode(File(_vectors).readAsStringSync()) as Map<String, Object?>;
    final cases = (doc['cases']! as List<Object?>).cast<Map<String, Object?>>();

    test('the plan-difference rule equals patchTouchesRange on the patch PlanSync sends', () {
      var checked = 0;
      for (final c in cases) {
        final before = PlanJson.decodePlan((c['before']! as Map).cast<String, Object?>());
        final after = PlanJson.decodePlan((c['after']! as Map).cast<String, Object?>());
        final patch = diffPlans(before, after);
        for (final r in (c['ranges']! as List<Object?>).cast<Map<String, Object?>>()) {
          final range = PlanRange(r['s']! as int, r['e']! as int);
          final touched = rangeTouched(before, after, range);
          expect(touched, r['touched'], reason: '${c['name']}: $range (committed verdict)');
          expect(patchTouchesRange(before, patch, range.range), touched, reason: '${c['name']}: $range (wire patch rule)');
          checked++;
        }
      }
      expect(checked, greaterThan(200));
    });
  });

  group('the controller binds a list only to the plan it was computed for', () {
    test('a render finishing while a touching patch is in flight is deferred, never bound to the newer plan', () {
      _run((async, engine, store, session) {
        final p1 = basePlan();
        var holds = true;
        var acked = p1;
        final c = _controller(engine, store, (p) => holds && identical(p, acked))..attach(session);
        unawaited(c.planChanged(p1));
        async.flushMicrotasks();
        final b1 = _hashAt(p1, 30), c1 = _hashAt(p1, 90);

        // PlanSync sends the edit (B moves, touching [30,60)); the engine applies it, the ack has
        // not reached Dart yet. Meanwhile the manual renders of p1's heavy ranges finish.
        final p2 = editedPlan();
        holds = false;
        unawaited(session.applyPatch(diffPlans(p1, p2)));
        async.flushMicrotasks();
        final sendsBefore = _sends(engine);
        unawaited(c.render(const RenderTarget.timeline()));
        async.flushMicrotasks();
        expect(store.puts.toSet(), {b1, c1}, reason: 'both renders finished');
        expect(_sends(engine), sendsBefore, reason: 'no list is sent while the engine may hold another plan');
        expect(c.sendDeferred, isTrue);
        expect(hashesOf(session.renderedRanges), isNot(contains(b1)));

        // Settling without a new plan keeps waiting while the engine still does not hold p1.
        c.planSettled();
        async.flushMicrotasks();
        expect(_sends(engine), sendsBefore);

        // The ack arrives: the controller recomputes for p2 and sends only what is valid there.
        acked = p2;
        holds = true;
        unawaited(c.planChanged(p2));
        async.flushMicrotasks();
        expect(c.sendDeferred, isFalse);
        expect(hashesOf(session.renderedRanges), {c1}, reason: 'B changed in p2: its p1 render must not play');
        c.dispose();
      });
    });

    test('without the guard the same race binds the stale render to the newer plan (the hazard)', () {
      _run((async, engine, store, session) {
        final p1 = basePlan();
        final c = _controller(engine, store, null)..attach(session);
        unawaited(c.planChanged(p1));
        async.flushMicrotasks();
        final b1 = _hashAt(p1, 30);
        unawaited(session.applyPatch(diffPlans(p1, editedPlan())));
        async.flushMicrotasks();
        unawaited(c.render(const RenderTarget.timeline()));
        async.flushMicrotasks();
        expect(hashesOf(session.renderedRanges), contains(b1), reason: 'a list for p1 bound to p2: B would play stale');
        c.dispose();
      });
    });

    test('a deferred send goes out when the plan sync settles on the same plan (failed patch)', () {
      _run((async, engine, store, session) {
        final p1 = basePlan();
        var holds = true;
        final c = _controller(engine, store, (p) => holds && identical(p, p1))..attach(session);
        unawaited(c.planChanged(p1));
        async.flushMicrotasks();
        holds = false; // a patch is in flight
        unawaited(c.render(const RenderTarget.timeline()));
        async.flushMicrotasks();
        expect(c.sendDeferred, isTrue);
        expect(session.renderedRanges, isEmpty);
        holds = true; // the patch failed: the engine still holds p1
        c.planSettled();
        async.flushMicrotasks();
        expect(c.sendDeferred, isFalse);
        expect(hashesOf(session.renderedRanges), {_hashAt(p1, 30), _hashAt(p1, 90)});
        c.dispose();
      });
    });
  });

  test('ranges the engine drops without a pixel change (a proxy arrives) come back with the resend', () {
    _run((async, engine, store, session) {
      final p1 = basePlan();
      var acked = p1;
      final c = _controller(engine, store, (p) => identical(p, acked))..attach(session);
      unawaited(c.planChanged(p1));
      unawaited(c.render(const RenderTarget.timeline()));
      async.flushMicrotasks();
      final rendered = hashesOf(session.renderedRanges);
      expect(rendered, hasLength(2));

      // The proxy of B's asset arrives: same fingerprint, new proxy uri. Every range is touched.
      final b = p1.assets['b']!;
      final p2 = RenderPlan(
        rev: 2,
        target: p1.target,
        canvas: p1.canvas,
        durUs: p1.durUs,
        assets: {
          ...p1.assets,
          'b': PlanAsset(
              kind: b.kind, uri: b.uri, fp: b.fp, w: b.w, h: b.h, rot: b.rot, durUs: b.durUs, proxyUri: 'file:///mem/cache/proxy_b.mp4'),
        },
        layers: p1.layers,
      );
      expect(splitRanges(p1).every((r) => rangeTouched(p1, p2, r)), isTrue);
      expect(invalidated(p1, p2), isEmpty);
      unawaited(session.applyPatch(diffPlans(p1, p2)));
      async.flushMicrotasks();
      expect(session.renderedRanges, isEmpty, reason: 'the engine drops every range on an asset change');

      acked = p2;
      unawaited(c.planChanged(p2));
      async.flushMicrotasks();
      expect(hashesOf(session.renderedRanges), rendered, reason: 'the hashes did not change, so the renders play again');
      c.dispose();
    });
  });
}
