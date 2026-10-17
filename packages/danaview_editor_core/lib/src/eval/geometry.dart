// OWNER: CORE-07
//
// The single implementation of placement math (ARCH §6.1, §11.6 "Place", domain.md §8) used by the
// preview handles (UX-22), the RenderPlan compiler (CORE-30/31), the Dart reference renderer
// (API-03) and the AI tools:
//
// * canvas ↔ normalized conversions: positions are canvas fractions with (0, 0) at the canvas
//   centre; text sizes are points at a 1,080 px canvas short side;
// * [baseSize]: the size in canvas px of the cropped, display-oriented source after the fit mode,
//   before the transform (the plan's `base`);
// * the placement matrix
//   `M = T(cx, cy) · R(r° clockwise, y down) · S(s·(fx ? −1 : 1), s·(fy ? −1 : 1)) · T(−base.w/2, −base.h/2)`
//   ([placementMatrix]), which maps base-local px `[0, base.w] × [0, base.h]` to canvas px;
// * [boxAt]: the oriented box of an item at a timeline time (keyframes and text animation
//   evaluated), its inverse mapping and hit tests.
//
// Pure Dart: no Flutter types. The UI converts [Offset2]/[Size2] to `Offset`/`Size` at its edge.

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/keyframes/property_keys.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/subtitle.dart';
import '../model/track.dart';
import '../model/visual_props.dart';
import '../plan/render_plan.dart';
import '../time/time.dart';
import 'evaluate.dart';
import 'text_animation_eval.dart';
import 'text_layout_spec.dart';

/// Canvas short side, in px, at which text sizes in points equal px (ARCH §6.1).
const double textReferenceShortSidePx = 1080;

/// Vertical safe margin of subtitle cues placed at the bottom or top, as a fraction of the canvas
/// height (ARCH §6.6 `SubtitlePosition`).
const double subtitleSafeMargin = 0.06;

// ---------------------------------------------------------------------------------------------
// Value types.
// ---------------------------------------------------------------------------------------------

/// A size in canvas px (or any 2-D extent). Pure-Dart stand-in for Flutter's `Size`.
@immutable
final class Size2 {
  /// Creates `width × height`.
  const Size2(this.width, this.height);

  /// `0 × 0`.
  static const Size2 zero = Size2(0, 0);

  /// Width.
  final double width;

  /// Height.
  final double height;

  /// `min(width, height)`.
  double get shortSide => width < height ? width : height;

  /// `max(width, height)`.
  double get longSide => width > height ? width : height;

  /// Whether both sides are finite and positive.
  bool get isPositive => width > 0 && height > 0 && width.isFinite && height.isFinite;

  /// This size scaled by [f] on both axes.
  Size2 operator *(double f) => Size2(width * f, height * f);

  @override
  bool operator ==(Object other) => other is Size2 && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Size2($width, $height)';
}

/// A point or vector in canvas px (y grows downward). Pure-Dart stand-in for Flutter's `Offset`.
@immutable
final class Offset2 {
  /// Creates `(dx, dy)`.
  const Offset2(this.dx, this.dy);

  /// `(0, 0)`.
  static const Offset2 zero = Offset2(0, 0);

  /// Horizontal component.
  final double dx;

  /// Vertical component (down is positive).
  final double dy;

  /// Component-wise sum.
  Offset2 operator +(Offset2 o) => Offset2(dx + o.dx, dy + o.dy);

  /// Component-wise difference.
  Offset2 operator -(Offset2 o) => Offset2(dx - o.dx, dy - o.dy);

  /// Scaled by [f].
  Offset2 operator *(double f) => Offset2(dx * f, dy * f);

  /// Euclidean length.
  double get distance => math.sqrt(dx * dx + dy * dy);

  @override
  bool operator ==(Object other) => other is Offset2 && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'Offset2($dx, $dy)';
}

/// An axis-aligned rectangle `[left, right) × [top, bottom)` in canvas px.
@immutable
final class Rect2 {
  /// Creates a rectangle from its edges.
  const Rect2(this.left, this.top, this.right, this.bottom);

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Right edge.
  final double right;

  /// Bottom edge.
  final double bottom;

