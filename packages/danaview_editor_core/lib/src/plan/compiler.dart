// OWNER: CORE-30
//
// The RenderPlan compiler (ARCH §11, D-01, D-02): `compileRenderPlan(project, target, resolver)`
// lowers an `EditProject` into the flat, fully lowered layer list the native engines render.
//
// Pure and synchronous: no I/O, no clocks, no platform. Above [compileIsolateThreshold] items
// callers run it in `Isolate.run` (the project, the resolver and the options are plain data).
//
// Pipeline:
// 1. canvas: the project canvas and rate (preview), or an export output size and rate
//    ([PlanOutputSpec]) with `gridFps` = the project rate and the project canvas letterboxed
//    inside ([CanvasMapping]);
// 2. visual lowering of every media clip on the visible video and overlay lanes
//    (`lowering_visual.dart`), memoized per clip through [ClipLoweringMemo] when one is given;
// 3. the extra [PlanLoweringStage]s in order (CORE-31: transitions, text and subtitle sprites,
//    audio), which add or rewrite layers, audio segments, assets and requirements;
// 4. finalisation: a content clip on every layer of a letterboxed export, `seq` per media layer
//    from CORE-36's packing ([packVisualLayers], the same function `LayerLimits` uses), sorting
//    (layers by (z, t0, id), audio by (t0, id)), `durUs`, unreferenced assets dropped, and
//    `req` on preview plans.
//
// Plans are exact (no ε bias, D-04); every layer edge and map breakpoint lies on the project grid
// (`canvas.gridFps`, D-35); preview plans contain no text or subtitle layers (D-05); export plans
// never carry proxies (ARCH §9.5). Compiled plans pass [PlanValidator] (CORE-29).

import 'package:meta/meta.dart';

import '../eval/geometry.dart';
import '../eval/visual_packing.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/track.dart';
import 'asset_resolver.dart';
import 'lowering_visual.dart';
import 'plan_validator.dart';
import 'render_plan.dart';
import 'z_order.dart';

/// Item count above which callers compile in `Isolate.run` (ARCH §11.1 rule 3).
const int compileIsolateThreshold = 300;

/// Whether [project] is large enough to compile in an isolate ([compileIsolateThreshold]).
bool shouldCompileInIsolate(EditProject project) => project.index.itemCount > compileIsolateThreshold;

/// The output canvas of an export plan: size in px and frame rate (CORE-33 derives it from the
/// export settings). The project canvas is letterboxed inside; `gridFps` stays the project rate.
@immutable
final class PlanOutputSpec {
  /// Creates an output spec. [width] and [height] must be even and ≥ 16; [fps] a v1 rate.
  const PlanOutputSpec({required this.width, required this.height, required this.fps});

  /// Output width in px.
  final int width;

  /// Output height in px.
  final int height;

  /// Output frame rate (24, 25, 30, 48, 50 or 60).
  final int fps;

  @override
  bool operator ==(Object other) =>
      other is PlanOutputSpec && other.width == width && other.height == height && other.fps == fps;

  @override
  int get hashCode => Object.hash(width, height, fps);

  @override
  String toString() => 'PlanOutputSpec(${width}x$height @ $fps)';
}

/// A lowering pass run after visual lowering (CORE-31 implements transitions, text and subtitle
/// sprites, and audio as stages). Stages must be deterministic and sendable to an isolate.
abstract interface class PlanLoweringStage {
  /// Adds or rewrites layers, audio segments, assets and requirements of [compilation]. Layers
  /// need no `seq` and no particular order; the compiler packs and sorts afterwards.
  void lower(PlanCompilation compilation);
}

/// Memo of visual clip lowering (CORE-32's `PlanMemo` implements it): keyed by the clip object's
/// identity plus a [ClipLoweringKey], so a one-item edit recompiles that item only.
abstract interface class ClipLoweringMemo {
  /// The lowering stored for this very [clip] object under a key equal to [key], or null.
  LoweredClip? lookup(MediaClip clip, ClipLoweringKey key);

  /// Remembers [lowered] for [clip] under [key]. The compiler calls this after packing with the
  /// layers a stage left untouched carrying their final `seq`, so an unchanged clip yields
  /// `identical` layers on the next compile (identity-first diffs, ARCH §11.8).
  void store(MediaClip clip, ClipLoweringKey key, LoweredClip lowered);
}

