// OWNER: CORE-37
//
// heavyRanges per tier (ARCH D-45(A)) against the committed vectors in vectors/heavy_ranges.json:
// decoders over budget (live layers or Android packed slots), chroma key, effect cost.

import 'dart:convert';
import 'dart:io';

import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:test/test.dart';

import 'support.dart';

final Map<String, Object?> vectors =
    jsonDecode(File('test/plan/render_cache/vectors/heavy_ranges.json').readAsStringSync()) as Map<String, Object?>;

RenderBudget budgetOf(String key) {
  final parts = key.split('.');
  final tier = RenderTier.values.byName(parts[1]);
  return parts[0] == 'android'
      ? RenderBudget.forTier(tier, maxVisualSequences: RenderBudget.defaultLiveDecoders(tier))
      : RenderBudget.forTier(tier);
}

PlanEffects effectsOf(List<Object?> names, bool chroma) => PlanEffects(
      detail: names.contains('blur') || names.contains('sharpen')
          ? PlanDetail(blur: names.contains('blur') ? 0.5 : 0, sharpen: names.contains('sharpen') ? 0.5 : 0)
          : null,
      lut: names.contains('lut') ? const PlanLut('lut1', 1) : null,
      mask: names.contains('mask') ? const PlanMask(shape: PlanMaskShape.ellipse, w: 0.5, h: 0.5) : null,
      chroma: chroma ? const PlanChroma(key: 0x00FF00) : null,
    );

RenderPlan planOf(Map<String, Object?> c) {
  final chromaOn = ((c['chromaOn'] as List<Object?>?) ?? const []).cast<int>();
  final layers = <PlanLayer>[];
  final specs = (c['layers']! as List<Object?>).cast<Map<String, Object?>>();
  for (var i = 0; i < specs.length; i++) {
    final s = specs[i];
    final k = (s['k']! as List<Object?>).cast<int>();
    final z = s['z']! as int;
    final fx = effectsOf((s['fx'] as List<Object?>?) ?? const [], chromaOn.contains(i));
    layers.add(switch (s['kind']) {
      'media' => media('l$i#v', k[0], k[1], (s['asset'] as String?) ?? 'v$i',
          z: z, seq: s['seq'] as int?, src: (s['src'] as int?) ?? 0, fx: fx, hold: s['hold'] == true),
      'image' => still('l$i#v', k[0], k[1], 'i$i', z: z, fx: fx),
      _ => solid('l$i#v', k[0], k[1], z: z),
    });
  }
  final assets = <String, PlanAsset>{'lut1': lutAsset('lut1')};
  for (final l in layers) {
    if (l.asset == null) continue;
    assets[l.asset!] = l.kind == PlanLayerKind.image ? image('fp_${l.asset}') : video('fp_${l.asset}');
  }
  return plan(layers, assets: assets);
}

void main() {
  test('vector budgets are RenderBudget.forTier', () {
    final budgets = (vectors['budgets']! as Map<String, Object?>).cast<String, Map<String, Object?>>();
    expect(budgets, hasLength(8));
    for (final MapEntry(key: key, value: b) in budgets.entries) {
      final budget = budgetOf(key);
      expect(budget, RenderBudget(maxLiveDecoders: b['maxLiveDecoders']! as int, maxLiveSlots: b['maxLiveSlots'] as int?, effectCostLimit: b['effectCostLimit']! as int), reason: key);
    }
  });

  for (final c in (vectors['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
    test(c['name'], () {
      final p = planOf(c);
      for (final MapEntry(key: key, value: expected) in (c['expect']! as Map<String, Object?>).entries) {
        final want = [
          for (final e in (expected! as List<Object?>).cast<Map<String, Object?>>())
            HeavyRange(
              PlanRange(f((e['k']! as List<Object?>)[0]! as int), f((e['k']! as List<Object?>)[1]! as int)),
              {for (final r in (e['reasons']! as List<Object?>).cast<String>()) HeavyReason.values.byName(r)},
            ),
        ];
        expect(heavyRanges(p, budgetOf(key)), want, reason: '${c['name']} on $key');
      }
    });
  }

  test('layerEffectCost counts animated blur, sharpen and mask channels', () {
    final l = media('a#v', 0, 30, 'a', anim: {
      'detail.blur': [AnimKey(f(0), 0), AnimKey(f(10), 0.4)],
      'detail.sharpen': [AnimKey(f(0), 0)],
      'mask.w': [AnimKey(f(0), 1)],
    });
    expect(layerEffectCost(l), 2, reason: 'blur animates above 0, sharpen stays 0, a mask channel animates');
  });

  test('RenderTier and budgets', () {
    expect(RenderTier.values.where((t) => t.isConstrained), [RenderTier.minimal, RenderTier.low]);
    expect(RenderBudget.forTier(RenderTier.mid, maxConcurrentVideoLayers: 3).maxLiveDecoders, 3, reason: 'capabilities win');
  });
}
