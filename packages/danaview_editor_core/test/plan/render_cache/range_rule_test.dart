// OWNER: CORE-37
//
// FIX-RANGE-RULE: the engine's rendered-range rule against the hashes (ARCH §12.2 'Rendered
// ranges', D-45 'Contract'). Native engines only see plans, so IOS-19 and AND-18 drop a rendered
// range when the DIFFERENCE of two plans touches it (`rangeTouched`, the Dart mirror of
// `RenderedRangeRules.changeTouches` / `RangeTouch.changeTouches`). Over the same plan pairs:
//
// * P1 (no stale render): a range the engine keeps has the same hash in the new plan, so a kept
//   range never shows pixels that changed.
// * P2: a hash `invalidated` reports belonged to a range the engine dropped, or to a range the new
//   plan cut differently (same pixels, re-split).
// * The engine drops strictly more than the hash rule (ripple, proxy/uri change, re-split, seq or
//   id change); the controller restores those by resending after every applied plan (UX-44).
//
// The plan pairs (hand-made edge cases, random plan-level edits that may or may not change pixels,
// real editing commands on compiled projects) are committed as the shared vectors
// `test/fixtures/vectors/range_touch.json` (bundled into the iOS RunnerTests as
// `TestFixtures.url(.core, "vectors/range_touch.json")`), with the rule's verdict per range, for
// the native suites to replay. Native replay is not enforced yet: FIX-IOS-19-1 and FIX-AND-18-1
// (BUILD_STATE.md) add the RunnerTest and the Android unit test that assert `touched`.
// Regenerate with `UPDATE_RANGE_VECTORS=1 dart test test/plan/render_cache/range_rule_test.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:test/test.dart';

import '../../support/random_project.dart';
import '../compile_visual/support.dart' show resolverFor;
import '../diff/diff_support.dart' show compileMemo, randomEdit;
import 'support.dart';

const String vectorsPath = 'test/fixtures/vectors/range_touch.json';

/// One plan pair.
final class PlanPair {
  PlanPair(this.name, this.before, this.after);
  final String name;
  final RenderPlan before;
  final RenderPlan after;
}

RenderPlan _replan(RenderPlan p, List<PlanLayer> layers,
    {Map<String, PlanAsset>? assets, PlanCanvas? canvas, TimeUs? durUs, List<AudioSeg>? audio}) {
  final base = plan(layers, assets: assets ?? p.assets, rev: p.rev + 1, canvas: canvas ?? p.canvas);
  return RenderPlan(
    rev: base.rev,
    target: base.target,
    canvas: base.canvas,
    durUs: durUs ?? base.durUs,
    assets: base.assets,
    layers: base.layers,
    audio: audio ?? p.audio,
  );
}

AudioSeg _audio(String id, int k0, int k1, String asset, {double gain = 1}) => AudioSeg(
      id: id,
      asset: asset,
      t0: f(k0),
      t1: f(k1),
      map: [MapSegment(f(k0), f(k1), 0, f(k1) - f(k0))],
      gain: [AnimKey(0, gain)],
    );

