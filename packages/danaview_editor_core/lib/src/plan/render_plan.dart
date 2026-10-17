// OWNER: CORE-29
//
// RenderPlan contract v1 (ARCH §11): the flat, fully lowered layer list that Dart sends to the
// native engines (D-01). Normative sources: `schema/render_plan.v1.schema.json` and
// `schema/effects_reference.md`. JSON codec: `plan_json.dart`; invariants: `plan_validator.dart`.
//
// Units: times are integer µs on the plan's `canvas.gridFps` grid (D-35); colours are ARGB ints
// in Dart and `"#RRGGBBAA"` on the wire; canvas-space values are in canvas px.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../time/time.dart';

/// The RenderPlan schema version this library reads and writes (`"v"`).
const int renderPlanVersion = 1;

const ListEquality<Object?> _listEq = ListEquality<Object?>();
const DeepCollectionEquality _deepEq = DeepCollectionEquality();

/// Animatable channel names (ARCH §11.2). LUT intensity, chroma, crop, flips and colours are not
/// animatable.
abstract final class PlanChannels {
  /// Centre x in canvas px.
  static const String xfCx = 'xf.cx';

  /// Centre y in canvas px.
  static const String xfCy = 'xf.cy';

  /// Scale factor.
  static const String xfS = 'xf.s';

  /// Rotation in degrees clockwise.
  static const String xfR = 'xf.r';

  /// Opacity [0, 1].
  static const String xfOp = 'xf.op';

  /// Sprite glyph reveal count (floor applied); only on sprites whose asset has `reveal: true`.
  static const String reveal = 'reveal';

  /// The eight colour adjustments, each [-1, 1].
  static const List<String> adjust = [
    'adj.exposure',
    'adj.brightness',
    'adj.contrast',
    'adj.highlights',
    'adj.shadows',
    'adj.saturation',
    'adj.temperature',
    'adj.tint',
  ];

  /// Detail effects, each [0, 1].
  static const List<String> detail = ['detail.sharpen', 'detail.blur', 'detail.vignette'];

  /// Item mask channels.
  static const List<String> mask = ['mask.cx', 'mask.cy', 'mask.w', 'mask.h', 'mask.r', 'mask.feather', 'mask.op'];

  /// Every channel a layer `anim` may contain.
  static final Set<String> all = {xfCx, xfCy, xfS, xfR, xfOp, reveal, ...adjust, ...detail, ...mask};

  /// Channels a canvas mask `anim` may contain.
  static const Set<String> canvasMask = {'cx', 'cy', 'w', 'h'};
}

/// Stable layer and segment id helpers (ARCH §11.2 `id`).
abstract final class PlanIds {
  /// Clip or text item layer: `<itemId>#v`.
  static String visual(String itemId) => '$itemId#v';

  /// Blurred-background backdrop of a main-lane clip: `<itemId>#bd`.
  static String backdrop(String itemId) => '$itemId#bd';

  /// Transition helper solid number [n] next to [itemId]: `<itemId>#tx<n>`.
  static String transitionHelper(String itemId, int n) => '$itemId#tx$n';

  /// Burned subtitle cue: `<cueId>#c`.
  static String cue(String cueId) => '$cueId#c';

  /// Audio segment: `<itemId>#a`.
  static String audio(String itemId) => '$itemId#a';

  /// The item id a layer or segment id was derived from (text before `#`).
  static String itemOf(String layerId) {
    final i = layerId.indexOf('#');
    return i < 0 ? layerId : layerId.substring(0, i);
  }
}

/// Whether a plan drives the live preview or an export.
enum PlanTarget {
  /// Live preview (no text/subtitle layers, D-05; may carry proxies and requirements).
  preview,

  /// Export (originals only, sprite layers for text and burned cues).
  export,
}

/// One key of an animation channel: value [v] at absolute timeline time [tUs].
@immutable
final class AnimKey {
  /// Creates a key.
  const AnimKey(this.tUs, this.v);

  /// Absolute timeline time in µs.
  final TimeUs tUs;

