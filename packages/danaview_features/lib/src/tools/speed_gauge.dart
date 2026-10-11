import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Scale marks in Mbps, spread evenly around the dial so slow and fast links both read well.
const List<double> danaviewGaugeMarks = [0, 1, 5, 10, 25, 50, 100, 250, 500, 1000];

/// Where [mbps] sits on the dial, 0–1: linear within each pair of [danaviewGaugeMarks].
double danaviewGaugeFraction(double mbps) {
  if (mbps.isNaN || mbps <= 0) return 0;
  final last = danaviewGaugeMarks.length - 1;
  for (var i = 0; i < last; i++) {
    final lo = danaviewGaugeMarks[i];
    final hi = danaviewGaugeMarks[i + 1];
    if (mbps < hi) return (i + (mbps - lo) / (hi - lo)) / last;
  }
  return 1;
}

/// Height of [DanaviewSpeedGauge] relative to its width.
const double danaviewGaugeHeightFactor = 0.9;

/// A 270° speed dial with an animated arc and needle, and the reading in the middle.
class DanaviewSpeedGauge extends StatelessWidget {
  const DanaviewSpeedGauge({
    super.key,
    required this.mbps,
    required this.color,
    required this.label,
    required this.value,
    required this.unit,
    this.size = 280,
  });

  /// Drives the arc and needle.
  final double mbps;
  final Color color;

  /// Small caps line above [value], e.g. `DOWNLOAD`.
  final String label;
  final String value;
  final String unit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    final fontFamily = DefaultTextStyle.of(context).style.fontFamily;
    final reading = _Reading(label: label, value: value, unit: unit, color: color, size: size);
    return Semantics(
      label: '$label $value $unit',
      excludeSemantics: true,
      // The arc is open at the bottom, so the box stops just below its ends.
      child: SizedBox(
        width: size,
        height: size * danaviewGaugeHeightFactor,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: DanaviewMotion.slow,
          curve: DanaviewMotion.curve,
          builder: (context, animatedColor, child) => TweenAnimationBuilder<double>(
            tween: Tween(end: danaviewGaugeFraction(mbps)),
            duration: const Duration(milliseconds: 450),
            curve: DanaviewMotion.curve,
            builder: (context, fraction, child) => CustomPaint(
              painter: _GaugePainter(
                fraction: fraction,
                color: animatedColor ?? color,
                textScaler: textScaler,
                textDirection: Directionality.of(context),
                fontFamily: fontFamily,
              ),
              child: child,
            ),
            child: child,
          ),
          child: reading,
        ),
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.size,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Centered on the dial, inside the ring of scale labels.
    return Align(
      alignment: const Alignment(0, (0.5 / danaviewGaugeHeightFactor - 0.5) * 2),
      child: SizedBox(
        width: size * 0.46,
        height: size * 0.42,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                style: DanaviewTextStyles.micro.copyWith(
                  color: DanaviewColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  letterSpacing: -1.5,
                  color: DanaviewColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                unit,
                maxLines: 1,
                style: DanaviewTextStyles.label.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.fraction,
    required this.color,
    required this.textScaler,
    required this.textDirection,
    required this.fontFamily,
  });

  final double fraction;
  final Color color;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final String? fontFamily;

  static const double _start = 0.75 * math.pi;
  static const double _sweep = 1.5 * math.pi;
  static const int _minorPerSegment = 4;

  Offset _point(Offset center, double radius, double angle) =>
      center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width;
    final center = Offset(side / 2, side / 2);
    final stroke = side * 0.06;
    final radius = side / 2 - stroke / 2 - 1;
    final arcRect = Rect.fromCircle(center: center, radius: radius);
    final value = fraction.clamp(0.0, 1.0);

    canvas.drawArc(
      arcRect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = DanaviewColors.trackBackground,
    );
    if (value > 0.002) {
      canvas.drawArc(
        arcRect,
        _start,
        _sweep * value,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }

    // Ticks and scale labels inside the arc.
    final tickOuter = radius - stroke / 2 - side * 0.025;
    final majorLength = side * 0.035;
    final minorLength = side * 0.018;
    final segments = danaviewGaugeMarks.length - 1;
    final tickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.0, side * 0.006);
    final fontSize = (side * 0.04).clamp(9.0, 12.0);
    for (var i = 0; i <= segments * _minorPerSegment; i++) {
      final t = i / (segments * _minorPerSegment);
      final major = i % _minorPerSegment == 0;
      final angle = _start + _sweep * t;
      final passed = t <= value + 1e-6 && value > 0.002;
      tickPaint.color = passed
          ? color.withValues(alpha: major ? 0.9 : 0.6)
          : DanaviewColors.textMuted.withValues(alpha: major ? 0.55 : 0.3);
      canvas.drawLine(
        _point(center, tickOuter, angle),
        _point(center, tickOuter - (major ? majorLength : minorLength), angle),
        tickPaint,
      );
      if (!major) continue;
      final mark = danaviewGaugeMarks[i ~/ _minorPerSegment];
      final painter = TextPainter(
        text: TextSpan(
          text: mark.toStringAsFixed(0),
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            color: passed ? DanaviewColors.textSecondary : DanaviewColors.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final labelRadius = tickOuter - majorLength - side * 0.02 - math.max(painter.width, painter.height) / 2;
      final anchor = _point(center, labelRadius, angle);
      painter.paint(canvas, anchor - Offset(painter.width / 2, painter.height / 2));
      painter.dispose();
    }

    // A short tapered needle across the ticks, between the scale labels and the arc, so it never
    // covers a label or the reading; and a knob on the arc's tip.
    final angle = _start + _sweep * value;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final normal = Offset(-direction.dy, direction.dx);
    final base = center + direction * (tickOuter - majorLength - side * 0.012);
    final tip = center + direction * (radius - stroke / 2 - side * 0.004);
    final halfWidth = side * 0.014;
    canvas.drawPath(
      Path()
        ..moveTo(base.dx + normal.dx * halfWidth, base.dy + normal.dy * halfWidth)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(base.dx - normal.dx * halfWidth, base.dy - normal.dy * halfWidth)
        ..close(),
      Paint()..color = DanaviewColors.textPrimary.withValues(alpha: 0.9),
    );
    final knob = _point(center, radius, angle);
    canvas.drawCircle(knob, stroke * 0.62, Paint()..color = DanaviewColors.textPrimary);
    canvas.drawCircle(knob, stroke * 0.32, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.color != color ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.fontFamily != fontFamily;
  }
}