  /// `right − left`.
  double get width => right - left;

  /// `bottom − top`.
  double get height => bottom - top;

  /// Centre point.
  Offset2 get center => Offset2((left + right) / 2, (top + bottom) / 2);

  /// Whether [p] lies inside (edges included).
  bool contains(Offset2 p) => p.dx >= left && p.dx <= right && p.dy >= top && p.dy <= bottom;

  @override
  bool operator ==(Object other) =>
      other is Rect2 && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Rect2($left, $top, $right, $bottom)';
}

/// The cosine and sine of [deg] degrees, exact (0, ±1) at multiples of 90°.
(double cos, double sin) cosSinDeg(double deg) {
  final r = deg % 360; // in [0, 360) for finite deg
  if (r == 0) return (1.0, 0.0);
  if (r == 90) return (0.0, 1.0);
  if (r == 180) return (-1.0, 0.0);
  if (r == 270) return (0.0, -1.0);
  final rad = deg * math.pi / 180;
  return (math.cos(rad), math.sin(rad));
}

/// A 2-D affine transform mapping `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)` (column-vector
/// convention, y down). `A * B` applies `B` first.
@immutable
final class Affine2 {
  /// Creates the transform with the given coefficients.
  const Affine2(this.a, this.b, this.c, this.d, this.tx, this.ty);

  /// The identity.
  static const Affine2 identity = Affine2(1, 0, 0, 1, 0, 0);

  /// Translation by `(dx, dy)`.
  const Affine2.translation(double dx, double dy) : this(1, 0, 0, 1, dx, dy);

  /// Scale by `(sx, sy)` about the origin.
  const Affine2.scaling(double sx, double sy) : this(sx, 0, 0, sy, 0, 0);

  /// Rotation by [deg] degrees **clockwise on a y-down canvas** (counter-clockwise in y-up maths):
  /// `(1, 0)` rotated by 90° becomes `(0, 1)`. Exact at multiples of 90°.
  factory Affine2.rotationDeg(double deg) {
    final (cos, sin) = cosSinDeg(deg);
    return Affine2(cos, sin, -sin, cos, 0, 0);
  }

  /// x coefficient of x'.
  final double a;

  /// x coefficient of y'.
  final double b;

  /// y coefficient of x'.
  final double c;

  /// y coefficient of y'.
  final double d;

  /// x translation.
  final double tx;

  /// y translation.
  final double ty;

  /// `this ∘ other`: applies [other] first, then this.
  Affine2 operator *(Affine2 o) => Affine2(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.tx + c * o.ty + tx,
        b * o.tx + d * o.ty + ty,
      );

  /// Maps the point [p].
  Offset2 apply(Offset2 p) => Offset2(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);

  /// Maps the vector [v] (no translation).
  Offset2 applyVector(Offset2 v) => Offset2(a * v.dx + c * v.dy, b * v.dx + d * v.dy);

  /// `a·d − b·c`.
  double get determinant => a * d - b * c;

  /// The inverse transform, or null when the transform is singular (zero scale).
  Affine2? inverse() {
    final det = determinant;
    if (det == 0 || !det.isFinite) return null;
    final ia = d / det;
    final ib = -b / det;
    final ic = -c / det;
    final id = a / det;
    return Affine2(ia, ib, ic, id, -(ia * tx + ic * ty), -(ib * tx + id * ty));
  }

  /// Whether every coefficient is within [eps] of [other]'s.
  bool closeTo(Affine2 other, [double eps = 1e-9]) =>
      (a - other.a).abs() <= eps &&
      (b - other.b).abs() <= eps &&
      (c - other.c).abs() <= eps &&
      (d - other.d).abs() <= eps &&
      (tx - other.tx).abs() <= eps &&
      (ty - other.ty).abs() <= eps;

  @override
  bool operator ==(Object other) =>
      other is Affine2 &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.tx == tx &&
      other.ty == ty;

  @override
  int get hashCode => Object.hash(a, b, c, d, tx, ty);

  @override
  String toString() => 'Affine2(a: $a, b: $b, c: $c, d: $d, tx: $tx, ty: $ty)';
}

