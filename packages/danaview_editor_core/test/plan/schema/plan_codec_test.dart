// OWNER: CORE-29
//
// Deterministic JSON codec: canonical form, defaults omitted, number and colour formats, typed
// round trips over random plans, animation evaluation helpers, ids.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

PlanCanvas _canvas() => const PlanCanvas(w: 1920, h: 1080, fps: 30);

RenderPlan _plan({List<PlanLayer> layers = const [], List<AudioSeg> audio = const [], Map<String, PlanAsset> assets = const {}, int durUs = 3000000}) =>
    RenderPlan(rev: 1, target: PlanTarget.preview, canvas: _canvas(), durUs: durUs, assets: assets, layers: layers, audio: audio);

String _enc(RenderPlan p) => utf8.decode(PlanJson.encodePlanBytes(p));

const _vid = PlanAsset(kind: PlanAssetKind.video, uri: 'file:///a.mp4', fp: 'ab', w: 1920, h: 1080, durUs: 8000000);

PlanLayer _media({String id = 'it_a#v', int z = 10, int seq = 0, int t0 = 0, int t1 = 3000000, PlanTransform xf = PlanTransform.identity, PlanEffects fx = PlanEffects.none, Map<String, List<AnimKey>> anim = const {}}) =>
    PlanLayer(id: id, z: z, seq: seq, t0: t0, t1: t1, kind: PlanLayerKind.media, asset: 'md_a', map: [MapSegment(t0, t1, 0, t1 - t0)], base: const PlanSize(1920, 1080), xf: xf, fx: fx, anim: anim);

