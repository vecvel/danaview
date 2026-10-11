// OWNER: API-03
//
// The Dart CPU reference renderer (ARCH §11.5, §11.6): layer parameter snapshots, frame selection
// (greatest PTS ≤ s + 500 µs, hold), half-open activity, draw order, opacity and canvas-mask
// compositing, sprite reveal, effects on the layer raster, failures on missing content, and
// determinism across runs and renderer instances.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/src/reference/fixtures/golden_cases.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

const PlanCanvas canvas = PlanCanvas(w: 32, h: 16, fps: 30);

/// A 25 fps video whose frame j is a flat colour with red = j / 100.
final ReferenceVideo counter = ReferenceVideo.constantRate(
  fps: 25,
  frameCount: 100,
  frame: (j) => RenderRaster.filled(4, 4, RenderRgba(j / 100, 0, 0)),
);

const PlanAsset videoAsset = PlanAsset(kind: PlanAssetKind.video, uri: 'file:///v.mp4', w: 32, h: 16, durUs: 4000000);

PlanLayer media({String id = 'it_a#v', int z = 10, TimeUs t0 = 0, TimeUs t1 = 1000000, int s0 = 0, bool hold = false}) => PlanLayer(
      id: id,
      z: z,
      seq: 0,
      t0: t0,
      t1: t1,
      kind: PlanLayerKind.media,
      asset: 'md_v',
      map: [MapSegment(t0, t1, s0, s0 + (t1 - t0))],
      hold: hold,
      base: const PlanSize(32, 16),
    );

PlanLayer solid(String id, int argb, {int z = 10, TimeUs t0 = 0, TimeUs t1 = 1000000, PlanTransform xf = PlanTransform.identity}) =>
    PlanLayer(id: id, z: z, t0: t0, t1: t1, kind: PlanLayerKind.solid, color: argb, xf: xf);

RenderPlan plan(List<PlanLayer> layers, {int bg = 0xFF000000, Map<String, PlanAsset> assets = const {'md_v': videoAsset}}) =>
    RenderPlan(rev: 1, target: PlanTarget.preview, canvas: canvas.copyWith(bg: bg), durUs: 2000000, assets: assets, layers: layers);

final ReferenceRenderer renderer = ReferenceRenderer(sources: MapReferenceSources(videos: {'md_v': counter}));

List<int> px(Uint8List rgba, int x, int y, [int w = 32]) => rgba.sublist((y * w + x) * 4, (y * w + x) * 4 + 4);

