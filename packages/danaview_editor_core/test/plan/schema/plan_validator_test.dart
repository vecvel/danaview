// OWNER: CORE-29
//
// PlanValidator (ARCH §11.3) through the typed API: edge cases the fixture corpus does not spell
// out one by one, and the exact semantics of ordering, grids, ranges and bands.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

const _vid = PlanAsset(kind: PlanAssetKind.video, uri: 'file:///a.mp4', fp: 'ab', w: 1920, h: 1080, durUs: 8000000);
const _aud = PlanAsset(kind: PlanAssetKind.audio, uri: 'file:///a.m4a');
const _img = PlanAsset(kind: PlanAssetKind.image, uri: 'file:///a.jpg');

TimeUs f(int k, [int fps = 30]) => FrameRate(fps, 1).timeOfFrame(k);

PlanLayer media(String id, {int z = 10, int seq = 0, int a = 0, int b = 30, double rate = 1, int fps = 30, String asset = 'md_v'}) {
  final t0 = f(a, fps);
  final t1 = f(b, fps);
  return PlanLayer(id: id, z: z, seq: seq, t0: t0, t1: t1, kind: PlanLayerKind.media, asset: asset, map: [MapSegment(t0, t1, 0, ((t1 - t0) * rate).round())]);
}

RenderPlan plan({List<PlanLayer>? layers, List<AudioSeg> audio = const [], int fps = 30, int? gridFps, int? durFrames, Map<String, PlanAsset>? assets, int v = 1}) {
  final ls = layers ?? [media('it_a#v')];
  return RenderPlan(
    v: v,
    rev: 1,
    target: PlanTarget.preview,
    canvas: PlanCanvas(w: 1920, h: 1080, fps: fps, gridFps: gridFps),
    durUs: f(durFrames ?? 60, gridFps ?? fps),
    assets: assets ?? {'md_v': _vid, 'md_a': _aud, 'md_i': _img},
    layers: ls,
    audio: audio,
  );
}

Set<PlanViolationCode> codes(RenderPlan p) => {for (final v in PlanValidator.validate(p)) v.code};

AudioSeg seg(String id, {int a = 0, int b = 30, List<AnimKey>? gain}) =>
    AudioSeg(id: id, asset: 'md_a', t0: f(a), t1: f(b), map: [MapSegment(f(a), f(b), 0, f(b) - f(a))], gain: gain ?? [AnimKey(f(a), 1)]);

