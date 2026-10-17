// OWNER: CORE-37
//
// Render-preview cache model (ARCH D-45(A), §9.5, §17.10): pure Dart, no I/O.
//
// - `splitRanges(preview)` cuts a preview RenderPlan on its frame grid at every layer edge
//   (transitions are lowered into layers, helper solids and canvas masks, so their edges are
//   layer edges), merging adjacent ranges whose content simply continues across the cut (a split
//   clip whose halves are identical apart from their id and a seamless map).
// - `rangeHash(plan, range)` is a SHA-256 over a canonical JSON of everything that can change the
//   range's pixels: the layers overlapping the range, clipped to it, with times relative to its
//   start; assets by `fp` (never `uri`, bookmarks or paths; LUT and sprite assets also by id); all
//   params, keyframes (clipped exactly: value entering the range, interior keys, value leaving it)
//   and canvas masks; draw order (list order, never the opaque `z` value); the canvas, `gridFps`
//   and the preview render size. It never includes `rev`, layer ids, `seq` slots, audio or
//   anything outside the range, so an undo that restores a range finds its old hash again.
// - `heavyRanges(plan, budget)`: ranges above the live decode budget, with chroma key, or above
//   the tier's effect-cost threshold.
// - `invalidated(old, new)`: the old hashes no longer present.
// - `rangeTouched(before, after, range)`: the engine's plan-difference rule for rendered ranges
//   (ARCH §12.2; IOS-19 and AND-18 implement it natively), which a range the hash keeps may still
//   fail (FIX-RANGE-RULE): the controller resends after every applied plan.
// - `coverage(plan, lookup, budget)`: rendered / heavyUnrendered / notNeeded per range for the
//   timeline render marker (UX-44).
// - `RenderPolicy`: when the automatic background render may run (tier, setting, idle, charging).
//
// Render-cache files are preview-only: export plans never reference them (compile test in
// test/plan/render_cache/).

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../time/time.dart';
import 'render_plan.dart';

/// Version of the canonical hash input; bump when its layout changes (old entries then miss and
/// age out of the LRU).
const int renderRangeHashVersion = 1;

const DeepCollectionEquality _deepEq = DeepCollectionEquality();

/// Device tier as seen by the render-preview cache (mirrors the engine API's `DeviceTier`, which
/// core cannot import; the session maps one to the other).
enum RenderTier {
  /// < 3 GB RAM (D-40).
  minimal,

  /// Low tier.
  low,

  /// Mid tier.
  mid,

  /// High tier.
  high;

  /// Whether this is minimal or low (automatic rendering, 512 MB cache).
  bool get isConstrained => this == minimal || this == low;
}

/// A half-open plan time range `[start, end)` on the plan's grid.
@immutable
final class PlanRange {
  /// Creates `[start, end)`.
  const PlanRange(this.start, this.end) : assert(end > start);

  /// Inclusive start (µs).
  final TimeUs start;

  /// Exclusive end (µs).
  final TimeUs end;

  /// `end - start`.
  TimeUs get duration => end - start;

  /// As a [TimeRange].
  TimeRange get range => TimeRange(start, end);

  /// Whether this range shares at least one µs with `[start, end)`.
  bool overlapsSpan(TimeUs s, TimeUs e) => start < e && s < end;

  /// Whether this range shares at least one µs with [other].
  bool overlaps(PlanRange other) => overlapsSpan(other.start, other.end);

  @override
  bool operator ==(Object other) => other is PlanRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'PlanRange($start, $end)';
}

/// The size the render-preview job renders at (preview canvas, ≤ `maxPreviewLongSide`).
@immutable
final class RenderSize {
  /// Creates a size in px.
  const RenderSize(this.w, this.h);

  /// Width.
  final int w;

  /// Height.
  final int h;

  @override
  bool operator ==(Object other) => other is RenderSize && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(w, h);

  @override
  String toString() => 'RenderSize($w×$h)';
}

// ---------------------------------------------------------------------------------------------
// (1) splitRanges
// ---------------------------------------------------------------------------------------------

