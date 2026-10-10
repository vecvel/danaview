// OWNER: CORE-32
//
// Patch classification vectors (ARCH §11.2 "Patch classification"): one case per field of the
// rule — param-only: xf, crop, base, fx, anim, cmasks, color, audio gain; structural: layer set,
// kind, z, t, asset, map, hold, seq, any other audio field, canvas, durUs, asset set and entries.
// The vectors are written to test/fixtures/render_plans/classification.json (plan JSON + patch
// JSON + expected class) for the native suites (IOS-08, AND-08); this test checks the Dart
// classifier against them and that the committed file is current
// (`VWISH_UPDATE_GOLDENS=1 dart test <this file>` rewrites it).

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import '../compile_lowering/lowering_support.dart';

/// The base plan: a media clip, a dip helper solid, an image overlay and two audio segments.
RenderPlan basePlan() {
  final vA = asset('md_videoA00001', MediaKind.video);
  final vB = asset('md_videoB00001', MediaKind.video);
  final photo = asset('md_photo000001', MediaKind.image, w: 4000, h: 3000);
  final music = asset('md_music000001', MediaKind.audio, w: null, h: null);
  final p = project([
    mainLane([
      clip('it_left0000001', 0, 60, 'md_videoA00001', sourceIn: 1000000),
      clip('it_right000001', 60, 120, 'md_videoB00001'),
    ]).copyWith(transitions: [transition('tn_0000000001', 'it_left0000001', 'it_right000001', TransitionKind.dipToBlack, 10)]),
    lane('tr_ov1', TrackKind.overlay, [clip('it_photo000001', 0, 30, 'md_photo000001')]),
    lane('tr_music', TrackKind.audio, [audioClip('it_music000001', 0, 90, 'md_music000001')]),
  ], assets: [vA, vB, photo, music]);
  return compileStd(p, PlanTarget.preview).plan;
}

PlanLayer edit(PlanLayer l,
        {int? z,
        int? seq,
        int? t0,
        int? t1,
        PlanLayerKind? kind,
        String? asset,
        List<MapSegment>? map,
        bool? hold,
        int? color,
        PlanSize? base,
        PlanCrop? crop,
        PlanTransform? xf,
        PlanEffects? fx,
        Map<String, List<AnimKey>>? anim,
        List<CanvasMask>? cmasks}) =>
    PlanLayer(
      id: l.id,
      z: z ?? l.z,
      seq: seq ?? l.seq,
      t0: t0 ?? l.t0,
      t1: t1 ?? l.t1,
      kind: kind ?? l.kind,
      asset: asset ?? l.asset,
      map: map ?? l.map,
      hold: hold ?? l.hold,
      color: color ?? l.color,
      base: base ?? l.base,
      crop: crop ?? l.crop,
      xf: xf ?? l.xf,
      fx: fx ?? l.fx,
      anim: anim ?? l.anim,
      cmasks: cmasks ?? l.cmasks,
    );

AudioSeg editAudio(AudioSeg a, {String? asset, int? stream, int? t1, List<MapSegment>? map, List<AnimKey>? gain, bool? pitch}) => AudioSeg(
      id: a.id,
      asset: asset ?? a.asset,
      stream: stream ?? a.stream,
      t0: a.t0,
      t1: t1 ?? a.t1,
      map: map ?? a.map,
      gain: gain ?? a.gain,
      pitch: pitch ?? a.pitch,
    );

