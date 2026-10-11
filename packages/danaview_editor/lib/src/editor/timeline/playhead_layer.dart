// OWNER: UX-10
//
// The playhead layer (ux.md §8.7): a 2 px line over the ruler and the lanes plus, in free mode, a
// 12×18 knob in the ruler. A leaf render object with its own repaint boundary that repaints only
// when the playhead (a ValueListenable, UX-14's PlayheadController) or the viewport changes; it
// never rebuilds per frame. In centre-locked mode the line sits at the centre and stays still while
// the content moves. It takes no hits: the knob is hit-tested by the canvas (`HitPlayheadKnob`).
//
// Coordinates: x is lanes-area x (as in TimelineViewportController); the layer covers the ruler
// (top `rulerHeight` px) and the lanes below it.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart' show TimeUs;

import 'timeline_metrics.dart';
import 'timeline_style.dart';
import 'timeline_viewport.dart';

/// The playhead line and knob (ux.md §8.7).
class PlayheadLayer extends LeafRenderObjectWidget {
  /// Creates the layer.
  const PlayheadLayer({super.key, required this.viewport, required this.playhead, this.style, this.metrics});

  /// Zoom, scroll and follow mode.
  final TimelineViewportController viewport;

  /// The playhead time.
  final ValueListenable<TimeUs> playhead;

  /// Colours (default [TimelineStyle.standard]).
  final TimelineStyle? style;

  /// Ruler height (default: from `MediaQuery`'s text scaler).
  final TimelineMetrics? metrics;

  TimelineMetrics _metricsOf(BuildContext context) =>
      metrics ?? TimelineMetrics(textScale: TimelineMetrics.scaleOf(MediaQuery.textScalerOf(context)));

  double _dprOf(BuildContext context) => MediaQuery.maybeDevicePixelRatioOf(context) ?? View.of(context).devicePixelRatio;

  @override
  RenderPlayheadLayer createRenderObject(BuildContext context) => RenderPlayheadLayer(
        viewport: viewport,
        playhead: playhead,
        style: style ?? TimelineStyle.standard,
        rulerHeight: _metricsOf(context).rulerHeight,
        devicePixelRatio: _dprOf(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderPlayheadLayer renderObject) {
    renderObject
      ..viewport = viewport
      ..playhead = playhead
      ..style = style ?? TimelineStyle.standard
      ..rulerHeight = _metricsOf(context).rulerHeight
      ..devicePixelRatio = _dprOf(context);
  }
}

/// Render object of [PlayheadLayer] (a repaint boundary sized by its parent).
class RenderPlayheadLayer extends RenderBox {
  /// Creates the render object.
  RenderPlayheadLayer({
    required TimelineViewportController viewport,
    required ValueListenable<TimeUs> playhead,
    required TimelineStyle style,
    required double rulerHeight,
    double devicePixelRatio = 1,
  })  : _viewport = viewport,
        _playhead = playhead,
        _style = style,
        _rulerHeight = rulerHeight,
        _dpr = devicePixelRatio;

  TimelineViewportController _viewport;
  ValueListenable<TimeUs> _playhead;
  TimelineStyle _style;
  double _rulerHeight;
  double _dpr;
  double? _lastX;
  bool? _lastLocked;

  /// Number of paints (debug builds), for repaint tests.
  int debugPaintCount = 0;

  /// The x of the line in the last paint (null when nothing was drawn).
  double? get debugLastX => _lastX;

  /// The viewport.
  TimelineViewportController get viewport => _viewport;
  set viewport(TimelineViewportController value) {
    if (identical(value, _viewport)) return;
    if (attached) _viewport.removeListener(_onChange);
    _viewport = value;
    if (attached) _viewport.addListener(_onChange);
    markNeedsPaint();
  }

  /// The playhead.
  ValueListenable<TimeUs> get playhead => _playhead;
  set playhead(ValueListenable<TimeUs> value) {
    if (identical(value, _playhead)) return;
    if (attached) _playhead.removeListener(_onChange);
    _playhead = value;
    if (attached) _playhead.addListener(_onChange);
    markNeedsPaint();
  }

  /// Colours.
  TimelineStyle get style => _style;
  set style(TimelineStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsPaint();
  }

  /// Height of the ruler band at the top (the knob sits in it).
  double get rulerHeight => _rulerHeight;
  set rulerHeight(double value) {
    if (value == _rulerHeight) return;
    _rulerHeight = value;
    markNeedsPaint();
  }

  /// Device pixel ratio (the line snaps to physical pixels).
  double get devicePixelRatio => _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    markNeedsPaint();
  }

  /// The lanes-area x of the line: the centre in centre-locked mode, the playhead otherwise; null
  /// before the viewport has a layout.
  double? lineX() {
    if (!_viewport.hasLayout || _viewport.pxPerSecond <= 0) return null;
    final x = _viewport.centerLocked ? _viewport.lanesWidth / 2 : _viewport.xOf(_playhead.value);
    final dpr = _dpr > 0 ? _dpr : 1.0;
    return (x * dpr).roundToDouble() / dpr;
  }

  // Repaint only when what is drawn moves.
  void _onChange() {
    final x = lineX();
    if (x == _lastX && _viewport.centerLocked == _lastLocked) return;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest.isFinite ? constraints.biggest : constraints.smallest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewport.addListener(_onChange);
    _playhead.addListener(_onChange);
  }

  @override
  void detach() {
    _viewport.removeListener(_onChange);
    _playhead.removeListener(_onChange);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(() {
      debugPaintCount++;
      return true;
    }());
    final x = lineX();
    _lastX = x;
    _lastLocked = _viewport.centerLocked;
    if (x == null) return;
    const w = TimelineMetrics.playheadWidth;
    if (x < -TimelineMetrics.playheadKnobWidth || x > size.width + TimelineMetrics.playheadKnobWidth) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    final paint = Paint()..color = _style.playhead;
    canvas.drawRect(Rect.fromLTWH(offset.dx + x - w / 2, offset.dy, w, size.height), paint);
    if (!_viewport.centerLocked) {
      // The knob: a 12×18 pentagon pointing down, in the ruler band.
      const kw = TimelineMetrics.playheadKnobWidth;
      final kh = math.min(TimelineMetrics.playheadKnobHeight, _rulerHeight);
      final left = offset.dx + x - kw / 2, top = offset.dy + math.max(0.0, _rulerHeight - kh);
      final knob = Path()
        ..moveTo(left, top)
        ..lineTo(left + kw, top)
        ..lineTo(left + kw, top + kh * 0.62)
        ..lineTo(left + kw / 2, top + kh)
        ..lineTo(left, top + kh * 0.62)
        ..close();
      canvas.drawShadow(knob, const Color(0xFF000000), 2, false);
      canvas.drawPath(knob, paint);
    }
    canvas.restore();
  }
}