/// Cuts [preview] into ranges on its frame grid at every layer edge (ARCH D-45(A)); adjacent
/// ranges are merged when every layer simply continues across the cut. Ranges cover
/// `[0, durUs)` without gaps (an empty stretch is its own range). Empty for an empty plan.
List<PlanRange> splitRanges(RenderPlan preview) {
  final elementary = _elementary(preview);
  if (elementary.isEmpty) return const [];
  final out = <PlanRange>[];
  var start = elementary.first.start;
  for (var i = 0; i < elementary.length - 1; i++) {
    final left = elementary[i];
    final right = elementary[i + 1];
    if (!_continues(preview, left, right)) {
      out.add(PlanRange(start, left.end));
      start = right.start;
    }
  }
  out.add(PlanRange(start, elementary.last.end));
  return out;
}

/// Elementary interval: a stretch with a constant set of active layers.
final class _Piece {
  _Piece(this.start, this.end, this.layers);
  final TimeUs start;
  final TimeUs end;

  /// Active layers in draw order.
  final List<PlanLayer> layers;
}

List<_Piece> _elementary(RenderPlan plan) {
  final grid = plan.canvas.gridRate;
  final dur = grid.quantize(plan.durUs);
  if (dur <= 0) return const [];
  final cuts = <TimeUs>{0, dur};
  for (final l in plan.layers) {
    for (final t in [l.t0, l.t1]) {
      final q = grid.quantize(t);
      if (q > 0 && q < dur) cuts.add(q);
    }
  }
  final sorted = cuts.toList()..sort();
  return [
    for (var i = 0; i < sorted.length - 1; i++)
      _Piece(sorted[i], sorted[i + 1], [
        for (final l in plan.layers)
          if (l.t0 < sorted[i + 1] && sorted[i] < l.t1) l,
      ]),
  ];
}

bool _continues(RenderPlan plan, _Piece left, _Piece right) {
  if (left.layers.length != right.layers.length) return false;
  final b = left.end;
  for (var i = 0; i < left.layers.length; i++) {
    final l = left.layers[i];
    final r = right.layers[i];
    if (identical(l, r) || (l.id == r.id && l == r)) continue;
    if (l.t1 != b || r.t0 != b || !_sameLook(plan, l, r) || !_mapContinues(l, r)) return false;
  }
  return true;
}

/// Everything except id, timing, `seq` and the map is equal (assets compared by content).
bool _sameLook(RenderPlan plan, PlanLayer l, PlanLayer r) =>
    l.kind == r.kind &&
    _assetKey(plan, l.asset) == _assetKey(plan, r.asset) &&
    l.hold == r.hold &&
    l.color == r.color &&
    l.base == r.base &&
    l.crop == r.crop &&
    l.xf == r.xf &&
    _fxJson(plan, l.fx) == _fxJson(plan, r.fx) &&
    _deepEq.equals(l.anim, r.anim) &&
    const ListEquality<CanvasMask>().equals(l.cmasks, r.cmasks);

bool _mapContinues(PlanLayer l, PlanLayer r) {
  if (l.kind != PlanLayerKind.media) return true;
  if (l.hold || r.hold) return l.hold && r.hold && l.map.first.s0 == r.map.first.s0;
  if (l.map.isEmpty || r.map.isEmpty) return l.map.isEmpty && r.map.isEmpty;
  final a = l.map.last;
  final c = r.map.first;
  if (a.s1 != c.s0) return false;
  // Same rate: (a.s1 - a.s0) / (a.t1 - a.t0) == (c.s1 - c.s0) / (c.t1 - c.t0), exactly.
  return BigInt.from(a.s1 - a.s0) * BigInt.from(c.t1 - c.t0) == BigInt.from(c.s1 - c.s0) * BigInt.from(a.t1 - a.t0);
}

// ---------------------------------------------------------------------------------------------
// (2) rangeHash
// ---------------------------------------------------------------------------------------------

/// SHA-256 (lowercase hex) of the canonical description of [range]'s pixels in [plan] (file
/// header). [previewSize] is the render size of the cached file (default: the plan canvas).
String rangeHash(RenderPlan plan, PlanRange range, {RenderSize? previewSize}) =>
    sha256.convert(utf8.encode(rangeCanonicalJson(plan, range, previewSize: previewSize))).toString();

