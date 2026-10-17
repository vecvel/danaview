// OWNER: CORE-30
//
// Visual lowering of media clips on video and overlay lanes (ARCH §11.7, every row except
// transitions, text and audio, which CORE-31 lowers as compile stages):
//
// | Domain concept               | Lowered to                                                       |
// |------------------------------|------------------------------------------------------------------|
// | Fit + crop                   | `base` from geometry's [baseSize] (the same code as [boxAt])     |
// | Transform                    | `xf` (centre in canvas px via [positionToCanvas], scale, …)      |
// | Effects / look / chroma/mask | `fx.adj`, `fx.detail`, `fx.lut` (+ a `lut` asset), `fx.chroma`, `fx.mask` |
// | Item keyframes               | `anim` channels at absolute timeline µs (in-range keys only)     |
// | Constant speed / ramp        | `map` from `ClipTimeMap.lower()` (≤ 250 µs, grid breakpoints)    |
// | Reversed clip                | the ready rendition asset with an increasing map (`r = R.end − s`) |
// | Pending reverse              | forward media layer + `req.pendingReverse`                       |
// | Background `BlurOfMain(r)`   | `<itemId>#bd` per main-lane clip: same map, fill base, blur r, z − 5 |
// | Missing media                | dark-grey `solid` with the item's box + `req.offline`            |
// | Pending freeze still         | `hold` media layer over the source (or a neutral solid when the engine cannot hold frames) + `req.pendingStill` |
//
// Plans are exact (no ε bias, D-04): maps carry unbiased source µs and engines apply the
// source-frame rule. Every layer edge is an item edge (on the project grid) and every map
// breakpoint a frame start of the project grid (ARCH §11.3, CORE-06).
//
// Lowering is split in two steps so CORE-32's memo can skip the expensive one: [resolveVisualClip]
// decides what the clip shows (cheap pool and resolver lookups) and [lowerVisualClip] builds the
// layers (time-map lowering, base sizes, animation channels). A [ClipLoweringKey] of the
// resolution plus the lane and compile context identifies a lowering result.

import 'package:meta/meta.dart';

import '../eval/clip_time_map.dart';
import '../eval/geometry.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/keyframes/keyframe_data.dart';
import '../model/keyframes/property_keys.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/settings.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import 'asset_resolver.dart';
import 'render_plan.dart';

/// Colour of the solid that stands in for missing or offline media (ARCH §11.7): dark grey.
const int offlinePlaceholderColor = 0xFF303030;

/// Colour of the neutral solid shown for a pending freeze still when the engine cannot hold
/// frames (`capabilities.holdFrame == false`, ARCH §11.7).
const int pendingStillPlaceholderColor = 0xFF303030;

// ---------------------------------------------------------------------------------------------
// Canvas mapping.
// ---------------------------------------------------------------------------------------------

/// Maps project-canvas px onto the plan canvas: the identity for preview plans and same-size
/// exports, otherwise a centred uniform fit of the project canvas inside the output canvas
/// (letterbox; never a silent crop, CORE-33).
@immutable
final class CanvasMapping {
  const CanvasMapping._(this.project, this.output, this.scale, this.offsetX, this.offsetY);

  /// The identity mapping of a canvas of [canvas] px.
  factory CanvasMapping.identity(Size2 canvas) => CanvasMapping._(canvas, canvas, 1, 0, 0);

  /// The centred uniform fit of a [project] canvas into an [output] canvas (both in px).
  factory CanvasMapping.fit(Size2 project, Size2 output) {
    if (!project.isPositive || !output.isPositive) {
      throw ArgumentError('canvases must have a positive area ($project → $output)');
    }
    if (project == output) return CanvasMapping.identity(project);
    final sx = output.width / project.width;
    final sy = output.height / project.height;
    final k = sx < sy ? sx : sy;
    return CanvasMapping._(
      project,
      output,
      k,
      (output.width - k * project.width) / 2,
      (output.height - k * project.height) / 2,
    );
  }

  /// Project canvas size in px.
  final Size2 project;

  /// Plan (output) canvas size in px.
  final Size2 output;

  /// Uniform scale from project px to plan px.
  final double scale;

  /// Horizontal offset of the project canvas inside the plan canvas.
  final double offsetX;

  /// Vertical offset of the project canvas inside the plan canvas.
  final double offsetY;

  /// Whether project px are plan px.
  bool get isIdentity => scale == 1 && offsetX == 0 && offsetY == 0;

  /// The plan x of project x [px].
  double x(double px) => isIdentity ? px : offsetX + scale * px;

  /// The plan y of project y [py].
  double y(double py) => isIdentity ? py : offsetY + scale * py;

  /// A project-px length in plan px.
  double length(double l) => isIdentity ? l : scale * l;

  /// A project-px size in plan px.
  Size2 size(Size2 s) => isIdentity ? s : Size2(s.width * scale, s.height * scale);

  /// The project canvas inside the plan canvas.
  Rect2 get contentRect => Rect2(offsetX, offsetY, offsetX + scale * project.width, offsetY + scale * project.height);