// ---------------------------------------------------------------------------------------------
// Canvas conversions.
// ---------------------------------------------------------------------------------------------

/// Pixel geometry of a [CanvasSpec].
extension CanvasSpecGeometry on CanvasSpec {
  /// The canvas size in px.
  Size2 get sizePx => Size2(widthPx.toDouble(), heightPx.toDouble());

  /// Canvas px per text point: `min(W, H) / 1080`.
  double get pxPerPoint => pxPerPointOf(sizePx);
}

/// Canvas px per text point for a canvas of [canvas] px: `min(W, H) / 1080`.
double pxPerPointOf(Size2 canvas) => canvas.shortSide / textReferenceShortSidePx;

/// A text size in points converted to canvas px.
double pointsToPx(double points, Size2 canvas) => points * pxPerPointOf(canvas);

/// A canvas px length converted to text points.
double pxToPoints(double px, Size2 canvas) => px / pxPerPointOf(canvas);

/// The canvas px of a normalized [position] (canvas fractions, (0, 0) = centre):
/// `(W/2 + x·W, H/2 + y·H)`.
Offset2 positionToCanvas(Vec2 position, Size2 canvas) =>
    Offset2(canvas.width / 2 + position.x * canvas.width, canvas.height / 2 + position.y * canvas.height);

/// The normalized position (canvas fractions, (0, 0) = centre) of the canvas point [p]; the
/// inverse of [positionToCanvas].
Vec2 canvasToPosition(Offset2 p, Size2 canvas) =>
    Vec2((p.dx - canvas.width / 2) / canvas.width, (p.dy - canvas.height / 2) / canvas.height);

// ---------------------------------------------------------------------------------------------
// Base size and the placement matrix.
// ---------------------------------------------------------------------------------------------

/// The display-oriented size of a probed source (rotation already applied by the probe), or null
/// when the probe has no positive picture size (audio, unknown).
Size2? sourceDisplaySize(MediaProbe probe) {
  final w = probe.width;
  final h = probe.height;
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return Size2(w.toDouble(), h.toDouble());
}

/// The size in canvas px of the [crop]ped, display-oriented [source] after [fit] into [canvas],
/// before the item transform (the plan layer's `base`, ARCH §11.2, §11.6 "Place"):
///
/// * the cropped size is `(source.w·(r − l), source.h·(b − t))`;
/// * `fit` scales it uniformly by `min(W/cw, H/ch)` (letterbox), `fill` by `max(…)` (cover);
/// * `stretch` returns the canvas size.
///
/// Throws [ArgumentError] when the source, the crop or the canvas has no positive area.
Size2 baseSize({required FitMode fit, CropRect crop = CropRect.full, required Size2 source, required Size2 canvas}) {
  if (!source.isPositive) throw ArgumentError.value(source, 'source', 'must have a positive area');
  if (!canvas.isPositive) throw ArgumentError.value(canvas, 'canvas', 'must have a positive area');
  final cw = source.width * (crop.right - crop.left);
  final ch = source.height * (crop.bottom - crop.top);
  if (!(cw > 0 && ch > 0)) throw ArgumentError.value(crop, 'crop', 'must keep a positive area');
  switch (fit) {
    case FitMode.stretch:
      return canvas;
    case FitMode.fit:
    case FitMode.fill:
      final sx = canvas.width / cw;
      final sy = canvas.height / ch;
      final s = fit == FitMode.fit ? (sx < sy ? sx : sy) : (sx > sy ? sx : sy);
      // The constrained side equals the canvas side exactly (no rounding drift).
      if (s == sx) return Size2(canvas.width, ch * s);
      return Size2(cw * s, canvas.height);
  }
}

