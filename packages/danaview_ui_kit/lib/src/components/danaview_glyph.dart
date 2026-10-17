import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/danaview_theme.dart';

/// Icons Danaview draws itself, in the language of the brand mark: solid rounded shapes whose
/// details (the play triangle, a plus, a slash) are cut through to whatever is behind them.
enum DanaviewGlyphKind {
  /// A phone with the play mark on its screen: the app's own video storage ("On This Device").
  device,

  /// A closed folder.
  folder,

  /// An open folder, for open and browse actions.
  folderOpen,

  /// A folder with a plus cut out of its front, for adding a folder.
  folderAdd,

  /// A slashed folder, for a folder that is missing or can't be opened.
  folderOff,

  /// A folder with the play mark cut out of its front: a library folder of videos.
  folderVideo,
}

/// Draws a [DanaviewGlyphKind] in one colour; sized, themed and hit-tested like [Icon], though it
/// reports no text baseline.
///
/// [size] and [color] fall back to the ambient [IconTheme], whose opacity also applies. The glyph
/// is drawn at [size] centred in its box (smaller only when the constraints are), never paints
/// outside it, and is decorative unless [semanticLabel] is set. Depth comes from [color] alone:
/// a folder's back plate uses [DanaviewGlyphPainter.backAlphaFor] of its alpha, and since the
/// layers never overlap, translucent colours stay even.
///
/// With [pixelSnap], straight edges land on the device pixel grid while the glyph is only
/// translated relative to the screen. The grid is read when the glyph paints; a glyph painted
/// under a scale or rotation (a dialog's opening zoom) checks again after each frame and repaints
/// snapped once only a translation is left. A cached layer that later moves by a fraction of a
/// pixel (a list item scrolled behind its repaint boundary) stays plainly anti-aliased until the
/// next paint.
class DanaviewGlyph extends StatelessWidget {
  const DanaviewGlyph(
    this.kind, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.pixelSnap = true,
  });

  final DanaviewGlyphKind kind;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// Turn off for a glyph that slides around, so its edges don't shift by a fraction of a pixel
  /// when it comes to rest.
  final bool pixelSnap;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final opacity = (iconTheme.opacity ?? 1).clamp(0.0, 1.0);
    var glyphColor = color ?? iconTheme.color ?? DanaviewColors.textSecondary;
    if (opacity < 1) glyphColor = glyphColor.withValues(alpha: glyphColor.a * opacity);

    final Widget glyph = _DanaviewGlyphBox(
      kind: kind,
      glyphSize: size ?? iconTheme.size ?? 24,
      color: glyphColor,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? View.maybeOf(context)?.devicePixelRatio ?? 1,
      pixelSnap: pixelSnap,
    );
    if (semanticLabel == null) return ExcludeSemantics(child: glyph);
    return Semantics(label: semanticLabel, image: true, child: ExcludeSemantics(child: glyph));
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(EnumProperty<DanaviewGlyphKind>('kind', kind))
      ..add(DoubleProperty('size', size, defaultValue: null))
      ..add(ColorProperty('color', color, defaultValue: null))
      ..add(StringProperty('semanticLabel', semanticLabel, defaultValue: null))
      ..add(FlagProperty('pixelSnap', value: pixelSnap, ifFalse: 'unsnapped'));
  }
}

/// Paints a [DanaviewGlyphKind] centred in the largest square of the canvas, for drawing a glyph
/// outside the widget tree (into an image, say). On screen use [DanaviewGlyph], which caches the
/// geometry and snaps to the screen's own pixel grid.
///
/// When [devicePixelRatio] is above 0, straight edges snap to that many pixels per logical
/// pixel, counted from the canvas origin, which must therefore sit on a whole device pixel.
class DanaviewGlyphPainter extends CustomPainter {
  const DanaviewGlyphPainter({required this.kind, required this.color, this.devicePixelRatio = 0});

  final DanaviewGlyphKind kind;
  final Color color;
  final double devicePixelRatio;

  /// Least share of the colour's alpha used for a folder's back plate.
  static const double backAlpha = 0.62;

  /// Most share of the colour's alpha used for a folder's back plate, which keeps it paler than
  /// the front.
  static const double maxBackAlpha = 0.8;

