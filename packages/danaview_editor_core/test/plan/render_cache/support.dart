// OWNER: CORE-37
//
// Builders for the render-cache tests: small hand-made preview plans on a 30 fps grid.

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

/// 30 fps grid.
const FrameRate grid = FrameRate.fps30;

/// Frame [k] on the 30 fps grid.
TimeUs f(int k) => grid.timeOfFrame(k);

/// A video asset with fingerprint [fp] at [uri].
PlanAsset video(String fp, {String? uri, String? proxy}) =>
    PlanAsset(kind: PlanAssetKind.video, uri: uri ?? 'file:///media/$fp.mp4', fp: fp, w: 1920, h: 1080, rot: 0, durUs: 600000000, proxyUri: proxy);

/// An image asset.
PlanAsset image(String fp) => PlanAsset(kind: PlanAssetKind.image, uri: 'file:///media/$fp.jpg', fp: fp, w: 1080, h: 1080, rot: 0);

/// A LUT asset.
PlanAsset lutAsset(String id) => PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///support/danaview/editor/luts/$id.vlut', n: 33);

/// A media layer on frames `[k0, k1)` showing [asset] from source frame [src] at [rate]×.
PlanLayer media(
  String id,
  int k0,
  int k1,
  String asset, {
  int z = 0,
  int? seq,
  int src = 0,
  int rate = 1,
  PlanTransform xf = PlanTransform.identity,
  PlanEffects fx = PlanEffects.none,
  Map<String, List<AnimKey>> anim = const {},
  List<CanvasMask> cmasks = const [],
  bool hold = false,
}) =>
    PlanLayer(
      id: id,
      z: z,
      seq: seq ?? z,
      t0: f(k0),
      t1: f(k1),
      kind: PlanLayerKind.media,
      asset: asset,
      map: [MapSegment(f(k0), f(k1), f(src), f(src) + (f(k1) - f(k0)) * rate)],
      hold: hold,
      base: const PlanSize(1920, 1080),
      xf: xf,
      fx: fx,
      anim: anim,
      cmasks: cmasks,
    );

/// A solid layer.
PlanLayer solid(String id, int k0, int k1, {int z = 0, int color = 0xFF112233}) =>
    PlanLayer(id: id, z: z, t0: f(k0), t1: f(k1), kind: PlanLayerKind.solid, color: color, base: const PlanSize(1920, 1080));

/// An image layer.
PlanLayer still(String id, int k0, int k1, String asset, {int z = 0, PlanEffects fx = PlanEffects.none}) => PlanLayer(
    id: id, z: z, t0: f(k0), t1: f(k1), kind: PlanLayerKind.image, asset: asset, base: const PlanSize(1080, 1080), fx: fx);

/// Sorts layers by (z, t0, id) like the compiler.
List<PlanLayer> sorted(Iterable<PlanLayer> layers) => layers.toList()
  ..sort((a, b) {
    final z = a.z.compareTo(b.z);
    if (z != 0) return z;
    final t = a.t0.compareTo(b.t0);
    return t != 0 ? t : a.id.compareTo(b.id);
  });

/// A 1920×1080 30 fps preview plan.
RenderPlan plan(List<PlanLayer> layers, {Map<String, PlanAsset>? assets, int rev = 1, PlanCanvas? canvas}) {
  final ls = sorted(layers);
  final dur = ls.fold<TimeUs>(0, (m, l) => l.t1 > m ? l.t1 : m);
  return RenderPlan(
    rev: rev,
    target: PlanTarget.preview,
    canvas: canvas ?? const PlanCanvas(w: 1920, h: 1080, fps: 30),
    durUs: dur,
    assets: assets ?? {for (final l in ls) if (l.asset != null) l.asset!: video('fp_${l.asset}')},
    layers: ls,
  );
}

/// [p] with [layer] replaced (by id) or added.
RenderPlan withLayer(RenderPlan p, PlanLayer layer) =>
    plan([for (final l in p.layers) if (l.id != layer.id) l, layer], assets: p.assets, rev: p.rev + 1, canvas: p.canvas);

/// [p] without the layer [id].
RenderPlan withoutLayer(RenderPlan p, String id) =>
    plan([for (final l in p.layers) if (l.id != id) l], assets: p.assets, rev: p.rev + 1, canvas: p.canvas);

/// A copy of [l] with the given fields replaced.
PlanLayer copyLayer(PlanLayer l, {String? id, TimeUs? t0, TimeUs? t1, List<MapSegment>? map, PlanTransform? xf, PlanEffects? fx, Map<String, List<AnimKey>>? anim, int? z, int? seq, int? color}) =>
    PlanLayer(
      id: id ?? l.id,
      z: z ?? l.z,
      seq: seq ?? l.seq,
      t0: t0 ?? l.t0,
      t1: t1 ?? l.t1,
      kind: l.kind,
      asset: l.asset,
      map: map ?? l.map,
      hold: l.hold,
      color: color ?? l.color,
      base: l.base,
      crop: l.crop,
      xf: xf ?? l.xf,
      fx: fx ?? l.fx,
      anim: anim ?? l.anim,
      cmasks: l.cmasks,
    );
