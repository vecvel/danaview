import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:danaview_domain/danaview_domain.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

class DanaviewSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final List<Chapter> chapters;
  final AbLoop? abLoop;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeeking;

  const DanaviewSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffer,
    this.chapters = const [],
    this.abLoop,
    required this.onSeek,
    this.onSeeking,
  });

  @override
  State<DanaviewSeekBar> createState() => _DanaviewSeekBarState();
}

class _DanaviewSeekBarState extends State<DanaviewSeekBar> {
  static const double _thumbRadius = 6;

  bool _isDragging = false;
  double _dragValue = 0.0;
  bool _isHovering = false;
  double _hoverFraction = 0.0;
  double _width = 0;

  int get _durMs => widget.duration.inMilliseconds;

  double _fractionAt(double dx) {
    final usable = _width - _thumbRadius * 2;
    if (usable <= 0) return 0;
    return ((dx - _thumbRadius) / usable).clamp(0.0, 1.0);
  }

  Duration _durationAt(double fraction) => Duration(milliseconds: (fraction * _durMs).round());

  @override
  Widget build(BuildContext context) {
    final durMs = _durMs;
    final playedFraction = durMs > 0
        ? (_isDragging ? _dragValue : (widget.position.inMilliseconds / durMs).clamp(0.0, 1.0))
        : 0.0;
    final bufferFraction = durMs > 0 ? (widget.buffer.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
    // The hover time preview is information and stays; the track and thumb grow only while
    // dragging (owner rule: no hover effect on controls).
    final showPreview = _isHovering || _isDragging;
    final height = context.isTouchPlatform ? DanaviewSpacing.minTapTarget : 28.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0;
        final previewFraction = _isDragging ? _dragValue : _hoverFraction;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() => _isHovering = false),
          onHover: (event) => setState(() => _hoverFraction = _fractionAt(event.localPosition.dx)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) {
              setState(() {
                _isDragging = true;
                _dragValue = _fractionAt(details.localPosition.dx);
              });
            },
            onHorizontalDragUpdate: (details) {
              setState(() => _dragValue = _fractionAt(details.localPosition.dx));
              if (durMs > 0) widget.onSeeking?.call(_durationAt(_dragValue));
            },
            onHorizontalDragEnd: (_) {
              setState(() => _isDragging = false);
              if (durMs > 0) widget.onSeek(_durationAt(_dragValue));
            },
            onHorizontalDragCancel: () => setState(() => _isDragging = false),
            onTapUp: (details) {
              if (durMs > 0) widget.onSeek(_durationAt(_fractionAt(details.localPosition.dx)));
            },
            child: SizedBox(
              height: height,
              width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _SeekBarPainter(
                        playedFraction: playedFraction,
                        bufferFraction: bufferFraction,
                        chapters: widget.chapters,
                        duration: widget.duration,
                        abLoop: widget.abLoop,
                        isActive: _isDragging,
                        thumbRadius: _thumbRadius,
                      ),
                    ),
                  ),
                  if (showPreview && durMs > 0 && _width > 0)
                    _TimePreview(
                      label: _formatDuration(_durationAt(previewFraction)),
                      centerX: _thumbRadius + previewFraction * math.max(0, _width - _thumbRadius * 2),
                      maxWidth: _width,
                      bottom: height / 2 + 14,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _TimePreview extends StatelessWidget {
  const _TimePreview({
    required this.label,
    required this.centerX,
    required this.maxWidth,
    required this.bottom,
  });

  static const TextStyle _style = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
    color: DanaviewColors.textPrimary,
  );
  static const EdgeInsets _padding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  final String label;
  final double centerX;
  final double maxWidth;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    // Sized from the label so H:MM:SS fits at any text scale.
    final painter = TextPainter(
      text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_style)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = math.min(maxWidth, painter.width.ceilToDouble() + _padding.horizontal + 2);
    painter.dispose();
    final double left = (centerX - width / 2).clamp(0.0, math.max(0.0, maxWidth - width));
    return Positioned(
      left: left,
      bottom: bottom,
      width: width,
      child: Container(
        padding: _padding,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.smAll,
          border: DanaviewBorders.all,
          boxShadow: DanaviewShadows.soft,
        ),
        child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: _style),
      ),
    );
  }
}

class _SeekBarPainter extends CustomPainter {
  final double playedFraction;
  final double bufferFraction;
  final List<Chapter> chapters;
  final Duration duration;
  final AbLoop? abLoop;
  final bool isActive;
  final double thumbRadius;

  _SeekBarPainter({
    required this.playedFraction,
    required this.bufferFraction,
    required this.chapters,
    required this.duration,
    this.abLoop,
    required this.isActive,
    required this.thumbRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackHeight = isActive ? 6.0 : 4.0;
    final yCenter = size.height / 2;
    final left = thumbRadius;
    final usable = math.max(0.0, size.width - thumbRadius * 2);
    final radius = Radius.circular(trackHeight / 2);
    double xAt(double fraction) => left + usable * fraction;

    RRect bar(double from, double to) => RRect.fromRectAndRadius(
          Rect.fromLTRB(xAt(from), yCenter - trackHeight / 2, xAt(to), yCenter + trackHeight / 2),
          radius,
        );

    canvas.drawRRect(bar(0, 1), Paint()..color = DanaviewColors.trackBackground);

    final durMs = duration.inMilliseconds;
    if (abLoop != null && durMs > 0) {
      final a = (abLoop!.a.inMilliseconds / durMs).clamp(0.0, 1.0);
      final b = abLoop!.b != null ? (abLoop!.b!.inMilliseconds / durMs).clamp(0.0, 1.0) : 1.0;
      if (b > a) canvas.drawRRect(bar(a, b), Paint()..color = DanaviewColors.primaryLight.withValues(alpha: 0.35));
    }

    if (bufferFraction > 0) {
      canvas.drawRRect(bar(0, bufferFraction), Paint()..color = DanaviewColors.bufferTrack);
    }

    if (playedFraction > 0) {
      canvas.drawRRect(bar(0, playedFraction), Paint()..color = DanaviewColors.primary);
    }

    if (chapters.isNotEmpty && durMs > 0) {
      final tickPaint = Paint()
        ..color = DanaviewColors.background.withValues(alpha: 0.7)
        ..strokeWidth = 1.5;
      for (final chapter in chapters) {
        if (chapter.start <= Duration.zero) continue;
        final x = xAt((chapter.start.inMilliseconds / durMs).clamp(0.0, 1.0));
        canvas.drawLine(
          Offset(x, yCenter - trackHeight / 2),
          Offset(x, yCenter + trackHeight / 2),
          tickPaint,
        );
      }
    }

    if (durMs > 0) {
      final thumb = Offset(xAt(playedFraction), yCenter);
      final r = isActive ? thumbRadius + 1.5 : thumbRadius;
      final shadow = DanaviewShadows.subtle.first;
      canvas.drawCircle(thumb + shadow.offset, math.max(0, r + shadow.spreadRadius / 2), shadow.toPaint());
      canvas.drawCircle(thumb, r, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter oldDelegate) {
    return oldDelegate.playedFraction != playedFraction ||
        oldDelegate.bufferFraction != bufferFraction ||
        oldDelegate.isActive != isActive ||
        oldDelegate.duration != duration ||
        oldDelegate.thumbRadius != thumbRadius ||
        oldDelegate.abLoop != abLoop ||
        !identical(oldDelegate.chapters, chapters);
  }
}