void main() {
  group('canonical form', () {
    test('defaults are omitted', () {
      final text = _enc(_plan(layers: [_media()], assets: {'md_a': _vid}));
      expect(text, isNot(contains('"xf"')));
      expect(text, isNot(contains('"crop"')));
      expect(text, isNot(contains('"fx"')));
      expect(text, isNot(contains('"anim"')));
      expect(text, isNot(contains('"cmasks"')));
      expect(text, isNot(contains('"hold"')));
      expect(text, isNot(contains('gridFps')));
      expect(text, isNot(contains('"req"')));
      expect(text, isNot(contains('"transfer"')));
    });

    test('non-default values are written, defaults inside a partial xf are not', () {
      final l = _media(xf: const PlanTransform(cx: 100, s: 2, fx: true));
      final text = _enc(_plan(layers: [l], assets: {'md_a': _vid}));
      expect(text, contains('"xf":{"cx":100,"s":2,"fx":true}'));
    });

    test('key order follows the ARCH §11.2 tables and is stable', () {
      final json = PlanJson.encodePlan(_plan(layers: [_media()], assets: {'md_a': _vid}));
      expect(json.keys.toList(), ['v', 'rev', 'target', 'canvas', 'durUs', 'assets', 'layers', 'audio']);
      final layer = (json['layers']! as List).first as Map<String, Object?>;
      expect(layer.keys.toList(), ['id', 'z', 'seq', 't', 'kind', 'asset', 'map', 'base']);
      expect(_enc(_plan(layers: [_media()], assets: {'md_a': _vid})), _enc(_plan(layers: [_media()], assets: {'md_a': _vid})));
    });

    test('assets and animation channels are sorted by name regardless of insertion order', () {
      final p = _plan(
        assets: {'md_z': _vid, 'md_a': _vid, 'md_m': _vid},
        layers: [
          _media(anim: {
            'xf.s': [const AnimKey(0, 1)],
            'adj.exposure': [const AnimKey(0, 0)],
            'xf.cx': [const AnimKey(0, 5)],
          }),
        ],
      );
      final json = PlanJson.encodePlan(p);
      expect((json['assets']! as Map<String, Object?>).keys.toList(), ['md_a', 'md_m', 'md_z']);
      final anim = (((json['layers']! as List).first as Map<String, Object?>)['anim']! as Map<String, Object?>).keys.toList();
      expect(anim, ['adj.exposure', 'xf.cx', 'xf.s']);
    });

    test('integral doubles are integers, other doubles keep the shortest round-trip text', () {
      final l = _media(xf: const PlanTransform(cx: 960.0, cy: 540.5, s: 1.25, r: -0.0, op: 0.30000000000000004));
      final text = _enc(_plan(layers: [l], assets: {'md_a': _vid}));
      expect(text, contains('"cx":960,'));
      expect(text, contains('"cy":540.5'));
      expect(text, contains('"s":1.25'));
      expect(text, isNot(contains('"r"')), reason: '-0.0 equals the default 0');
      expect(text, contains('"op":0.30000000000000004'));
      final back = PlanJson.decodePlan(jsonDecode(text) as Map<String, Object?>);
      expect(back.layers.single.xf.op, 0.30000000000000004);
    });

    test('the bytes are UTF-8 JSON without a byte-order mark or trailing newline', () {
      final bytes = PlanJson.encodePlanBytes(_plan());
      expect(bytes.first, 0x7B);
      expect(bytes.last, 0x7D);
      expect(PlanJson.canonicalString(PlanJson.encodePlan(_plan())), utf8.decode(bytes));
    });

    test('non-ASCII text in uris and ids survives', () {
      final p = _plan(assets: {'md_é': const PlanAsset(kind: PlanAssetKind.video, uri: 'file:///Vidéos/été.mp4')});
      final back = PlanJson.decodePlanBytes(PlanJson.encodePlanBytes(p));
      expect(back.assets['md_é']!.uri, 'file:///Vidéos/été.mp4');
    });
  });

  group('colours', () {
    test('#RRGGBBAA uppercase with alpha last', () {
      expect(PlanJson.encodeColor(0xFF102030), '#102030FF');
      expect(PlanJson.encodeColor(0x80FFFFFF), '#FFFFFF80');
      expect(PlanJson.encodeColor(0x00000000), '#00000000');
      expect(PlanJson.encodeColor(0xFFabcdef), '#ABCDEFFF');
    });

    test('decode accepts #RRGGBBAA, lowercase and #RRGGBB (alpha FF)', () {
      expect(PlanJson.decodeColor('#102030FF'), 0xFF102030);
      expect(PlanJson.decodeColor('#abcdef80'), 0x80ABCDEF);
      expect(PlanJson.decodeColor('#102030'), 0xFF102030);
    });

    test('decode rejects everything else', () {
      for (final bad in ['', '102030FF', '#12', '#1020304', '#10203040FF', '#GGGGGG', 'red']) {
        expect(() => PlanJson.decodeColor(bad), throwsA(isA<PlanFormatException>()), reason: bad);
      }
    });

    test('the chroma key is a plain #RRGGBB', () {
      final l = _media(fx: const PlanEffects(chroma: PlanChroma(key: 0x00B140)));
      final text = _enc(_plan(layers: [l], assets: {'md_a': _vid}));
      expect(text, contains('"key":"#00B140"'));
      expect(PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode(text))).layers.single.fx.chroma!.key, 0x00B140);
    });
  });

  group('typed round trips', () {
    test('decode(encode(plan)) == plan over 300 random plans', () {
      final rnd = Random(29);
      for (var i = 0; i < 300; i++) {
        final plan = _randomPlan(rnd);
        final bytes = PlanJson.encodePlanBytes(plan);
        final back = PlanJson.decodePlanBytes(bytes);
        expect(back, plan, reason: 'plan $i');
        expect(back.hashCode, plan.hashCode);
        expect(PlanJson.encodePlanBytes(back), bytes, reason: 'plan $i re-encodes to the same bytes');
      }
    });

    test('patches and transients round-trip', () {
      final rnd = Random(30);
      for (var i = 0; i < 100; i++) {
        final patch = RenderPlanPatch(
          from: i,
          to: i + 1,
          canvas: rnd.nextBool() ? _canvas() : null,
          durUs: rnd.nextBool() ? 6000000 : null,
          assetUpserts: rnd.nextBool() ? {'md_a': _vid} : const {},
          assetRemovals: rnd.nextBool() ? ['md_old'] : const [],
          layers: PatchSet<PlanLayer>(upsert: rnd.nextBool() ? [_randomLayer(rnd, 'it_p$i#v')] : const [], remove: rnd.nextBool() ? ['it_x#v'] : const []),
          audio: PatchSet<AudioSeg>(upsert: rnd.nextBool() ? [_randomAudio(rnd, 'it_p$i#a')] : const [], remove: rnd.nextBool() ? ['it_y#a'] : const []),
        );
        expect(PlanJson.decodePatchBytes(PlanJson.encodePatchBytes(patch)), patch, reason: 'patch $i');

        final t = PlanTransient(item: 'it_p$i', layers: [
          TransientLayer(
            id: 'it_p$i#v',
            xf: rnd.nextBool() ? PlanTransform(cx: rnd.nextDouble() * 1000, s: 0.5 + rnd.nextDouble()) : null,
            crop: rnd.nextBool() ? const PlanCrop(0.1, 0.1, 0.9, 0.9) : null,
            base: rnd.nextBool() ? const PlanSize(100.5, 50) : null,
            fx: rnd.nextBool() ? _randomFx(rnd) : null,
            anim: rnd.nextBool() ? _randomAnim(rnd) : null,
            cmasks: rnd.nextBool() ? [const CanvasMask(cx: 1, cy: 2, w: 3, h: 4, r: 5, feather: 6, inv: true)] : null,
          ),
        ]);
        expect(PlanJson.decodeTransientBytes(PlanJson.encodeTransientBytes(t)), t, reason: 'transient $i');
      }
    });

    test('an empty patch set is omitted and decodes back to an empty set', () {
      final p = RenderPlanPatch(from: 1, to: 2);
      final json = PlanJson.encodePatch(p);
      expect(json.keys.toList(), ['v', 'from', 'to']);
      expect(PlanJson.decodePatch(json), p);
      expect(p.layers.isEmpty && p.audio.isEmpty, isTrue);
    });

    test('a transient with empty (non-null) overrides keeps them: they clear the layer\'s value', () {
      final t = PlanTransient(item: 'x', layers: [TransientLayer(id: 'x#v', fx: PlanEffects.none, anim: const {}, cmasks: const [])]);
      final json = PlanJson.encodeTransient(t);
      final layer = (json['layers']! as List).first as Map<String, Object?>;
      expect(layer.keys, containsAll(['fx', 'anim', 'cmasks']));
      expect(PlanJson.decodeTransient(json), t);
    });
  });

  group('plan value types', () {
    test('collections are unmodifiable', () {
      final p = _plan(layers: [_media(anim: {'xf.s': [const AnimKey(0, 1)]})], assets: {'md_a': _vid});
      expect(() => p.layers.add(p.layers.first), throwsUnsupportedError);
      expect(() => p.assets['x'] = _vid, throwsUnsupportedError);
      expect(() => p.audio.clear(), throwsUnsupportedError);
      expect(() => p.layers.first.anim['x'] = [], throwsUnsupportedError);
      expect(() => p.layers.first.map.clear(), throwsUnsupportedError);
    });

    test('copyWith keeps the version and replaces the given fields', () {
      final p = _plan(layers: [_media()], assets: {'md_a': _vid});
      expect(p.copyWith(), p);
      expect(p.copyWith(rev: 9).rev, 9);
      expect(p.copyWith(rev: 9), isNot(p));
      expect(p.copyWith(target: PlanTarget.export).target, PlanTarget.export);
      expect(p.copyWith(durUs: 1).durUs, 1);
      expect(p.copyWith(canvas: _canvas().copyWith(w: 1280, h: 720)).canvas.w, 1280);
      expect(p.copyWith(layers: const []).layers, isEmpty);
      expect(p.copyWith(req: PlanRequirements(offline: ['x'])).req!.offline, ['x']);
      expect(p.v, renderPlanVersion);
    });

    test('canvas: gridFps defaults to fps; rates and copyWith', () {
      const c = PlanCanvas(w: 1280, h: 720, fps: 24);
      expect(c.gridFps, 24);
      expect(c.frameRate, FrameRate.fps24);
      expect(c.gridRate, FrameRate.fps24);
      final e = c.copyWith(gridFps: 30);
      expect(e.gridFps, 30);
      expect(e.gridRate, FrameRate.fps30);
      expect(e, isNot(c));
      expect(c.copyWith(), c);
      expect(c.bg, 0xFF000000);
    });

    test('layers: half-open activity, range', () {
      final l = _media(t0: 1000, t1: 2000);
      expect(l.isActiveAt(999), isFalse);
      expect(l.isActiveAt(1000), isTrue);
      expect(l.isActiveAt(1999), isTrue);
      expect(l.isActiveAt(2000), isFalse);
      expect(l.range, const TimeRange(1000, 2000));
    });

    test('activeLayerIdsAt lists layers bottom to top', () {
      final p = _plan(layers: [_media(id: 'a#v', t1: 2000000), _media(id: 'b#v', z: 10010, seq: 1, t0: 1000000, t1: 3000000)], assets: {'md_a': _vid});
      expect(p.activeLayerIdsAt(0), ['a#v']);
      expect(p.activeLayerIdsAt(1500000), ['a#v', 'b#v']);
      expect(p.activeLayerIdsAt(2500000), ['b#v']);
      expect(p.activeLayerIdsAt(3000000), isEmpty);
    });

    test('effects, crop and transform defaults', () {
      expect(PlanEffects.none.isEmpty, isTrue);
      expect(const PlanEffects(detail: PlanDetail()).isEmpty, isFalse);
      expect(PlanCrop.full.isFull, isTrue);
      expect(const PlanCrop(0, 0, 1, 0.9).isFull, isFalse);
      expect(PlanTransform.identity.isIdentity, isTrue);
      expect(const PlanTransform(op: 0.5).isIdentity, isFalse);
      expect(const PlanAdjust(exposure: 1, tint: -1).values, [1, 0, 0, 0, 0, 0, 0, -1]);
      expect(PlanChannels.adjust, hasLength(8));
      expect(PlanChannels.detail, hasLength(3));
      expect(PlanChannels.mask, hasLength(7));
      expect(PlanChannels.all, hasLength(5 + 1 + 8 + 3 + 7));
    });

    test('requirements', () {
      expect(PlanRequirements().isEmpty, isTrue);
      expect(PlanRequirements(pendingStill: ['md_s']).isEmpty, isFalse);
      expect(PlanRequirements(offline: ['a']), PlanRequirements(offline: ['a']));
      expect(PlanRequirements(offline: ['a']), isNot(PlanRequirements(offline: ['b'])));
      expect(PlanRequirements(offline: ['a']).hashCode, PlanRequirements(offline: ['a']).hashCode);
    });
  });

  group('animation keys', () {
    final keys = [const AnimKey(100, 0), const AnimKey(200, 10), const AnimKey(400, 30)];

    test('held before the first and after the last key', () {
      expect(evaluateAnimKeys(keys, -50), 0);
      expect(evaluateAnimKeys(keys, 100), 0);
      expect(evaluateAnimKeys(keys, 400), 30);
      expect(evaluateAnimKeys(keys, 9999), 30);
    });

    test('linear between keys', () {
      expect(evaluateAnimKeys(keys, 150), 5);
      expect(evaluateAnimKeys(keys, 200), 10);
      expect(evaluateAnimKeys(keys, 300), 20);
      expect(evaluateAnimKeys(keys, 399), closeTo(29.9, 1e-12));
    });

    test('a single key is a constant; many keys use binary search correctly', () {
      expect(evaluateAnimKeys([const AnimKey(5, 7)], 0), 7);
      expect(evaluateAnimKeys([const AnimKey(5, 7)], 500), 7);
      final many = [for (var i = 0; i < 1000; i++) AnimKey(i * 10, i * 2.0)];
      for (var t = 0; t <= 9990; t += 7) {
        expect(evaluateAnimKeys(many, t), closeTo(t / 5, 1e-9), reason: 't=$t');
      }
    });

    test('AnimKey equality and text', () {
      expect(const AnimKey(1, 2), const AnimKey(1, 2));
      expect(const AnimKey(1, 2).hashCode, const AnimKey(1, 2).hashCode);
      expect(const AnimKey(1, 2).toString(), '[1, 2.0]');
    });
  });

  group('stable ids (ARCH §11.2)', () {
    test('formats', () {
      expect(PlanIds.visual('it_a'), 'it_a#v');
      expect(PlanIds.backdrop('it_a'), 'it_a#bd');
      expect(PlanIds.transitionHelper('it_a', 2), 'it_a#tx2');
      expect(PlanIds.cue('it_c'), 'it_c#c');
      expect(PlanIds.audio('it_a'), 'it_a#a');
    });

    test('itemOf strips the suffix', () {
      for (final id in ['it_a#v', 'it_a#bd', 'it_a#tx1', 'it_a#a', 'it_a']) {
        expect(PlanIds.itemOf(id), 'it_a');
      }
      expect(PlanIds.itemOf(PlanIds.cue('it_cue')), 'it_cue');
    });
  });
}