  /// Share of [color]'s alpha for a folder's back plate, which carries the tab that makes the shape
  /// read as a folder: [backAlpha], raised for darker colours (up to [maxBackAlpha]) until the
  /// plate keeps 3:1 against a tile tinted with the colour over [DanaviewColors.surfaceElevated], the
  /// lightest surface such tiles sit on.
  static double backAlphaFor(Color color) {
    final opaque = color.withValues(alpha: 1);
    final tile = Color.alphaBlend(opaque.withValues(alpha: 0.16), DanaviewColors.surfaceElevated);
    var alpha = backAlpha;
    while (alpha < maxBackAlpha && DanaviewColors.contrastRatio(opaque.withValues(alpha: alpha), tile) < 3) {
      alpha = math.min(maxBackAlpha, alpha + 0.02);
    }
    return alpha;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || color.a == 0) return;
    final grid = _Grid(size, size.shortestSide, devicePixelRatio, devicePixelRatio > 0 ? Offset.zero : null);
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    _paintLayers(canvas, _layers(kind, grid), color, backAlphaFor(color));
    canvas.restore();
  }

  @override
  bool shouldRepaint(DanaviewGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color || oldDelegate.devicePixelRatio != devicePixelRatio;
}

class _DanaviewGlyphBox extends LeafRenderObjectWidget {
  const _DanaviewGlyphBox({
    required this.kind,
    required this.glyphSize,
    required this.color,
    required this.devicePixelRatio,
    required this.pixelSnap,
  });

  final DanaviewGlyphKind kind;
  final double glyphSize;
  final Color color;
  final double devicePixelRatio;
  final bool pixelSnap;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDanaviewGlyph(
        kind: kind,
        glyphSize: glyphSize,
        color: color,
        devicePixelRatio: devicePixelRatio,
        pixelSnap: pixelSnap,
      );

  @override
  void updateRenderObject(BuildContext context, _RenderDanaviewGlyph renderObject) {
    renderObject
      ..kind = kind
      ..glyphSize = glyphSize
      ..color = color
      ..devicePixelRatio = devicePixelRatio
      ..pixelSnap = pixelSnap;
  }
}

class _RenderDanaviewGlyph extends RenderBox {
  _RenderDanaviewGlyph({
    required DanaviewGlyphKind kind,
    required double glyphSize,
    required Color color,
    required double devicePixelRatio,
    required bool pixelSnap,
  })  : _kind = kind,
        _glyphSize = glyphSize,
        _color = color,
        _devicePixelRatio = devicePixelRatio,
        _pixelSnap = pixelSnap;

  DanaviewGlyphKind _kind;
  set kind(DanaviewGlyphKind value) {
    if (value == _kind) return;
    _kind = value;
    markNeedsPaint();
  }

  double _glyphSize;
  set glyphSize(double value) {
    if (value == _glyphSize) return;
    _glyphSize = value;
    markNeedsLayout();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    _backAlpha = null;
    markNeedsPaint();
  }