/// (name, patch, structural).
List<(String, RenderPlanPatch, bool)> vectors(RenderPlan from) {
  final media = from.layers.firstWhere((l) => l.id == 'it_left0000001#v');
  final solid = from.layers.firstWhere((l) => l.id == 'it_left0000001#tx0');
  final image = from.layers.firstWhere((l) => l.id == 'it_photo000001#v');
  final music = from.audio.firstWhere((a) => a.id == 'it_music000001#a');
  RenderPlanPatch layers(List<PlanLayer> upsert, [List<String> remove = const []]) =>
      RenderPlanPatch(from: from.rev, to: from.rev + 1, layers: PatchSet<PlanLayer>(upsert: upsert, remove: remove));
  RenderPlanPatch audio(List<AudioSeg> upsert, [List<String> remove = const []]) =>
      RenderPlanPatch(from: from.rev, to: from.rev + 1, audio: PatchSet<AudioSeg>(upsert: upsert, remove: remove));
  final m = media.map.single;
  return [
    ('empty', RenderPlanPatch(from: from.rev, to: from.rev + 1), false),
    ('param_xf', layers([edit(media, xf: const PlanTransform(s: 1.5, r: 10, op: 0.5))]), false),
    ('param_crop', layers([edit(media, crop: const PlanCrop(0.1, 0, 1, 1))]), false),
    ('param_base', layers([edit(media, base: const PlanSize(960, 540))]), false),
    ('param_fx', layers([edit(media, fx: const PlanEffects(adj: PlanAdjust(contrast: 0.3)))]), false),
    ('param_anim', layers([edit(media, anim: {PlanChannels.xfOp: [AnimKey(media.t0, 0), AnimKey(media.t1, 1)]})]), false),
    ('param_cmasks', layers([edit(image, cmasks: const [CanvasMask(cx: 960, cy: 540, w: 960, h: 1080)])]), false),
    ('param_color', layers([edit(solid, color: 0xFFFFFFFF)]), false),
    ('param_several_layers', layers([edit(media, xf: const PlanTransform(s: 2)), edit(image, fx: const PlanEffects(detail: PlanDetail(blur: 0.2)))]), false),
    ('param_audio_gain', audio([editAudio(music, gain: const [AnimKey(0, 0.5)])]), false),
    ('structural_layer_added', layers([PlanLayer(id: 'it_new00000001#v', z: 10010, t0: 0, t1: fr(30), kind: PlanLayerKind.solid, color: 0xFF303030, base: const PlanSize(1920, 1080))]), true),
    ('structural_layer_removed', layers(const [], ['it_photo000001#v']), true),
    ('structural_kind', layers([edit(image, kind: PlanLayerKind.solid, color: 0xFF303030)]), true),
    ('structural_z', layers([edit(image, z: 10020)]), true),
    ('structural_t0', layers([edit(image, t0: fr(1))]), true),
    ('structural_t1', layers([edit(image, t1: fr(29))]), true),
    ('structural_asset', layers([edit(media, asset: 'md_videoB00001')]), true),
    ('structural_map', layers([edit(media, map: [MapSegment(m.t0, m.t1, m.s0 + 1000, m.s1 + 1000)])]), true),
    ('structural_hold', layers([edit(media, hold: true)]), true),
    ('structural_seq', layers([edit(media, seq: 1)]), true),
    ('structural_audio_added', audio([editAudio(music).let((a) => AudioSeg(id: 'it_new00000002#a', asset: a.asset, t0: a.t0, t1: a.t1, map: a.map, gain: a.gain))]), true),
    ('structural_audio_removed', audio(const [], ['it_music000001#a']), true),
    ('structural_audio_asset', audio([editAudio(music, asset: 'md_videoA00001')]), true),
    ('structural_audio_stream', audio([editAudio(music, stream: 1)]), true),
    ('structural_audio_range_and_map', audio([editAudio(music, t1: fr(60), map: [MapSegment(0, fr(60), 0, fr(60))])]), true),
    ('structural_audio_pitch', audio([editAudio(music, pitch: false)]), true),
    ('structural_canvas', RenderPlanPatch(from: from.rev, to: from.rev + 1, canvas: PlanCanvas(w: 1280, h: 720, fps: 30, bg: from.canvas.bg)), true),
    ('structural_duration', RenderPlanPatch(from: from.rev, to: from.rev + 1, durUs: from.durUs + fr(1)), true),
    ('structural_asset_added', RenderPlanPatch(from: from.rev, to: from.rev + 1, assetUpserts: const {'md_extra000001': PlanAsset(kind: PlanAssetKind.image, uri: 'file:///media/md_extra000001.jpg')}), true),
    ('structural_asset_removed', RenderPlanPatch(from: from.rev, to: from.rev + 1, assetRemovals: const ['md_photo000001']), true),
    (
      'structural_asset_entry_changed',
      RenderPlanPatch(from: from.rev, to: from.rev + 1, assetUpserts: {
        'md_videoA00001': PlanAsset(
            kind: PlanAssetKind.video,
            uri: from.assets['md_videoA00001']!.uri,
            fp: from.assets['md_videoA00001']!.fp,
            proxyUri: 'file:///cache/vwish/editor/proxies/md_videoA00001-540.mp4'),
      }),
      true
    ),
    ('structural_mixed_with_param', layers([edit(media, xf: const PlanTransform(s: 2)), edit(image, t1: fr(20))]), true),
  ];
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

void main() {
  final from = basePlan();
  final cases = vectors(from);

  test('base plan is valid', () => expect(PlanValidator.validate(from), isEmpty));

  for (final (name, patch, structural) in cases) {
    test('$name → ${structural ? 'structural' : 'paramOnly'}', () {
      expect(classifyPatch(from, patch), structural ? PatchClass.structural : PatchClass.paramOnly);
      // Every vector applies cleanly and survives the wire format.
      final wire = PlanJson.decodePatchBytes(PlanJson.encodePatchBytes(patch));
      expect(classifyPatch(from, wire), classifyPatch(from, patch));
      applyPatch(from, patch);
    });
  }

  test('vectors are committed at test/fixtures/render_plans/classification.json', () {
    final json = {
      'v': 1,
      'description': 'RenderPlan patch classification vectors (ARCH §11.2). For each case, apply `patch` to `from` '
          'and classify: structural = true means rebuild the composition, false means swap the ParamSnapshot.',
      'from': PlanJson.encodePlan(from),
      'cases': [
        for (final (name, patch, structural) in cases)
          {'name': name, 'patch': PlanJson.encodePatch(patch), 'structural': structural},
      ],
    };
    final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
    final file = File('test/fixtures/render_plans/classification.json');
    if (updateGoldens || !file.existsSync()) {
      file.writeAsStringSync(text);
      if (!updateGoldens) fail('${file.path} was missing and has been written; rerun');
    }
    expect(file.readAsStringSync(), text, reason: 'VWISH_UPDATE_GOLDENS=1 to rewrite');
    // The committed vectors decode and classify as recorded.
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final plan = PlanJson.decodePlan(decoded['from']! as Map<String, Object?>);
    for (final c in (decoded['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
      final patch = PlanJson.decodePatch(c['patch']! as Map<String, Object?>);
      expect(patchIsStructural(plan, patch), c['structural'], reason: c['name'] as String);
    }
  });
}
