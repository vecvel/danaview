// OWNER: CORE-37
//
// splitRanges and rangeHash (ARCH D-45(A)): grid cuts at every layer edge, merging of seamless
// continuations, and a hash that is stable across a codec round trip, `rev`, `uri`/bookmark/proxy
// changes and edits outside the range, but changes with anything that alters the range's pixels.

import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('splitRanges', () {
    test('cuts at every layer edge and covers [0, dur) without gaps', () {
      final p = plan([
        media('a#v', 0, 60, 'a'),
        media('b#v', 30, 90, 'b', z: 1),
        solid('s#v', 100, 120, z: 2),
      ]);
      final ranges = splitRanges(p);
      expect(ranges, [
        PlanRange(f(0), f(30)),
        PlanRange(f(30), f(60)),
        PlanRange(f(60), f(90)),
        PlanRange(f(90), f(100)),
        PlanRange(f(100), f(120)),
      ]);
      for (final r in ranges) {
        expect(grid.isOnGrid(r.start) && grid.isOnGrid(r.end), isTrue);
      }
    });

    test('empty plan has no ranges', () {
      expect(splitRanges(plan([])), isEmpty);
    });

    test('a split clip whose halves continue seamlessly is one range', () {
      final whole = media('a#v', 0, 60, 'a', src: 10);
      final left = copyLayer(whole, id: 'a1#v', t1: f(25), map: [MapSegment(f(0), f(25), f(10), f(10) + f(25))]);
      final right = copyLayer(whole, id: 'a2#v', t0: f(25), map: [MapSegment(f(25), f(60), f(10) + f(25), f(10) + f(60))]);
      expect(splitRanges(plan([left, right])), [PlanRange(f(0), f(60))]);
    });

    test('a discontinuous cut (jump in source, other speed or other look) is not merged', () {
      final left = media('a1#v', 0, 25, 'a', src: 0);
      final jump = media('a2#v', 25, 60, 'a', src: 40);
      expect(splitRanges(plan([left, jump])), hasLength(2));
      final faster = media('a2#v', 25, 60, 'a', src: 25, rate: 2);
      expect(splitRanges(plan([left, faster])), hasLength(2));
      final dimmer = media('a2#v', 25, 60, 'a', src: 25, xf: const PlanTransform(op: 0.5));
      expect(splitRanges(plan([left, dimmer])), hasLength(2));
      final same = media('a2#v', 25, 60, 'a', src: 25);
      expect(splitRanges(plan([left, same])), hasLength(1));
    });
  });

  group('rangeHash', () {
    final base = plan([
      media('a#v', 0, 60, 'a', fx: const PlanEffects(adj: PlanAdjust(exposure: 0.25), lut: PlanLut('lut1', 0.8))),
      media('b#v', 20, 50, 'b', z: 1, xf: const PlanTransform(cx: 500.5, s: 0.5), anim: {
        PlanChannels.xfOp: [AnimKey(f(20), 0), AnimKey(f(30), 1), AnimKey(f(45), 0.25)],
      }),
    ], assets: {'a': video('fp_a'), 'b': video('fp_b'), 'lut1': lutAsset('lut1')});

    test('is 64 hex digits and deterministic', () {
      final r = splitRanges(base)[1];
      final h = rangeHash(base, r);
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(rangeHash(base, r), h);
    });

    test('stable across a codec round trip and a rev change', () {
      final decoded = PlanJson.decodePlanBytes(PlanJson.encodePlanBytes(base));
      expect(rangeHashes(decoded), rangeHashes(base));
      expect(rangeHashes(base.copyWith(rev: 999)), rangeHashes(base));
    });

    test('stable across uri, bookmark and proxy changes with the same fp', () {
      final moved = base.copyWith(assets: {
        'a': video('fp_a', uri: 'file:///elsewhere/renamed.mov', proxy: 'file:///cache/danaview/editor/proxies/a-540.mp4'),
        'b': PlanAsset(kind: PlanAssetKind.video, uri: 'content://media/42', bookmark: 'Ym9va21hcms=', fp: 'fp_b', w: 1920, h: 1080, rot: 0, durUs: 600000000),
        'lut1': lutAsset('lut1'),
      });
      expect(rangeHashes(moved), rangeHashes(base));
    });

    test('changes when the fp (the content) changes', () {
      final other = base.copyWith(assets: {...base.assets, 'a': video('fp_other', uri: base.assets['a']!.uri)});
      expect(rangeHashes(other).first, isNot(rangeHashes(base).first));
    });

    test('changes with canvas, gridFps and preview size', () {
      final r = splitRanges(base)[1];
      final h = rangeHash(base, r);
      expect(rangeHash(base.copyWith(canvas: base.canvas.copyWith(bg: 0xFFFFFFFF)), r), isNot(h));
      expect(rangeHash(base.copyWith(canvas: base.canvas.copyWith(gridFps: 60)), r), isNot(h));
      expect(rangeHash(base, r, previewSize: const RenderSize(960, 540)), isNot(h));
      expect(rangeHash(base, r, previewSize: const RenderSize(1920, 1080)), h);
    });

    test('ignores layer ids, z values and seq slots (only draw order matters)', () {
      final renamed = plan([
        copyLayer(base.layers[0], id: 'x#v', z: 10, seq: 3),
        copyLayer(base.layers[1], id: 'y#v', z: 20, seq: 7),
      ], assets: base.assets);
      expect(rangeHashes(renamed), rangeHashes(base));
      final swapped = plan([
        copyLayer(base.layers[0], z: 30),
        base.layers[1],
      ], assets: base.assets);
      expect(rangeHash(swapped, splitRanges(base)[1]), isNot(rangeHash(base, splitRanges(base)[1])));
    });

    test('independent of anything outside the range', () {
      final r = PlanRange(f(30), f(40));
      final h = rangeHash(base, r);
      // Trim both layers outside r, change a key outside r's neighbouring keys, add a layer after.
      final a = base.layers[0];
      final b = base.layers[1];
      final edited = plan([
        copyLayer(a, t0: f(10), t1: f(55), map: [MapSegment(f(10), f(55), f(10), f(55))]),
        copyLayer(b, t1: f(45), map: [MapSegment(f(20), f(45), 0, f(45) - f(20))], anim: {
          PlanChannels.xfOp: [AnimKey(f(22), 0.7), AnimKey(f(30), 1), AnimKey(f(45), 0.25)],
        }),
        solid('late#v', 70, 80, z: 5),
      ], assets: base.assets);
      expect(rangeHash(edited, r), h);
      // But a change of the interior of r is seen.
      final param = withLayer(base, copyLayer(b, xf: const PlanTransform(cx: 500.5, s: 0.51)));
      expect(rangeHash(param, r), isNot(h));
    });

    test('identical content shifted on the timeline hashes the same', () {
      final p1 = plan([media('a#v', 0, 30, 'a', src: 5)]);
      final p2 = plan([solid('pad#v', 0, 30), media('a#v', 30, 60, 'a', src: 5, z: 1)]);
      // Frame durations of 30 fps vary by 1 µs, so compare ranges at equal grid phase (0 and 30).
      expect(rangeHash(p2, PlanRange(f(30), f(60))), rangeHash(p1, PlanRange(f(0), f(30))));
    });

    test('keyframes are clipped exactly: entering value, interior keys, leaving value', () {
      final keys = [AnimKey(f(0), 0), AnimKey(f(10), 1), AnimKey(f(40), 0)];
      final p1 = plan([media('a#v', 0, 60, 'a', anim: {PlanChannels.xfS: keys})]);
      final r = PlanRange(f(20), f(30));
      // Same line through r with different keys outside it.
      final p2 = plan([media('a#v', 0, 60, 'a', anim: {PlanChannels.xfS: [AnimKey(f(10), 1), AnimKey(f(40), 0), AnimKey(f(50), 3)]})]);
      expect(rangeHash(p2, r), rangeHash(p1, r));
      final p3 = plan([media('a#v', 0, 60, 'a', anim: {PlanChannels.xfS: [AnimKey(f(10), 1), AnimKey(f(41), 0)]})]);
      expect(rangeHash(p3, r), isNot(rangeHash(p1, r)));
    });

    test('map clipping is exact for fractional source positions', () {
      // Rate 3/7: interior source positions are not integral.
      final l = PlanLayer(id: 'a#v', z: 0, t0: 0, t1: 700000, kind: PlanLayerKind.media, asset: 'a', map: const [MapSegment(0, 700000, 0, 300000)]);
      final longer = PlanLayer(id: 'a#v', z: 0, t0: 0, t1: 1400000, kind: PlanLayerKind.media, asset: 'a', map: const [MapSegment(0, 1400000, 0, 600000)]);
      final r = const PlanRange(100001, 200003);
      final p1 = RenderPlan(rev: 1, target: PlanTarget.preview, canvas: const PlanCanvas(w: 64, h: 64, fps: 30), durUs: 700000, assets: {'a': video('fp')}, layers: [l]);
      final p2 = p1.copyWith(durUs: 1400000, layers: [longer]);
      expect(rangeHash(p2, r), rangeHash(p1, r));
    });
  });
}
