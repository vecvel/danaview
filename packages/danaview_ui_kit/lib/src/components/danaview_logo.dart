import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// The Danaview brand mark ("6B", the page-fold Dv) on its indigo tile.
///
/// [accent] recolours the flap only, for product variants (see [DanaviewLogoPainter.editorAccent] and
/// friends). Without it the flap uses the master tone [DanaviewLogoPainter.flapTone].
class DanaviewLogo extends StatelessWidget {
  const DanaviewLogo({super.key, this.size = 48, this.semanticLabel = 'Danaview', this.accent});

  final double size;
  final String? semanticLabel;

  /// Flap colour for a product variant; null paints the master flap tone.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: DanaviewLogoPainter(accent: accent)),
      ),
    );
  }
}

/// Paints the brand icon into any square; also usable for rasterising launcher assets.
///
/// The geometry is a port of `assets/branding/generate_brand.py` (the source of truth) on its
/// 1024 grid, mapped onto the centred square of the canvas:
///   * page: 448 square (288 to 736), spine corners r 68, bottom-right bowl r 216 about (520, 520);
///   * fold: 35 degrees from A (516, 288) to B (736, 442); the flap is the corner reflected across
///     AB, with its vertex C at (591.2, 494.7);
///   * knockout: the page is cut 44 around the flap triangle; the visible flap has its fold edge
///     set 20 in from AB and is rounded by 4, which leaves a 40 gap.
class DanaviewLogoPainter extends CustomPainter {
  const DanaviewLogoPainter({this.tile = true, this.accent});

  /// When false only the glyph is painted (e.g. adaptive-icon foreground). The glyph keeps the
  /// same size and position as on the tile.
  final bool tile;

  /// Flap colour for a product variant; null paints [flapTone].
  final Color? accent;

  static const Color gradientStart = Color(0xFF7C7FF5);
  static const Color gradientEnd = Color(0xFF5141DD);

  /// The page (the D) colour.
  static const Color pageColor = Color(0xFFFFFFFF);

  /// The master flap tone.
  static const Color flapTone = Color(0xFFC9CBFF);

  /// Product accents: they go on the flap only.
  static const Color editorAccent = Color(0xFF8B5CF6);
  static const Color cameraAccent = Color(0xFF06B6D4);
  static const Color photosAccent = Color(0xFFF59E0B);
  static const Color docsAccent = Color(0xFF10B981);

  /// Tile corner radius as a share of the side.
  static const double tileRadius = 0.225;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final origin = Offset((size.width - s) / 2, (size.height - s) / 2);
    final rect = origin & Size.square(s);

    if (tile) {
      final tileShape = RRect.fromRectAndRadius(rect, Radius.circular(s * tileRadius));
      canvas.drawRRect(
        tileShape,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [gradientStart, gradientEnd],
          ).createShader(rect),
      );
      canvas.save();
      canvas.clipRRect(tileShape);
      // White glow centred at (225.28, 143.36) with r 798.72 on the 1024 grid: 10% -> 3.5% -> 0.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(225.28 / 512 - 1, 143.36 / 512 - 1),
            radius: 798.72 / 1024,
            colors: [Color(0x1AFFFFFF), Color(0x09FFFFFF), Color(0x00FFFFFF)],
            stops: [0, 0.55, 1],
          ).createShader(rect),
      );
      canvas.restore();
    }

    // Drop shadow under the whole mark: blur 25.6 and offset y 15.36 on the grid, black at 16%.
    canvas.drawPath(
      glyphPath(rect).shift(Offset(0, s * 15.36 / 1024)),
      Paint()
        ..color = const Color(0x29000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 25.6 / 1024),
    );
    canvas.drawPath(glyphPagePath(rect), Paint()..color = pageColor);
    canvas.drawPath(glyphFlapPath(rect), Paint()..color = accent ?? flapTone);
  }

  /// The whole mark as one silhouette (page with its knockout, plus the flap), mapped from the
  /// 1024 grid onto the centred square of [rect]. Use it for single-colour marks and shadows.
  static Path glyphPath(Rect rect) => _map(_GlyphGeometry.mark, rect);

  /// The page (the D) with the knockout gap around the flap.
  static Path glyphPagePath(Rect rect) => _map(_GlyphGeometry.page, rect);

  /// The folded flap (the v), painted in the flap tone or a product accent.
  static Path glyphFlapPath(Rect rect) => _map(_GlyphGeometry.flap, rect);

  static Path _map(Path grid, Rect rect) {
    final s = rect.shortestSide;
    final k = s / 1024;
    final dx = rect.left + (rect.width - s) / 2;
    final dy = rect.top + (rect.height - s) / 2;
    final m = Float64List(16)
      ..[0] = k
      ..[5] = k
      ..[10] = 1
      ..[12] = dx
      ..[13] = dy
      ..[15] = 1;
    return grid.transform(m);
  }

  @override
  bool shouldRepaint(DanaviewLogoPainter oldDelegate) => oldDelegate.tile != tile || oldDelegate.accent != accent;
}

