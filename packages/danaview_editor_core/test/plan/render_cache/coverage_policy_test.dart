// OWNER: CORE-37
//
// coverage() for the timeline render marker and the RenderPolicy truth table (ARCH D-45(A),
// §17.10): Auto renders only on minimal/low while idle and charging; Manual never auto-renders;
// the manual action is allowed on every tier.

import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:test/test.dart';

import 'support.dart';

final class SetLookup implements RenderCacheLookup {
  SetLookup(this.hashes);
  final Set<String> hashes;
  @override
  bool contains(String hash) => hashes.contains(hash);
}

void main() {
  group('coverage', () {
    // [0,10) one layer, [10,20) three layers (heavy on minimal), [20,30) gap, [30,40) chroma.
    final p = plan([
      media('a#v', 0, 20, 'a'),
      media('b#v', 10, 20, 'b', z: 1),
      media('c#v', 10, 20, 'c', z: 2),
      media('k#v', 30, 40, 'k', z: 3, fx: const PlanEffects(chroma: PlanChroma(key: 0x00FF00))),
    ]);
    final budget = RenderBudget.forTier(RenderTier.minimal);

    test('nothing rendered: heavy ranges amber, the rest not needed, gaps included', () {
      final c = coverage(p, SetLookup({}), budget);
      expect(c.map((s) => s.range), [PlanRange(f(0), f(10)), PlanRange(f(10), f(20)), PlanRange(f(20), f(30)), PlanRange(f(30), f(40))]);
      expect(c.map((s) => s.state), [RangeState.notNeeded, RangeState.heavyUnrendered, RangeState.notNeeded, RangeState.heavyUnrendered]);
      expect(c[1].reasons, {HeavyReason.decoders});
      expect(c[3].reasons, {HeavyReason.chromaKey});
      expect(c.map((s) => s.hash), rangeHashes(p));
    });

    test('a rendered hash marks its range rendered (heavy or manually rendered light range)', () {
      final hashes = rangeHashes(p);
      final c = coverage(p, SetLookup({hashes[1], hashes[0]}), budget);
      expect(c.map((s) => s.state), [RangeState.rendered, RangeState.rendered, RangeState.notNeeded, RangeState.heavyUnrendered]);
      expect(c[1].isHeavy, isTrue);
    });

    test('an edit inside a rendered range turns it back to heavy-unrendered', () {
      final hashes = rangeHashes(p);
      final edited = withLayer(p, media('b#v', 10, 20, 'b', z: 1, xf: const PlanTransform(s: 0.9)));
      final c = coverage(edited, SetLookup({hashes[1]}), budget);
      expect(c[1].state, RangeState.heavyUnrendered);
      expect(invalidated(p, edited), {hashes[1]});
    });

    test('preview size is part of the hash', () {
      final hashes = rangeHashes(p, previewSize: const RenderSize(640, 360));
      final c = coverage(p, SetLookup(hashes.toSet()), budget, previewSize: const RenderSize(640, 360));
      expect(c.every((s) => s.state == RangeState.rendered), isTrue);
      final other = coverage(p, SetLookup(hashes.toSet()), budget);
      expect(other.any((s) => s.state == RangeState.rendered), isFalse);
    });
  });

  group('RenderPolicy', () {
    test('truth table of shouldAutoRender', () {
      for (final tier in RenderTier.values) {
        for (final setting in RenderPreviewSetting.values) {
          for (final idle in [false, true]) {
            for (final charging in [false, true]) {
              final expected = setting == RenderPreviewSetting.auto &&
                  (tier == RenderTier.minimal || tier == RenderTier.low) &&
                  idle &&
                  charging;
              expect(RenderPolicy.shouldAutoRender(tier, setting, idle: idle, charging: charging), expected,
                  reason: '$tier $setting idle=$idle charging=$charging');
            }
          }
        }
      }
    });

    test('tier defaults: Auto on minimal/low, Manual on mid/high', () {
      expect({for (final t in RenderTier.values) t: RenderPolicy.defaultSetting(t)}, {
        RenderTier.minimal: RenderPreviewSetting.auto,
        RenderTier.low: RenderPreviewSetting.auto,
        RenderTier.mid: RenderPreviewSetting.manual,
        RenderTier.high: RenderPreviewSetting.manual,
      });
    });

    test('manual action on every tier', () {
      expect(RenderTier.values.every(RenderPolicy.manualRenderAllowed), isTrue);
    });

    test('idle means 5 s without playback, edit or job', () {
      final t = DateTime.utc(2026, 10, 14, 12);
      expect(RenderPolicy.isIdle(lastActivity: t, now: t.add(const Duration(milliseconds: 4999))), isFalse);
      expect(RenderPolicy.isIdle(lastActivity: t, now: t.add(const Duration(seconds: 5))), isTrue);
    });
  });
}