/// The canonical JSON text hashed by [rangeHash] (exposed for tests and diagnostics).
String rangeCanonicalJson(RenderPlan plan, PlanRange range, {RenderSize? previewSize}) {
  final c = plan.canvas;
  final size = previewSize ?? RenderSize(c.w, c.h);
  final layers = [
    for (final l in plan.layers)
      if (l.t0 < range.end && range.start < l.t1) _clipLayer(plan, l, range),
  ];
  return jsonEncode(<String, Object?>{
    'v': renderRangeHashVersion,
    'canvas': [c.w, c.h, c.fps, c.gridFps, c.bg],
    'size': [size.w, size.h],
    'dur': range.duration,
    'layers': layers,
  });
}

Map<String, Object?> _clipLayer(RenderPlan plan, PlanLayer l, PlanRange range) {
  final a = range.start;
  final b = range.end;
  final t0 = l.t0 > a ? l.t0 : a;
  final t1 = l.t1 < b ? l.t1 : b;
  return <String, Object?>{
    'k': l.kind.name,
    't': [t0 - a, t1 - a],
    if (l.asset != null) 'as': _assetKey(plan, l.asset),
    if (l.kind == PlanLayerKind.media && l.hold && l.map.isNotEmpty) 'hold': l.map.first.s0,
    if (l.kind == PlanLayerKind.media && !l.hold) 'map': _clipMap(l.map, t0, t1, a),
    if (l.color != null) 'col': l.color,
    if (l.base != null) 'base': [_n(l.base!.w), _n(l.base!.h)],
    'crop': [_n(l.crop.l), _n(l.crop.t), _n(l.crop.r), _n(l.crop.b)],
    'xf': [_n(l.xf.cx), _n(l.xf.cy), _n(l.xf.s), _n(l.xf.r), l.xf.fx, l.xf.fy, _n(l.xf.op)],
    'fx': _fxJson(plan, l.fx),
    'anim': _clipAnim(l.anim, a, b),
    'cm': [
      for (final m in l.cmasks)
        [_n(m.cx), _n(m.cy), _n(m.w), _n(m.h), _n(m.r), _n(m.feather), m.inv, _clipAnim(m.anim, a, b)],
    ],
  };
}

/// Canonical asset identity: kind plus content fingerprint and pixel-relevant metadata. LUT and
/// sprite assets also carry their id (content-addressed). Never `uri`, `proxyUri` or bookmarks.
String? _assetKey(RenderPlan plan, String? id) {
  if (id == null) return null;
  final a = plan.assets[id];
  if (a == null) return 'missing:$id';
  final byId = a.kind == PlanAssetKind.lut || a.kind == PlanAssetKind.sprite || a.fp.isEmpty;
  return jsonEncode([
    a.kind.name,
    a.fp,
    if (byId) id,
    a.w,
    a.h,
    a.rot,
    a.transfer.name,
    a.n,
    a.sw,
    a.sh,
    _n(a.sscale),
    a.reveal,
  ]);
}

String _fxJson(RenderPlan plan, PlanEffects fx) {
  final adj = fx.adj;
  final d = fx.detail;
  final lut = fx.lut;
  final ch = fx.chroma;
  final m = fx.mask;
  return jsonEncode([
    adj == null ? null : [for (final v in adj.values) _n(v)],
    d == null ? null : [_n(d.sharpen), _n(d.blur), _n(d.vignette)],
    lut == null ? null : [_assetKey(plan, lut.asset), _n(lut.i)],
    ch == null ? null : [ch.key, _n(ch.sim), _n(ch.smooth), _n(ch.spill)],
    m == null ? null : [m.shape.name, _n(m.cx), _n(m.cy), _n(m.w), _n(m.h), _n(m.r), _n(m.corner), _n(m.feather), _n(m.op), m.inv],
  ]);
}

/// The map restricted to timeline `[t0, t1)`, times relative to [origin], source positions as
/// exact reduced fractions (`"n/d"`), so the result depends only on what the range shows.
List<Object?> _clipMap(List<MapSegment> map, TimeUs t0, TimeUs t1, TimeUs origin) => [
      for (final s in map)
        if (s.t0 < t1 && t0 < s.t1)
          () {
            final c0 = s.t0 > t0 ? s.t0 : t0;
            final c1 = s.t1 < t1 ? s.t1 : t1;
            return [c0 - origin, c1 - origin, _sourceAt(s, c0), _sourceAt(s, c1)];
          }(),
    ];