/// Hand-made edge cases on A 0–120 (background), B 30–60 (z 1), C 90–120 (z 2).
List<PlanPair> handCases() {
  final assets = {'a': video('fp_a'), 'b': video('fp_b'), 'c': video('fp_c'), 'm': video('fp_m')};
  final a = media('a#v', 0, 120, 'a');
  final b = media('b#v', 30, 60, 'b', z: 1);
  final c = media('c#v', 90, 120, 'c', z: 2);
  final p0 = plan([a, b, c], assets: assets);
  final base = RenderPlan(
    rev: p0.rev,
    target: p0.target,
    canvas: p0.canvas,
    durUs: p0.durUs,
    assets: p0.assets,
    layers: p0.layers,
    audio: [_audio('m#a', 0, 120, 'm')],
  );
  List<PlanLayer> others(String id) => [
        for (final l in base.layers)
          if (l.id != id) l
      ];
  return [
    PlanPair('param edit inside one range', base, _replan(base, [...others('b#v'), copyLayer(b, xf: const PlanTransform(s: 0.5))])),
    PlanPair(
        'keyframe edit',
        base,
        _replan(base, [
          ...others('c#v'),
          copyLayer(c, anim: {
            'xf.op': const [AnimKey(0, 1), AnimKey(500000, 0)]
          })
        ])),
    PlanPair('remove the spanning layer', base, _replan(base, others('a#v'))),
    PlanPair('add a layer over the gap', base, _replan(base, [...base.layers, solid('t#v', 65, 80, z: 5)])),
    PlanPair(
        'ripple: everything moves one second later',
        base,
        _replan(base, [
          for (final l in base.layers)
            copyLayer(l,
                t0: l.t0 + f(30), t1: l.t1 + f(30), map: [for (final m in l.map) MapSegment(m.t0 + f(30), m.t1 + f(30), m.s0, m.s1)]),
        ])),
    PlanPair('proxy arrives (asset uri change, same fp)', base,
        _replan(base, base.layers, assets: {...assets, 'b': video('fp_b', proxy: 'file:///cache/proxy_b.mp4')})),
    PlanPair('asset added only', base, _replan(base, base.layers, assets: {...assets, 'z': video('fp_z')})),
    PlanPair('canvas change', base, _replan(base, base.layers, canvas: const PlanCanvas(w: 1280, h: 720, fps: 30))),
    PlanPair('duration shrinks (empty tail removed)', _replan(base, base.layers, durUs: f(150)), base.copyWith(rev: base.rev + 2)),
    PlanPair('duration grows (empty tail)', base, _replan(base, base.layers, durUs: f(150))),
    PlanPair('seq slot change only', base, _replan(base, [...others('b#v'), copyLayer(b, seq: 7)])),
    PlanPair(
        'split B into two seamless halves',
        base,
        _replan(base, [
          ...others('b#v'),
          copyLayer(b, id: 'b1#v', t1: f(45), map: [MapSegment(f(30), f(45), 0, f(15))]),
          copyLayer(b, id: 'b2#v', t0: f(45), map: [MapSegment(f(45), f(60), f(15), f(30))]),
        ])),
    PlanPair(
        'trim the tail of the spanning layer',
        base,
        _replan(base, [
          ...others('a#v'),
          copyLayer(a, t1: f(110), map: [MapSegment(0, f(110), 0, f(110))])
        ])),
    PlanPair('audio only', base, _replan(base, base.layers, audio: [_audio('m#a', 0, 120, 'm', gain: 0.5)])),
    PlanPair('identical plan, new revision', base, base.copyWith(rev: base.rev + 1)),
  ];
}

/// A random plan-level edit that may or may not change pixels.
RenderPlan randomAnyEdit(RenderPlan p, Random rnd) {
  final l = p.layers[rnd.nextInt(p.layers.length)];
  List<PlanLayer> others() => [
        for (final x in p.layers)
          if (x.id != l.id) x
      ];
  switch (rnd.nextInt(9)) {
    case 0:
      return _replan(p, [...others(), copyLayer(l, xf: PlanTransform(s: l.xf.s + 0.25))]);
    case 1:
      return _replan(p, others().isEmpty ? p.layers : others());
    case 2: // move
      final n = (1 + rnd.nextInt(30)) * (rnd.nextBool() ? 1 : -1);
      final k0 = grid.frameIndexOf(l.t0) + n;
      if (k0 < 0) return p.copyWith(rev: p.rev + 1);
      final t0 = f(k0);
      final t1 = f(grid.frameIndexOf(l.t1) + n);
      final map = l.map.isEmpty ? l.map : [MapSegment(t0, t1, l.map.first.s0, l.map.first.s0 + (t1 - t0))];
      return _replan(p, [...others(), copyLayer(l, t0: t0, t1: t1, map: map)]);
    case 3: // seq only
      return _replan(p, [...others(), copyLayer(l, seq: (l.seq ?? 0) + 10)]);
    case 4: // proxy / uri change
      final id = p.assets.keys.elementAt(rnd.nextInt(p.assets.length));
      final x = p.assets[id]!;
      return _replan(p, p.layers, assets: {...p.assets, id: video(x.fp, uri: 'file:///moved/${x.fp}.mp4')});
    case 5: // new asset only
      return _replan(p, p.layers, assets: {...p.assets, 'n${p.rev}': video('fp_n${p.rev}')});
    case 6: // split a media layer seamlessly
      if (l.kind != PlanLayerKind.media || l.t1 - l.t0 < f(2)) return p.copyWith(rev: p.rev + 1);
      final mid = f(grid.frameIndexOf(l.t0) + 1);
      final s = l.map.first;
      final sm = s.s0 + (mid - l.t0);
      return _replan(p, [
        ...others(),
        copyLayer(l, id: '${l.id}L${p.rev}', t1: mid, map: [MapSegment(l.t0, mid, s.s0, sm)]),
        copyLayer(l, id: '${l.id}R${p.rev}', t0: mid, map: [MapSegment(mid, l.t1, sm, s.s1)]),
      ]);
    case 7: // add on top
      final k0 = rnd.nextInt(280);
      return _replan(p, [...p.layers, solid('add${p.rev}#v', k0, k0 + 1 + rnd.nextInt(30), z: 100)]);
    default: // no change
      return p.copyWith(rev: p.rev + 1);
  }
}