// ---------------------------------------------------------------------------------------------
// Random plans.
// ---------------------------------------------------------------------------------------------

double _d(Random r, [double max = 1]) => (r.nextInt(2000) / 1000 - 1) * max;
double _u(Random r) => r.nextInt(1001) / 1000;

Map<String, List<AnimKey>> _randomAnim(Random r) {
  final channels = [...PlanChannels.all.where((c) => c != PlanChannels.reveal)]..shuffle(r);
  return {
    for (final c in channels.take(r.nextInt(4)))
      c: [for (var i = 0; i < 1 + r.nextInt(4); i++) AnimKey(i * 100000, _u(r))],
  };
}

PlanEffects _randomFx(Random r) => PlanEffects(
      adj: r.nextBool() ? PlanAdjust(exposure: _d(r), contrast: _d(r), tint: _d(r)) : null,
      detail: r.nextBool() ? PlanDetail(sharpen: _u(r), blur: _u(r)) : null,
      lut: r.nextBool() ? PlanLut('lt_a', _u(r)) : null,
      chroma: r.nextBool() ? PlanChroma(key: r.nextInt(0x1000000), sim: _u(r), smooth: _u(r), spill: _u(r)) : null,
      mask: r.nextBool()
          ? PlanMask(shape: r.nextBool() ? PlanMaskShape.rect : PlanMaskShape.ellipse, cx: _u(r), cy: _u(r), w: _u(r), h: _u(r), r: _d(r, 90), corner: _u(r) / 2, feather: _u(r), op: _u(r), inv: r.nextBool())
          : null,
    );