void main() {
  test('a valid plan has no violations', () => expect(PlanValidator.validate(plan()), isEmpty));

  test('an empty plan is valid, including durUs 0', () {
    expect(PlanValidator.validate(RenderPlan(rev: 0, target: PlanTarget.export, canvas: const PlanCanvas(w: 16, h: 16, fps: 24), durUs: 0)), isEmpty);
  });

  test('version other than 1 is a violation', () => expect(codes(plan(v: 2)), {PlanViolationCode.version}));

  group('violations name the layer', () {
    test('toString carries code, id and text', () {
      final v = PlanValidator.validate(plan(layers: [media('it_a#v', a: 0, b: 90)])).single;
      expect(v.id, 'it_a#v');
      expect(v.code, PlanViolationCode.range);
      expect(v.toString(), allOf(contains('range'), contains('it_a#v')));
    });
  });

  group('grid (D-35)', () {
    test('every edge on the gridFps grid is accepted at every project rate', () {
      for (final fps in FrameRate.supportedProjectRates) {
        for (final start in [0, 1, 2, 31, 32, 61, 62]) {
          final l = media('it_a#v', a: start, b: start + 7, fps: fps);
          final p = RenderPlan(
            rev: 1,
            target: PlanTarget.preview,
            canvas: PlanCanvas(w: 1920, h: 1080, fps: fps),
            durUs: f(start + 7, fps),
            assets: {'md_v': _vid},
            layers: [l],
          );
          expect(PlanValidator.validate(p), isEmpty, reason: '$fps fps start $start');
        }
      }
    });

    test('platform times one µs before the plan edge are off the grid (they must be mapped first)', () {
      final rate = FrameRate.fps30;
      final p = rate.platformTimeOfFrame(31); // 1 µs before the plan edge of frame 31
      expect(p, rate.timeOfFrame(31) - 1);
      final l = PlanLayer(id: 'it_a#v', z: 10, seq: 0, t0: 0, t1: p, kind: PlanLayerKind.media, asset: 'md_v', map: [MapSegment(0, p, 0, p)]);
      expect(codes(plan(layers: [l])), contains(PlanViolationCode.offGrid));
    });

    test('with gridFps ≠ fps the project rate decides', () {
      final onProjectGrid = media('it_a#v', fps: 30);
      expect(PlanValidator.validate(plan(fps: 24, gridFps: 30, layers: [onProjectGrid])), isEmpty);
      final onOutputGrid = media('it_a#v', fps: 24, a: 1, b: 25);
      expect(codes(plan(fps: 24, gridFps: 30, layers: [onOutputGrid])), contains(PlanViolationCode.offGrid));
    });

    test('an invalid gridFps is reported once, not as a cascade of off-grid edges', () {
      final p = RenderPlan(rev: 1, target: PlanTarget.preview, canvas: const PlanCanvas(w: 1920, h: 1080, fps: 30, gridFps: 29), durUs: 1000001, assets: {'md_v': _vid}, layers: [media('it_a#v')]);
      expect(codes(p), {PlanViolationCode.canvas});
    });

    test('audio edges and map breakpoints are checked too', () {
      final bad = AudioSeg(id: 'it_a#a', asset: 'md_a', t0: 1, t1: f(30), map: [MapSegment(1, f(30), 0, f(30))], gain: [const AnimKey(1, 1)]);
      expect(codes(plan(audio: [bad])), {PlanViolationCode.offGrid});
    });
  });

  group('maps', () {
    PlanLayer withMap(List<MapSegment> m, {int a = 0, int b = 30}) =>
        PlanLayer(id: 'it_a#v', z: 10, seq: 0, t0: f(a), t1: f(b), kind: PlanLayerKind.media, asset: 'md_v', map: m);

    test('rate bounds are inclusive with a small epsilon for rounding', () {
      final t1 = f(30);
      expect(PlanValidator.validate(plan(layers: [withMap([MapSegment(0, t1, 0, (t1 * 10).floor())])])), isEmpty);
      expect(PlanValidator.validate(plan(layers: [withMap([MapSegment(0, t1, 0, (t1 * 0.1).ceil())])])), isEmpty);
      expect(codes(plan(layers: [withMap([MapSegment(0, t1, 0, (t1 * 10.01).ceil())])])), {PlanViolationCode.map});
      expect(codes(plan(layers: [withMap([MapSegment(0, t1, 0, (t1 * 0.099).floor())])])), {PlanViolationCode.map});
      expect(codes(plan(layers: [withMap([MapSegment(0, t1, 5, 5)])])), {PlanViolationCode.map}, reason: 'rate 0');
    });

    test('segments must start at t0, end at t1 and touch', () {
      expect(codes(plan(layers: [withMap([MapSegment(f(1), f(30), 0, 100)])])), {PlanViolationCode.map});
      expect(codes(plan(layers: [withMap([MapSegment(0, f(29), 0, 100)])])), {PlanViolationCode.map});
      expect(PlanValidator.validate(plan(layers: [withMap([MapSegment(0, f(10), 0, f(10)), MapSegment(f(10), f(30), f(10), f(30))])])), isEmpty);
      expect(codes(plan(layers: [withMap([MapSegment(0, f(10), 0, f(10)), MapSegment(f(11), f(30), f(10), f(30))])])), {PlanViolationCode.map});
    });

    test('image layers ignore maps but may not carry one; hold is for media only', () {
      final img = PlanLayer(id: 'it_i#v', z: 10010, t0: 0, t1: f(30), kind: PlanLayerKind.image, asset: 'md_i');
      expect(PlanValidator.validate(plan(layers: [img])), isEmpty);
      final held = PlanLayer(id: 'it_h#v', z: 10, seq: 0, t0: 0, t1: f(30), kind: PlanLayerKind.media, asset: 'md_v', hold: true, map: [MapSegment(0, f(30), 0, f(30))]);
      expect(PlanValidator.validate(plan(layers: [held])), isEmpty);
    });
  });

  group('sequence slots (seq)', () {
    test('touching layers may share a slot; overlapping ones may not', () {
      expect(PlanValidator.validate(plan(layers: [media('it_a#v', a: 0, b: 30), media('it_b#v', a: 30, b: 60)])), isEmpty);
      expect(codes(plan(layers: [media('it_a#v', a: 0, b: 31), media('it_b#v', a: 30, b: 60)])), contains(PlanViolationCode.seq));
    });

    test('overlap across different slots is fine inside a transition window (≤ 2 layers per z)', () {
      expect(PlanValidator.validate(plan(layers: [media('it_a#v', a: 0, b: 36), media('it_b#v', seq: 1, a: 24, b: 60)])), isEmpty);
    });

    test('a third overlapping layer within one z is rejected', () {
      final v = codes(plan(layers: [media('it_a#v', a: 0, b: 40), media('it_b#v', seq: 1, a: 10, b: 50), media('it_c#v', seq: 2, a: 20, b: 60)]));
      expect(v, {PlanViolationCode.zBand});
    });

    test('three layers at different z may overlap freely', () {
      final p = plan(layers: [media('it_a#v', a: 0, b: 60), media('it_b#v', z: 20, seq: 1, a: 0, b: 60), media('it_c#v', z: 30, seq: 2, a: 0, b: 60)]);
      expect(PlanValidator.validate(p), isEmpty);
    });
  });

  group('ordering', () {
    test('layers sort by (z, t0, id); ties on z and t0 break by id', () {
      expect(PlanValidator.validate(plan(layers: [media('a#v', b: 10), media('b#v', seq: 1, b: 10)])), isEmpty);
      expect(codes(plan(layers: [media('b#v', b: 10), media('a#v', seq: 1, b: 10)])), {PlanViolationCode.order});
      expect(codes(plan(layers: [media('it_a#v', z: 20, b: 10), media('it_b#v', z: 10, seq: 1, b: 10)])), {PlanViolationCode.order});
    });

    test('audio sorts by (t0, id)', () {
      expect(PlanValidator.validate(plan(audio: [seg('a#a', b: 10), seg('b#a', b: 10)])), isEmpty);
      expect(codes(plan(audio: [seg('b#a', b: 10), seg('a#a', b: 10)])), {PlanViolationCode.order});
      expect(codes(plan(audio: [seg('a#a', a: 10, b: 20), seg('b#a', a: 0, b: 10)])), {PlanViolationCode.order});
    });
  });

  group('bands (ARCH §11.4)', () {
    PlanLayer sprite(int z) => PlanLayer(id: 'it_s#v', z: z, t0: 0, t1: f(30), kind: PlanLayerKind.sprite, asset: 'sp');
    const spriteAsset = PlanAsset(kind: PlanAssetKind.sprite, uri: 'file:///s.vsprite', sw: 10, sh: 10, sscale: 1);

    test('sprites belong to the text and subtitle bands', () {
      final assets = {'md_v': _vid, 'sp': spriteAsset};
      expect(PlanValidator.validate(plan(layers: [sprite(20010)], assets: assets)), isEmpty);
      expect(PlanValidator.validate(plan(layers: [sprite(30010)], assets: assets)), isEmpty);
      expect(codes(plan(layers: [sprite(10010)], assets: assets)), {PlanViolationCode.zBand});
      expect(codes(plan(layers: [sprite(10)], assets: assets)), {PlanViolationCode.zBand});
    });

    test('media and images stay below the text band; solids may sit anywhere', () {
      expect(codes(plan(layers: [media('it_a#v', z: 20010)])), {PlanViolationCode.zBand});
      final solid = PlanLayer(id: 'it_x#tx1', z: 20015, t0: 0, t1: f(30), kind: PlanLayerKind.solid, color: 0xFF000000);
      expect(PlanValidator.validate(plan(layers: [solid])), isEmpty);
      expect(PlanValidator.validate(plan(layers: [PlanLayer(id: 'it_b#bd', z: 5, seq: 0, t0: 0, t1: f(30), kind: PlanLayerKind.media, asset: 'md_v', map: [MapSegment(0, f(30), 0, f(30))])])), isEmpty);
    });
  });

  group('values', () {
    test('animated values obey the channel ranges, unbounded channels do not', () {
      PlanLayer withAnim(String channel, double v) => PlanLayer(
            id: 'it_a#v',
            z: 10,
            seq: 0,
            t0: 0,
            t1: f(30),
            kind: PlanLayerKind.media,
            asset: 'md_v',
            map: [MapSegment(0, f(30), 0, f(30))],
            anim: {channel: [AnimKey(0, v)]},
          );
      expect(PlanValidator.validate(plan(layers: [withAnim('xf.cx', -5000)])), isEmpty);
      expect(PlanValidator.validate(plan(layers: [withAnim('xf.r', 720)])), isEmpty);
      expect(PlanValidator.validate(plan(layers: [withAnim('adj.exposure', 1)])), isEmpty);
      expect(codes(plan(layers: [withAnim('adj.exposure', 1.01)])), {PlanViolationCode.value});
      expect(codes(plan(layers: [withAnim('detail.blur', -0.01)])), {PlanViolationCode.value});
      expect(codes(plan(layers: [withAnim('xf.op', 1.2)])), {PlanViolationCode.value});
      expect(codes(plan(layers: [withAnim('mask.op', 2)])), {PlanViolationCode.value});
      expect(codes(plan(layers: [withAnim('xf.s', -0.5)])), {PlanViolationCode.value});
    });

    test('gain envelope: 0 and 2 are valid, anything outside is not', () {
      expect(PlanValidator.validate(plan(audio: [seg('a#a', gain: [const AnimKey(0, 0), AnimKey(f(10), 2)])])), isEmpty);
      expect(codes(plan(audio: [seg('a#a', gain: [const AnimKey(0, 2.0001)])])), {PlanViolationCode.gain});
      expect(codes(plan(audio: [seg('a#a', gain: [const AnimKey(0, -0.0001)])])), {PlanViolationCode.gain});
      expect(codes(plan(audio: [seg('a#a', gain: const [])])), {PlanViolationCode.gain});
    });
  });

  group('assets', () {
    test('uris must be file:// or content://', () {
      for (final bad in ['http://x/a.mp4', 'https://x/a.mp4', '/tmp/a.mp4', 'ftp://x']) {
        final p = plan(assets: {'md_v': PlanAsset(kind: PlanAssetKind.video, uri: bad)});
        expect(codes(p), {PlanViolationCode.asset}, reason: bad);
      }
      expect(PlanValidator.validate(plan(assets: {'md_v': const PlanAsset(kind: PlanAssetKind.video, uri: 'content://media/42')})), isEmpty);
    });

    test('audio segments accept audio and video assets, not images', () {
      expect(PlanValidator.validate(plan(audio: [seg('a#a', b: 10)])), isEmpty);
      final videoAudio = AudioSeg(id: 'v#a', asset: 'md_v', t0: 0, t1: f(10), map: [MapSegment(0, f(10), 0, f(10))], gain: [const AnimKey(0, 1)]);
      expect(PlanValidator.validate(plan(audio: [videoAudio])), isEmpty);
      final onImage = AudioSeg(id: 'i#a', asset: 'md_i', t0: 0, t1: f(10), map: [MapSegment(0, f(10), 0, f(10))], gain: [const AnimKey(0, 1)]);
      expect(codes(plan(audio: [onImage])), {PlanViolationCode.asset});
    });

    test('a layer may reference a missing asset only by being reported', () {
      final v = PlanValidator.validate(plan(layers: [media('it_a#v', asset: 'md_missing')]));
      expect(v.single.code, PlanViolationCode.asset);
      expect(v.single.id, 'it_a#v');
    });
  });
}