/// Options of one compile.
@immutable
final class CompileOptions {
  /// Creates options.
  const CompileOptions({this.rev, this.output, this.holdFrame = true, this.stages = const [], this.memo});

  /// The plan's `rev`; defaults to the project's session-monotonic timeline revision.
  final int? rev;

  /// Export output canvas, or null for the project canvas and rate.
  final PlanOutputSpec? output;

  /// `capabilities.holdFrame`: pending freeze stills lower to `hold` layers (true) or neutral
  /// solids (false).
  final bool holdFrame;

  /// Extra lowering passes, in order (CORE-31).
  final List<PlanLoweringStage> stages;

  /// Memo of visual clip lowering (CORE-32), or null.
  final ClipLoweringMemo? memo;

  /// A copy with the given fields replaced.
  CompileOptions copyWith({
    int? rev,
    PlanOutputSpec? output,
    bool? holdFrame,
    List<PlanLoweringStage>? stages,
    ClipLoweringMemo? memo,
  }) =>
      CompileOptions(
        rev: rev ?? this.rev,
        output: output ?? this.output,
        holdFrame: holdFrame ?? this.holdFrame,
        stages: stages ?? this.stages,
        memo: memo ?? this.memo,
      );
}

/// Accumulates `req` entries (sorted, de-duplicated on [build]).
final class PlanRequirementsBuilder {
  final Set<String> _offline = {};
  final Set<String> _pendingReverse = {};
  final Set<String> _pendingStill = {};

  /// Lists [media] as offline.
  void offline(MediaId media) => _offline.add(media);

  /// Lists [item] as waiting for its reversed rendition.
  void pendingReverse(ItemId item) => _pendingReverse.add(item);

  /// Lists [still] as waiting for its freeze-frame still.
  void pendingStill(MediaId still) => _pendingStill.add(still);

  /// Whether nothing is listed.
  bool get isEmpty => _offline.isEmpty && _pendingReverse.isEmpty && _pendingStill.isEmpty;

  /// The requirements, each list sorted.
  PlanRequirements build() => PlanRequirements(
        offline: _offline.toList()..sort(),
        pendingReverse: _pendingReverse.toList()..sort(),
        pendingStill: _pendingStill.toList()..sort(),
      );
}

/// The mutable state of one compile, handed to every [PlanLoweringStage].
final class PlanCompilation {
  PlanCompilation._({
    required this.project,
    required this.target,
    required this.options,
    required this.canvas,
    required this.mapping,
    required this.lanes,
    required this.visual,
  });

  /// The project being compiled.
  final EditProject project;

  /// Preview or export.
  final PlanTarget target;

  /// The options of this compile.
  final CompileOptions options;

  /// The plan canvas.
  final PlanCanvas canvas;

  /// Project canvas → plan canvas.
  final CanvasMapping mapping;

  /// Every visual lane bottom → top with its z (hidden lanes included; [PlanLane.hidden]).
  final List<PlanLane> lanes;

  /// The visual lowering context (asset factory, renditions, rate).
  final VisualLoweringContext visual;

  /// Plan asset entries by id. Stages register what their layers and segments reference (entries
  /// nothing references are dropped at the end).
  final Map<String, PlanAsset> assets = {};

  /// Layers by id (any order; `seq` is assigned at the end).
  final Map<String, PlanLayer> layers = {};

  /// Audio segments by id.
  final Map<String, AudioSeg> audio = {};

  /// The visual lowering of every compiled clip by item id (CORE-31 reads the clip layers'
  /// `playbackAsset`/`playbackMap` for transitions and audio).
  final Map<ItemId, LoweredClip> clips = {};

  /// The lane of every compiled clip by item id.
  final Map<ItemId, PlanLane> laneOfClip = {};

  /// Requirements (`req` of preview plans; the export blockers of CORE-33).
  final PlanRequirementsBuilder requirements = PlanRequirementsBuilder();

  /// The asset entry factory of this compile.
  PlanAssetFactory get assetFactory => visual.assets;