  double? _backAlpha;

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _pixelSnap;
  set pixelSnap(bool value) {
    if (value == _pixelSnap) return;
    _pixelSnap = value;
    markNeedsPaint();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(Size.square(_glyphSize));

  @override
  void performLayout() => size = computeDryLayout(constraints);

  @override
  double computeMinIntrinsicWidth(double height) => _glyphSize;

  @override
  double computeMaxIntrinsicWidth(double height) => _glyphSize;

  @override
  double computeMinIntrinsicHeight(double width) => _glyphSize;

  @override
  double computeMaxIntrinsicHeight(double width) => _glyphSize;

  @override
  bool hitTestSelf(Offset position) => true;

  /// Transform to the screen when snapping applies at all. It stops below the root view, so it
  /// excludes the view's device pixel ratio scale.
  Matrix4? _screenTransform() {
    assert(attached);
    if (!_pixelSnap || owner?.rootNode == null) return null;
    return getTransformTo(null);
  }

  /// Logical position on the screen while [transform] only translates, else null: under a scale,
  /// rotation or perspective the device grid is unknown.
  static Offset? _translation(Matrix4 transform) {
    final m = transform.storage;
    bool near(double a, double b) => (a - b).abs() < 1e-6;
    for (final i in const [1, 2, 3, 4, 6, 7, 8, 9, 11]) {
      if (!near(m[i], 0)) return null;
    }
    if (!near(m[0], 1) || !near(m[5], 1) || !near(m[10], 1) || !near(m[15], 1)) return null;
    return Offset(m[12], m[13]);
  }

  // A glyph painted under a scale often sits behind a repaint boundary that the transition then
  // only moves (a dialog's or menu's opening zoom), so nothing would repaint it once the zoom ends.
  // Check after each frame instead, repaint once only a translation is left, and give up when the
  // transform holds still for a few frames (a lasting scale).
  bool _paintedUnsnapped = false;
  bool _recheckScheduled = false;
  Matrix4? _recheckTransform;
  int _stillFrames = 0;

  void _scheduleSnapRecheck() {
    if (_recheckScheduled) return;
    _recheckScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _recheckScheduled = false;
      if (!attached || !_paintedUnsnapped) return;
      final transform = _screenTransform();
      if (transform == null) return;
      if (_translation(transform) != null) {
        markNeedsPaint();
        return;
      }
      _stillFrames = transform == _recheckTransform ? _stillFrames + 1 : 0;
      _recheckTransform = transform;
      if (_stillFrames < 3) _scheduleSnapRecheck();
    }, debugLabel: 'DanaviewGlyph.snapRecheck');
  }

  // Geometry depends only on the kind, the box, the ratio and the origin's sub-pixel phase, so
  // repaints (a colour change, a parent repaint, an animation) reuse the paths.
  Object? _layersKey;
  List<_Layer> _layersCache = const [];

  @override
  void paint(PaintingContext context, Offset offset) {
    final side = math.min(_glyphSize, size.shortestSide);
    if (side <= 0 || _color.a == 0) return;
    final transform = _screenTransform();
    final origin = transform == null ? null : _translation(transform);
    _paintedUnsnapped = transform != null && origin == null;
    if (_paintedUnsnapped) {
      _scheduleSnapRecheck();
    } else {
      _recheckTransform = null;
      _stillFrames = 0;
    }
    final grid = _Grid(size, side, _devicePixelRatio, origin);
    final key = (_kind, size, side, grid.dpr, grid.snapping, grid.gx, grid.gy);
    if (key != _layersKey) {
      _layersCache = _layers(_kind, grid);
      _layersKey = key;
    }
    final canvas = context.canvas
      ..save()
      ..clipRect(offset & size)
      ..translate(offset.dx, offset.dy);
    _paintLayers(canvas, _layersCache, _color, _backAlpha ??= DanaviewGlyphPainter.backAlphaFor(_color));
    canvas.restore();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(EnumProperty<DanaviewGlyphKind>('kind', _kind))
      ..add(DoubleProperty('glyphSize', _glyphSize))
      ..add(ColorProperty('color', _color))
      ..add(DoubleProperty('devicePixelRatio', _devicePixelRatio))
      ..add(FlagProperty('pixelSnap', value: _pixelSnap, ifFalse: 'unsnapped'));
  }
}

void _paintLayers(Canvas canvas, List<_Layer> layers, Color color, double backAlpha) {
  final paint = Paint();
  for (final layer in layers) {
    canvas.drawPath(layer.path, paint..color = color.withValues(alpha: color.a * (layer.back ? backAlpha : 1)));
  }
}

// ---------------------------------------------------------------------------
// Geometry, on a 24 x 24 design grid.
// ---------------------------------------------------------------------------

class _Layer {
  const _Layer(this.path, {this.back = false});

  final Path path;

  /// Drawn at the paler back plate alpha.
  final bool back;
}

/// Maps design units to local logical pixels, snapping to the device pixel grid when the box's
/// screen origin is known.
class _Grid {
  _Grid(Size box, this.side, this.dpr, Offset? origin)
      : unit = side / 24,
        left = (box.width - side) / 2,
        top = (box.height - side) / 2,
        snapping = dpr > 0 && origin != null,
        gx = _phase(origin?.dx, dpr),
        gy = _phase(origin?.dy, dpr);

  const _Grid._(this.side, this.unit, this.left, this.top, this.dpr, this.snapping, this.gx, this.gy);

  /// Only the sub-pixel phase of the origin matters for snapping; keeping just that makes the
  /// geometry (and its cache key) independent of where the box is.
  static double _phase(double? v, double dpr) {
    if (v == null || dpr <= 0) return 0;
    final device = v * dpr;
    return ((device - device.floorToDouble()) * 1e4).roundToDouble() / 1e4 / dpr;
  }

  final double side;
  final double unit;
  final double left;
  final double top;
  final double dpr;
  final bool snapping;
  final double gx;
  final double gy;