String _sourceAt(MapSegment s, TimeUs t) {
  final den = BigInt.from(s.t1 - s.t0);
  final num = BigInt.from(s.s0) * den + BigInt.from(t - s.t0) * BigInt.from(s.s1 - s.s0);
  final g = num.gcd(den);
  final n = g == BigInt.zero ? num : num ~/ g;
  final d = g == BigInt.zero ? den : den ~/ g;
  return d == BigInt.one ? '$n' : '$n/$d';
}

/// Channels clipped to `[a, b]`: the value entering the range, every key strictly inside it
/// (relative times) and the value leaving it, each from its neighbouring keys only.
Map<String, Object?> _clipAnim(Map<String, List<AnimKey>> anim, TimeUs a, TimeUs b) {
  final names = anim.keys.toList()..sort();
  return {
    for (final name in names)
      if (anim[name]!.isNotEmpty)
        name: [
          [0, _n(_valueFrom(anim[name]!, a))],
          for (final k in anim[name]!)
            if (k.tUs > a && k.tUs < b) [k.tUs - a, _n(k.v)],
          [b - a, _n(_valueUntil(anim[name]!, b))],
        ],
  };
}

/// Value at and just after [t] (the last key at [t] wins).
double _valueFrom(List<AnimKey> keys, TimeUs t) {
  var lo = -1; // last key with tUs <= t
  for (var i = 0; i < keys.length; i++) {
    if (keys[i].tUs <= t) lo = i;
  }
  if (lo < 0) return keys.first.v;
  if (lo == keys.length - 1 || keys[lo].tUs == t) return keys[lo].v;
  return _lerp(keys[lo], keys[lo + 1], t);
}

/// Left limit at [t] (the value approaching [t] from below; the first key at [t] wins).
double _valueUntil(List<AnimKey> keys, TimeUs t) {
  var hi = keys.length; // first key with tUs >= t
  for (var i = keys.length - 1; i >= 0; i--) {
    if (keys[i].tUs >= t) hi = i;
  }
  if (hi == keys.length) return keys.last.v;
  if (hi == 0 || keys[hi].tUs == t) return keys[hi].v;
  return _lerp(keys[hi - 1], keys[hi], t);
}

double _lerp(AnimKey a, AnimKey b, TimeUs t) => a.v + (b.v - a.v) * (t - a.tUs) / (b.tUs - a.tUs);

/// Canonical number: integral finite doubles as ints (so a codec round trip that turns `1.0` into
/// `1` hashes the same), null stays null.
Object? _n(double? d) {
  if (d == null) return null;
  if (d.isFinite && d == d.truncateToDouble() && d.abs() < 9007199254740992) return d.toInt();
  return d;
}

// ---------------------------------------------------------------------------------------------
// (3) heavyRanges
// ---------------------------------------------------------------------------------------------

/// Why a range is heavy.
enum HeavyReason {
  /// Peak decoder-backed layers above `maxLiveDecoders`, or packed slots above `maxLiveSlots`.
  decoders,

  /// A chroma-keyed layer.
  chromaKey,

  /// Effect cost above `effectCostLimit`.
  effects,
}

/// The live-preview budget of a device (ARCH D-45(A)), built per tier from `EditorCapabilities`
/// by the session ([RenderBudget.forTier]).
@immutable
final class RenderBudget {
  /// Creates a budget.
  const RenderBudget({required this.maxLiveDecoders, this.maxLiveSlots, required this.effectCostLimit})
      : assert(maxLiveDecoders > 0),
        assert(effectCostLimit >= 0);

  /// The budget of [tier]: [maxConcurrentVideoLayers] (default 2 / 3 / 4 / 6) live decoders,
  /// [maxVisualSequences] live slots (Android `maxVisualSequences`; pass null on iOS, where the
  /// composition-track limit is not the binding one), and the tier's effect-cost threshold
  /// ([effectCostLimitFor]).
  factory RenderBudget.forTier(RenderTier tier, {int? maxConcurrentVideoLayers, int? maxVisualSequences}) => RenderBudget(
        maxLiveDecoders: maxConcurrentVideoLayers ?? defaultLiveDecoders(tier),
        maxLiveSlots: maxVisualSequences,
        effectCostLimit: effectCostLimitFor(tier),
      );

