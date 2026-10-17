// OWNER: CORE-30
//
// Compiler properties over seeded random projects (CORE-08's generator): plans pass the CORE-29
// validator for every target, output canvas and holdFrame setting; model-derived packing inputs
// equal the compiled media layers; the placement of every layer is geometry's boxAt matrix
// (shared code); maps stay within 250 µs of the clip time map; hidden/muted/solo; no text in
// preview plans (D-05); no proxies in export plans; isolate compiles are identical.

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';
import 'support.dart';

const List<PlanOutputSpec?> outputs = [
  null,
  PlanOutputSpec(width: 1920, height: 1080, fps: 60),
  PlanOutputSpec(width: 1080, height: 1920, fps: 24),
  PlanOutputSpec(width: 1280, height: 720, fps: 25),
];

/// Item ids of the media clips of [p] on visible video/overlay lanes.
Iterable<MediaClip> visualClips(EditProject p) sync* {
  for (final t in p.tracks) {
    if (t.hidden || (t.kind != TrackKind.video && t.kind != TrackKind.overlay)) continue;
    yield* t.items.whereType<MediaClip>();
  }
}

/// [p] with every visual lane's track flags changed by [f].
EditProject withTracks(EditProject p, Track Function(Track t) f) =>
    p.copyWith(timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) f(t)]));