/// The 6B glyph on the 1024 grid, built once (see generate_brand.py).
abstract final class _GlyphGeometry {
  static const double _l = 288, _t = 288, _r = 736, _b = 736;
  static const double _cornerR = 68;
  static const double _bowlR = 216;
  static const Offset _bowlC = Offset(520, 520);
  static const double _foldDeg = 35;
  static const double _foldA = 220;
  static const double _knock = 44;
  static const double _flapInset = 20;
  static const double _flapRound = 4;

  static final ({Offset a, Offset b, Offset c}) _fold = () {
    final th = _foldDeg * math.pi / 180;
    final a = Offset(_r - _foldA, _t);
    final b = Offset(_r, _t + _foldA * math.tan(th));
    final ang = (2 * _foldDeg - 180) * math.pi / 180;
    final c = Offset(a.dx - _foldA * math.cos(ang), a.dy - _foldA * math.sin(ang));
    return (a: a, b: b, c: c);
  }();

  static final Path _pageOutline = () {
    final f = _fold;
    return Path()
      ..moveTo(_l + _cornerR, _t)
      ..lineTo(f.a.dx, _t)
      ..lineTo(_r, f.b.dy)
      ..lineTo(_r, _bowlC.dy)
      ..arcToPoint(Offset(_bowlC.dx, _b), radius: const Radius.circular(_bowlR))
      ..lineTo(_l + _cornerR, _b)
      ..arcToPoint(const Offset(_l, _b - _cornerR), radius: const Radius.circular(_cornerR))
      ..lineTo(_l, _t + _cornerR)
      ..arcToPoint(const Offset(_l + _cornerR, _t), radius: const Radius.circular(_cornerR))
      ..close();
  }();

  /// Page minus the triangle ACB grown by [_knock] with round joins.
  static final Path page = () {
    final f = _fold;
    return Path.combine(PathOperation.difference, _pageOutline, _roundedOffset([f.a, f.c, f.b], _knock));
  }();

  /// The visible flap: A and B moved [_flapInset] towards C, grown by [_flapRound] with round joins.
  static final Path flap = () {
    final f = _fold;
    final h =
        ((f.b.dx - f.a.dx) * (f.a.dy - f.c.dy) - (f.a.dx - f.c.dx) * (f.b.dy - f.a.dy)).abs() / (f.b - f.a).distance;
    final t = _flapInset / h;
    Offset mv(Offset p) => p + (f.c - p) * t;
    return _roundedOffset([mv(f.a), f.c, mv(f.b)], _flapRound);
  }();

  static final Path mark = Path.combine(PathOperation.union, page, flap);

  /// A convex polygon grown outwards by [r] with round corners (the shape SVG draws for a polygon
  /// filled and stroked with width 2r and round joins).
  static Path _roundedOffset(List<Offset> pts, double r) {
    var area = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i], q = pts[(i + 1) % pts.length];
      area += p.dx * q.dy - q.dx * p.dy;
    }
    // Positive area in y-down coordinates is a visually clockwise outline.
    final clockwise = area > 0;
    Offset normal(Offset p, Offset q) {
      final d = q - p;
      final n = clockwise ? Offset(d.dy, -d.dx) : Offset(-d.dy, d.dx);
      return n / n.distance * r;
    }

    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i], q = pts[(i + 1) % pts.length], next = pts[(i + 2) % pts.length];
      final n = normal(p, q);
      final n2 = normal(q, next);
      final start = p + n;
      if (i == 0) path.moveTo(start.dx, start.dy);
      path.lineTo(q.dx + n.dx, q.dy + n.dy);
      final end = q + n2;
      path.arcToPoint(end, radius: Radius.circular(r), clockwise: clockwise);
    }
    return path..close();
  }
}