  /// The same grid with the design moved up by [units]; edges still snap afterwards.
  _Grid lifted(double units) => _Grid._(side, unit, left, top - units * unit, dpr, snapping, gx, gy);

  /// 1 at 16 logical px and below, 0 from 24: drives small-size optical tweaks.
  double get small => ((24 - side) / 8).clamp(0.0, 1.0);

  /// 0 up to 24 logical px, 1 from 72: keeps large renders from looking chunky.
  double get large => ((side - 24) / 48).clamp(0.0, 1.0);

  double _snap(double local, double phase) => snapping ? ((phase + local) * dpr).roundToDouble() / dpr - phase : local;

  double snapX(double local) => _snap(local, gx);
  double snapY(double local) => _snap(local, gy);

  /// Snapped x / y of a design coordinate.
  double x(double u) => snapX(left + u * unit);
  double y(double u) => snapY(top + u * unit);
  Offset p(double ux, double uy) => Offset(x(ux), y(uy));

  /// Snapped edges of a span from design x (or y) [u0] to [u1]. A span centred on the grid stays
  /// centred whenever the middle falls between two device pixels, instead of both edges rounding
  /// the same way on a tie.
  (double, double) spanX(double u0, double u1) => _span(u0, u1, left, gx);
  (double, double) spanY(double u0, double u1) => _span(u0, u1, top, gy);

  (double, double) _span(double u0, double u1, double origin, double phase) {
    final start = _snap(origin + u0 * unit, phase);
    final end = _snap(origin + u1 * unit, phase);
    final twiceMiddle = 2 * origin + side;
    if ((u0 + u1 - 24).abs() > 1e-9 || (_snap(twiceMiddle - start, phase) - (twiceMiddle - start)).abs() > 1e-6) {
      return (start, end);
    }
    // Mirror whichever edge keeps the width closer to the design, the wider one on a tie.
    final exact = (u1 - u0) * unit;
    final fromStart = twiceMiddle - 2 * start;
    final fromEnd = 2 * end - twiceMiddle;
    final startError = (fromStart - exact).abs();
    final endError = (fromEnd - exact).abs();
    final useEnd = endError < startError - 1e-6 || ((endError - startError).abs() <= 1e-6 && fromEnd > fromStart);
    return useEnd ? (twiceMiddle - end, end) : (start, twiceMiddle - start);
  }

  /// Unsnapped point and length, for diagonal geometry and radii.
  Offset raw(double ux, double uy) => Offset(left + ux * unit, top + uy * unit);
  double l(double u) => u * unit;

  /// A length in whole device pixels, never below [minDevicePx].
  double px(double u, {double minDevicePx = 1}) {
    if (!snapping) return math.max(u * unit, dpr > 0 ? minDevicePx / dpr : 0);
    return math.max(minDevicePx, (u * unit * dpr).roundToDouble()) / dpr;
  }

  /// A bar [u] thick centred on design y [c], both edges on the device grid: (top, bottom).
  (double, double) barY(double c, double u) {
    final t = px(u);
    final start = snapY(top + c * unit - t / 2);
    return (start, start + t);
  }

  /// One axis of a plus centred on design coordinate [c]: the spans of its bar ([thickness]
  /// across) and arm ([length] along). Snapped, both are whole device pixels of the same parity,
  /// so the plus stays symmetric with equally thick arms; a stubby plus, which reads as a dot,
  /// trades a pixel of thickness for length.
  ((double, double), (double, double)) plusSpans(double c, double length, double thickness, {required bool vertical}) {
    final phase = vertical ? gy : gx;
    final mid = (vertical ? top : left) + c * unit;
    if (!snapping) {
      final bar = thickness * unit / 2;
      final arm = length * unit / 2;
      return ((mid - bar, mid + bar), (mid - arm, mid + arm));
    }
    final exactArm = length * unit * dpr;
    int armFor(int bar) {
      var arm = math.max(bar, exactArm.round());
      if ((arm - bar).isOdd) arm += arm > exactArm ? -1 : 1;
      return arm;
    }

    var barPx = math.max(1, (thickness * unit * dpr).round());
    var armPx = armFor(barPx);
    if (barPx > 1 && armPx < barPx * 2.2) {
      barPx -= 1;
      armPx = armFor(barPx);
    }
    final barLo = ((phase + mid) * dpr - barPx / 2).roundToDouble();
    final armLo = barLo - (armPx - barPx) / 2;
    double local(double device) => device / dpr - phase;
    return ((local(barLo), local(barLo + barPx)), (local(armLo), local(armLo + armPx)));
  }
}