PlanLayer _randomLayer(Random r, String id) {
  final t0 = r.nextInt(30) * 33334;
  final t1 = t0 + (1 + r.nextInt(60)) * 33334;
  return PlanLayer(
    id: id,
    z: 10 + r.nextInt(3) * 10000,
    seq: r.nextInt(3),
    t0: t0,
    t1: t1,
    kind: PlanLayerKind.media,
    asset: 'md_a',
    map: [MapSegment(t0, t1, 1000, 1000 + (t1 - t0))],
    hold: r.nextInt(5) == 0,
    base: PlanSize(100 + r.nextInt(1000) + r.nextDouble(), 100 + r.nextInt(1000).toDouble()),
    crop: r.nextBool() ? const PlanCrop(0.05, 0.1, 0.95, 0.9) : PlanCrop.full,
    xf: r.nextBool() ? PlanTransform(cx: r.nextBool() ? _u(r) * 1920 : null, s: 0.5 + _u(r), r: _d(r, 180), fx: r.nextBool(), fy: r.nextBool(), op: _u(r)) : PlanTransform.identity,
    fx: r.nextBool() ? _randomFx(r) : PlanEffects.none,
    anim: _randomAnim(r),
    cmasks: r.nextBool() ? [CanvasMask(cx: _u(r) * 100, cy: 5, w: 10, h: 20, r: _d(r, 45), feather: _u(r) * 5, inv: r.nextBool(), anim: r.nextBool() ? {'cx': [const AnimKey(0, 1), const AnimKey(100, 2)]} : const {})] : const [],
  );
}