/// A random plan of up to 8 layers in 300 frames.
RenderPlan randomPlan(Random rnd) {
  final layers = <PlanLayer>[];
  final n = 2 + rnd.nextInt(7);
  for (var i = 0; i < n; i++) {
    final k0 = rnd.nextInt(250);
    final k1 = k0 + 5 + rnd.nextInt(45);
    layers.add(switch (rnd.nextInt(4)) {
      0 => solid('s$i#v', k0, k1, z: i, color: 0xFF000000 | rnd.nextInt(0xFFFFFF)),
      _ => media('m$i#v', k0, k1, 'a${rnd.nextInt(3)}', z: i, src: rnd.nextInt(100)),
    });
  }
  return plan(layers, assets: {for (var i = 0; i < 3; i++) 'a$i': video('fp_a$i')});
}

List<PlanPair> randomPlanPairs({required int seeds, required int steps, int first = 0}) {
  final out = <PlanPair>[];
  for (var seed = first; seed < first + seeds; seed++) {
    final rnd = Random(1000 + seed);
    var p = randomPlan(rnd);
    for (var step = 0; step < steps; step++) {
      final next = randomAnyEdit(p, rnd);
      if (next.layers.isEmpty) break;
      out.add(PlanPair('random plan seed $seed step $step', p, next));
      p = next;
    }
  }
  return out;
}

List<PlanPair> commandPairs({required int seeds, required int steps}) {
  final out = <PlanPair>[];
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed + 4242);
    var project = randomProject(seed, const RandomProjectSpec(items: 20));
    final resolver = resolverFor(project);
    final ctx = EditContext(ids: SeededIdGenerator(seed + 900), now: DateTime.utc(2026, 10, 15));
    var a = compileMemo(project, resolver).plan;
    for (var step = 0; step < steps; step++) {
      final res = applyCommand(project, randomEdit(project, rnd), ctx);
      if (!res.changed) continue;
      project = res.project;
      final b = compileMemo(project, resolver).plan;
      out.add(PlanPair('commands seed $seed step $step', a, b));
      a = b;
    }
  }
  return out;
}

/// Every range of [before] with the rule's verdict and whether the hash survives at that span.
List<Map<String, Object?>> verdicts(PlanPair pair) => [
      for (final r in splitRanges(pair.before))
        {
          's': r.start,
          'e': r.end,
          'touched': rangeTouched(pair.before, pair.after, r),
          'sameHash': rangeHash(pair.after, r) == rangeHash(pair.before, r),
        },
    ];

Map<String, Object?> vectorsDocument(List<PlanPair> pairs) => {
      'v': 1,
      'about': 'FIX-RANGE-RULE shared vectors: for each plan pair, every range of `before` with the engine '
          'rule (ARCH 12.2: drop when the before->after difference touches the range) as `touched`. '
          'Native suites (IOS-19 RenderedRangeRules.changeTouches, AND-18 RangeTouch.changeTouches) '
          'must reproduce `touched` exactly. `sameHash` is the Dart rangeHash comparison at that span; '
          '`touched == false` implies `sameHash == true` (no stale render).',
      'cases': [
        for (final p in pairs)
          {
            'name': p.name,
            'before': PlanJson.encodePlan(p.before),
            'after': PlanJson.encodePlan(p.after),
            'ranges': verdicts(p),
          },
      ],
    };