/// The placement matrix of ARCH §11.6 "Place":
/// `M = T(center) · R(rotationDeg clockwise, y down) · S(s·(flipH ? −1 : 1), s·(flipV ? −1 : 1)) · T(−base.w/2, −base.h/2)`.
///
/// It maps base-local px (`(0, 0)` = top-left of the cropped, fitted source before flips) to canvas
/// px. The Metal and GLSL kernels, the Dart reference renderer and [boxAt] all use this matrix.
Affine2 placementMatrix({
  required Offset2 center,
  required Size2 base,
  double scale = 1,
  double rotationDeg = 0,
  bool flipH = false,
  bool flipV = false,
}) {
  final (cos, sin) = cosSinDeg(rotationDeg);
  final sx = flipH ? -scale : scale;
  final sy = flipV ? -scale : scale;
  final a = cos * sx;
  final b = sin * sx;
  final c = -sin * sy;
  final d = cos * sy;
  final hw = base.width / 2;
  final hh = base.height / 2;
  return Affine2(a, b, c, d, center.dx - (a * hw + c * hh), center.dy - (b * hw + d * hh));
}

/// [placementMatrix] of a plan layer's `xf` and `base` on a canvas of [canvas] px (a null centre
/// means the canvas centre, ARCH §11.2 defaults).
Affine2 planPlacementMatrix(PlanTransform xf, PlanSize base, Size2 canvas) => placementMatrix(
      center: Offset2(xf.cx ?? canvas.width / 2, xf.cy ?? canvas.height / 2),
      base: Size2(base.w, base.h),
      scale: xf.s,
      rotationDeg: xf.r,
      flipH: xf.fx,
      flipV: xf.fy,
    );

// ---------------------------------------------------------------------------------------------
// Item boxes.
// ---------------------------------------------------------------------------------------------

/// The oriented box of an item on the canvas at one time (domain.md §8, ux.md §7.2), in canvas px.
///
/// The box is the [base] rectangle placed by [matrix]: scaled by [scale], flipped, rotated
/// [rotationDeg] clockwise about its centre and centred at [center]. [opacity] is the evaluated
/// layer opacity (it does not affect hit testing).
@immutable
final class ItemBox {
  /// Creates a box.
  const ItemBox({
    required this.center,
    required this.base,
    this.scale = 1,
    this.rotationDeg = 0,
    this.flipH = false,
    this.flipV = false,
    this.opacity = 1,
  });

  /// Centre in canvas px.
  final Offset2 center;

  /// Size before the transform (the plan's `base`), canvas px.
  final Size2 base;

  /// Uniform scale.
  final double scale;

  /// Clockwise rotation in degrees (y down).
  final double rotationDeg;

  /// Horizontal mirror.
  final bool flipH;

  /// Vertical mirror.
  final bool flipV;

  /// Evaluated opacity in [0, 1].
  final double opacity;

  /// The placed size `base × |scale|` (before rotation).
  Size2 get size => base * scale.abs();

  /// The placement matrix from base-local px to canvas px ([placementMatrix]).
  Affine2 get matrix => placementMatrix(
        center: center,
        base: base,
        scale: scale,
        rotationDeg: rotationDeg,
        flipH: flipH,
        flipV: flipV,
      );

  /// The four corners in canvas px, in base-local order: (0, 0), (w, 0), (w, h), (0, h).
  List<Offset2> get corners {
    final m = matrix;
    return [
      m.apply(Offset2.zero),
      m.apply(Offset2(base.width, 0)),
      m.apply(Offset2(base.width, base.height)),
      m.apply(Offset2(0, base.height)),
    ];
  }

  /// The axis-aligned bounds of the rotated box.
  Rect2 get bounds {
    final cs = corners;
    var l = cs[0].dx, r = cs[0].dx, t = cs[0].dy, b = cs[0].dy;
    for (final p in cs.skip(1)) {
      if (p.dx < l) l = p.dx;
      if (p.dx > r) r = p.dx;
      if (p.dy < t) t = p.dy;
      if (p.dy > b) b = p.dy;
    }
    return Rect2(l, t, r, b);
  }

  /// The base-local px of the canvas point [p] (inverse of [matrix]), or null when the box is
  /// degenerate (zero scale or base).
  Offset2? toLocal(Offset2 p) {
    if (!(base.width > 0 && base.height > 0)) return null;
    return matrix.inverse()?.apply(p);
  }

  /// The layer-normalized coordinates (`[0, 1]²` over [base], the coordinates of item masks) of the
  /// canvas point [p], or null when the box is degenerate.
  Offset2? toLocalNormalized(Offset2 p) {
    final l = toLocal(p);
    return l == null ? null : Offset2(l.dx / base.width, l.dy / base.height);
  }

