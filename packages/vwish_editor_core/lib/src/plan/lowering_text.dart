// OWNER: CORE-31
//
// Text items and burned subtitle cues → sprite layers (ARCH §11.7 "Text item / subtitle cue",
// "Text animations", D-05, D-06). **Export plans only**: preview plans carry no text or subtitle
// layers (the Flutter overlay draws them with the same layout engine).
//
// For every request of [collectSpriteRequests] with a file in the export's [SpriteManifest]:
//
// * asset `sp_<key>` of kind `sprite`: `uri`, `sw`, `sh`, `reveal` from the file and `sscale`
//   per plan px (`SpriteFile.sscale / exportScale`, see sprite_requests.dart);
// * text item `<itemId>#v` on its text lane's z: `base` = sprite size / plan sscale, `xf` from the
//   item's transform (centre on the plan canvas, scale, rotation, opacity; flips ignored), `anim`
//   = the item's transform keyframes merged with the text animation sampled at
//   [textAnimationBreakpoints] (opacity and scale multiply, the slide offset adds; exact, since
//   the animation is linear between those breakpoints) and, for a typewriter, `reveal` 0 → n over
//   the in-duration (engines apply floor, ARCH §11.6 "Sprite");
// * cue `<cueId>#c` on its subtitle track's z: `base` from the sprite, centred horizontally and
//   placed vertically by the track's `SubtitlePosition` using the sprite height ([cueCenter]).
//
// A request without a manifest file is skipped here; `compileExport` (CORE-33) refuses to compile
// in that case and returns `ExportBlocked` with the missing keys instead.

import '../eval/geometry.dart';
import '../eval/text_animation_eval.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/subtitle.dart';
import '../model/text_style.dart';
import '../model/track.dart';
import 'compiler.dart';
import 'lowering_transitions.dart';
import 'lowering_visual.dart';
import 'render_plan.dart';
import 'sprite_request.dart';
import 'sprite_requests.dart';

/// Prefix of sprite asset ids (`sp_<key>`).
const String spriteAssetPrefix = 'sp_';

/// The plan asset id of the sprite with content [key].
String spriteAssetId(String key) => '$spriteAssetPrefix$key';

/// Lowers text items and burned cues of an export plan to sprite layers (file header).
final class TextLoweringStage implements PlanLoweringStage {
  /// Creates the stage. [requests] are the export's sprite requests (recomputed with
  /// [collectSpriteRequests] from [burnIn], [maxTextureSize] and [fontsVersion] when null; pass
  /// the list the pre-pass used when it measured with a `TextMetricsProvider`).
  const TextLoweringStage({
    required this.sprites,
    this.requests,
    this.burnIn = const {},
    this.maxTextureSize = defaultMaxTextureSize,
    this.fontsVersion = contentFontsVersion,
  });

  /// Rasterized sprites by key.
  final SpriteManifest sprites;

  /// The export's sprite requests, or null to recompute them.
  final List<SpriteRequest>? requests;

  /// Per-track burn-in overrides.
  final Map<TrackId, bool> burnIn;

  /// `capabilities.maxTextureSize`.
  final int maxTextureSize;

  /// Content fonts version.
  final int fontsVersion;

  @override
  void lower(PlanCompilation c) {
    if (c.target != PlanTarget.export) return;
    final exportScale = c.mapping.scale;
    final list = requests ??
        collectSpriteRequests(c.project, Size2(c.canvas.w.toDouble(), c.canvas.h.toDouble()), exportScale,
            maxTextureSize: maxTextureSize, burnIn: burnIn, fontsVersion: fontsVersion);
    final byItem = {for (final r in list) r.itemId: r};
    for (final lane in c.lanes) {
      if (lane.hidden) continue;
      final track = lane.track;
      if (track.kind == TrackKind.text) {
        for (final item in track.items) {
          if (item is! TextItem) continue;
          final placed = _sprite(c, byItem[item.id]);
          if (placed == null) continue;
          final layer = lowerTextItem(item, z: lane.z, assetId: placed.$1, asset: placed.$2, c: c);
          c.layers[layer.id] = layer;
        }
      } else if (track.kind == TrackKind.subtitle && burnsIn(track, burnIn)) {
        final data = track.subtitle;
        if (data == null) continue;
        for (final item in track.items) {
          if (item is! SubtitleCue) continue;
          final placed = _sprite(c, byItem[item.id]);
          if (placed == null) continue;
          final layer = lowerCue(item, data.position, z: lane.z, assetId: placed.$1, asset: placed.$2, c: c);
          c.layers[layer.id] = layer;
        }
      }
    }
  }

  (String, PlanAsset)? _sprite(PlanCompilation c, SpriteRequest? request) {
    if (request == null) return null;
    final file = sprites[request.key];
    if (file == null || (request.reveal && !file.reveal)) return null;
    final id = spriteAssetId(request.key);
    final asset = c.assets.putIfAbsent(id, () => spriteAssetOf(file, c.mapping.scale));
    return (id, asset);
  }
}

/// The plan asset of a rasterized sprite [file] in a plan whose project canvas is scaled by
/// [exportScale] (sprite_requests.dart units).
PlanAsset spriteAssetOf(SpriteFile file, double exportScale) => PlanAsset(
      kind: PlanAssetKind.sprite,
      uri: file.uri,
      sw: file.sw,
      sh: file.sh,
      sscale: file.sscale / exportScale,
      reveal: file.reveal,
    );

