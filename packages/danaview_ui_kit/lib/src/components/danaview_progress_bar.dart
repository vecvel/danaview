import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

/// Linear progress for exports, downloads, transcription and background tasks.
///
/// A [value] in 0..1 draws a determinate bar; `null` draws an indeterminate one (a segment that
/// travels along the track; a static partial fill when the platform asks to reduce motion). The bar
/// fills the width it is given (160 when unbounded) and has a fixed [height].
class DanaviewProgressBar extends StatefulWidget {
  const DanaviewProgressBar({
    super.key,
    this.value,
    this.height = 6,
    this.color = DanaviewColors.primary,
    this.trackColor = DanaviewColors.trackBackground,
    this.semanticLabel,
    this.semanticFormatter,
  });

  /// 0..1, clamped; `null` is indeterminate.
  final double? value;
  final double height;
  final Color color;
  final Color trackColor;

  /// Spoken before the value, e.g. "Exporting".
  final String? semanticLabel;

  /// Replaces the default "45 percent" announcement.
  final String Function(double fraction)? semanticFormatter;

  /// Bar width used when the parent does not bound it.
  static const double defaultWidth = 160;

  @override
  State<DanaviewProgressBar> createState() => _DanaviewProgressBarState();
}

class _DanaviewProgressBarState extends State<DanaviewProgressBar> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _indeterminate => widget.value == null;

  void _syncController(bool reduceMotion) {
    if (_indeterminate && !reduceMotion) {
      _controller ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
      if (!_controller!.isAnimating) _controller!.repeat();
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncController(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  @override
  void didUpdateWidget(DanaviewProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  static double _clamp(double value) => value.isNaN ? 0 : value.clamp(0.0, 1.0);

  String? _announce() {
    final value = widget.value;
    if (value == null) return null;
    final fraction = _clamp(value);
    return widget.semanticFormatter?.call(fraction) ?? '${(fraction * 100).round()} percent';
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final Widget bar;
    if (value == null) {
      final controller = _controller;
      bar = RepaintBoundary(
        child: controller == null
            ? CustomPaint(painter: _ProgressPainter(widget, indeterminate: true, phase: null, fraction: 0.3))
            : AnimatedBuilder(
                animation: controller,
                builder: (context, _) => CustomPaint(
                  painter: _ProgressPainter(widget, indeterminate: true, phase: controller.value, fraction: 0),
                ),
              ),
      );
    } else {
      bar = RepaintBoundary(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _clamp(value)),
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          builder: (context, fraction, _) => CustomPaint(
            painter: _ProgressPainter(widget, indeterminate: false, phase: null, fraction: fraction),
          ),
        ),
      );
    }

    return Semantics(
      label: widget.semanticLabel ?? (value == null ? 'Loading' : 'Progress'),
      value: _announce(),
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth ? constraints.maxWidth : DanaviewProgressBar.defaultWidth;
            return SizedBox(width: width, height: widget.height, child: bar);
          },
        ),
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(
    DanaviewProgressBar bar, {
    required this.indeterminate,
    required this.phase,
    required this.fraction,
  })  : color = bar.color,
        trackColor = bar.trackColor;

  final Color color;
  final Color trackColor;
  final bool indeterminate;

  /// 0..1 loop position of the traveling segment; null draws it at rest.
  final double? phase;
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(track, Paint()..color = trackColor);
    canvas.save();
    canvas.clipRRect(track);
    final fill = Paint()..color = color;

    if (!indeterminate) {
      if (fraction <= 0) {
        canvas.restore();
        return;
      }
      // Never narrower than the bar is tall, so the rounded cap stays a cap.
      final width = math.max(size.height, size.width * fraction);
      canvas.drawRRect(RRect.fromLTRBR(0, 0, width, size.height, radius), fill);
    } else {
      final segment = size.width * 0.35;
      final start = phase == null
          ? (size.width - segment) / 2
          : -segment + (size.width + segment) * Curves.easeInOut.transform(phase!);
      canvas.drawRRect(RRect.fromLTRBR(start, 0, start + segment, size.height, radius), fill);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.color != color ||
      old.trackColor != trackColor ||
      old.indeterminate != indeterminate ||
      old.phase != phase ||
      old.fraction != fraction;
}