void main() {
  group('random projects compile to plans that pass the CORE-29 validator', () {
    for (var seed = 1; seed <= 40; seed++) {
      test('seed $seed', () {
        final p = randomProject(seed);
        final resolver = resolverFor(p);
        for (final target in PlanTarget.values) {
          for (final output in outputs) {
            for (final hold in [true, false]) {
              final c = compilePlan(p, target, resolver, options: CompileOptions(output: output, holdFrame: hold));
              expect(c.violations(), isEmpty, reason: '$target $output hold $hold');
              expect(c.plan.canvas.gridFps, p.settings.frameRate.num);
              expect(c.plan.canvas.fps, output?.fps ?? p.settings.frameRate.num);
            }
          }
        }
      });
    }
  });

  test('a project with media missing from the pool and offline files still compiles to a valid plan', () {
    for (var seed = 1; seed <= 15; seed++) {
      final p = randomProject(seed);
      final ids = p.pool.assets.keys.toList();
      final offline = {for (var i = 0; i < ids.length; i += 3) ids[i] as String};
      final dropped = p.copyWith(pool: p.pool.without({for (var i = 1; i < ids.length; i += 4) ids[i]}));
      for (final target in PlanTarget.values) {
        final c = compilePlan(dropped, target, resolverFor(dropped, offline: offline));
        expect(c.violations(), isEmpty);
        if (target == PlanTarget.preview && !c.requirements.isEmpty) expect(c.plan.req, c.requirements);
        if (target == PlanTarget.export) expect(c.plan.req, isNull);
      }
    }
  });

  group('model-derived packing inputs equal the compiled media layers', () {
    for (var seed = 1; seed <= 30; seed++) {
      test('seed $seed', () {
        // Overlap transitions extend clips in CORE-31's lowering stage; without it they cut.
        final p = randomProject(seed, const RandomProjectSpec(items: 120, transitions: false));
        for (final hold in [true, false]) {
          final c = compilePlan(p, PlanTarget.preview, resolverFor(p), options: CompileOptions(holdFrame: hold));
          final derived = packingInputsOf(p, holdFrame: hold);
          expect(mediaInputsOf(c.plan), derived);
          final packed = packVisualLayers(derived);
          expect(c.packing.slotCount, packed.slotCount);
          expect(c.packing.peakConcurrentDecoders, packed.peakConcurrentDecoders);
          for (final l in c.plan.layers.where((l) => l.kind == PlanLayerKind.media)) {
            expect(l.seq, packed.seqOf(l.id));
          }
        }
      });
    }
  });

  group('shared code: every layer is placed by geometry.boxAt\'s matrix', () {
    test('lowering_visual derives base and centre from geometry (baseSize, positionToCanvas)', () {
      final src = File('lib/src/plan/lowering_visual.dart').readAsStringSync();
      expect(src, contains("import '../eval/geometry.dart';"));
      expect(src, contains('baseSize(fit: fit, crop: crop, source: picture, canvas: canvas)'));
      expect(src, contains('positionToCanvas(transform.position, ctx.projectCanvas)'));
    });

    for (var seed = 1; seed <= 25; seed++) {
      test('seed $seed', () {
        final p = randomProject(seed);
        final c = compilePlan(p, PlanTarget.preview, resolverFor(p));
        final canvas = Size2(c.plan.canvas.w.toDouble(), c.plan.canvas.h.toDouble());
        var checked = 0;
        for (final l in c.plan.layers) {
          if (!l.id.endsWith('#v')) continue;
          final item = ItemId(PlanIds.itemOf(l.id));
          final times = {l.t0, (l.t0 + l.t1) ~/ 2, l.t1 - 1, for (final keys in l.anim.values) for (final k in keys) k.tUs};
          for (final t in times) {
            if (t < l.t0 || t >= l.t1) continue;
            final box = boxAt(p, item, t);
            if (box == null) continue; // offline media without a pool entry
            final xf = PlanTransform(
              cx: planValue(l, PlanChannels.xfCx, t, c.plan.canvas),
              cy: planValue(l, PlanChannels.xfCy, t, c.plan.canvas),
              s: planValue(l, PlanChannels.xfS, t, c.plan.canvas),
              r: planValue(l, PlanChannels.xfR, t, c.plan.canvas),
              fx: l.xf.fx,
              fy: l.xf.fy,
            );
            final m = planPlacementMatrix(xf, l.base!, canvas);
            expect(m.closeTo(box.matrix, 1e-6), isTrue, reason: '${l.id} at $t: $m vs ${box.matrix}');
            expect(planValue(l, PlanChannels.xfOp, t, c.plan.canvas), closeTo(box.opacity, 1e-9), reason: '${l.id} at $t');
            checked++;
          }
        }
        expect(checked, greaterThan(0));
      });
    }
  });

  test('media maps are within 250 µs of the clip time map at every frame start', () {
    for (var seed = 1; seed <= 20; seed++) {
      final p = randomProject(seed);
      final rate = p.settings.frameRate;
      final c = compilePlan(p, PlanTarget.preview, resolverFor(p));
      final byId = {for (final clip in visualClips(p)) clip.id: clip};
      for (final l in c.plan.layers) {
        if (l.kind != PlanLayerKind.media || l.hold || !l.id.endsWith('#v')) continue;
        final clip = byId[ItemId(PlanIds.itemOf(l.id))]!;
        // Reversed clips without a rendition play forward (pending); others follow their own map.
        final tm = ClipTimeMap(start: clip.start, duration: clip.duration, sourceIn: clip.sourceIn, speed: clip.speed, rate: rate);
        for (var k = rate.frameIndexOf(l.t0); rate.timeOfFrame(k) < l.t1; k++) {
          final t = rate.timeOfFrame(k);
          if (t < l.t0) continue;
          final seg = l.map.lastWhere((s) => s.t0 <= t);
          expect((seg.sourceAt(t) - tm.sourceAt(t)).abs(), lessThanOrEqualTo(250), reason: '${l.id} frame $k');
        }
      }
    }
  });

  group('track flags (ARCH §11.7 "Track hidden / muted / solo")', () {
    test('hidden visual lanes contribute no layers; the other lanes keep their z', () {
      for (var seed = 1; seed <= 15; seed++) {
        final p = randomProject(seed);
        final full = compileRenderPlan(p, PlanTarget.preview, resolverFor(p));
        final overlays = {for (final t in p.tracks) if (t.kind == TrackKind.overlay) t.id};
        final hidden = withTracks(p, (t) => overlays.contains(t.id) ? t.copyWith(hidden: true) : t);
        final plan = compileRenderPlan(hidden, PlanTarget.preview, resolverFor(hidden));
        final overlayItems = {
          for (final t in p.tracks)
            if (overlays.contains(t.id)) ...t.items.map((i) => i.id as String),
        };
        expect(plan.layers.where((l) => overlayItems.contains(PlanIds.itemOf(l.id))), isEmpty);
        final kept = {for (final l in full.layers) if (!overlayItems.contains(PlanIds.itemOf(l.id))) l.id: l.z};
        expect({for (final l in plan.layers) l.id: l.z}, kept);
        expect(plan.layers.every((l) => PlanZ.bandOf(l.z) == 0), isTrue);
      }
    });

    test('muted and solo lanes keep every visual layer (they affect audio only)', () {
      for (var seed = 1; seed <= 15; seed++) {
        final p = randomProject(seed);
        final base = compileRenderPlan(p, PlanTarget.preview, resolverFor(p));
        final flagged = withTracks(p, (t) => t.copyWith(muted: !t.muted, solo: !t.solo));
        expect(compileRenderPlan(flagged, PlanTarget.preview, resolverFor(flagged)).layers, base.layers);
      }
    });
  });

  test('plans hold no text or subtitle layers without CORE-31\'s stages; preview never (D-05)', () {
    var withText = 0;
    for (var seed = 1; seed <= 15; seed++) {
      final p = randomProject(seed);
      if (p.tracks.any((t) => (t.kind == TrackKind.text || t.kind == TrackKind.subtitle) && t.items.isNotEmpty)) withText++;
      for (final target in PlanTarget.values) {
        final plan = compileRenderPlan(p, target, resolverFor(p));
        expect(plan.layers.every((l) => l.kind != PlanLayerKind.sprite && PlanZ.bandOf(l.z) < PlanZ.textBand), isTrue);
      }
    }
    expect(withText, greaterThan(10), reason: 'the generator covers text and subtitle lanes');
  });

  test('preview plans carry ready proxies; export plans never carry proxies', () {
    for (var seed = 1; seed <= 10; seed++) {
      final r = randomProject(seed);
      final p = r.copyWith(pool: MediaPool({for (final a in r.pool.assets.values) a.id: a.copyWith(proxy: ProxyState.ready)}));
      final resolver = resolverFor(p, proxied: {for (final id in p.pool.assets.keys) id});
      final preview = compileRenderPlan(p, PlanTarget.preview, resolver);
      final videos = preview.assets.values.where((a) => a.kind == PlanAssetKind.video);
      expect(videos, isNotEmpty);
      expect(videos.every((a) => a.proxyUri != null), isTrue);
      final export = compileRenderPlan(p, PlanTarget.export, resolver);
      expect(export.assets.values.every((a) => a.proxyUri == null), isTrue);
    }
  });

  test('plans are exact: maps carry unbiased source µs (no +500 µs, D-04)', () {
    final p = project([mainLane([clip('it_a', 0, 30, 'md_v', sourceIn: 1234567)])], assets: [asset('md_v', MediaKind.video)]);
    final plan = compileRenderPlan(p, PlanTarget.export, resolverFor(p));
    expect(plan.layers.single.map, [MapSegment(0, 1000000, 1234567, 2234567)]);
  });

  test('compiling in Isolate.run gives the same plan (callers isolate above 300 items)', () async {
    final p = randomProject(5, const RandomProjectSpec(items: 400));
    expect(shouldCompileInIsolate(p), isTrue);
    expect(shouldCompileInIsolate(randomProject(5, const RandomProjectSpec(items: 40))), isFalse);
    final resolver = resolverFor(p);
    final local = compilePlan(p, PlanTarget.preview, resolver);
    final remote = await Isolate.run(() => compilePlan(p, PlanTarget.preview, resolver));
    expect(remote.plan, local.plan);
    expect(remote.requirements, local.requirements);
    expect(remote.packing, local.packing);
  });

  test('durUs is the timeline duration (incl. audio and text tails), rev the timeline revision unless overridden', () {
    final p = project([
      mainLane([clip('it_a', 0, 30, 'md_v')]),
      lane('tr_tx', TrackKind.text, [TextItem(id: const ItemId('it_t'), start: fr(30), duration: fr(30), text: 'tail')]),
    ], assets: [asset('md_v', MediaKind.video)], revision: 42);
    final plan = compileRenderPlan(p, PlanTarget.preview, resolverFor(p));
    expect(plan.durUs, fr(60));
    expect(plan.rev, 42);
    expect(compileRenderPlan(p, PlanTarget.preview, resolverFor(p), options: const CompileOptions(rev: 99)).rev, 99);
    final empty = project(const []);
    final e = compileRenderPlan(empty, PlanTarget.preview, resolverFor(empty));
    expect(e.durUs, 0);
    expect(e.layers, isEmpty);
    expect(PlanValidator.validate(e), isEmpty);
  });

  test('the canvas background is the opaque solid colour (black under BlurOfMain)', () {
    final solid = project(const [], settings: const ProjectSettings(background: SolidBackground(0x80336699)));
    expect(compileRenderPlan(solid, PlanTarget.preview, resolverFor(solid)).canvas.bg, 0xFF336699);
    final blur = project(const [], settings: const ProjectSettings(background: BlurOfMainBackground(0.3)));
    expect(compileRenderPlan(blur, PlanTarget.preview, resolverFor(blur)).canvas.bg, 0xFF000000);
  });

  test('invalid output specs are rejected', () {
    final p = project(const []);
    for (final o in const [
      PlanOutputSpec(width: 1921, height: 1080, fps: 30),
      PlanOutputSpec(width: 8, height: 8, fps: 30),
      PlanOutputSpec(width: 1920, height: 1080, fps: 29),
    ]) {
      expect(() => compilePlan(p, PlanTarget.export, resolverFor(p), options: CompileOptions(output: o)), throwsArgumentError);
    }
  });
}