/// The pairs committed as vectors (a small, stable selection).
List<PlanPair> vectorPairs() => [
      ...handCases(),
      ...randomPlanPairs(seeds: 3, steps: 7),
      ...commandPairs(seeds: 1, steps: 4),
    ];

void checkPair(PlanPair pair, {Set<String>? stats}) {
  final before = splitRanges(pair.before);
  final afterRanges = splitRanges(pair.after).toSet();
  final gone = invalidated(pair.before, pair.after);
  for (final r in before) {
    final h = rangeHash(pair.before, r);
    final touched = rangeTouched(pair.before, pair.after, r);
    final same = rangeHash(pair.after, r) == h;
    // P1: a range the engine keeps shows unchanged pixels.
    if (!touched) expect(same, isTrue, reason: '${pair.name}: the engine keeps $r but its pixels changed');
    // P2: an invalidated hash belonged to a dropped range or to a range cut differently now.
    if (gone.contains(h)) {
      expect(touched || !afterRanges.contains(r), isTrue, reason: '${pair.name}: $r invalidated but the engine keeps it in place');
    }
    if (stats != null) {
      if (touched && same) stats.add('engine-only drop');
      if (!touched && !same) stats.add('violation');
      if (touched && !same) stats.add('both');
      if (!touched && same) stats.add('kept');
    }
  }
  expect(rangesKept(pair.before, pair.after, before), [
    for (final r in before)
      if (!rangeTouched(pair.before, pair.after, r)) r
  ]);
}