void main() {
  group('LayerParamSnapshot', () {
    test('animated channels override static values; centre defaults to the canvas centre', () {
      final l = PlanLayer(
        id: 'a#v',
        z: 10,
        t0: 0,
        t1: 1000000,
        kind: PlanLayerKind.solid,
        color: 0xFFFFFFFF,
        xf: const PlanTransform(s: 2, op: 0.5),
        fx: const PlanEffects(
          adj: PlanAdjust(contrast: 0.3),
          mask: PlanMask(shape: PlanMaskShape.ellipse, w: 0.5, h: 0.5),
        ),
        anim: const {
          'xf.s': [AnimKey(0, 1), AnimKey(1000000, 3)],
          'adj.exposure': [AnimKey(0, -1), AnimKey(1000000, 1)],
          'detail.blur': [AnimKey(500000, 0.5)],
          'mask.w': [AnimKey(0, 0.2), AnimKey(1000000, 0.4)],
        },
        cmasks: const [
          CanvasMask(cx: 0, cy: 8, w: 0, h: 16, anim: {
            'w': [AnimKey(0, 0), AnimKey(1000000, 64)],
          }),
        ],
      );
      final p = LayerParamSnapshot.at(l, canvas, 500000);
      expect(p.xf.cx, 16);
      expect(p.xf.cy, 8);
      expect(p.xf.s, 2);
      expect(p.xf.op, 0.5);
      expect(p.adj!.exposure, 0);
      expect(p.adj!.contrast, 0.3);
      expect(p.detail!.blur, 0.5);
      expect(p.mask!.w, closeTo(0.3, 1e-12));
      expect(p.mask!.h, 0.5);
      expect(p.reveal, isNull);
      expect(p.cmasks.single.w, 32);
      expect(p.cmasks.single.anim, isEmpty);
    });

    test('frameTime maps platform times to the plan time of the nearest output frame (D-35)', () {
      // 30 fps: frame 1 starts at 33334 µs; iOS stamps it 33333.33 and Media3 33333.
      expect(LayerParamSnapshot.frameTime(canvas, 33333), 33334);
      expect(LayerParamSnapshot.frameTime(canvas, 33334), 33334);
      expect(LayerParamSnapshot.frameTime(canvas, 49999), 33334);
      expect(LayerParamSnapshot.frameTime(canvas, 50001), 66667);
    });
  });

  group('frame selection (ARCH §11.5)', () {
    test('the displayed frame has the greatest PTS ≤ s + 500 µs', () {
      // s = t: frame 5 of 25 fps starts at 200000.
      expect(px(renderer.renderFrame(plan([media()]), 199334), 16, 8)[0], RenderMath.toByte(4 / 100));
      expect(px(renderer.renderFrame(plan([media()]), 200000), 16, 8)[0], RenderMath.toByte(5 / 100));
      // s = 39600 is 400 µs before frame 1 (PTS 40000): the +500 µs bias shows frame 1.
      expect(px(renderer.renderFrame(plan([media(s0: 39600 - 33334)]), 33334), 16, 8)[0], RenderMath.toByte(1 / 100));
      // 600 µs before: still frame 0.
      expect(px(renderer.renderFrame(plan([media(s0: 39400 - 33334)]), 33334), 16, 8)[0], 0);
      expect(counter.displayedFrameIndex(39500), 1);
      expect(counter.displayedFrameIndex(39499.9), 0);
      expect(counter.displayedFrameIndex(1e12), 99);
    });

    test('hold shows map[0].s0 for the whole range', () {
      final held = plan([media(s0: 400000, hold: true)]);
      for (final t in [0, 300000, 999999]) {
        expect(px(renderer.renderFrame(held, t), 3, 3)[0], RenderMath.toByte(10 / 100));
      }
    });

    test('explicit PTS lists pick the greatest PTS at or below the target', () {
      final v = ReferenceVideo.withPts([0, 30000, 70000, 100000], frame: (j) => RenderRaster.filled(1, 1, RenderRgba(j / 10, 0, 0)));
      expect(v.frameIndexAt(-5), 0);
      expect(v.frameIndexAt(69999), 1);
      expect(v.frameIndexAt(70000), 2);
      expect(v.frameIndexAt(5e6), 3);
    });
  });

  group('compositing', () {
    test('layers are active on [t0, t1) only and the background is opaque', () {
      final p = plan([solid('it_w#v', 0xFFFFFFFF, t0: 33334, t1: 66667)], bg: 0x40102030);
      expect(px(renderer.renderFrame(p, 0), 0, 0), [0x10, 0x20, 0x30, 255]);
      expect(px(renderer.renderFrame(p, 33334), 0, 0), [255, 255, 255, 255]);
      expect(px(renderer.renderFrame(p, 66666), 0, 0), [255, 255, 255, 255]);
      expect(px(renderer.renderFrame(p, 66667), 0, 0), [0x10, 0x20, 0x30, 255]);
      expect(renderer.render(p, 0).drawnLayerIds, isEmpty);
    });

    test('opacity and translucent colours composite premultiplied source-over', () {
      final half = plan([solid('it_w#v', 0xFFFFFFFF, xf: const PlanTransform(op: 0.5))]);
      expect(px(renderer.renderFrame(half, 0), 5, 5), [128, 128, 128, 255]);
      final translucent = plan([solid('it_r#v', 0x80FF0000)], bg: 0xFF0000FF);
      final a = 0x80 / 255;
      expect(px(renderer.renderFrame(translucent, 0), 5, 5), [RenderMath.toByte(a), 0, RenderMath.toByte(1 - a), 255]);
    });

    test('draw order is (z, t0, id): within one z a later t0 is on top', () {
      final p = plan([
        solid('it_b#v', 0xFF0000FF, t0: 0, t1: 1000000),
        solid('it_a#v', 0xFFFF0000, t0: 33334, t1: 1000000),
        solid('it_c#v', 0xFF00FF00, z: 5, t0: 0, t1: 1000000),
      ]);
      expect(px(renderer.renderFrame(p, 0), 1, 1), [0, 0, 255, 255]);
      expect(px(renderer.renderFrame(p, 33334), 1, 1), [255, 0, 0, 255]);
      expect(renderer.render(p, 33334).drawnLayerIds, ['it_c#v', 'it_b#v', 'it_a#v']);
    });

    test('placement follows M: a half-scale full-canvas solid at (8, 8) covers [0, 16) × [4, 12)', () {
      final p = plan([solid('it_w#v', 0xFFFFFFFF, xf: const PlanTransform(cx: 8, cy: 8, s: 0.5))]);
      final f = renderer.renderFrame(p, 0);
      expect(px(f, 0, 4)[0], 255);
      expect(px(f, 15, 11)[0], 255);
      expect(px(f, 16, 4)[0], 0);
      expect(px(f, 0, 3)[0], 0);
      expect(px(f, 0, 12)[0], 0);
    });

    test('canvas masks multiply alpha after placement', () {
      final l = PlanLayer(
        id: 'it_w#v',
        z: 10,
        t0: 0,
        t1: 1000000,
        kind: PlanLayerKind.solid,
        color: 0xFFFFFFFF,
        cmasks: const [CanvasMask(cx: 8, cy: 8, w: 16, h: 16)],
      );
      final f = renderer.renderFrame(plan([l]), 0);
      expect(px(f, 7, 8)[0], 255);
      expect(px(f, 16, 8)[0], 0);
    });

    test('effects run on the layer raster (chroma keys the key colour out)', () {
      final green =
          ReferenceVideo.constantRate(fps: 25, frameCount: 1, frame: (_) => RenderRaster.filled(4, 4, RenderRgba.fromRgb(0x00B140)));
      final keyed = PlanLayer(
        id: 'it_k#v',
        z: 10010,
        seq: 1,
        t0: 0,
        t1: 1000000,
        kind: PlanLayerKind.media,
        asset: 'md_v',
        map: const [MapSegment(0, 1000000, 0, 1000000)],
        fx: const PlanEffects(chroma: PlanChroma(key: 0x00B140)),
      );
      final r = ReferenceRenderer(sources: MapReferenceSources(videos: {'md_v': green}));
      expect(px(r.renderFrame(plan([solid('it_bg#v', 0xFFFF00FF), keyed]), 0), 10, 10), [255, 0, 255, 255]);
    });

    test('sprites reveal glyph g iff g < floor(reveal(t)); without reveal they draw whole', () {
      const asset = PlanAsset(kind: PlanAssetKind.sprite, uri: 'file:///s.vsprite', sw: 4, sh: 1, sscale: 0.125, reveal: true);
      final sprite = ReferenceSprite(RenderRaster.filled(4, 1, const RenderRgba(1, 1, 1)), glyphs: Uint16List.fromList([0, 1, 2, 0xFFFF]));
      final layer = PlanLayer(
        id: 'it_s#v',
        z: 20010,
        t0: 0,
        t1: 1000000,
        kind: PlanLayerKind.sprite,
        asset: 'sp',
        anim: const {
          'reveal': [AnimKey(0, 0), AnimKey(1000000, 4)],
        },
      );
      final r = ReferenceRenderer(sources: MapReferenceSources(sprites: {'sp': sprite}));
      final p = RenderPlan(rev: 1, target: PlanTarget.export, canvas: canvas, durUs: 1000000, assets: const {'sp': asset}, layers: [layer]);
      List<int> lit(int t) {
        final f = r.renderFrame(p, t);
        return [
          for (final x in [4, 12, 20, 28]) px(f, x, 4)[0]
        ];
      }

      expect(lit(0), [0, 0, 0, 0]);
      expect(lit(250000), [255, 0, 0, 0]); // reveal 1
      expect(lit(600000), [255, 255, 0, 0]); // reveal 2.4
      expect(lit(999999), [255, 255, 255, 0]); // reveal 3.99…, background never
      final whole = RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: canvas,
        durUs: 1000000,
        assets: const {'sp': asset},
        layers: [PlanLayer(id: 'it_s#v', z: 20010, t0: 0, t1: 1000000, kind: PlanLayerKind.sprite, asset: 'sp')],
      );
      expect([
        for (final x in [4, 12, 20, 28]) px(r.renderFrame(whole, 0), x, 4)[0]
      ], [
        255,
        255,
        255,
        255
      ]);
    });

    test('missing content is an error, never a silently skipped layer', () {
      expect(() => const ReferenceRenderer(sources: MapReferenceSources()).renderFrame(plan([media()]), 0), throwsStateError);
    });
  });

  group('determinism', () {
    test('rendering twice, with a fresh renderer and in another order gives identical bytes', () {
      final cases = GoldenCases.all.where((c) => c.plan != null).toList();
      final first = <String, Uint8List>{};
      for (final c in cases) {
        final r = ReferenceRenderer(longSide: c.longSide);
        for (final k in c.frames) {
          first['${c.name}@$k'] = r.renderOutputFrame(c.plan!, k);
        }
      }
      for (final c in cases.reversed) {
        final r = ReferenceRenderer(longSide: c.longSide);
        for (final k in c.frames.reversed) {
          expect(r.renderOutputFrame(c.plan!, k), first['${c.name}@$k'], reason: '${c.name} frame $k');
        }
      }
    });

    test('output size follows longSide; null renders at the canvas size', () {
      const big = PlanCanvas(w: 1920, h: 1080, fps: 30);
      expect(const ReferenceRenderer(longSide: 96).outputSizeOf(big), (96, 54));
      expect(const ReferenceRenderer(longSide: 96).outputSizeOf(const PlanCanvas(w: 1080, h: 1920, fps: 30)), (54, 96));
      expect(const ReferenceRenderer().outputSizeOf(canvas), (32, 16));
      expect(renderer.renderFrame(plan([]), 0), hasLength(32 * 16 * 4));
    });
  });
}