  /// D-14 default concurrent decoder-backed layers: 2 minimal / 3 low / 4 mid / 6 high.
  static int defaultLiveDecoders(RenderTier tier) => switch (tier) {
        RenderTier.minimal => 2,
        RenderTier.low => 3,
        RenderTier.mid => 4,
        RenderTier.high => 6,
      };

  /// Effect cost a range may carry and still play live: 2 minimal / 4 low / 6 mid / 8 high (one
  /// unit per blur, sharpen, LUT, mask or chroma key per active layer).
  static int effectCostLimitFor(RenderTier tier) => switch (tier) {
        RenderTier.minimal => 2,
        RenderTier.low => 4,
        RenderTier.mid => 6,
        RenderTier.high => 8,
      };

  /// Most decoder-backed video layers active at one instant.
  final int maxLiveDecoders;

  /// Most distinct packed slots (`seq`) in one range; null = not limiting.
  final int? maxLiveSlots;

  /// Highest effect cost at one instant that still plays live.
  final int effectCostLimit;

  @override
  bool operator ==(Object other) =>
      other is RenderBudget &&
      other.maxLiveDecoders == maxLiveDecoders &&
      other.maxLiveSlots == maxLiveSlots &&
      other.effectCostLimit == effectCostLimit;

  @override
  int get hashCode => Object.hash(maxLiveDecoders, maxLiveSlots, effectCostLimit);
}

/// The load figures of one range.
@immutable
final class RangeLoad {
  /// Creates load figures.
  const RangeLoad({required this.range, required this.peakDecoders, required this.slots, required this.peakEffectCost, required this.chromaKey});

  /// The range.
  final PlanRange range;

  /// Most playing (non-hold) media layers active at one instant.
  final int peakDecoders;

  /// Distinct packed slots of the media layers in the range.
  final int slots;

  /// Highest summed effect cost at one instant.
  final int peakEffectCost;

  /// Whether any layer in the range is chroma-keyed.
  final bool chromaKey;

  /// Why the range is heavy under [budget] (empty when it plays live).
  Set<HeavyReason> reasonsUnder(RenderBudget budget) => {
        if (peakDecoders > budget.maxLiveDecoders || (budget.maxLiveSlots != null && slots > budget.maxLiveSlots!))
          HeavyReason.decoders,
        if (chromaKey) HeavyReason.chromaKey,
        if (peakEffectCost > budget.effectCostLimit) HeavyReason.effects,
      };
}

/// A heavy range and why.
@immutable
final class HeavyRange {
  /// Creates a heavy range.
  HeavyRange(this.range, Set<HeavyReason> reasons) : reasons = Set.unmodifiable(reasons);

  /// The range.
  final PlanRange range;

  /// Non-empty reasons.
  final Set<HeavyReason> reasons;

  @override
  bool operator ==(Object other) => other is HeavyRange && other.range == range && const SetEquality<HeavyReason>().equals(other.reasons, reasons);

  @override
  int get hashCode => Object.hash(range, const SetEquality<HeavyReason>().hash(reasons));

  @override
  String toString() => 'HeavyRange($range, ${reasons.map((r) => r.name).join('|')})';
}

/// Effect cost of one layer: one unit each for blur, sharpen, LUT, item mask and chroma key
/// (static or animated).
int layerEffectCost(PlanLayer l) {
  bool animated(String channel) => l.anim[channel]?.any((k) => k.v != 0) ?? false;
  bool anyAnimated(Iterable<String> channels) => channels.any((c) => l.anim.containsKey(c));
  final d = l.fx.detail;
  var cost = 0;
  if ((d != null && d.blur > 0) || animated('detail.blur')) cost++;
  if ((d != null && d.sharpen > 0) || animated('detail.sharpen')) cost++;
  if (l.fx.lut != null) cost++;
  if (l.fx.mask != null || anyAnimated(PlanChannels.mask)) cost++;
  if (l.fx.chroma != null) cost++;
  return cost;
}