AudioSeg _randomAudio(Random r, String id) {
  final t0 = r.nextInt(30) * 33334;
  final t1 = t0 + (1 + r.nextInt(60)) * 33334;
  return AudioSeg(
    id: id,
    asset: 'md_a',
    stream: r.nextInt(3),
    t0: t0,
    t1: t1,
    map: [MapSegment(t0, t1, 0, t1 - t0)],
    gain: [for (var i = 0; i < 1 + r.nextInt(5); i++) AnimKey(t0 + i * 1000, _u(r) * 2)],
    pitch: r.nextBool(),
  );
}

RenderPlan _randomPlan(Random r) => RenderPlan(
      rev: r.nextInt(1000),
      target: r.nextBool() ? PlanTarget.preview : PlanTarget.export,
      canvas: PlanCanvas(w: 2 * (8 + r.nextInt(1000)), h: 2 * (8 + r.nextInt(1000)), fps: [24, 25, 30, 48, 50, 60][r.nextInt(6)], gridFps: r.nextBool() ? 30 : null, bg: r.nextInt(0x7FFFFFFF)),
      durUs: r.nextInt(100000000),
      assets: {
        'md_a': PlanAsset(
          kind: PlanAssetKind.video,
          uri: 'file:///a.mp4',
          bookmark: r.nextBool() ? 'AAEC' : null,
          fp: r.nextBool() ? 'ff' : '',
          proxyUri: r.nextBool() ? 'file:///p.mp4' : null,
          w: 1920,
          h: 1080,
          rot: [0, 90, 180, 270][r.nextInt(4)],
          durUs: 1000,
          transfer: PlanTransfer.values[r.nextInt(3)],
          hasAudio: r.nextBool() ? true : null,
        ),
        if (r.nextBool()) 'lt_a': const PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///l.vlut', n: 33),
        if (r.nextBool()) 'sp_a': PlanAsset(kind: PlanAssetKind.sprite, uri: 'file:///s.vsprite', sw: 100, sh: 20, sscale: 1.5, reveal: r.nextBool()),
      },
      layers: [for (var i = 0; i < r.nextInt(6); i++) _randomLayer(r, 'it_$i#v')],
      audio: [for (var i = 0; i < r.nextInt(4); i++) _randomAudio(r, 'it_$i#a')],
      req: r.nextBool() ? PlanRequirements(offline: r.nextBool() ? ['md_x'] : [], pendingReverse: r.nextBool() ? ['it_y'] : [], pendingStill: r.nextBool() ? ['md_z'] : []) : null,
    );