void main() {
  group('hand-made cases', () {
    final cases = {for (final c in handCases()) c.name: c};
    final r0 = PlanRange(0, f(30));
    final r1 = PlanRange(f(30), f(60));
    final r2 = PlanRange(f(60), f(90));
    final r3 = PlanRange(f(90), f(120));
    bool touched(String name, PlanRange r) => rangeTouched(cases[name]!.before, cases[name]!.after, r);

    test('the base plan splits into the four ranges', () {
      expect(splitRanges(cases.values.first.before), [r0, r1, r2, r3]);
    });

    test('a layer change touches the ranges its old or new span overlaps, and no other', () {
      expect([
        for (final r in [r0, r1, r2, r3]) touched('param edit inside one range', r)
      ], [
        false,
        true,
        false,
        false
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('keyframe edit', r)
      ], [
        false,
        false,
        false,
        true
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('remove the spanning layer', r)
      ], [
        true,
        true,
        true,
        true
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('add a layer over the gap', r)
      ], [
        false,
        false,
        true,
        false
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('ripple: everything moves one second later', r)
      ], [
        true,
        true,
        true,
        true
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('seq slot change only', r)
      ], [
        false,
        true,
        false,
        false
      ]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('split B into two seamless halves', r)
      ], [
        false,
        true,
        false,
        false
      ]);
    });

    test('canvas and changed assets touch every range; an added asset or audio touches none', () {
      for (final r in [r0, r1, r2, r3]) {
        expect(touched('canvas change', r), isTrue);
        expect(touched('proxy arrives (asset uri change, same fp)', r), isTrue);
        expect(touched('asset added only', r), isFalse);
        expect(touched('audio only', r), isFalse);
        expect(touched('identical plan, new revision', r), isFalse);
      }
    });

    test('a duration change touches the ranges ending after the shorter duration', () {
      final shrunk = cases['duration shrinks (empty tail removed)']!;
      expect(
          [for (final r in splitRanges(shrunk.before)) rangeTouched(shrunk.before, shrunk.after, r)], [false, false, false, false, true]);
      expect([
        for (final r in [r0, r1, r2, r3]) touched('duration grows (empty tail)', r)
      ], [
        false,
        false,
        false,
        false
      ]);
      final grown = cases['duration grows (empty tail)']!;
      expect(rangeTouched(grown.before, grown.after, PlanRange(f(90), f(121))), isTrue);
    });

    test('the engine drops ranges whose pixels did not change (the controller resends them)', () {
      for (final name in [
        'proxy arrives (asset uri change, same fp)',
        'seq slot change only',
      ]) {
        final c = cases[name]!;
        expect(invalidated(c.before, c.after), isEmpty, reason: name);
        expect(splitRanges(c.before).any((r) => rangeTouched(c.before, c.after, r)), isTrue, reason: name);
      }
      // A split is conservative on both sides: the halves are listed as two layers, so the hash
      // changes too (a cache miss, never a stale render).
      final split = cases['split B into two seamless halves']!;
      expect(rangeTouched(split.before, split.after, r1), isTrue);
      expect(invalidated(split.before, split.after), contains(rangeHash(split.before, r1)));
      // A ripple keeps the moved range's hash at its new place.
      final ripple = cases['ripple: everything moves one second later']!;
      expect(invalidated(ripple.before, ripple.after), isEmpty);
      expect(rangeHashes(ripple.after).skip(1), rangeHashes(ripple.before));
    });

    for (final c in handCases()) {
      test('P1/P2: ${c.name}', () => checkPair(c));
    }
  });

  group('random plan-level edits (pixel-changing or not)', () {
    for (var seed = 0; seed < 30; seed++) {
      test('seed $seed', () {
        final stats = <String>{};
        for (final pair in randomPlanPairs(seeds: 1, steps: 30, first: 100 + seed)) {
          checkPair(pair, stats: stats);
        }
      });
    }
    test('over many pairs the engine drops more than the hashes and never fewer', () {
      final stats = <String>{};
      for (final pair in randomPlanPairs(seeds: 30, steps: 20)) {
        checkPair(pair, stats: stats);
      }
      expect(stats, containsAll(['engine-only drop', 'both', 'kept']));
      expect(stats, isNot(contains('violation')));
    });
  });

  group('real editing commands on compiled projects', () {
    for (var seed = 0; seed < 8; seed++) {
      test('seed $seed', () {
        final rnd = Random(seed + 4242);
        var project = randomProject(seed, const RandomProjectSpec(items: 30));
        final resolver = resolverFor(project);
        final ctx = EditContext(ids: SeededIdGenerator(seed + 900), now: DateTime.utc(2026, 10, 15));
        var a = compileMemo(project, resolver).plan;
        var changed = 0;
        for (var step = 0; step < 15; step++) {
          final res = applyCommand(project, randomEdit(project, rnd), ctx);
          if (!res.changed) continue;
          changed++;
          final previous = project;
          project = res.project;
          final b = compileMemo(project, resolver).plan;
          checkPair(PlanPair('seed $seed step $step', a, b));
          // Undo: the engine's rule on the way back is the same check.
          final undone = compileMemo(previous, resolver).plan.copyWith(rev: b.rev + 1);
          checkPair(PlanPair('seed $seed step $step undo', b, undone));
          a = b;
        }
        expect(changed, greaterThan(3));
      });
    }
  });

  group('shared vectors', () {
    test('vectors/range_touch.json is current (UPDATE_RANGE_VECTORS=1 regenerates it)', () {
      final text = '${const JsonEncoder.withIndent(null).convert(vectorsDocument(vectorPairs()))}\n';
      final file = File(vectorsPath);
      if (Platform.environment['UPDATE_RANGE_VECTORS'] == '1') file.writeAsStringSync(text);
      expect(file.readAsStringSync(), text);
    });

    test('decoded vectors reproduce every verdict (what the native suites replay)', () {
      final doc = jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, Object?>;
      final cases = (doc['cases']! as List<Object?>).cast<Map<String, Object?>>();
      expect(cases.length, greaterThan(30));
      var touched = 0;
      var kept = 0;
      for (final c in cases) {
        final before = PlanJson.decodePlan((c['before']! as Map).cast<String, Object?>());
        final after = PlanJson.decodePlan((c['after']! as Map).cast<String, Object?>());
        for (final r in (c['ranges']! as List<Object?>).cast<Map<String, Object?>>()) {
          final range = PlanRange(r['s']! as int, r['e']! as int);
          final t = rangeTouched(before, after, range);
          expect(t, r['touched'], reason: '${c['name']}: $range');
          expect(rangeHash(after, range) == rangeHash(before, range), r['sameHash'], reason: '${c['name']}: $range');
          if (r['touched'] == false) expect(r['sameHash'], isTrue, reason: '${c['name']}: $range');
          t ? touched++ : kept++;
        }
      }
      expect(touched, greaterThan(20));
      expect(kept, greaterThan(20));
    });
  });
}