/// Load figures of every range of [splitRanges]`(plan)`.
List<RangeLoad> rangeLoads(RenderPlan plan) {
  final pieces = _elementary(plan);
  final out = <RangeLoad>[];
  var i = 0;
  for (final r in splitRanges(plan)) {
    var peakDec = 0;
    var peakCost = 0;
    var chroma = false;
    final slots = <Object?>{};
    for (; i < pieces.length && pieces[i].start < r.end; i++) {
      final piece = pieces[i];
      var dec = 0;
      var cost = 0;
      for (final l in piece.layers) {
        if (l.kind == PlanLayerKind.media && !l.hold) {
          dec++;
          slots.add(l.seq ?? l.id);
        }
        cost += layerEffectCost(l);
        if (l.fx.chroma != null) chroma = true;
      }
      if (dec > peakDec) peakDec = dec;
      if (cost > peakCost) peakCost = cost;
    }
    out.add(RangeLoad(range: r, peakDecoders: peakDec, slots: slots.length, peakEffectCost: peakCost, chromaKey: chroma));
  }
  return out;
}

/// The ranges of [plan] that cannot play live under [budget] (ARCH D-45(A)), in time order.
List<HeavyRange> heavyRanges(RenderPlan plan, RenderBudget budget) => [
      for (final load in rangeLoads(plan))
        if (load.reasonsUnder(budget).isNotEmpty) HeavyRange(load.range, load.reasonsUnder(budget)),
    ];

// ---------------------------------------------------------------------------------------------
// (4) invalidated
// ---------------------------------------------------------------------------------------------

/// The hashes of every range of [plan] ([splitRanges] order).
List<String> rangeHashes(RenderPlan plan, {RenderSize? previewSize}) =>
    [for (final r in splitRanges(plan)) rangeHash(plan, r, previewSize: previewSize)];

/// The hashes of [oldPlan]'s ranges that no longer occur in [newPlan]: any edit touching a range
/// invalidates its entry, and an undo that restores a range finds its old hash again.
Set<String> invalidated(RenderPlan oldPlan, RenderPlan newPlan, {RenderSize? previewSize}) =>
    rangeHashes(oldPlan, previewSize: previewSize).toSet().difference(rangeHashes(newPlan, previewSize: previewSize).toSet());

/// The engine's rule for a rendered range across the plan change [before] → [after] (ARCH §12.2
/// 'Rendered ranges', D-45 'Contract'; FIX-RANGE-RULE). Native engines see plans, not patches, so
/// IOS-19 (`RenderedRangeRules.changeTouches`) and AND-18 (`RangeTouch.changeTouches`) drop the
/// rendered range `[range.start, range.end)` when the difference of the two plans touches it:
///
/// * the canvas changed (every range);
/// * the duration changed and the range ends after the shorter duration;
/// * an asset [before] had changed or is gone (every range; added assets never touch);
/// * a layer was added whose span overlaps the range, removed whose old span overlaps it, or
///   changed (any field, by id) with its old or its new span overlapping it.
///
/// Audio never touches a range. This is `patchTouchesRange` (API-01's reference rule) applied to
/// the patch equivalent of the difference, so a patch that re-sends an identical layer is
/// invisible here.
///
/// How it relates to the hashes (property-tested in `test/plan/render_cache/range_rule_test.dart`
/// on the shared vectors `test/fixtures/vectors/range_touch.json`): a range the engine keeps shows the same
/// pixels in [after], so `rangeHash(after, range) == rangeHash(before, range)` whenever this is
/// false. The converse does not hold: the engine also drops ranges whose pixels did not change (a
/// ripple, a proxy or `uri` change, a re-split), which the hash keeps; the render-preview
/// controller (UX-44) therefore resends every hash-valid range after each applied plan, bound to
/// that plan.
bool rangeTouched(RenderPlan before, RenderPlan after, PlanRange range) {
  if (before.canvas != after.canvas) return true;
  if (before.durUs != after.durUs && range.end > (before.durUs < after.durUs ? before.durUs : after.durUs)) return true;
  for (final MapEntry(:key, :value) in before.assets.entries) {
    if (after.assets[key] != value) return true;
  }
  final old = {for (final l in before.layers) l.id: l};
  final seen = <String>{};
  for (final l in after.layers) {
    seen.add(l.id);
    final o = old[l.id];
    if (o == null) {
      if (range.overlapsSpan(l.t0, l.t1)) return true;
    } else if (o != l && (range.overlapsSpan(o.t0, o.t1) || range.overlapsSpan(l.t0, l.t1))) {
      return true;
    }
  }
  for (final l in before.layers) {
    if (!seen.contains(l.id) && range.overlapsSpan(l.t0, l.t1)) return true;
  }
  return false;
}

