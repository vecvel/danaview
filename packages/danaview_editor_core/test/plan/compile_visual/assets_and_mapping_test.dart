// OWNER: CORE-30
//
// Asset resolution (PlanAssetFactory over a PlanAssetResolver), the canvas mapping of export
// output sizes, and the map helpers of visual lowering (clipMap, extendMap, holdSegment).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import 'support.dart';

PlanAssetFactory factoryFor(List<MediaAsset> assets, PlanAssetResolver resolver, {PlanTarget target = PlanTarget.preview}) =>
    PlanAssetFactory(pool: MediaPool({for (final a in assets) a.id: a}), resolver: resolver, target: target);

void main() {
  group('PlanAssetFactory', () {
    final video = asset('md_v', MediaKind.video, rotation: -90, transfer: ColorTransfer.pq, proxy: ProxyState.ready);
    final resolver = MapPlanAssetResolver(
      originals: {
        const MediaId('md_v'): ResolvedMedia(uri: 'content://media/42', fingerprint: 'fp_v', bookmark: Uint8List.fromList([1, 2, 3])),
        const MediaId('md_http'): const ResolvedMedia(uri: 'https://example.invalid/a.mp4', fingerprint: 'x'),
        const MediaId('md_i'): const ResolvedMedia(uri: 'file:///i.jpg', fingerprint: 'fp_i'),
      },
      proxies: {const MediaId('md_v'): const ResolvedMedia(uri: 'file:///p.mp4', fingerprint: 'fp_v', isProxy: true)},
      looks: {'warm': const ResolvedLut(uri: 'file:///warm.vlut', size: 17), 'bad': const ResolvedLut(uri: 'file:///bad.vlut', size: 66)},
      luts: {const MediaId('md_lut'): const ResolvedLut(uri: 'file:///l.vlut', size: 65)},
    );
    final assets = [video, asset('md_http', MediaKind.video), asset('md_i', MediaKind.image, w: 300, h: 200), asset('md_lut', MediaKind.lut)];

    test('video entry from the resolution and the probe; proxy in preview only', () {
      final preview = factoryFor(assets, resolver).media(const MediaId('md_v'), PlanAssetKind.video)!;
      expect(preview, const PlanAsset(
        kind: PlanAssetKind.video,
        uri: 'content://media/42',
        bookmark: 'AQID',
        fp: 'fp_v',
        proxyUri: 'file:///p.mp4',
        w: 1920,
        h: 1080,
        rot: 270,
        durUs: 10000000,
        transfer: PlanTransfer.pq,
        hasAudio: true,
      ));
      final export = factoryFor(assets, resolver, target: PlanTarget.export).media(const MediaId('md_v'), PlanAssetKind.video)!;
      expect(export.proxyUri, isNull);
    });

    test('a proxy the pool does not mark ready is not used', () {
      final notReady = [video.copyWith(proxy: ProxyState.pending)];
      expect(factoryFor(notReady, resolver).media(const MediaId('md_v'), PlanAssetKind.video)!.proxyUri, isNull);
    });

    test('unknown media, missing resolutions and non-file URIs are offline', () {
      final f = factoryFor(assets, resolver);
      expect(f.media(const MediaId('md_none'), PlanAssetKind.video), isNull);
      expect(f.media(const MediaId('md_http'), PlanAssetKind.video), isNull);
      expect(f.isAvailable(const MediaId('md_http')), isFalse);
      expect(f.isAvailable(const MediaId('md_v')), isTrue);
    });

    test('image entries carry no duration or audio flag', () {
      final e = factoryFor(assets, resolver).media(const MediaId('md_i'), PlanAssetKind.image)!;
      expect(e, const PlanAsset(kind: PlanAssetKind.image, uri: 'file:///i.jpg', fp: 'fp_i', w: 300, h: 200));
    });

    test('LUTs: bundled looks by preset id, imported LUTs by pool asset, sizes 2…65', () {
      final f = factoryFor(assets, resolver);
      expect(f.builtinLook('warm'), const PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///warm.vlut', n: 17));
      expect(f.builtinLook('bad'), isNull);
      expect(f.builtinLook('nope'), isNull);
      expect(f.importedLut(const MediaId('md_lut')), const PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///l.vlut', n: 65));
      expect(f.importedLut(const MediaId('md_v')), isNull); // not a LUT asset
      expect(PlanAssetIds.builtinLook('warm'), 'lk_warm');
    });

    test('a derived still without its own size takes its source\'s', () {
      final src = asset('md_src', MediaKind.video, w: 640, h: 480);
      final still = asset('md_still', MediaKind.still, w: null, h: null, derived: const StillSpec(MediaId('md_src'), 0, sourceQuickHash: 'qh_md_src'));
      final pool = MediaPool({src.id: src, still.id: still});
      final r = resolverFor(project(const [], assets: [src, still]));
      final e = PlanAssetFactory(pool: pool, resolver: r, target: PlanTarget.preview).media(still.id, PlanAssetKind.image)!;
      expect((e.w, e.h), (640, 480));
      expect(pictureSizeOf(still, pool), const Size2(640, 480));
    });
  });

  group('CanvasMapping', () {
    test('identity keeps project px', () {
      final m = CanvasMapping.identity(const Size2(1920, 1080));
      expect(m.isIdentity, isTrue);
      expect(m.x(123.25), 123.25);
      expect(m.blurScale, 1);
      expect(m.letterboxed, isFalse);
      expect(m.contentClip, isNull);
      expect(CanvasMapping.fit(const Size2(1920, 1080), const Size2(1920, 1080)), m);
    });

    test('fit letterboxes a portrait project into a landscape output', () {
      final m = CanvasMapping.fit(const Size2(1080, 1920), const Size2(1920, 1080));
      expect(m.scale, 0.5625);
      expect(m.offsetX, 656.25);
      expect(m.offsetY, 0);
      expect(m.x(0), 656.25);
      expect(m.x(1080), 1263.75);
      expect(m.letterboxed, isTrue);
      expect(m.contentClip, const CanvasMask(cx: 960, cy: 540, w: 607.5, h: 1080));
      expect(m.blurScale, 0.5625); // 0.5625 · 1080 / 1080: the short side shrinks with the content
    });

    test('blur keeps its size relative to the project canvas and never exceeds 1×', () {
      for (final (p, o) in const [
        (Size2(1920, 1080), Size2(1080, 1920)),
        (Size2(1080, 1920), Size2(1920, 1080)),
        (Size2(1920, 1080), Size2(1280, 720)),
        (Size2(1080, 1080), Size2(1920, 1080)),
      ]) {
        final m = CanvasMapping.fit(p, o);
        expect(m.blurScale, lessThanOrEqualTo(1 + 1e-12));
        // σ = blur·0.03·min(W, H) in plan px equals the project σ scaled into plan px.
        expect(m.blurScale * o.shortSide, closeTo(m.scale * p.shortSide, 1e-9));
      }
    });

    test('rejects empty canvases', () {
      expect(() => CanvasMapping.fit(Size2.zero, const Size2(16, 16)), throwsArgumentError);
    });
  });

  group('maps', () {
    test('clipMap: forward, reversed with an offset rendition, reversed forward fallback', () {
      const rate = FrameRate.fps30;
      final c = clip('it_c', 30, 90, 'md_v', sourceIn: 2000000, reversed: true);
      final rendition = asset('md_r', MediaKind.video, derived: const ReversedSpec(MediaId('md_v'), TimeRange(1000000, 5000000), sourceQuickHash: 'q'));
      // Plays [2 s, 4 s) backwards; r = 5 s − s runs 1 s → 3 s.
      expect(clipMap(c, rate, rendition: rendition), [MapSegment(fr(30), fr(90), 1000000, 3000000)]);
      expect(clipMap(c, rate, forwardFallback: true), [MapSegment(fr(30), fr(90), 2000000, 4000000)]);
      expect(clipMap(c.copyWith(reversed: false), rate), [MapSegment(fr(30), fr(90), 2000000, 4000000)]);
    });

    test('clipPlayback picks the rendition and flags a pending reverse', () {
      const rate = FrameRate.fps30;
      final src = asset('md_v', MediaKind.video);
      final ready = asset('md_r', MediaKind.video, derived: const ReversedSpec(MediaId('md_v'), TimeRange(0, 10000000), sourceQuickHash: 'qh_md_v'));
      final pool = MediaPool({src.id: src, ready.id: ready});
      final c = clip('it_c', 0, 30, 'md_v', reversed: true);
      final withRendition = clipPlayback(c, rate, ReversedRenditionIndex(pool), available: (_) => true);
      expect(withRendition.media, 'md_r');
      expect(withRendition.pendingReverse, isFalse);
      expect(withRendition.map, [MapSegment(0, 1000000, 9000000, 10000000)]);
      final unavailable = clipPlayback(c, rate, ReversedRenditionIndex(pool), available: (id) => id != 'md_r');
      expect(unavailable.media, 'md_v');
      expect(unavailable.pendingReverse, isTrue);
      expect(clipPlayback(c.copyWith(reversed: false), rate, ReversedRenditionIndex(pool), available: (_) => true).media, 'md_v');
    });

    test('extendMap extends the edge segments at their rates', () {
      final map = [const MapSegment(1000000, 2000000, 5000000, 7000000), const MapSegment(2000000, 3000000, 7000000, 7500000)];
      expect(extendMap(map, t0: 500000, t1: 3200000), [
        const MapSegment(500000, 2000000, 4000000, 7000000),
        const MapSegment(2000000, 3200000, 7000000, 7600000),
      ]);
      expect(extendMap(map), map);
      expect(extendMap([const MapSegment(1000000, 2000000, 100000, 1100000)], t0: 0).first.s0, 0); // never below 0
      expect(() => extendMap(const []), throwsArgumentError);
    });

    test('holdSegment names the shortest valid source range near the end', () {
      expect(holdSegment(0, 1000000, 2000000, sourceDurationUs: 10000000), const MapSegment(0, 1000000, 2000000, 3000000));
      expect(holdSegment(0, 1000000, 9500000, sourceDurationUs: 10000000), const MapSegment(0, 1000000, 9500000, 9600000));
      expect(holdSegment(0, 33334, 9999000, sourceDurationUs: 10000000).rate, greaterThanOrEqualTo(0.1));
    });
  });
}