  void _addClip(PlanLane lane, MediaClip clip, LoweredClip lowered) {
    clips[clip.id] = lowered;
    laneOfClip[clip.id] = lane;
    for (final l in lowered.layers) {
      layers[l.id] = l;
    }
    assets.addAll(lowered.assets);
    for (final m in lowered.offline) {
      requirements.offline(m);
    }
    for (final i in lowered.pendingReverse) {
      requirements.pendingReverse(i);
    }
    for (final s in lowered.pendingStill) {
      requirements.pendingStill(s);
    }
  }
}

/// The result of [compilePlan].
@immutable
final class CompiledPlan {
  /// Creates a result.
  const CompiledPlan({required this.plan, required this.requirements, required this.packing});

  /// The plan (`req` set on preview plans with requirements).
  final RenderPlan plan;

  /// Offline media, pending reverses and pending stills, for both targets: an export plan with
  /// any requirement must not be rendered (CORE-33 returns `ExportBlocked(requirements)`).
  final PlanRequirements requirements;

  /// The packing of the plan's media layers (slot count = visual sequences, peak decoders).
  final PackResult packing;

  /// Whether nothing is offline or pending.
  bool get isComplete => requirements.isEmpty;

  /// [PlanValidator] violations of [plan] (empty for every compiled plan).
  List<PlanViolation> violations() => PlanValidator.validate(plan);
}

/// Compiles [project] for [target] (ARCH §11; file header). [resolver] supplies files, proxies
/// and LUTs. Pure and deterministic. Throws [ArgumentError] for an invalid [CompileOptions.output].
CompiledPlan compilePlan(
  EditProject project,
  PlanTarget target,
  PlanAssetResolver resolver, {
  CompileOptions options = const CompileOptions(),
}) {
  final settings = project.settings;
  final rate = settings.frameRate;
  final projectCanvas = settings.canvas.sizePx;
  final output = options.output;
  if (output != null) _checkOutput(output);
  final mapping = output == null
      ? CanvasMapping.identity(projectCanvas)
      : CanvasMapping.fit(projectCanvas, Size2(output.width.toDouble(), output.height.toDouble()));
  final background = settings.background;
  final canvas = PlanCanvas(
    w: output?.width ?? settings.canvas.widthPx,
    h: output?.height ?? settings.canvas.heightPx,
    fps: output?.fps ?? rate.num,
    gridFps: rate.num,
    bg: (background is SolidBackground ? background.color : 0xFF000000) | 0xFF000000,
  );
  final visual = VisualLoweringContext(
    settings: settings,
    pool: project.pool,
    assets: PlanAssetFactory(pool: project.pool, resolver: resolver, target: target),
    target: target,
    mapping: mapping,
    holdFrame: options.holdFrame,
  );
  final c = PlanCompilation._(
    project: project,
    target: target,
    options: options,
    canvas: canvas,
    mapping: mapping,
    lanes: planLanesOf(project.tracks),
    visual: visual,
  );

  // 2. Visual lowering.
  final memo = options.memo;
  final keys = <ItemId, (MediaClip, ClipLoweringKey)>{};
  final backdropBlur = background is BlurOfMainBackground ? background.radius * mapping.blurScale : null;
  for (final lane in c.lanes) {
    if (lane.hidden) continue;
    final kind = lane.track.kind;
    if (kind != TrackKind.video && kind != TrackKind.overlay) continue;
    final blur = lane.isMain ? backdropBlur : null;
    for (final item in lane.track.items) {
      if (item is! MediaClip) continue;
      final res = resolveVisualClip(item, visual);
      if (res == null) continue;
      final key = ClipLoweringKey(
        resolution: res,
        z: lane.z,
        backdropBlur: blur,
        target: target,
        holdFrame: options.holdFrame,
        canvas: settings.canvas,
        rate: rate,
        mapping: mapping,
      );
      final lowered = memo?.lookup(item, key) ?? lowerVisualClip(item, res, z: lane.z, backdropBlur: blur, ctx: visual);
      if (memo != null) keys[item.id] = (item, key);
      c._addClip(lane, item, lowered);
    }
  }
  // Snapshot of the visual layers before the stages run (a stage may replace them).
  final lowered = memo == null ? null : {for (final e in c.clips.entries) e.key: e.value};

  // 3. Extra stages.
  for (final stage in options.stages) {
    stage.lower(c);
  }

  // 4. Finalisation.
  final clip = mapping.contentClip;
  var layers = [for (final l in c.layers.values) clip == null ? l : _withContentClip(l, clip)];
  final media = [
    for (final l in layers)
      if (l.kind == PlanLayerKind.media) PackInput(l.id, l.z, l.t0, l.t1),
  ];
  final packing = packVisualLayers(media);
  layers = [
    for (final l in layers) l.kind == PlanLayerKind.media ? withSeq(l, packing.seqOf(l.id)) : withSeq(l, null),
  ]..sort(_compareLayers);
  final audio = c.audio.values.toList()..sort(_compareAudio);

  var dur = project.duration;
  for (final l in layers) {
    if (l.t1 > dur) dur = l.t1;
  }
  for (final a in audio) {
    if (a.t1 > dur) dur = a.t1;
  }

  final used = <String>{};
  for (final l in layers) {
    if (l.asset != null) used.add(l.asset!);
    final lut = l.fx.lut;
    if (lut != null) used.add(lut.asset);
  }
  for (final a in audio) {
    used.add(a.asset);
  }
  final assets = {
    for (final e in c.assets.entries)
      if (used.contains(e.key)) e.key: e.value,
  };

  final requirements = c.requirements.build();
  final plan = RenderPlan(
    rev: options.rev ?? project.revision,
    target: target,
    canvas: canvas,
    durUs: dur,
    assets: assets,
    layers: layers,
    audio: audio,
    req: target == PlanTarget.preview && !requirements.isEmpty ? requirements : null,
  );

  if (memo != null && lowered != null) {
    final byId = {for (final l in layers) l.id: l};
    for (final e in keys.entries) {
      final before = lowered[e.key]!;
      final current = c.layers;
      final stored = [
        for (final l in before.layers)
          // A layer no stage replaced is stored with its final seq (identity on the next compile).
          identical(current[l.id], l) && clip == null ? byId[l.id] ?? l : l,
      ];
      memo.store(e.value.$1, e.value.$2, before.withLayers(stored));
    }
  }
  return CompiledPlan(plan: plan, requirements: requirements, packing: packing);
}