  /// Whether the project canvas leaves bars wider than half a pixel on the plan canvas.
  bool get letterboxed => offsetX > 0.5 || offsetY > 0.5;

  /// Factor applied to `detail.blur` so the blur radius, defined on `min(W, H)` of the plan canvas
  /// (ARCH §11.6), keeps its size relative to the project canvas: `scale·min(pw, ph) / min(W, H)`
  /// (≤ 1, exactly 1 for the identity).
  double get blurScale => isIdentity ? 1 : scale * project.shortSide / output.shortSide;

  /// When [letterboxed]: a canvas mask restricting every layer to the project canvas, so nothing
  /// that the project canvas clips spills into the bars. Null otherwise.
  CanvasMask? get contentClip {
    if (!letterboxed) return null;
    final r = contentRect;
    return CanvasMask(cx: r.center.dx, cy: r.center.dy, w: r.width, h: r.height);
  }

  @override
  bool operator ==(Object other) =>
      other is CanvasMapping &&
      other.project == project &&
      other.output == output &&
      other.scale == scale &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(project, output, scale, offsetX, offsetY);

  @override
  String toString() => 'CanvasMapping($project → $output, scale $scale, offset ($offsetX, $offsetY))';
}

// ---------------------------------------------------------------------------------------------
// Reversed renditions and clip playback.
// ---------------------------------------------------------------------------------------------