  /// The canvas point of the layer-normalized coordinates [n] (inverse of [toLocalNormalized]).
  Offset2 fromLocalNormalized(Offset2 n) => matrix.apply(Offset2(n.dx * base.width, n.dy * base.height));

  /// Whether the canvas point [p] lies inside the box, edges included (to within floating-point
  /// rounding), grown by [slop] canvas px on every side.
  bool contains(Offset2 p, {double slop = 0}) {
    final l = toLocal(p);
    if (l == null) return false;
    final s = scale.abs();
    final ls = (s == 0 ? 0.0 : slop / s) + 1e-9 * (base.width > base.height ? base.width : base.height);
    return l.dx >= -ls && l.dx <= base.width + ls && l.dy >= -ls && l.dy <= base.height + ls;
  }

  @override
  bool operator ==(Object other) =>
      other is ItemBox &&
      other.center == center &&
      other.base == base &&
      other.scale == scale &&
      other.rotationDeg == rotationDeg &&
      other.flipH == flipH &&
      other.flipV == flipV &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(center, base, scale, rotationDeg, flipH, flipV, opacity);

  @override
  String toString() =>
      'ItemBox(center: $center, base: $base, scale: $scale, rotation: $rotationDeg, flipH: $flipH, flipV: $flipV)';
}

/// Measures laid-out text (implemented in the app with `ui.Paragraph` through API-04's
/// `TextLayoutEngine`, so handles match the rendered pixels).
abstract interface class TextMetricsProvider {
  /// The size in canvas px of [spec] laid out, background box padding included.
  Size2 measure(TextLayoutSpec spec);
}

/// The canvas-px centre of a subtitle cue block of [measured] size placed at [position] on a
/// canvas of [canvas] px: horizontally centred; `bottom` puts the block's bottom edge
/// [subtitleSafeMargin]·H above the canvas bottom, `top` its top edge that far below the top,
/// `custom(y)` its centre at `y·H`.
Offset2 cueCenter(Size2 measured, SubtitlePosition position, Size2 canvas) {
  final x = canvas.width / 2;
  final margin = subtitleSafeMargin * canvas.height;
  return switch (position) {
    BottomSubtitlePosition() => Offset2(x, canvas.height - margin - measured.height / 2),
    TopSubtitlePosition() => Offset2(x, margin + measured.height / 2),
    CustomSubtitlePosition(:final yFraction) => Offset2(x, yFraction * canvas.height),
  };
}

/// The box of [item] at timeline time [t] (absolute µs) on a project with [settings] and [pool],
/// or null when it has no visual box:
///
/// * media clips: null without visual props (audio lanes) or when the asset is missing or has no
///   picture size (a derived still or rendition without its own size uses its source's);
///   otherwise `baseSize(fit, crop, source)` placed by the keyframe-evaluated transform
///   (position, scale, rotation, opacity at `t − item.start`);
/// * text items: null without [text]; the base is the measured [textLayoutSpecOf], the transform
///   is keyframe-evaluated, and the text animation ([evaluateTextAnimation]) adds its offset and
///   multiplies scale and opacity; flips are ignored;
/// * subtitle cues: null without [text] or [subtitle]; the measured [cueLayoutSpecOf] block placed
///   by [cueCenter].
///
/// [t] is not clamped to the item (keyframes hold outside their range).
ItemBox? itemBoxAt(
  TimelineItem item,
  TimeUs t, {
  required ProjectSettings settings,
  MediaPool pool = MediaPool.empty,
  SubtitleTrackData? subtitle,
  TextMetricsProvider? text,
}) {
  final canvas = settings.canvas.sizePx;
  final local = t - item.start;
  switch (item) {
    case MediaClip(:final visual):
      if (visual == null) return null;
      final asset = pool[item.media];
      if (asset == null) return null;
      final source = _pictureSize(asset, pool);
      if (source == null) return null;
      final crop = visual.crop;
      if (!(crop.right > crop.left && crop.bottom > crop.top)) return null;
      final base = baseSize(fit: visual.fit, crop: crop, source: source, canvas: canvas);
      return ItemBox(
        center: positionToCanvas(evaluate(item, PropertyKeys.position, local), canvas),
        base: base,
        scale: evaluate(item, PropertyKeys.scale, local),
        rotationDeg: evaluate(item, PropertyKeys.rotation, local),
        flipH: visual.transform.flipH,
        flipV: visual.transform.flipV,
        opacity: evaluate(item, PropertyKeys.opacity, local),
      );
    case TextItem():
      if (text == null) return null;
      final base = text.measure(textLayoutSpecOf(item, settings.canvas));
      final anim = evaluateTextAnimation(item, t, settings.canvas);
      return ItemBox(
        center: positionToCanvas(evaluate(item, PropertyKeys.position, local), canvas) + anim.offset,
        base: base,
        scale: evaluate(item, PropertyKeys.scale, local) * anim.scale,
        rotationDeg: evaluate(item, PropertyKeys.rotation, local),
        opacity: evaluate(item, PropertyKeys.opacity, local) * anim.opacity,
      );
    case SubtitleCue():
      if (text == null || subtitle == null) return null;
      final base = text.measure(cueLayoutSpecOf(item, subtitle, settings.canvas));
      return ItemBox(center: cueCenter(base, subtitle.position, canvas), base: base);
  }
}