  /// Value in the channel's units.
  final double v;

  @override
  bool operator ==(Object other) => other is AnimKey && other.tUs == tUs && other.v == v;

  @override
  int get hashCode => Object.hash(tUs, v);

  @override
  String toString() => '[$tUs, $v]';
}

/// Linear interpolation of [keys] at [t], held outside the first and last key (ARCH §11.1 rule 2).
double evaluateAnimKeys(List<AnimKey> keys, TimeUs t) {
  assert(keys.isNotEmpty);
  if (t <= keys.first.tUs) return keys.first.v;
  if (t >= keys.last.tUs) return keys.last.v;
  var lo = 0;
  var hi = keys.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (keys[mid].tUs <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = keys[lo];
  final b = keys[hi];
  return a.v + (b.v - a.v) * (t - a.tUs) / (b.tUs - a.tUs);
}

/// The plan canvas (ARCH §11.2 Canvas).
@immutable
final class PlanCanvas {
  /// Creates a canvas. [gridFps] defaults to [fps].
  const PlanCanvas({required this.w, required this.h, required this.fps, int? gridFps, this.bg = 0xFF000000})
      : gridFps = gridFps ?? fps;

  /// Width in px (even, ≥ 16). For export: the output width.
  final int w;

  /// Height in px (even, ≥ 16). For export: the output height.
  final int h;

  /// Output frame rate (24, 25, 30, 48, 50 or 60).
  final int fps;

  /// The project rate: the grid every layer edge, map breakpoint and audio edge lies on (D-35).
  final int gridFps;

  /// Opaque background colour (ARGB).
  final int bg;

  /// Output rate as a [FrameRate].
  FrameRate get frameRate => FrameRate(fps, 1);

  /// Grid rate as a [FrameRate].
  FrameRate get gridRate => FrameRate(gridFps, 1);

  /// A copy with the given fields replaced.
  PlanCanvas copyWith({int? w, int? h, int? fps, int? gridFps, int? bg}) =>
      PlanCanvas(w: w ?? this.w, h: h ?? this.h, fps: fps ?? this.fps, gridFps: gridFps ?? this.gridFps, bg: bg ?? this.bg);

  @override
  bool operator ==(Object other) =>
      other is PlanCanvas && other.w == w && other.h == h && other.fps == fps && other.gridFps == gridFps && other.bg == bg;

  @override
  int get hashCode => Object.hash(w, h, fps, gridFps, bg);
}

/// Asset kinds referenced by layers and audio segments.
enum PlanAssetKind {
  /// Video file (decoder-backed).
  video,

  /// Audio-only file.
  audio,

  /// Still image.
  image,

  /// `.vlut` colour lookup table.
  lut,

  /// `.vsprite` text raster (export only).
  sprite,
}

/// Transfer function of a source; HDR sources are tone-mapped to SDR before effects.
enum PlanTransfer {
  /// SDR (BT.709).
  sdr,

  /// HLG.
  hlg,

  /// PQ (HDR10).
  pq,
}

/// An asset entry of `plan.assets` (ARCH §11.2 Asset).
@immutable
final class PlanAsset {
  /// Creates an asset.
  const PlanAsset({
    required this.kind,
    required this.uri,
    this.bookmark,
    this.fp = '',
    this.proxyUri,
    this.w,
    this.h,
    this.rot,
    this.durUs,
    this.transfer = PlanTransfer.sdr,
    this.hasAudio,
    this.n,
    this.sw,
    this.sh,
    this.sscale,
    this.reveal,
  });

  /// Kind.
  final PlanAssetKind kind;

  /// `file://…` or `content://…` (never http).
  final String uri;

  /// iOS security-scoped bookmark (base64).
  final String? bookmark;

  /// `quickHash` cache key (video/audio/image); empty when not applicable.
  final String fp;

  /// Preview only: proxy rendition with the same timestamps.
  final String? proxyUri;

  /// Display width (rotation applied).
  final int? w;

  /// Display height (rotation applied).
  final int? h;

  /// Rotation 0/90/180/270.
  final int? rot;

  /// Duration in µs.
  final TimeUs? durUs;

  /// Transfer function (default sdr).
  final PlanTransfer transfer;

  /// Whether the file has audio.
  final bool? hasAudio;

  /// `lut` only: `.vlut` size N (2–65).
  final int? n;

  /// `sprite` only: pixel width.
  final int? sw;

  /// `sprite` only: pixel height.
  final int? sh;

  /// `sprite` only: sprite px per canvas px.
  final double? sscale;

  /// `sprite` only: whether a glyph-order map is present.
  final bool? reveal;

  @override
  bool operator ==(Object other) =>
      other is PlanAsset &&
      other.kind == kind &&
      other.uri == uri &&
      other.bookmark == bookmark &&
      other.fp == fp &&
      other.proxyUri == proxyUri &&
      other.w == w &&
      other.h == h &&
      other.rot == rot &&
      other.durUs == durUs &&
      other.transfer == transfer &&
      other.hasAudio == hasAudio &&
      other.n == n &&
      other.sw == sw &&
      other.sh == sh &&
      other.sscale == sscale &&
      other.reveal == reveal;

  @override
  int get hashCode =>
      Object.hash(kind, uri, bookmark, fp, proxyUri, w, h, rot, durUs, transfer, hasAudio, n, sw, sh, sscale, reveal);
}

/// Visual layer kinds.
enum PlanLayerKind {
  /// Decoder-backed video (has `map`, `seq`).
  media,

  /// Still image.
  image,

  /// Solid colour (transition helpers, placeholders).
  solid,

  /// Text raster (export only).
  sprite,
}

/// A size in canvas px (`base`).
@immutable
final class PlanSize {
  /// Creates a size.
  const PlanSize(this.w, this.h);

  /// Width.
  final double w;

  /// Height.
  final double h;

  @override
  bool operator ==(Object other) => other is PlanSize && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(w, h);
}

/// Normalized crop `[l, t, r, b]` of the display-oriented source.
@immutable
final class PlanCrop {
  /// Creates a crop.
  const PlanCrop(this.l, this.t, this.r, this.b);

  /// No crop.
  static const PlanCrop full = PlanCrop(0, 0, 1, 1);

  /// Left.
  final double l;

  /// Top.
  final double t;

  /// Right.
  final double r;

  /// Bottom.
  final double b;

  /// Whether this is [full].
  bool get isFull => l == 0 && t == 0 && r == 1 && b == 1;

  @override
  bool operator ==(Object other) => other is PlanCrop && other.l == l && other.t == t && other.r == r && other.b == b;

  @override
  int get hashCode => Object.hash(l, t, r, b);
}

/// Placement `xf` (ARCH §11.2): centre, scale, rotation (degrees clockwise, y down), flips, opacity.
@immutable
final class PlanTransform {
  /// Creates a transform. A null [cx]/[cy] means the canvas centre.
  const PlanTransform({this.cx, this.cy, this.s = 1, this.r = 0, this.fx = false, this.fy = false, this.op = 1});

  /// Identity placement at the canvas centre.
  static const PlanTransform identity = PlanTransform();

  /// Centre x in canvas px (null = W/2).
  final double? cx;

  /// Centre y in canvas px (null = H/2).
  final double? cy;

  /// Scale factor.
  final double s;

  /// Rotation in degrees clockwise.
  final double r;

  /// Horizontal flip.
  final bool fx;

  /// Vertical flip.
  final bool fy;

  /// Opacity [0, 1].
  final double op;

  /// Whether every field has its default value.
  bool get isIdentity => cx == null && cy == null && s == 1 && r == 0 && !fx && !fy && op == 1;

  @override
  bool operator ==(Object other) =>
      other is PlanTransform &&
      other.cx == cx &&
      other.cy == cy &&
      other.s == s &&
      other.r == r &&
      other.fx == fx &&
      other.fy == fy &&
      other.op == op;

  @override
  int get hashCode => Object.hash(cx, cy, s, r, fx, fy, op);
}

/// Colour adjustments, each in [-1, 1] (0 = neutral).
@immutable
final class PlanAdjust {
  /// Creates adjustments.
  const PlanAdjust({
    this.exposure = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.saturation = 0,
    this.temperature = 0,
    this.tint = 0,
  });

  /// Exposure (±2 EV at ±1).
  final double exposure;

  /// Brightness.
  final double brightness;

  /// Contrast.
  final double contrast;

  /// Highlights.
  final double highlights;

  /// Shadows.
  final double shadows;

  /// Saturation.
  final double saturation;

  /// Temperature.
  final double temperature;

  /// Tint.
  final double tint;

  /// Values in wire order (exposure … tint), matching [PlanChannels.adjust].
  List<double> get values => [exposure, brightness, contrast, highlights, shadows, saturation, temperature, tint];

  @override
  bool operator ==(Object other) => other is PlanAdjust && _listEq.equals(other.values, values);

  @override
  int get hashCode => Object.hashAll(values);
}

/// Detail effects, each in [0, 1].
@immutable
final class PlanDetail {
  /// Creates detail effects.
  const PlanDetail({this.sharpen = 0, this.blur = 0, this.vignette = 0});

  /// Sharpen amount.
  final double sharpen;

  /// Blur amount (σ = blur · 0.03 · min(W, H) plan px).
  final double blur;

  /// Vignette amount.
  final double vignette;

  @override
  bool operator ==(Object other) =>
      other is PlanDetail && other.sharpen == sharpen && other.blur == blur && other.vignette == vignette;

  @override
  int get hashCode => Object.hash(sharpen, blur, vignette);
}

/// LUT reference: an asset of kind `lut` mixed at intensity [i].
@immutable
final class PlanLut {
  /// Creates a LUT reference.
  const PlanLut(this.asset, this.i);

  /// Asset id.
  final String asset;

  /// Intensity [0, 1].
  final double i;

  @override
  bool operator ==(Object other) => other is PlanLut && other.asset == asset && other.i == i;

  @override
  int get hashCode => Object.hash(asset, i);
}

/// Chroma key parameters, keyed on the source colours (D-08).
@immutable
final class PlanChroma {
  /// Creates chroma parameters. [key] is `0xRRGGBB`.
  const PlanChroma({required this.key, this.sim = 0.4, this.smooth = 0.1, this.spill = 0.3});

  /// Key colour `0xRRGGBB`.
  final int key;

  /// Similarity [0, 1].
  final double sim;

  /// Smoothness [0, 1].
  final double smooth;

  /// Spill reduction [0, 1].
  final double spill;

  @override
  bool operator ==(Object other) =>
      other is PlanChroma && other.key == key && other.sim == sim && other.smooth == smooth && other.spill == spill;

  @override
  int get hashCode => Object.hash(key, sim, smooth, spill);
}

/// Mask shapes.
enum PlanMaskShape {
  /// Rotated rounded rectangle.
  rect,

  /// Ellipse.
  ellipse,
}

/// Item mask in layer-normalized space over `base` (ARCH §11.2 Effects.mask).
@immutable
final class PlanMask {
  /// Creates a mask.
  const PlanMask({
    required this.shape,
    this.cx = 0.5,
    this.cy = 0.5,
    this.w = 1,
    this.h = 1,
    this.r = 0,
    this.corner = 0,
    this.feather = 0,
    this.op = 1,
    this.inv = false,
  });

  /// Shape.
  final PlanMaskShape shape;

  /// Centre x (layer-normalized).
  final double cx;

  /// Centre y (layer-normalized).
  final double cy;

  /// Width (layer-normalized).
  final double w;

  /// Height (layer-normalized).
  final double h;

  /// Rotation in degrees.
  final double r;

  /// Corner radius [0, 0.5] as a fraction of min(w, h).
  final double corner;

  /// Feather [0, 1].
  final double feather;

  /// Opacity [0, 1].
  final double op;

  /// Inverted.
  final bool inv;

  @override
  bool operator ==(Object other) =>
      other is PlanMask &&
      other.shape == shape &&
      other.cx == cx &&
      other.cy == cy &&
      other.w == w &&
      other.h == h &&
      other.r == r &&
      other.corner == corner &&
      other.feather == feather &&
      other.op == op &&
      other.inv == inv;

  @override
  int get hashCode => Object.hash(shape, cx, cy, w, h, r, corner, feather, op, inv);
}

/// The fixed effect set of a layer, applied in the D-08 order.
@immutable
final class PlanEffects {
  /// Creates effects; null members are absent (neutral).
  const PlanEffects({this.adj, this.detail, this.lut, this.chroma, this.mask});

  /// No effects.
  static const PlanEffects none = PlanEffects();

  /// Colour adjustments.
  final PlanAdjust? adj;

  /// Detail effects.
  final PlanDetail? detail;

  /// LUT.
  final PlanLut? lut;

  /// Chroma key.
  final PlanChroma? chroma;

  /// Item mask.
  final PlanMask? mask;

  /// Whether no effect is present.
  bool get isEmpty => adj == null && detail == null && lut == null && chroma == null && mask == null;

  @override
  bool operator ==(Object other) =>
      other is PlanEffects &&
      other.adj == adj &&
      other.detail == detail &&
      other.lut == lut &&
      other.chroma == chroma &&
      other.mask == mask;

  @override
  int get hashCode => Object.hash(adj, detail, lut, chroma, mask);
}

/// A canvas-space mask multiplying a layer's alpha after placement (wipes).
@immutable
final class CanvasMask {
  /// Creates a canvas mask.
  const CanvasMask({
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    this.r = 0,
    this.feather = 0,
    this.inv = false,
    this.anim = const {},
  });

  /// Centre x in canvas px.
  final double cx;

  /// Centre y in canvas px.
  final double cy;

  /// Width in canvas px.
  final double w;

  /// Height in canvas px.
  final double h;

  /// Rotation in degrees.
  final double r;

  /// Feather in px.
  final double feather;

  /// Inverted.
  final bool inv;

  /// Animated `cx`, `cy`, `w`, `h` (absolute µs).
  final Map<String, List<AnimKey>> anim;

  @override
  bool operator ==(Object other) =>
      other is CanvasMask &&
      other.cx == cx &&
      other.cy == cy &&
      other.w == w &&
      other.h == h &&
      other.r == r &&
      other.feather == feather &&
      other.inv == inv &&
      _deepEq.equals(other.anim, anim);

  @override
  int get hashCode => Object.hash(cx, cy, w, h, r, feather, inv, _deepEq.hash(anim));
}

/// A visual layer (ARCH §11.2 Layer).
@immutable
final class PlanLayer {
  /// Creates a layer.
  PlanLayer({
    required this.id,
    required this.z,
    required this.t0,
    required this.t1,
    required this.kind,
    this.seq,
    this.asset,
    List<MapSegment> map = const [],
    this.hold = false,
    this.color,
    this.base,
    this.crop = PlanCrop.full,
    this.xf = PlanTransform.identity,
    this.fx = PlanEffects.none,
    Map<String, List<AnimKey>> anim = const {},
    List<CanvasMask> cmasks = const [],
  })  : map = List.unmodifiable(map),
        anim = Map.unmodifiable(anim),
        cmasks = List.unmodifiable(cmasks);

  /// Stable id (see [PlanIds]).
  final String id;

  /// Opaque sort key (ARCH §11.4).
  final int z;

  /// `media` layers only: visual sequence / composition-track slot from core packing (CORE-36).
  final int? seq;

  /// Timeline start (inclusive, on the grid).
  final TimeUs t0;

  /// Timeline end (exclusive, on the grid).
  final TimeUs t1;

  /// Kind.
  final PlanLayerKind kind;

  /// Asset id (media, image, sprite).
  final String? asset;

  /// `media` only: contiguous map covering `[t0, t1)`.
  final List<MapSegment> map;

  /// `media` only: show the frame at `map[0].s0` throughout (pending freeze still).
  final bool hold;

  /// `solid` only: ARGB colour.
  final int? color;

  /// Cropped source size after fit, before transform, in canvas px.
  final PlanSize? base;

  /// Normalized crop.
  final PlanCrop crop;

  /// Placement.
  final PlanTransform xf;

  /// Effects.
  final PlanEffects fx;

  /// Animated channels (absolute µs), see [PlanChannels].
  final Map<String, List<AnimKey>> anim;

  /// Canvas masks (wipes).
  final List<CanvasMask> cmasks;

  /// `[t0, t1)`.
  TimeRange get range => TimeRange(t0, t1);

  /// Whether the layer is active at plan time [t] (`t0 ≤ t < t1`). Platform times must be mapped
  /// with `frameIndexNearest` and `timeOfFrame` first (D-35).
  bool isActiveAt(TimeUs t) => t >= t0 && t < t1;

  @override
  bool operator ==(Object other) =>
      other is PlanLayer &&
      other.id == id &&
      other.z == z &&
      other.seq == seq &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      other.kind == kind &&
      other.asset == asset &&
      _listEq.equals(other.map, map) &&
      other.hold == hold &&
      other.color == color &&
      other.base == base &&
      other.crop == crop &&
      other.xf == xf &&
      other.fx == fx &&
      _deepEq.equals(other.anim, anim) &&
      _listEq.equals(other.cmasks, cmasks);

  @override
  int get hashCode => Object.hash(id, z, seq, t0, t1, kind, asset, Object.hashAll(map), hold, color, base, crop, xf,
      fx, _deepEq.hash(anim), Object.hashAll(cmasks));
}

/// An audio segment (ARCH §11.2 AudioSeg).
@immutable
final class AudioSeg {
  /// Creates a segment.
  AudioSeg({
    required this.id,
    required this.asset,
    required this.t0,
    required this.t1,
    required List<MapSegment> map,
    required List<AnimKey> gain,
    this.stream = 0,
    this.pitch = true,
  })  : map = List.unmodifiable(map),
        gain = List.unmodifiable(gain);

  /// Stable id `<itemId>#a`.
  final String id;

  /// Asset id (audio, or video with audio).
  final String asset;

  /// Audio stream index.
  final int stream;

  /// Timeline start (on the grid).
  final TimeUs t0;

  /// Timeline end (on the grid).
  final TimeUs t1;

  /// Contiguous map covering `[t0, t1)`; shares boundaries with the clip's video layer.
  final List<MapSegment> map;

  /// Linear gain envelope (≥ 1 key, values 0–2, absolute µs).
  final List<AnimKey> gain;

  /// Keep pitch when the rate ≠ 1.
  final bool pitch;

  @override
  bool operator ==(Object other) =>
      other is AudioSeg &&
      other.id == id &&
      other.asset == asset &&
      other.stream == stream &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      _listEq.equals(other.map, map) &&
      _listEq.equals(other.gain, gain) &&
      other.pitch == pitch;

  @override
  int get hashCode => Object.hash(id, asset, stream, t0, t1, Object.hashAll(map), Object.hashAll(gain), pitch);
}

/// Preview-only, informational requirements (ARCH §11.2 Requirements).
@immutable
final class PlanRequirements {
  /// Creates requirements.
  PlanRequirements({List<String> offline = const [], List<String> pendingReverse = const [], List<String> pendingStill = const []})
      : offline = List.unmodifiable(offline),
        pendingReverse = List.unmodifiable(pendingReverse),
        pendingStill = List.unmodifiable(pendingStill);

  /// Offline media ids.
  final List<String> offline;

  /// Items waiting for a reversed rendition.
  final List<String> pendingReverse;

  /// Media waiting for a freeze still.
  final List<String> pendingStill;

  /// Whether nothing is pending or offline.
  bool get isEmpty => offline.isEmpty && pendingReverse.isEmpty && pendingStill.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is PlanRequirements &&
      _listEq.equals(other.offline, offline) &&
      _listEq.equals(other.pendingReverse, pendingReverse) &&
      _listEq.equals(other.pendingStill, pendingStill);

  @override
  int get hashCode => Object.hash(Object.hashAll(offline), Object.hashAll(pendingReverse), Object.hashAll(pendingStill));
}

/// A complete RenderPlan (ARCH §11.2 Plan).
@immutable
final class RenderPlan {
  /// Creates a plan. [layers] must be sorted by (z, t0, id) and [audio] by (t0, id); the codec and
  /// validator check this.
  RenderPlan({
    this.v = renderPlanVersion,
    required this.rev,
    required this.target,
    required this.canvas,
    required this.durUs,
    Map<String, PlanAsset> assets = const {},
    List<PlanLayer> layers = const [],
    List<AudioSeg> audio = const [],
    this.req,
  })  : assets = Map.unmodifiable(assets),
        layers = List.unmodifiable(layers),
        audio = List.unmodifiable(audio);

  /// Schema version (1).
  final int v;

  /// Session-monotonic revision stamp.
  final int rev;

  /// Preview or export.
  final PlanTarget target;

  /// Canvas.
  final PlanCanvas canvas;

  /// Timeline duration (end of the last layer/segment), on the grid.
  final TimeUs durUs;

  /// Assets by id.
  final Map<String, PlanAsset> assets;

  /// Visual layers sorted by (z, t0, id).
  final List<PlanLayer> layers;

  /// Audio segments sorted by (t0, id).
  final List<AudioSeg> audio;

  /// Preview requirements (informational).
  final PlanRequirements? req;

  /// Ids of the layers active at plan time [t], in draw order (bottom → top). Callers holding a
  /// platform time map it first: `t = gridRate.timeOfFrame(gridRate.frameIndexNearest(tau))`
  /// (D-35).
  List<String> activeLayerIdsAt(TimeUs t) => [for (final l in layers) if (l.isActiveAt(t)) l.id];

  /// A copy with the given fields replaced.
  RenderPlan copyWith({
    int? rev,
    PlanTarget? target,
    PlanCanvas? canvas,
    TimeUs? durUs,
    Map<String, PlanAsset>? assets,
    List<PlanLayer>? layers,
    List<AudioSeg>? audio,
    PlanRequirements? req,
  }) =>
      RenderPlan(
        v: v,
        rev: rev ?? this.rev,
        target: target ?? this.target,
        canvas: canvas ?? this.canvas,
        durUs: durUs ?? this.durUs,
        assets: assets ?? this.assets,
        layers: layers ?? this.layers,
        audio: audio ?? this.audio,
        req: req ?? this.req,
      );

  @override
  bool operator ==(Object other) =>
      other is RenderPlan &&
      other.v == v &&
      other.rev == rev &&
      other.target == target &&
      other.canvas == canvas &&
      other.durUs == durUs &&
      const MapEquality<String, PlanAsset>().equals(other.assets, assets) &&
      _listEq.equals(other.layers, layers) &&
      _listEq.equals(other.audio, audio) &&
      other.req == req;

  @override
  int get hashCode => Object.hash(v, rev, target, canvas, durUs, const MapEquality<String, PlanAsset>().hash(assets),
      Object.hashAll(layers), Object.hashAll(audio), req);
}

/// Upserts and removals of one collection inside a [RenderPlanPatch].
@immutable
final class PatchSet<T> {
  /// Creates a patch set.
  PatchSet({List<T> upsert = const [], List<String> remove = const []})
      : upsert = List.unmodifiable(upsert),
        remove = List.unmodifiable(remove);

  /// Objects replaced (or added) whole, by id.
  final List<T> upsert;

  /// Ids removed.
  final List<String> remove;

  /// Whether nothing changes.
  bool get isEmpty => upsert.isEmpty && remove.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is PatchSet<T> && _listEq.equals(other.upsert, upsert) && _listEq.equals(other.remove, remove);

  @override
  int get hashCode => Object.hash(Object.hashAll(upsert), Object.hashAll(remove));
}

/// A plan patch, applied atomically only when [from] equals the engine's current revision
/// (otherwise `planOutOfSync`, ARCH §11.2 Patch).
@immutable
final class RenderPlanPatch {
  /// Creates a patch.
  RenderPlanPatch({
    this.v = renderPlanVersion,
    required this.from,
    required this.to,
    this.canvas,
    this.durUs,
    Map<String, PlanAsset> assetUpserts = const {},
    List<String> assetRemovals = const [],
    PatchSet<PlanLayer>? layers,
    PatchSet<AudioSeg>? audio,
  })  : assetUpserts = Map.unmodifiable(assetUpserts),
        assetRemovals = List.unmodifiable(assetRemovals),
        layers = layers ?? PatchSet<PlanLayer>(),
        audio = audio ?? PatchSet<AudioSeg>();

  /// Schema version.
  final int v;

  /// Revision the patch applies to.
  final int from;

  /// Revision after applying.
  final int to;

  /// New canvas, when changed.
  final PlanCanvas? canvas;

  /// New duration, when changed.
  final TimeUs? durUs;

  /// Assets added or replaced, by id.
  final Map<String, PlanAsset> assetUpserts;

  /// Asset ids removed.
  final List<String> assetRemovals;

  /// Layer changes.
  final PatchSet<PlanLayer> layers;

  /// Audio segment changes.
  final PatchSet<AudioSeg> audio;

  @override
  bool operator ==(Object other) =>
      other is RenderPlanPatch &&
      other.v == v &&
      other.from == from &&
      other.to == to &&
      other.canvas == canvas &&
      other.durUs == durUs &&
      const MapEquality<String, PlanAsset>().equals(other.assetUpserts, assetUpserts) &&
      _listEq.equals(other.assetRemovals, assetRemovals) &&
      other.layers == layers &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(v, from, to, canvas, durUs, const MapEquality<String, PlanAsset>().hash(assetUpserts),
      Object.hashAll(assetRemovals), layers, audio);
}

/// Param-only override of one layer inside a [PlanTransient]. Timing fields are not allowed.
@immutable
final class TransientLayer {
  /// Creates a transient layer override; null fields keep the current layer's value.
  const TransientLayer({required this.id, this.xf, this.crop, this.base, this.fx, this.anim, this.cmasks});

  /// Layer id.
  final String id;

  /// Placement override.
  final PlanTransform? xf;

  /// Crop override.
  final PlanCrop? crop;

  /// Base size override.
  final PlanSize? base;

  /// Effects override.
  final PlanEffects? fx;

  /// Animation override.
  final Map<String, List<AnimKey>>? anim;

  /// Canvas masks override.
  final List<CanvasMask>? cmasks;

  @override
  bool operator ==(Object other) =>
      other is TransientLayer &&
      other.id == id &&
      other.xf == xf &&
      other.crop == crop &&
      other.base == base &&
      other.fx == fx &&
      _deepEq.equals(other.anim, anim) &&
      _deepEq.equals(other.cmasks, cmasks);

  @override
  int get hashCode => Object.hash(id, xf, crop, base, fx, _deepEq.hash(anim), _deepEq.hash(cmasks));
}

/// A gesture-time, param-only override of one item's layers (ARCH §11.2 Transient). Never assigned
/// a revision, never persisted; dropped by the next plan/patch touching the layer or by
/// `clearTransient(item)`.
@immutable
final class PlanTransient {
  /// Creates a transient for [item].
  PlanTransient({this.v = renderPlanVersion, required this.item, required List<TransientLayer> layers})
      : layers = List.unmodifiable(layers);

  /// Schema version.
  final int v;

  /// Item id whose layers are overridden.
  final String item;

  /// Layer overrides.
  final List<TransientLayer> layers;

  @override
  bool operator ==(Object other) =>
      other is PlanTransient && other.v == v && other.item == item && _listEq.equals(other.layers, layers);

  @override
  int get hashCode => Object.hash(v, item, Object.hashAll(layers));
}