/// The `base` of a sprite [asset] in plan px.
PlanSize spriteBaseOf(PlanAsset asset) => PlanSize(asset.sw! / asset.sscale!, asset.sh! / asset.sscale!);

/// Model transform keyframe channel → (plan channel, conversion: 0 identity, 1 canvas x, 2 canvas y).
const List<(String, String, int)> _textChannels = [
  ('transform.position.x', PlanChannels.xfCx, 1),
  ('transform.position.y', PlanChannels.xfCy, 2),
  ('transform.scale', PlanChannels.xfS, 0),
  ('transform.rotation', PlanChannels.xfR, 0),
  ('transform.opacity', PlanChannels.xfOp, 0),
];

/// The `anim` channels of [item]'s transform keyframes (in-range keys at absolute time,
/// positions converted to plan px), like the clips' (`animChannelsOf`).
Map<String, List<AnimKey>> textKeyframeChannels(TextItem item, PlanCompilation c) {
  final kf = item.keyframes;
  if (kf.isEmpty) return const {};
  final w = c.visual.projectCanvas.width;
  final h = c.visual.projectCanvas.height;
  final m = c.mapping;
  final out = <String, List<AnimKey>>{};
  for (final (model, plan, conv) in _textChannels) {
    final track = kf[model];
    if (track == null) continue;
    final keys = [
      for (final k in track.keys)
        if (k.t >= 0 && k.t < item.duration)
          AnimKey(
            item.start + k.t,
            switch (conv) {
              1 => m.x(w / 2 + k.v * w),
              2 => m.y(h / 2 + k.v * h),
              _ => k.v,
            },
          ),
    ];
    if (keys.isNotEmpty) out[plan] = keys;
  }
  return out;
}

/// The sprite layer of text [item] (file header).
PlanLayer lowerTextItem(TextItem item, {required int z, required String assetId, required PlanAsset asset, required PlanCompilation c}) {
  final xf = planTransformOf(item.transform, c.visual, flips: false);
  final layer = PlanLayer(
    id: PlanIds.visual(item.id),
    z: z,
    t0: item.start,
    t1: item.end,
    kind: PlanLayerKind.sprite,
    asset: assetId,
    base: spriteBaseOf(asset),
    xf: xf,
    anim: textKeyframeChannels(item, c),
  );
  final bps = textAnimationBreakpoints(item);
  if (bps.isEmpty) return layer;
  final canvasSpec = c.project.settings.canvas;
  final states = [for (final t in bps) evaluateTextAnimation(item, t, canvasSpec)];
  final helpers = <String, List<ChannelHelper>>{};
  void help(String channel, ChannelOp op, double Function(TextAnimState s) value, double identity) {
    final keys = [for (var i = 0; i < bps.length; i++) AnimKey(bps[i], value(states[i]))];
    if (keys.every((k) => k.v == identity)) return;
    helpers[channel] = [ChannelHelper(op, keys)];
  }

  final k = c.mapping.scale;
  help(PlanChannels.xfOp, ChannelOp.multiply, (s) => s.opacity, 1);
  help(PlanChannels.xfCx, ChannelOp.add, (s) => s.offset.dx * k, 0);
  help(PlanChannels.xfCy, ChannelOp.add, (s) => s.offset.dy * k, 0);
  help(PlanChannels.xfS, ChannelOp.multiply, (s) => s.scale, 1);
  var out = applyClipEdit(layer, helpers: helpers, canvas: c.canvas, rate: c.project.settings.frameRate);
  if (item.animation.inKind == TextAnimKind.typewriter && asset.reveal == true) {
    final reveal = [
      for (var i = 0; i < bps.length; i++)
        if (states[i].reveal != null) AnimKey(bps[i], states[i].reveal!),
    ];
    // Held values after the in phase add nothing: keep the first key of each constant run that
    // ends the channel.
    while (reveal.length > 1 && reveal[reveal.length - 1].v == reveal[reveal.length - 2].v) {
      reveal.removeLast();
    }
    if (reveal.isNotEmpty) out = _withAnim(out, {...out.anim, PlanChannels.reveal: reveal});
  }
  return out;
}

/// The sprite layer of burned [cue] placed at [position] (file header).
PlanLayer lowerCue(SubtitleCue cue, SubtitlePosition position, {required int z, required String assetId, required PlanAsset asset, required PlanCompilation c}) {
  // Project px size of the sprite: plan size / exportScale.
  final base = spriteBaseOf(asset);
  final k = c.mapping.scale;
  final centre = cueCenter(Size2(base.w / k, base.h / k), position, c.visual.projectCanvas);
  final cx = c.mapping.x(centre.dx);
  final cy = c.mapping.y(centre.dy);
  return PlanLayer(
    id: PlanIds.cue(cue.id),
    z: z,
    t0: cue.start,
    t1: cue.end,
    kind: PlanLayerKind.sprite,
    asset: assetId,
    base: base,
    xf: PlanTransform(cx: cx == c.canvas.w / 2 ? null : cx, cy: cy == c.canvas.h / 2 ? null : cy),
  );
}

PlanLayer _withAnim(PlanLayer l, Map<String, List<AnimKey>> anim) => PlanLayer(
      id: l.id,
      z: l.z,
      seq: l.seq,
      t0: l.t0,
      t1: l.t1,
      kind: l.kind,
      asset: l.asset,
      map: l.map,
      hold: l.hold,
      color: l.color,
      base: l.base,
      crop: l.crop,
      xf: l.xf,
      fx: l.fx,
      anim: anim,
      cmasks: l.cmasks,
    );