/// The picture size of [asset], falling back to the source of a derived asset (a pending
/// freeze still or reversed rendition has the size of the media it is made from).
Size2? _pictureSize(MediaAsset asset, MediaPool pool) {
  final own = sourceDisplaySize(asset.probe);
  if (own != null) return own;
  final source = switch (asset.derived) {
    StillSpec(:final media) => pool[media],
    ReversedSpec(:final media) => pool[media],
    null => null,
  };
  return source == null ? null : sourceDisplaySize(source.probe);
}

/// The box of the item [id] of [project] at timeline time [t] (absolute µs), or null when the
/// item does not exist or has no visual box ([itemBoxAt]). Keyframes and the text animation are
/// evaluated at `t` (domain.md §8, ux.md §7.2).
ItemBox? boxAt(EditProject project, ItemId id, TimeUs t, {TextMetricsProvider? text}) {
  final loc = project.index.locate(id);
  if (loc == null) return null;
  return itemBoxAt(
    loc.item,
    t,
    settings: project.settings,
    pool: project.pool,
    subtitle: loc.track.subtitle,
    text: text,
  );
}

/// The items whose box contains the canvas point [p] at timeline time [t], topmost first
/// (subtitle, text, overlay and video lanes from top to bottom of the composite, ARCH §11.4).
///
/// Only items active at `t` (`start ≤ t < end`) on visible lanes are considered; text items and
/// cues need [text]. [slop] grows every box by that many canvas px.
List<ItemId> hitTestAll(EditProject project, Offset2 p, TimeUs t, {TextMetricsProvider? text, double slop = 0}) {
  final out = <ItemId>[];
  final tracks = project.tracks;
  for (var i = tracks.length - 1; i >= 0; i--) {
    final track = tracks[i];
    if (!track.kind.isVisual || track.hidden) continue;
    final item = _activeItem(track, t);
    if (item == null) continue;
    final box = itemBoxAt(
      item,
      t,
      settings: project.settings,
      pool: project.pool,
      subtitle: track.subtitle,
      text: text,
    );
    if (box != null && box.contains(p, slop: slop)) out.add(item.id);
  }
  return out;
}

/// The topmost item whose box contains the canvas point [p] at timeline time [t] ([hitTestAll]),
/// or null.
ItemId? hitTest(EditProject project, Offset2 p, TimeUs t, {TextMetricsProvider? text, double slop = 0}) {
  final all = hitTestAll(project, p, t, text: text, slop: slop);
  return all.isEmpty ? null : all.first;
}

/// The item of [track] active at [t] (binary search; items are sorted and non-overlapping).
TimelineItem? _activeItem(Track track, TimeUs t) {
  final items = track.items;
  var lo = 0;
  var hi = items.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (items[mid].start <= t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo == 0) return null;
  final item = items[lo - 1];
  return t < item.end ? item : null;
}