/// The members of [ranges] (rendered ranges bound to [before]) that the engine still holds after
/// it moved to [after] ([rangeTouched] is false), in their order.
List<PlanRange> rangesKept(RenderPlan before, RenderPlan after, Iterable<PlanRange> ranges) =>
    [for (final r in ranges) if (!rangeTouched(before, after, r)) r];

// ---------------------------------------------------------------------------------------------
// (6) coverage
// ---------------------------------------------------------------------------------------------

/// Read access to the cache index that [coverage] needs (implemented by `RenderCacheIndex`).
abstract interface class RenderCacheLookup {
  /// Whether a rendered file for [hash] is indexed.
  bool contains(String hash);
}

/// State of one range on the timeline render marker (UX-44).
enum RangeState {
  /// A rendered file exists; playback uses it.
  rendered,

  /// Heavy and not rendered yet.
  heavyUnrendered,

  /// Plays live; no render needed.
  notNeeded,
}

/// The marker state of one range.
@immutable
final class RangeStatus {
  /// Creates a status.
  RangeStatus({required this.range, required this.hash, required this.state, Set<HeavyReason> reasons = const {}})
      : reasons = Set.unmodifiable(reasons);

  /// The range.
  final PlanRange range;

  /// Its [rangeHash].
  final String hash;

  /// Marker state.
  final RangeState state;

  /// Why it is heavy (empty for a light range).
  final Set<HeavyReason> reasons;

  /// Whether the range is heavy.
  bool get isHeavy => reasons.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is RangeStatus &&
      other.range == range &&
      other.hash == hash &&
      other.state == state &&
      const SetEquality<HeavyReason>().equals(other.reasons, reasons);

  @override
  int get hashCode => Object.hash(range, hash, state, const SetEquality<HeavyReason>().hash(reasons));

  @override
  String toString() => 'RangeStatus($range, ${state.name})';
}

/// One status per range of [plan] for the timeline marker: `rendered` when [lookup] holds the
/// range's hash (heavy or not: the manual action may render any range), else `heavyUnrendered`
/// for heavy ranges and `notNeeded` for the rest.
List<RangeStatus> coverage(RenderPlan plan, RenderCacheLookup lookup, RenderBudget budget, {RenderSize? previewSize}) => [
      for (final load in rangeLoads(plan))
        () {
          final hash = rangeHash(plan, load.range, previewSize: previewSize);
          final reasons = load.reasonsUnder(budget);
          final state = lookup.contains(hash)
              ? RangeState.rendered
              : reasons.isNotEmpty
                  ? RangeState.heavyUnrendered
                  : RangeState.notNeeded;
          return RangeStatus(range: load.range, hash: hash, state: state, reasons: reasons);
        }(),
    ];

// ---------------------------------------------------------------------------------------------
// (7) RenderPolicy
// ---------------------------------------------------------------------------------------------

/// The `editor.renderPreview` setting (ARCH §17.10).
enum RenderPreviewSetting {
  /// Render heavy ranges in the background (minimal/low tiers, idle and charging).
  auto,

  /// Only the manual "Render preview" action renders.
  manual,
}

/// When the render-preview cache renders (ARCH D-45(A), D-43(e) point 4).
abstract final class RenderPolicy {
  /// The editor is idle after this long without playback, an edit or a job.
  static const Duration idleAfter = Duration(seconds: 5);

  /// The tier default of `editor.renderPreview`: Auto on minimal/low, Manual on mid/high.
  static RenderPreviewSetting defaultSetting(RenderTier tier) =>
      tier.isConstrained ? RenderPreviewSetting.auto : RenderPreviewSetting.manual;

  /// Whether the editor counts as idle at [now] given the last playback, edit or job activity.
  static bool isIdle({required DateTime lastActivity, required DateTime now}) => now.difference(lastActivity) >= idleAfter;

  /// Whether heavy ranges may render automatically now: only with [setting] Auto on the minimal
  /// and low tiers, while [idle] and [charging]. Manual never auto-renders; mid/high never
  /// auto-render.
  static bool shouldAutoRender(RenderTier tier, RenderPreviewSetting setting, {required bool idle, required bool charging}) =>
      setting == RenderPreviewSetting.auto && tier.isConstrained && idle && charging;

  /// The manual "Render preview" action is available on every tier.
  static bool manualRenderAllowed(RenderTier tier) => true;
}