/// Compiles [project] for [target] and returns the plan only ([compilePlan]).
RenderPlan compileRenderPlan(
  EditProject project,
  PlanTarget target,
  PlanAssetResolver resolver, {
  CompileOptions options = const CompileOptions(),
}) =>
    compilePlan(project, target, resolver, options: options).plan;

/// [layer] with `seq` set to [seq]; the same instance when it already has it.
PlanLayer withSeq(PlanLayer layer, int? seq) {
  if (layer.seq == seq) return layer;
  return PlanLayer(
    id: layer.id,
    z: layer.z,
    seq: seq,
    t0: layer.t0,
    t1: layer.t1,
    kind: layer.kind,
    asset: layer.asset,
    map: layer.map,
    hold: layer.hold,
    color: layer.color,
    base: layer.base,
    crop: layer.crop,
    xf: layer.xf,
    fx: layer.fx,
    anim: layer.anim,
    cmasks: layer.cmasks,
  );
}

PlanLayer _withContentClip(PlanLayer l, CanvasMask clip) {
  if (l.cmasks.contains(clip)) return l;
  return PlanLayer(
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
    anim: l.anim,
    cmasks: [...l.cmasks, clip],
  );
}

int _compareLayers(PlanLayer a, PlanLayer b) {
  if (a.z != b.z) return a.z.compareTo(b.z);
  if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
  return a.id.compareTo(b.id);
}

int _compareAudio(AudioSeg a, AudioSeg b) {
  if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
  return a.id.compareTo(b.id);
}

void _checkOutput(PlanOutputSpec o) {
  if (o.width < 16 || o.height < 16 || o.width.isOdd || o.height.isOdd) {
    throw ArgumentError.value(o, 'output', 'width and height must be even and ≥ 16');
  }
  if (!const {24, 25, 30, 48, 50, 60}.contains(o.fps)) {
    throw ArgumentError.value(o, 'output', 'fps must be 24, 25, 30, 48, 50 or 60');
  }
}