/// Reversed renditions of a pool by source media (domain.md §6.4): built once per compile.
final class ReversedRenditionIndex {
  /// Indexes the assets of [pool] whose `derived` is a [ReversedSpec].
  ReversedRenditionIndex(this.pool) {
    for (final a in pool.assets.values) {
      final d = a.derived;
      if (d is ReversedSpec) (_bySource[d.media] ??= []).add(a);
    }
    for (final list in _bySource.values) {
      list.sort((a, b) {
        final ra = (a.derived! as ReversedSpec).range;
        final rb = (b.derived! as ReversedSpec).range;
        final c = ra.duration.compareTo(rb.duration);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    }
  }

  /// The indexed pool.
  final MediaPool pool;

  final Map<MediaId, List<MediaAsset>> _bySource = {};

  /// The rendition to play for a reversed clip of [media] over [sourceRange]: a **ready** asset
  /// with `derived = reversed(media, R)` where R covers [sourceRange], made from the same content
  /// (its `sourceQuickHash` equals the source's fingerprint while the source is in the pool), and
  /// [available] to the engine; the shortest such range wins (ties by id). Null when none.
  MediaAsset? bestFor(MediaId media, TimeRange sourceRange, {required bool Function(MediaId id) available}) {
    final list = _bySource[media];
    if (list == null) return null;
    final source = pool[media];
    for (final a in list) {
      if (a.status is! ReadyStatus) continue;
      final spec = a.derived! as ReversedSpec;
      if (spec.range.start > sourceRange.start || spec.range.end < sourceRange.end) continue;
      if (source != null && spec.sourceQuickHash != source.fingerprint.quickHash) continue;
      if (!available(a.id)) continue;
      return a;
    }
    return null;
  }
}

/// What a time-based clip plays (ARCH §11.5, domain.md §6.4): the file the [map] indexes and the
/// increasing, exact map itself. A clip's video layer and its audio segment (CORE-31) are lowered
/// from the same playback, which is the A/V sync contract.
@immutable
final class ClipPlayback {
  /// Creates a playback.
  ClipPlayback({required this.media, required List<MapSegment> map, this.rendition, this.pendingReverse = false})
      : map = List.unmodifiable(map);

  /// The pool asset whose time the map indexes: the original, or the reversed rendition.
  final MediaId media;

  /// Contiguous segments covering the clip, breakpoints on the project grid, rates in [0.1, 10].
  final List<MapSegment> map;

  /// The ready reversed rendition being played, when the clip is reversed and has one.
  final MediaAsset? rendition;

  /// Whether a reversed clip plays forward because its rendition is not ready (preview only;
  /// export is blocked).
  final bool pendingReverse;
}

/// The map of [clip] into the playback asset (ARCH §11.5):
///
/// * forward clips: `ClipTimeMap.lower()` in source time;
/// * reversed clips with a [rendition] (`reversed(media, R)`): the increasing rendition time
///   `r = R.end − s`, i.e. `lower()` (which starts at 0 for `s = sourceOut`) shifted by
///   `R.end − sourceOut`;
/// * reversed clips without one ([forwardFallback]): the forward map of the same source range.
///
/// Throws [ArgumentError] when the clip's time map is invalid (decoded projects are validated and
/// repaired before they are compiled).
List<MapSegment> clipMap(MediaClip clip, FrameRate rate, {MediaAsset? rendition, bool forwardFallback = false}) {
  if (!clip.reversed || forwardFallback) {
    return ClipTimeMap(
      start: clip.start,
      duration: clip.duration,
      sourceIn: clip.sourceIn,
      speed: clip.speed,
      rate: rate,
    ).lower();
  }
  final tm = ClipTimeMap.forClip(clip, rate);
  final lowered = tm.lower();
  if (rendition == null) return lowered;
  final spec = rendition.derived! as ReversedSpec;
  final offset = spec.range.end - tm.sourceOut;
  if (offset == 0) return lowered;
  return [for (final s in lowered) MapSegment(s.t0, s.t1, s.s0 + offset, s.s1 + offset)];
}

/// The playback of the time-based [clip] (video, or an audio stream for CORE-31): the original,
/// or for a reversed clip its best ready rendition ([ReversedRenditionIndex.bestFor]) and
/// otherwise the original played forward with [ClipPlayback.pendingReverse] set.
ClipPlayback clipPlayback(
  MediaClip clip,
  FrameRate rate,
  ReversedRenditionIndex renditions, {
  required bool Function(MediaId id) available,
}) {
  if (!clip.reversed) return ClipPlayback(media: clip.media, map: clipMap(clip, rate));
  final r = renditions.bestFor(clip.media, clip.sourceRange, available: available);
  if (r != null) return ClipPlayback(media: r.id, map: clipMap(clip, rate, rendition: r), rendition: r);
  return ClipPlayback(media: clip.media, map: clipMap(clip, rate, forwardFallback: true), pendingReverse: true);
}

/// [map] (contiguous, increasing) extended so it covers `[t0, t1)`: the first segment reaches back
/// to [t0] and the last forward to [t1] at their edge rates (source µs rounded; never below 0).
/// Used for transition handles (CORE-31: "using handle source at the edge speed").
List<MapSegment> extendMap(List<MapSegment> map, {TimeUs? t0, TimeUs? t1}) {
  if (map.isEmpty) throw ArgumentError.value(map, 'map', 'must not be empty');
  final out = [...map];
  if (t0 != null && t0 < out.first.t0) {
    final f = out.first;
    var s0 = f.s0 - ((f.t0 - t0) * f.rate).round();
    if (s0 < 0) s0 = 0;
    out[0] = MapSegment(t0, f.t1, s0 > f.s1 ? f.s1 : s0, f.s1);
  }
  if (t1 != null && t1 > out.last.t1) {
    final l = out.last;
    final s1 = l.s1 + ((t1 - l.t1) * l.rate).round();
    out[out.length - 1] = MapSegment(l.t0, t1, l.s0, s1 < l.s0 ? l.s0 : s1);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Resolution: what a clip shows.
// ---------------------------------------------------------------------------------------------

/// The compile-wide inputs of visual lowering.
final class VisualLoweringContext {
  /// Creates a context; [renditions] defaults to an index of [pool].
  VisualLoweringContext({
    required this.settings,
    required this.pool,
    required this.assets,
    required this.target,
    required this.mapping,
    this.holdFrame = true,
    ReversedRenditionIndex? renditions,
  })  : renditions = renditions ?? ReversedRenditionIndex(pool),
        projectCanvas = settings.canvas.sizePx;

  /// Project settings (canvas, frame rate, background).
  final ProjectSettings settings;

  /// Media pool.
  final MediaPool pool;

  /// Plan asset entries.
  final PlanAssetFactory assets;

  /// Preview or export.
  final PlanTarget target;

  /// Project canvas → plan canvas.
  final CanvasMapping mapping;

  /// Whether the engine can hold frames (`capabilities.holdFrame`).
  final bool holdFrame;

  /// Reversed renditions by source.
  final ReversedRenditionIndex renditions;

  /// The project canvas in px.
  final Size2 projectCanvas;

  /// The project frame rate (the plan's `gridFps`).
  FrameRate get rate => settings.frameRate;
}

/// What a visual clip shows, decided by [resolveVisualClip].
@immutable
sealed class VisualSource {
  const VisualSource(this.picture);

  /// Display size of the picture (rotation applied), or null when unknown.
  final Size2? picture;
}

/// A decoder-backed `media` layer over [assetId].
final class MediaVisualSource extends VisualSource {
  /// Creates a media source.
  const MediaVisualSource(this.assetId, this.entry, super.picture, {this.rendition, this.pendingReverse = false});

  /// Plan asset id (the original or the reversed rendition).
  final String assetId;

  /// Its plan asset entry.
  final PlanAsset entry;

  /// The ready reversed rendition being played, if any.
  final MediaAsset? rendition;

  /// Whether a reversed clip plays forward until its rendition is ready.
  final bool pendingReverse;

  @override
  bool operator ==(Object other) =>
      other is MediaVisualSource &&
      other.assetId == assetId &&
      other.entry == entry &&
      other.picture == picture &&
      _same(other.rendition, rendition) &&
      other.pendingReverse == pendingReverse;

  @override
  int get hashCode => Object.hash(assetId, entry, picture, rendition?.id, pendingReverse);
}

/// An `image` layer over [assetId] (a photo or a ready freeze still).
final class ImageVisualSource extends VisualSource {
  /// Creates an image source.
  const ImageVisualSource(this.assetId, this.entry, super.picture);

  /// Plan asset id.
  final String assetId;

  /// Its plan asset entry.
  final PlanAsset entry;

  @override
  bool operator ==(Object other) =>
      other is ImageVisualSource && other.assetId == assetId && other.entry == entry && other.picture == picture;

  @override
  int get hashCode => Object.hash(assetId, entry, picture);
}

/// A `hold: true` media layer over the source video of a pending freeze still: shows the frame at
/// [freezeTime] for the whole range.
final class HoldVisualSource extends VisualSource {
  /// Creates a hold source.
  const HoldVisualSource(this.assetId, this.entry, super.picture, {required this.freezeTime, required this.still});

  /// Plan asset id of the source video.
  final String assetId;

  /// Its plan asset entry.
  final PlanAsset entry;

  /// Source time of the frozen frame.
  final TimeUs freezeTime;

  /// The pending still asset (listed in `req.pendingStill`).
  final MediaId still;

  @override
  bool operator ==(Object other) =>
      other is HoldVisualSource &&
      other.assetId == assetId &&
      other.entry == entry &&
      other.picture == picture &&
      other.freezeTime == freezeTime &&
      other.still == still;

  @override
  int get hashCode => Object.hash(assetId, entry, picture, freezeTime, still);
}

/// A `solid` placeholder of [color] with the item's box (or the canvas when the picture size is
/// unknown).
final class SolidVisualSource extends VisualSource {
  /// Creates a solid source.
  const SolidVisualSource(this.color, super.picture, {this.offline, this.pendingStill});

  /// ARGB colour.
  final int color;

  /// Media listed in `req.offline`, if any.
  final MediaId? offline;

  /// Still listed in `req.pendingStill`, if any.
  final MediaId? pendingStill;

  @override
  bool operator ==(Object other) =>
      other is SolidVisualSource &&
      other.color == color &&
      other.picture == picture &&
      other.offline == offline &&
      other.pendingStill == pendingStill;

  @override
  int get hashCode => Object.hash(color, picture, offline, pendingStill);
}

/// The resolution of one visual clip: its source and its look's LUT asset.
@immutable
final class ClipResolution {
  /// Creates a resolution.
  const ClipResolution(this.source, {this.lutAssetId, this.lutEntry, this.lutOffline});

  /// What the clip shows.
  final VisualSource source;

  /// Plan asset id of the look's `.vlut` (bundled look or imported LUT), when it resolved.
  final String? lutAssetId;

  /// The `.vlut` asset entry.
  final PlanAsset? lutEntry;

  /// An imported LUT that is unavailable (listed in `req.offline`; the look is dropped).
  final MediaId? lutOffline;

  @override
  bool operator ==(Object other) =>
      other is ClipResolution &&
      other.source == source &&
      other.lutAssetId == lutAssetId &&
      other.lutEntry == lutEntry &&
      other.lutOffline == lutOffline;

  @override
  int get hashCode => Object.hash(source, lutAssetId, lutEntry, lutOffline);
}

bool _same(Object? a, Object? b) => identical(a, b) || a == b;

/// The display size of [asset]'s picture: its own probe's, or for a derived still or rendition
/// without one, its source's (geometry's `itemBoxAt` uses the same rule).
Size2? pictureSizeOf(MediaAsset asset, MediaPool pool) {
  final own = sourceDisplaySize(asset.probe);
  if (own != null) return own;
  final source = switch (asset.derived) {
    StillSpec(:final media) => pool[media],
    ReversedSpec(:final media) => pool[media],
    null => null,
  };
  return source == null ? null : sourceDisplaySize(source.probe);
}

/// Decides what the visual [clip] (on a video or overlay lane) shows, or null when its asset is
/// not visual (audio, recording, LUT):
///
/// * not in the pool, or its file unavailable → dark-grey solid + offline;
/// * video → media layer; reversed → the best ready rendition, else forward + pending reverse;
/// * image, ready still → image layer;
/// * pending still → hold layer over the source video when [VisualLoweringContext.holdFrame] and
///   the source is available, else a neutral solid; both list the still as pending;
/// * the look's LUT: a bundled look resolves through the resolver (unknown presets are dropped);
///   an unavailable imported LUT is dropped and listed offline.
ClipResolution? resolveVisualClip(MediaClip clip, VisualLoweringContext ctx) {
  final pool = ctx.pool;
  final asset = pool[clip.media];
  if (asset == null) return ClipResolution(SolidVisualSource(offlinePlaceholderColor, null, offline: clip.media));
  final picture = pictureSizeOf(asset, pool);
  final VisualSource source;
  switch (asset.kind) {
    case MediaKind.audio:
    case MediaKind.recording:
    case MediaKind.lut:
      return null;
    case MediaKind.video:
      final rendition = clip.reversed
          ? ctx.renditions.bestFor(clip.media, clip.sourceRange, available: ctx.assets.isAvailable)
          : null;
      if (rendition != null) {
        final id = PlanAssetIds.media(rendition.id);
        source = MediaVisualSource(id, ctx.assets.media(rendition.id, PlanAssetKind.video)!, picture, rendition: rendition);
      } else {
        final entry = ctx.assets.media(clip.media, PlanAssetKind.video);
        source = entry == null
            ? SolidVisualSource(offlinePlaceholderColor, picture, offline: clip.media)
            : MediaVisualSource(PlanAssetIds.media(clip.media), entry, picture, pendingReverse: clip.reversed);
      }
    case MediaKind.image:
      source = _image(clip.media, picture, ctx);
    case MediaKind.still:
      final spec = asset.derived;
      if (asset.status is ReadyStatus) {
        source = _image(clip.media, picture, ctx);
      } else if (spec is StillSpec) {
        final from = pool[spec.media];
        final entry = ctx.holdFrame && from != null && from.kind == MediaKind.video
            ? ctx.assets.media(spec.media, PlanAssetKind.video)
            : null;
        if (entry != null) {
          source = HoldVisualSource(PlanAssetIds.media(spec.media), entry, picture, freezeTime: spec.sourceTime, still: clip.media);
        } else {
          final sourceOffline = ctx.holdFrame && (from == null || (from.kind == MediaKind.video && !ctx.assets.isAvailable(spec.media)));
          source = SolidVisualSource(pendingStillPlaceholderColor, picture,
              pendingStill: clip.media, offline: sourceOffline ? spec.media : null);
        }
      } else {
        source = SolidVisualSource(offlinePlaceholderColor, picture, offline: clip.media);
      }
  }
  if (source is SolidVisualSource) return ClipResolution(source);
  final look = clip.visual?.look;
  switch (look) {
    case null:
      return ClipResolution(source);
    case BuiltinLook(:final presetId):
      final entry = ctx.assets.builtinLook(presetId);
      return entry == null
          ? ClipResolution(source)
          : ClipResolution(source, lutAssetId: PlanAssetIds.builtinLook(presetId), lutEntry: entry);
    case ImportedLut(:final lut):
      final entry = ctx.assets.importedLut(lut);
      return entry == null
          ? ClipResolution(source, lutOffline: lut)
          : ClipResolution(source, lutAssetId: PlanAssetIds.media(lut), lutEntry: entry);
  }
}

VisualSource _image(MediaId id, Size2? picture, VisualLoweringContext ctx) {
  final entry = ctx.assets.media(id, PlanAssetKind.image);
  return entry == null
      ? SolidVisualSource(offlinePlaceholderColor, picture, offline: id)
      : ImageVisualSource(PlanAssetIds.media(id), entry, picture);
}

// ---------------------------------------------------------------------------------------------
// Lowering.
// ---------------------------------------------------------------------------------------------

/// Identifies one lowering result: equal keys of the same clip object lower to equal layers
/// (CORE-32's memo stores [LoweredClip]s under this key).
@immutable
final class ClipLoweringKey {
  /// Creates a key.
  const ClipLoweringKey({
    required this.resolution,
    required this.z,
    required this.backdropBlur,
    required this.target,
    required this.holdFrame,
    required this.canvas,
    required this.rate,
    required this.mapping,
  });

  /// What the clip shows.
  final ClipResolution resolution;

  /// Lane z of the clip layer.
  final int z;

  /// Backdrop blur (already scaled), or null without a backdrop.
  final double? backdropBlur;

  /// Plan target.
  final PlanTarget target;

  /// Engine can hold frames.
  final bool holdFrame;

  /// Project canvas.
  final CanvasSpec canvas;

  /// Project frame rate.
  final FrameRate rate;

  /// Canvas mapping.
  final CanvasMapping mapping;

  @override
  bool operator ==(Object other) =>
      other is ClipLoweringKey &&
      other.z == z &&
      other.backdropBlur == backdropBlur &&
      other.target == target &&
      other.holdFrame == holdFrame &&
      other.canvas == canvas &&
      other.rate == rate &&
      other.mapping == mapping &&
      other.resolution == resolution;

  @override
  int get hashCode => Object.hash(resolution, z, backdropBlur, target, holdFrame, canvas, rate, mapping);
}

/// The visual lowering of one clip: its layers (`#bd` backdrop first, then `#v`; `seq` assigned
/// by the compiler after packing), the asset entries they reference, and its requirements.
@immutable
final class LoweredClip {
  /// Creates a lowered clip.
  LoweredClip({
    required this.item,
    required List<PlanLayer> layers,
    Map<String, PlanAsset> assets = const {},
    List<MediaId> offline = const [],
    List<ItemId> pendingReverse = const [],
    List<MediaId> pendingStill = const [],
    this.playbackAsset,
    List<MapSegment> playbackMap = const [],
  })  : layers = List.unmodifiable(layers),
        assets = Map.unmodifiable(assets),
        offline = List.unmodifiable(offline),
        pendingReverse = List.unmodifiable(pendingReverse),
        pendingStill = List.unmodifiable(pendingStill),
        playbackMap = List.unmodifiable(playbackMap);

  /// The clip.
  final ItemId item;

  /// Its layers, backdrop first.
  final List<PlanLayer> layers;

  /// Asset entries referenced by [layers], by id.
  final Map<String, PlanAsset> assets;

  /// Media for `req.offline`.
  final List<MediaId> offline;

  /// Items for `req.pendingReverse`.
  final List<ItemId> pendingReverse;

  /// Stills for `req.pendingStill`.
  final List<MediaId> pendingStill;

  /// The asset the clip's media layer plays (null for images, holds and solids). CORE-31 lowers
  /// the clip's audio segment from the same asset and [playbackMap] (A/V sync, ARCH §11.5).
  final String? playbackAsset;

  /// The map of the clip's media layer (empty when [playbackAsset] is null).
  final List<MapSegment> playbackMap;

  /// The clip's `<itemId>#v` layer.
  PlanLayer get visualLayer => layers.last;

  /// A copy with [layers] replaced (same assets and requirements).
  LoweredClip withLayers(List<PlanLayer> layers) => LoweredClip(
        item: item,
        layers: layers,
        assets: assets,
        offline: offline,
        pendingReverse: pendingReverse,
        pendingStill: pendingStill,
        playbackAsset: playbackAsset,
        playbackMap: playbackMap,
      );
}

/// How a model keyframe channel converts to a plan `anim` channel.
enum _Conv { identity, canvasX, canvasY, blur }

/// Model keyframe channel → (plan channel, conversion), in a fixed order (CORE-05 channel ids).
final List<(String, String, _Conv)> _channelTable = [
  (PropertyKeys.position.channels[0], PlanChannels.xfCx, _Conv.canvasX),
  (PropertyKeys.position.channels[1], PlanChannels.xfCy, _Conv.canvasY),
  (PropertyKeys.scale.channels[0], PlanChannels.xfS, _Conv.identity),
  (PropertyKeys.rotation.channels[0], PlanChannels.xfR, _Conv.identity),
  (PropertyKeys.opacity.channels[0], PlanChannels.xfOp, _Conv.identity),
  (PropertyKeys.exposure.channels[0], PlanChannels.adjust[0], _Conv.identity),
  (PropertyKeys.brightness.channels[0], PlanChannels.adjust[1], _Conv.identity),
  (PropertyKeys.contrast.channels[0], PlanChannels.adjust[2], _Conv.identity),
  (PropertyKeys.highlights.channels[0], PlanChannels.adjust[3], _Conv.identity),
  (PropertyKeys.shadows.channels[0], PlanChannels.adjust[4], _Conv.identity),
  (PropertyKeys.saturation.channels[0], PlanChannels.adjust[5], _Conv.identity),
  (PropertyKeys.temperature.channels[0], PlanChannels.adjust[6], _Conv.identity),
  (PropertyKeys.tint.channels[0], PlanChannels.adjust[7], _Conv.identity),
  (PropertyKeys.sharpness.channels[0], PlanChannels.detail[0], _Conv.identity),
  (PropertyKeys.blur.channels[0], PlanChannels.detail[1], _Conv.blur),
  (PropertyKeys.vignette.channels[0], PlanChannels.detail[2], _Conv.identity),
  (PropertyKeys.maskCenter.channels[0], PlanChannels.mask[0], _Conv.identity),
  (PropertyKeys.maskCenter.channels[1], PlanChannels.mask[1], _Conv.identity),
  (PropertyKeys.maskSize.channels[0], PlanChannels.mask[2], _Conv.identity),
  (PropertyKeys.maskSize.channels[1], PlanChannels.mask[3], _Conv.identity),
  (PropertyKeys.maskRotation.channels[0], PlanChannels.mask[4], _Conv.identity),
  (PropertyKeys.maskFeather.channels[0], PlanChannels.mask[5], _Conv.identity),
  (PropertyKeys.maskOpacity.channels[0], PlanChannels.mask[6], _Conv.identity),
];

/// The plan `anim` channels of [clip]'s keyframes (ARCH §11.7 "Item keyframes"): each model
/// channel with keys inside `[0, duration)` (keys outside are kept by the model and ignored by
/// evaluation, ARCH §6.7) becomes the same keys at absolute time `start + t`, values converted to
/// plan units (positions to plan canvas px, blur scaled by [CanvasMapping.blurScale]). Linear
/// interpolation held outside the keys is the semantics of both, so the plan evaluates exactly
/// like `evaluate()` at every time. [transformOnly] keeps the `xf.*` channels only (solids);
/// [withMask] drops the `mask.*` channels when false (no mask shape).
Map<String, List<AnimKey>> animChannelsOf(
  MediaClip clip,
  VisualLoweringContext ctx, {
  bool transformOnly = false,
  bool withMask = true,
}) {
  final keyframes = clip.keyframes;
  if (keyframes.isEmpty) return const {};
  final out = <String, List<AnimKey>>{};
  final w = ctx.projectCanvas.width;
  final h = ctx.projectCanvas.height;
  final m = ctx.mapping;
  for (final (model, plan, conv) in _channelTable) {
    final track = keyframes[model];
    if (track == null) continue;
    if (transformOnly && !plan.startsWith('xf.')) continue;
    if (!withMask && plan.startsWith('mask.')) continue;
    final keys = _inRange(track, clip.duration);
    if (keys.isEmpty) continue;
    out[plan] = [
      for (final k in keys)
        AnimKey(
          clip.start + k.t,
          switch (conv) {
            _Conv.identity => k.v,
            _Conv.canvasX => m.x(w / 2 + k.v * w),
            _Conv.canvasY => m.y(h / 2 + k.v * h),
            _Conv.blur => k.v * m.blurScale,
          },
        ),
    ];
  }
  return out;
}

List<Keyframe> _inRange(KeyframeTrack track, TimeUs duration) {
  final keys = track.keys;
  var lo = 0;
  while (lo < keys.length && keys[lo].t < 0) {
    lo++;
  }
  var hi = keys.length;
  while (hi > lo && keys[hi - 1].t >= duration) {
    hi--;
  }
  return lo == 0 && hi == keys.length ? keys : keys.sublist(lo, hi);
}

/// The static placement of [transform] on the plan canvas: centre via [positionToCanvas] and the
/// canvas mapping (null when it is the plan canvas centre, the `xf` default), scale, rotation,
/// flips and opacity.
PlanTransform planTransformOf(Transform2D transform, VisualLoweringContext ctx, {bool flips = true}) {
  final c = positionToCanvas(transform.position, ctx.projectCanvas);
  final cx = ctx.mapping.x(c.dx);
  final cy = ctx.mapping.y(c.dy);
  final out = ctx.mapping.output;
  return PlanTransform(
    cx: cx == out.width / 2 ? null : cx,
    cy: cy == out.height / 2 ? null : cy,
    s: transform.scale,
    r: transform.rotationDeg,
    fx: flips && transform.flipH,
    fy: flips && transform.flipV,
    op: transform.opacity,
  );
}

/// The plan `base` of a picture of [picture] px under [fit] and [crop]: [baseSize] into the
/// project canvas as it sits on the plan canvas (the project canvas itself for the identity
/// mapping; `baseSize` is homogeneous in the canvas size, and fitting into the mapped canvas keeps
/// the constrained side exact). The whole (mapped) canvas when the picture size is unknown or the
/// crop is empty.
PlanSize planBaseOf(Size2? picture, FitMode fit, CropRect crop, VisualLoweringContext ctx) {
  final canvas = ctx.mapping.size(ctx.projectCanvas);
  final Size2 base;
  if (picture == null || !picture.isPositive || !(crop.right > crop.left && crop.bottom > crop.top)) {
    base = canvas;
  } else {
    base = baseSize(fit: fit, crop: crop, source: picture, canvas: canvas);
  }
  return PlanSize(base.width, base.height);
}

/// The effect set of [visual] (D-08 order is the engines'): an `adj` or `detail` block when any
/// value is non-zero or animated in [anim], the look's LUT at its intensity, chroma when enabled,
/// the mask unless its shape is none.
PlanEffects planEffectsOf(VisualProps visual, ClipResolution res, Map<String, List<AnimKey>> anim, VisualLoweringContext ctx) {
  final a = visual.adjust;
  final adjAnimated = anim.keys.any((k) => k.startsWith('adj.'));
  final adj = !a.isNeutral || adjAnimated
      ? PlanAdjust(
          exposure: a.exposure,
          brightness: a.brightness,
          contrast: a.contrast,
          highlights: a.highlights,
          shadows: a.shadows,
          saturation: a.saturation,
          temperature: a.temperature,
          tint: a.tint,
        )
      : null;
  final d = visual.detail;
  final detailAnimated = anim.keys.any((k) => k.startsWith('detail.'));
  final detail = d.sharpness != 0 || d.blur != 0 || d.vignette != 0 || detailAnimated
      ? PlanDetail(sharpen: d.sharpness, blur: d.blur * ctx.mapping.blurScale, vignette: d.vignette)
      : null;
  final look = visual.look;
  final lut = look != null && res.lutAssetId != null ? PlanLut(res.lutAssetId!, look.intensity) : null;
  final c = visual.chroma;
  final chroma = c.enabled ? PlanChroma(key: c.color & 0xFFFFFF, sim: c.similarity, smooth: c.smoothness, spill: c.spill) : null;
  final mk = visual.mask;
  final mask = switch (mk.shape) {
    MaskShape.none => null,
    MaskShape.rectangle || MaskShape.ellipse => PlanMask(
        shape: mk.shape == MaskShape.ellipse ? PlanMaskShape.ellipse : PlanMaskShape.rect,
        cx: mk.center.x,
        cy: mk.center.y,
        w: mk.size.x,
        h: mk.size.y,
        r: mk.rotationDeg,
        corner: mk.cornerRadius,
        feather: mk.feather,
        op: mk.opacity,
        inv: mk.invert,
      ),
  };
  if (adj == null && detail == null && lut == null && chroma == null && mask == null) return PlanEffects.none;
  return PlanEffects(adj: adj, detail: detail, lut: lut, chroma: chroma, mask: mask);
}

/// Lowers the visual [clip] whose resolution is [res] on a lane at [z] (ARCH §11.7, file header).
/// [backdropBlur] (already scaled by [CanvasMapping.blurScale]) adds the `#bd` backdrop of a
/// main-lane clip under `BlurOfMain`. Layers carry no `seq`; the compiler packs them.
LoweredClip lowerVisualClip(
  MediaClip clip,
  ClipResolution res, {
  required int z,
  double? backdropBlur,
  required VisualLoweringContext ctx,
}) {
  final visual = clip.visual ?? VisualProps.neutral;
  final source = res.source;
  final id = PlanIds.visual(clip.id);
  final t0 = clip.start;
  final t1 = clip.end;
  final crop = PlanCrop(visual.crop.left, visual.crop.top, visual.crop.right, visual.crop.bottom);
  final xf = planTransformOf(visual.transform, ctx);
  final base = planBaseOf(source.picture, visual.fit, visual.crop, ctx);

  if (source is SolidVisualSource) {
    return LoweredClip(
      item: clip.id,
      layers: [
        PlanLayer(
          id: id,
          z: z,
          t0: t0,
          t1: t1,
          kind: PlanLayerKind.solid,
          color: source.color,
          base: base,
          xf: xf,
          anim: animChannelsOf(clip, ctx, transformOnly: true),
        ),
      ],
      offline: [if (source.offline != null) source.offline!],
      pendingStill: [if (source.pendingStill != null) source.pendingStill!],
    );
  }

  final anim = animChannelsOf(clip, ctx, withMask: visual.mask.shape != MaskShape.none);
  final fx = planEffectsOf(visual, res, anim, ctx);
  final assets = <String, PlanAsset>{
    if (res.lutAssetId != null && fx.lut != null) res.lutAssetId!: res.lutEntry!,
  };
  final offline = <MediaId>[if (res.lutOffline != null) res.lutOffline!];
  final pendingReverse = <ItemId>[];
  final pendingStill = <MediaId>[];

  final PlanLayerKind kind;
  final String assetId;
  var map = const <MapSegment>[];
  var hold = false;
  String? playbackAsset;
  switch (source) {
    case MediaVisualSource():
      kind = PlanLayerKind.media;
      assetId = source.assetId;
      assets[assetId] = source.entry;
      map = clipMap(clip, ctx.rate, rendition: source.rendition, forwardFallback: source.pendingReverse);
      if (source.pendingReverse) pendingReverse.add(clip.id);
      playbackAsset = assetId;
    case ImageVisualSource():
      kind = PlanLayerKind.image;
      assetId = source.assetId;
      assets[assetId] = source.entry;
    case HoldVisualSource():
      kind = PlanLayerKind.media;
      assetId = source.assetId;
      assets[assetId] = source.entry;
      map = [holdSegment(t0, t1, source.freezeTime, sourceDurationUs: source.entry.durUs)];
      hold = true;
      pendingStill.add(source.still);
    case SolidVisualSource():
      throw StateError('unreachable');
  }

  final layers = <PlanLayer>[];
  if (backdropBlur != null) {
    final fill = planBaseOf(source.picture, FitMode.fill, visual.crop, ctx);
    layers.add(PlanLayer(
      id: PlanIds.backdrop(clip.id),
      z: z - 5,
      t0: t0,
      t1: t1,
      kind: kind,
      asset: assetId,
      map: map,
      hold: hold,
      base: fill,
      crop: crop,
      xf: planTransformOf(Transform2D.identity, ctx),
      fx: backdropBlur > 0 ? PlanEffects(detail: PlanDetail(blur: backdropBlur)) : PlanEffects.none,
    ));
  }
  layers.add(PlanLayer(
    id: id,
    z: z,
    t0: t0,
    t1: t1,
    kind: kind,
    asset: assetId,
    map: map,
    hold: hold,
    base: base,
    crop: crop,
    xf: xf,
    fx: fx,
    anim: anim,
  ));
  return LoweredClip(
    item: clip.id,
    layers: layers,
    assets: assets,
    offline: offline,
    pendingReverse: pendingReverse,
    pendingStill: pendingStill,
    playbackAsset: playbackAsset,
    playbackMap: map,
  );
}

/// The one-segment map of a `hold` layer over `[t0, t1)` showing source time [freezeTime]
/// (engines show `map[0].s0` throughout, ARCH §11.5). The segment runs at rate 1 when that stays
/// inside the source ([sourceDurationUs]) and at the minimum rate 0.1 otherwise, so the source
/// range it names is as short as a valid map allows.
MapSegment holdSegment(TimeUs t0, TimeUs t1, TimeUs freezeTime, {TimeUs? sourceDurationUs}) {
  final dt = t1 - t0;
  var span = dt;
  if (sourceDurationUs != null && sourceDurationUs > 0 && freezeTime + span > sourceDurationUs) span = (dt + 9) ~/ 10;
  return MapSegment(t0, t1, freezeTime, freezeTime + span);
}