List<_Layer> _layers(DanaviewGlyphKind kind, _Grid grid) {
  final g = grid.lifted(_F.lift);
  return switch (kind) {
    DanaviewGlyphKind.device => _device(grid),
    DanaviewGlyphKind.folder => _closedFolder(g).layers(),
    DanaviewGlyphKind.folderOpen => _openFolder(g),
    DanaviewGlyphKind.folderAdd => _closedFolder(g).layers(
        cutOut: _plus(
          g,
          cx: 12,
          cy: _F.frontMiddle,
          length: 7 + 0.25 * g.small - 0.75 * g.large,
          thickness: 2 - 0.25 * g.large,
        ),
      ),
    DanaviewGlyphKind.folderOff => _folderOff(g),
    DanaviewGlyphKind.folderVideo => _closedFolder(g).layers(
        cutOut: _playTriangle(g, cx: 12, cy: _F.frontMiddle, heightU: 6.25 + 0.5 * g.small),
      ),
  };
}

/// Gap between a folder's layers, and around a slash.
double _gap(_Grid g) => g.px(1 + 0.4 * g.small - 0.15 * g.large);

/// Shared folder metrics, in design units before [lift].
abstract final class _F {
  static const left = 2.5;
  static const right = 21.5;
  static const tabTop = 3.5;
  static const tabEnd = 9.0;
  static const shoulderEnd = 11.25;
  static const bodyTop = 5.75;
  static const frontTop = 9.25;
  static const bottom = 20.5;
  static const frontMiddle = (frontTop + bottom) / 2;

  /// The solid front outweighs the paler back plate, so the folders sit this far above the grid
  /// centre: enough to bring their weight in line with neighbouring icons' while their outline
  /// stays within about a device pixel or two of theirs.
  static const lift = 0.4;
}

class _Folder {
  const _Folder(this.back, this.front);

  final Path back;
  final Path front;

  /// The back plate and the front panel, with [cutOut] cut through the front.
  List<_Layer> layers({Path? cutOut}) => [
        _Layer(back, back: true),
        _Layer(cutOut == null ? front : Path.combine(PathOperation.difference, front, cutOut)),
      ];
}

/// A back plate with the tab, a transparent gap, and the front panel.
_Folder _closedFolder(_Grid g) {
  final (left, right) = g.spanX(_F.left, _F.right);
  final tabTop = g.y(_F.tabTop);
  final bodyTop = g.y(_F.bodyTop);
  final frontTop = g.y(_F.frontTop);
  final backBottom = frontTop - _gap(g);

  final back = _roundedPolygon(
    [
      Offset(left, backBottom),
      Offset(left, tabTop),
      Offset(g.x(_F.tabEnd), tabTop),
      Offset(g.x(_F.shoulderEnd), bodyTop),
      Offset(right, bodyTop),
      Offset(right, backBottom),
    ],
    [0, g.l(2), g.l(1.5), g.l(1.5), g.l(2), 0],
  );
  final front = Path()
    ..addRRect(RRect.fromLTRBAndCorners(
      left,
      frontTop,
      right,
      g.y(_F.bottom),
      topLeft: Radius.circular(g.l(1.5)),
      topRight: Radius.circular(g.l(1.5)),
      bottomLeft: Radius.circular(g.l(2.5)),
      bottomRight: Radius.circular(g.l(2.5)),
    ));
  return _Folder(back, front);
}

/// The front swings out to the right from the closed folder's bottom-left corner, leaving the
/// tab and left side where they were and more of the back plate showing above it.
List<_Layer> _openFolder(_Grid g) {
  final gap = _gap(g);
  final frontPoints = [g.p(6.75, 10.75), g.p(22.5, 10.75), g.p(19.25, _F.bottom), g.p(_F.left, _F.bottom)];
  final frontRadii = [g.l(1.5), g.l(1.5), g.l(2.25), g.l(2.25)];
  final front = _roundedPolygon(frontPoints, frontRadii);
  final cut = _roundedPolygon(_inflate(frontPoints, gap), [for (final r in frontRadii) r + gap]);

  // The back plate ends in a generous round corner where the wedge beside the tilted front would
  // taper into a hairline.
  final back = _roundedPolygon(
    [
      g.p(_F.left, 15.5),
      g.p(_F.left, _F.tabTop),
      g.p(_F.tabEnd, _F.tabTop),
      g.p(_F.shoulderEnd, _F.bodyTop),
      g.p(19.75, _F.bodyTop),
      g.p(19.75, 15.5),
    ],
    [g.l(3), g.l(2), g.l(1.5), g.l(1.5), g.l(2), 0],
  );
  return [
    _Layer(Path.combine(PathOperation.difference, back, cut), back: true),
    _Layer(front),
  ];
}

