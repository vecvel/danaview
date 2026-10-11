import 'dart:math' as math;

import 'package:flutter/material.dart';

class DanaviewLogo extends StatelessWidget {
  const DanaviewLogo({super.key, this.size = 48, this.semanticLabel = 'Danaview'});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: DanaviewLogoPainter()),
      ),
    );
  }
}

/// Paints the brand icon into any square; also usable for rasterising launcher assets.
class DanaviewLogoPainter extends CustomPainter {
  const DanaviewLogoPainter({this.tile = true});

  /// When false only the glyph is painted (e.g. adaptive-icon foreground).
  final bool tile;

  static const Color gradientStart = Color(0xFF7C7FF5);
  static const Color gradientEnd = Color(0xFF5141DD);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final origin = Offset((size.width - s) / 2, (size.height - s) / 2);
    final rect = origin & Size.square(s);

    if (tile) {
      final tileShape = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.225));
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
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.7, -0.75),
            radius: 0.95,
            colors: [Color(0x1AFFFFFF), Color(0x00FFFFFF)],
          ).createShader(rect),
      );
      canvas.restore();
    }

    final glyph = playGlyphPath(rect);
    canvas.drawPath(
      glyph.shift(Offset(0, s * 0.015)),
      Paint()
        ..color = const Color(0x29000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(s * 0.05)),
    );
    canvas.drawPath(glyph, Paint()..color = Colors.white);
  }

  static Path playGlyphPath(Rect rect) {
    final s = rect.shortestSide;
    final height = s * 0.42;
    final width = height * math.sqrt(3) / 2;
    final cx = rect.center.dx + s * 0.035;
    final cy = rect.center.dy;
    final vertices = [
      Offset(cx - width / 2, cy - height / 2),
      Offset(cx + width / 2, cy),
      Offset(cx - width / 2, cy + height / 2),
    ];
    final radius = s * 0.07;
    final path = Path();
    for (var i = 0; i < vertices.length; i++) {
      final prev = vertices[(i + vertices.length - 1) % vertices.length];
      final current = vertices[i];
      final next = vertices[(i + 1) % vertices.length];
      final toPrev = prev - current;
      final toNext = next - current;
      final angle = math.acos(
        ((toPrev.dx * toNext.dx + toPrev.dy * toNext.dy) / (toPrev.distance * toNext.distance)).clamp(-1.0, 1.0),
      );
      final cut = radius / math.tan(angle / 2);
      final entry = current + toPrev / toPrev.distance * cut;
      final exit = current + toNext / toNext.distance * cut;
      if (i == 0) {
        path.moveTo(entry.dx, entry.dy);
      } else {
        path.lineTo(entry.dx, entry.dy);
      }
      path.arcToPoint(exit, radius: Radius.circular(radius));
    }
    return path..close();
  }

  @override
  bool shouldRepaint(DanaviewLogoPainter oldDelegate) => oldDelegate.tile != tile;
}
