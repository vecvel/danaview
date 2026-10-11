import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';

class DanaviewSpinner extends StatefulWidget {
  const DanaviewSpinner({
    super.key,
    this.color = DanaviewColors.primary,
    this.size = 24,
    this.strokeWidth,
    this.semanticLabel = 'Loading',
  });

  final Color color;
  final double size;

  final double? strokeWidth;
  final String semanticLabel;

  @override
  State<DanaviewSpinner> createState() => _DanaviewSpinnerState();
}

class _DanaviewSpinnerState extends State<DanaviewSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      child: SizedBox.square(
        dimension: widget.size,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _DanaviewSpinnerPainter(
              animation: _controller,
              color: widget.color,
              strokeWidth: widget.strokeWidth ?? math.max(2, widget.size / 10),
            ),
          ),
        ),
      ),
    );
  }
}

class _DanaviewSpinnerPainter extends CustomPainter {
  _DanaviewSpinnerPainter({required this.animation, required this.color, required this.strokeWidth})
      : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final sweepPhase = Curves.easeInOutCubic.transform(t < 0.5 ? t * 2 : 2 - t * 2);
    final sweep = math.pi * (0.25 + 1.15 * sweepPhase);
    final start = t * math.pi * 4 - math.pi / 2;

    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: color.a * 0.16),
    );
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_DanaviewSpinnerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