List<_Layer> _folderOff(_Grid g) {
  final f = _closedFolder(g);
  final gap = _gap(g);
  final half = g.l(1 + 0.15 * g.small - 0.1 * g.large);
  final a = g.raw(3.5, 3.5);
  final b = g.raw(20.5, 20.5);
  final slash = _capsule(a, b, half);
  final cut = _capsule(a, b, half + gap);
  // The back plate keeps only its part above the slash; the sliver of tab left below it would
  // turn into a stray speck at small sizes.
  final d = (b - a) / (b - a).distance;
  final n = Offset(-d.dy, d.dx);
  final far = g.l(48);
  final belowSlash = Path()..addPolygon([a - d * far, b + d * far, b + d * far + n * far, a - d * far + n * far], true);
  final back = Path.combine(PathOperation.difference, f.back, Path.combine(PathOperation.union, cut, belowSlash));
  return [
    _Layer(back, back: true),
    _Layer(Path.combine(PathOperation.difference, f.front, cut)),
    _Layer(slash),
  ];
}

List<_Layer> _device(_Grid g) {
  // Slightly slimmer at small sizes, where a centred span snaps to an even pixel count and the
  // wider choice would outweigh the folders.
  final halfWidth = 6.875 - 0.375 * g.small;
  final (left, right) = g.spanX(12 - halfWidth, 12 + halfWidth);
  final (top, bottom) = g.spanY(1.75, 22.25);
  final body = Path()..addRRect(RRect.fromLTRBR(left, top, right, bottom, Radius.circular(g.l(3.5))));
  // At 18 device px and below the island would shrink to a faint dash and the play mark to a
  // nick: drop the island and give the play mark the whole screen.
  if (g.side * (g.dpr > 0 ? g.dpr : 1) <= 18) {
    final play = _playTriangle(g, cx: 12, cy: 12, heightU: 9);
    return [_Layer(Path.combine(PathOperation.difference, body, play))];
  }
  final (islandLeft, islandRight) = g.spanX(9.875, 14.125);
  final (islandTop, islandBottom) = g.barY(4.25, 1.5 + 0.25 * g.small);
  final island = Path()
    ..addRRect(RRect.fromLTRBR(
      islandLeft,
      islandTop,
      islandRight,
      islandBottom,
      Radius.circular((islandBottom - islandTop) / 2),
    ));
  final play = _playTriangle(g, cx: 12, cy: 12.75, heightU: 7.5 + 0.4 * g.small);
  return [_Layer(Path.combine(PathOperation.difference, body, Path.combine(PathOperation.union, island, play)))];
}

/// The brand play triangle: corner radius a sixth of its height, nudged right by a tenth of its
/// width so it looks centred, as in the brand logo.
Path _playTriangle(_Grid g, {required double cx, required double cy, required double heightU}) {
  final top = g.y(cy - heightU / 2);
  final bottom = g.y(cy + heightU / 2);
  final h = bottom - top;
  final w = h * math.sqrt(3) / 2;
  final left = g.snapX(g.left + g.l(cx) - w / 2 + w * 0.1);
  return _roundedPolygon(
    [Offset(left, top), Offset(left + w, (top + bottom) / 2), Offset(left, bottom)],
    [h / 6, h / 6, h / 6],
  );
}

Path _plus(_Grid g, {required double cx, required double cy, required double length, required double thickness}) {
  final (xBar, xArm) = g.plusSpans(cx, length, thickness, vertical: false);
  final (yBar, yArm) = g.plusSpans(cy, length, thickness, vertical: true);
  final width = math.min(xBar.$2 - xBar.$1, yBar.$2 - yBar.$1);
  // Round ends once the bars are a few device pixels thick; squarer below that, where round ends
  // would melt a small plus into a blob.
  final devicePx = g.dpr > 0 ? width * g.dpr : 8.0;
  final radius = Radius.circular(width / 2 * ((devicePx - 2) / 4).clamp(0.4, 1.0));
  return Path.combine(
    PathOperation.union,
    Path()..addRRect(RRect.fromLTRBR(xArm.$1, yBar.$1, xArm.$2, yBar.$2, radius)),
    Path()..addRRect(RRect.fromLTRBR(xBar.$1, yArm.$1, xBar.$2, yArm.$2, radius)),
  );
}

/// A stadium from [a] to [b] with half-thickness [r].
Path _capsule(Offset a, Offset b, double r) {
  final d = b - a;
  final length = d.distance;
  final c = d.dx / length;
  final s = d.dy / length;
  final shape = Path()..addRRect(RRect.fromLTRBR(-r, -r, length + r, r, Radius.circular(r)));
  return shape.transform(Float64List.fromList([
    c, s, 0, 0, //
    -s, c, 0, 0, //
    0, 0, 1, 0, //
    a.dx, a.dy, 0, 1, //
  ]));
}

/// A polygon (clockwise on screen) with corners rounded by tangent arcs, concave ones included.
/// Radii shrink where two corners would overlap on a short edge.
Path _roundedPolygon(List<Offset> corners, List<double> cornerRadii) {
  // At a few device pixels snapping merges neighbouring points, and an edge of length 0 has no
  // direction: drop the repeats, and draw nothing once no area is left.
  final kept = [
    for (var i = 0; i < corners.length; i++)
      if ((corners[(i + 1) % corners.length] - corners[i]).distance > 1e-6) i,
  ];
  if (kept.length < 3) return Path();
  final points = [for (final i in kept) corners[i]];
  final radii = [for (final i in kept) cornerRadii[i]];
  final n = points.length;
  final cuts = List<double>.filled(n, 0);
  final halfAngles = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final current = points[i];
    final a = points[(i - 1 + n) % n] - current;
    final b = points[(i + 1) % n] - current;
    final cos = ((a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance)).clamp(-1.0, 1.0);
    final theta = math.acos(cos);
    halfAngles[i] = theta / 2;
    // A straight corner needs no arc, and a spike (theta near 0, only in collapsed shapes) has none.
    cuts[i] = radii[i] <= 0 || theta > math.pi - 1e-4 || theta < 1e-4 ? 0 : radii[i] / math.tan(theta / 2);
  }
  final scale = List<double>.filled(n, 1);
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final sum = cuts[i] + cuts[j];
    final length = (points[j] - points[i]).distance;
    if (sum > length && sum > 0) {
      final k = length / sum;
      scale[i] = math.min(scale[i], k);
      scale[j] = math.min(scale[j], k);
    }
  }
  final path = Path();
  for (var i = 0; i < n; i++) {
    final previous = points[(i - 1 + n) % n];
    final current = points[i];
    final next = points[(i + 1) % n];
    final cut = cuts[i] * scale[i];
    final toPrevious = previous - current;
    final toNext = next - current;
    final entry = current + toPrevious / toPrevious.distance * cut;
    final exit = current + toNext / toNext.distance * cut;
    if (i == 0) {
      path.moveTo(entry.dx, entry.dy);
    } else {
      path.lineTo(entry.dx, entry.dy);
    }
    if (cut > 0) {
      final d1 = current - previous;
      final d2 = next - current;
      path.arcToPoint(
        exit,
        radius: Radius.circular(cut * math.tan(halfAngles[i])),
        clockwise: d1.dx * d2.dy - d1.dy * d2.dx > 0,
      );
    }
  }
  return path..close();
}

/// Offsets a convex, clockwise polygon outward by [d], with mitred corners. Where snapping has
/// merged two points, the corner follows its one real edge.
List<Offset> _inflate(List<Offset> points, double d) {
  final n = points.length;
  Offset? normal(Offset from, Offset to) {
    final e = to - from;
    final length = e.distance;
    return length > 1e-6 ? Offset(e.dy, -e.dx) / length : null;
  }

  return [
    for (var i = 0; i < n; i++)
      () {
        final current = points[i];
        final n1 = normal(points[(i - 1 + n) % n], current);
        final n2 = normal(current, points[(i + 1) % n]);
        if (n1 == null || n2 == null) return current + (n1 ?? n2 ?? Offset.zero) * d;
        final mitre = 1 + n1.dx * n2.dx + n1.dy * n2.dy;
        return mitre < 1e-6 ? current + n1 * d : current + (n1 + n2) * (d / mitre);
      }(),
  ];
}
