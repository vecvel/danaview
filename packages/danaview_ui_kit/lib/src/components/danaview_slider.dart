import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

class DanaviewSlider extends StatefulWidget {
  const DanaviewSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.axis = Axis.horizontal,
    this.origin,
    this.activeColor = DanaviewColors.primary,
    this.inactiveColor = DanaviewColors.trackBackground,
    this.thumbColor = Colors.white,
    this.trackHeight = 4,
    this.thumbRadius = 8,
    this.semanticLabel,
    this.semanticFormatter,
    this.focusNode,
  });

  final double value;

  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// Vertical sliders grow upward (bottom = [min]) and fill the given height.
  final Axis axis;

  /// Value the active fill starts from (defaults to [min]); e.g. 0 for a -12…12 EQ band.
  final double? origin;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double trackHeight;
  final double thumbRadius;
  final String? semanticLabel;
  final String Function(double value)? semanticFormatter;
  final FocusNode? focusNode;

  @override
  State<DanaviewSlider> createState() => _DanaviewSliderState();
}

class _IncrementIntent extends Intent {
  const _IncrementIntent();
}

class _DecrementIntent extends Intent {
  const _DecrementIntent();
}

class _DanaviewSliderState extends State<DanaviewSlider> {
  final GlobalKey _paintKey = GlobalKey();
  bool _dragging = false;
  bool _focused = false;

  bool get _enabled => widget.onChanged != null && widget.max > widget.min;

  double get _range => widget.max - widget.min;

  double _fractionOf(double value) => _range <= 0 ? 0 : ((value - widget.min) / _range).clamp(0.0, 1.0);

  double _snap(double value) {
    final clamped = value.clamp(widget.min, widget.max);
    final divisions = widget.divisions;
    if (divisions == null || divisions <= 0) return clamped;
    final step = _range / divisions;
    return (widget.min + ((clamped - widget.min) / step).round() * step).clamp(widget.min, widget.max);
  }

  double get _keyboardStep {
    final divisions = widget.divisions;
    return divisions != null && divisions > 0 ? _range / divisions : _range * 0.05;
  }

  double? _valueAt(Offset local) {
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final size = box.size;
    final inset = _effectiveThumbRadius(size);
    final double fraction;
    if (widget.axis == Axis.horizontal) {
      final usable = size.width - inset * 2;
      fraction = usable <= 0 ? 0.5 : (local.dx - inset) / usable;
    } else {
      final usable = size.height - inset * 2;
      fraction = usable <= 0 ? 0.5 : 1 - (local.dy - inset) / usable;
    }
    final directional = widget.axis == Axis.horizontal && Directionality.of(context) == TextDirection.rtl
        ? 1 - fraction
        : fraction;
    return _snap(widget.min + directional.clamp(0.0, 1.0) * _range);
  }

  double _effectiveThumbRadius(Size size) {
    final cross = widget.axis == Axis.horizontal ? size.height : size.width;
    return math.min(widget.thumbRadius, cross / 2);
  }

  void _emit(double? value) {
    if (value == null || !_enabled) return;
    if (value != widget.value) widget.onChanged!(value);
  }

  void _onStart(Offset local) {
    if (!_enabled) return;
    setState(() => _dragging = true);
    final value = _valueAt(local) ?? widget.value;
    widget.onChangeStart?.call(widget.value);
    _emit(value);
  }

  void _onUpdate(Offset local) {
    if (!_dragging) return;
    _emit(_valueAt(local));
  }

  void _onEnd() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(widget.value);
  }

  void _onTapUp(TapUpDetails details) {
    if (!_enabled) return;
    final value = _valueAt(details.localPosition);
    if (value == null) return;
    widget.onChangeStart?.call(widget.value);
    _emit(value);
    widget.onChangeEnd?.call(value);
  }

  void _nudge(double delta) {
    if (!_enabled) return;
    final value = _snap(widget.value + delta);
    widget.onChangeStart?.call(widget.value);
    _emit(value);
    widget.onChangeEnd?.call(value);
  }

  String _format(double value) {
    final formatter = widget.semanticFormatter;
    if (formatter != null) return formatter(value);
    return '${(_fractionOf(value) * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final horizontal = widget.axis == Axis.horizontal;
    final rtl = horizontal && Directionality.of(context) == TextDirection.rtl;
    final step = _keyboardStep;
    final active = enabled ? widget.activeColor : DanaviewColors.disabled(widget.activeColor);
    final inactive = enabled ? widget.inactiveColor : DanaviewColors.disabled(widget.inactiveColor);
    final thumb = enabled ? widget.thumbColor : Color.lerp(widget.thumbColor, DanaviewColors.surfaceElevatedHigher, 0.5)!;

    Widget paint = _DanaviewSliderPaint(
      key: _paintKey,
      fraction: _fractionOf(widget.value),
      originFraction: _fractionOf(widget.origin ?? widget.min),
      axis: widget.axis,
      reversed: rtl,
      activeColor: active,
      inactiveColor: inactive,
      thumbColor: thumb,
      trackHeight: widget.trackHeight,
      thumbRadius: widget.thumbRadius,
      // Owner rule: hover adds no emphasis; only an active drag (content manipulation) does.
      emphasis: _dragging ? 2 : 0,
      focused: _focused,
    );

    paint = GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onTapUp: enabled ? _onTapUp : null,
      onHorizontalDragStart: enabled && horizontal ? (d) => _onStart(d.localPosition) : null,
      onHorizontalDragUpdate: enabled && horizontal ? (d) => _onUpdate(d.localPosition) : null,
      onHorizontalDragEnd: enabled && horizontal ? (_) => _onEnd() : null,
      onHorizontalDragCancel: enabled && horizontal ? _onEnd : null,
      onVerticalDragStart: enabled && !horizontal ? (d) => _onStart(d.localPosition) : null,
      onVerticalDragUpdate: enabled && !horizontal ? (d) => _onUpdate(d.localPosition) : null,
      onVerticalDragEnd: enabled && !horizontal ? (_) => _onEnd() : null,
      onVerticalDragCancel: enabled && !horizontal ? _onEnd : null,
      excludeFromSemantics: true,
      child: paint,
    );

    final increase = horizontal && !rtl || !horizontal;
    paint = FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowUp): const _IncrementIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowDown): const _DecrementIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            increase ? const _IncrementIntent() : const _DecrementIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            increase ? const _DecrementIntent() : const _IncrementIntent(),
      },
      actions: <Type, Action<Intent>>{
        _IncrementIntent: CallbackAction<_IncrementIntent>(onInvoke: (_) {
          _nudge(step);
          return null;
        }),
        _DecrementIntent: CallbackAction<_DecrementIntent>(onInvoke: (_) {
          _nudge(-step);
          return null;
        }),
      },
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      child: paint,
    );

    return Semantics(
      slider: true,
      enabled: enabled,
      label: widget.semanticLabel,
      value: _format(widget.value),
      increasedValue: _format(_snap(widget.value + step)),
      decreasedValue: _format(_snap(widget.value - step)),
      onIncrease: enabled ? () => _nudge(step) : null,
      onDecrease: enabled ? () => _nudge(-step) : null,
      child: paint,
    );
  }
}

class _DanaviewSliderPaint extends LeafRenderObjectWidget {
  const _DanaviewSliderPaint({
    super.key,
    required this.fraction,
    required this.originFraction,
    required this.axis,
    required this.reversed,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.trackHeight,
    required this.thumbRadius,
    required this.emphasis,
    required this.focused,
  });

  final double fraction;
  final double originFraction;
  final Axis axis;
  final bool reversed;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double trackHeight;
  final double thumbRadius;
  final int emphasis;
  final bool focused;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDanaviewSlider()..update(this);

  @override
  void updateRenderObject(BuildContext context, _RenderDanaviewSlider renderObject) => renderObject.update(this);
}

class _RenderDanaviewSlider extends RenderBox {
  static const double minThickness = 28;
  static const double defaultLength = 160;

  late _DanaviewSliderPaint _config;
  bool _hasConfig = false;

  void update(_DanaviewSliderPaint config) {
    final relayout = !_hasConfig ||
        config.axis != _config.axis ||
        config.thumbRadius != _config.thumbRadius ||
        config.trackHeight != _config.trackHeight;
    _config = config;
    _hasConfig = true;
    if (relayout) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  bool get _horizontal => _config.axis == Axis.horizontal;

  double get _thickness => math.max(minThickness, _config.thumbRadius * 2 + 6);

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final length = _horizontal
        ? (constraints.hasBoundedWidth ? constraints.maxWidth : defaultLength)
        : (constraints.hasBoundedHeight ? constraints.maxHeight : defaultLength);
    return constraints.constrain(_horizontal ? Size(length, _thickness) : Size(_thickness, length));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _horizontal ? _config.thumbRadius * 2 : _thickness;

  @override
  double computeMaxIntrinsicWidth(double height) => _horizontal ? defaultLength : _thickness;

  @override
  double computeMinIntrinsicHeight(double width) => _horizontal ? _thickness : _config.thumbRadius * 2;

  @override
  double computeMaxIntrinsicHeight(double width) => _horizontal ? _thickness : defaultLength;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final c = _config;
    final length = _horizontal ? size.width : size.height;
    final cross = _horizontal ? size.height : size.width;
    final baseRadius = math.min(c.thumbRadius, cross / 2);
    final thumbRadius = math.min(baseRadius + c.emphasis * 1.0, cross / 2);
    final inset = baseRadius;
    final usable = math.max(0.0, length - inset * 2);
    final track = math.min(c.trackHeight + (c.emphasis > 0 ? 1 : 0), cross);

    Offset point(double fraction) {
      final f = c.reversed ? 1 - fraction : fraction;
      if (_horizontal) return offset + Offset(inset + usable * f, size.height / 2);
      return offset + Offset(size.width / 2, size.height - inset - usable * f);
    }

    RRect segment(Offset a, Offset b) {
      final rect = _horizontal
          ? Rect.fromLTRB(math.min(a.dx, b.dx) - track / 2, a.dy - track / 2, math.max(a.dx, b.dx) + track / 2, a.dy + track / 2)
          : Rect.fromLTRB(a.dx - track / 2, math.min(a.dy, b.dy) - track / 2, a.dx + track / 2, math.max(a.dy, b.dy) + track / 2);
      return RRect.fromRectAndRadius(rect, Radius.circular(track / 2));
    }

    canvas.drawRRect(segment(point(0), point(1)), Paint()..color = c.inactiveColor);
    if ((c.fraction - c.originFraction).abs() > 0.0001) {
      canvas.drawRRect(segment(point(c.originFraction), point(c.fraction)), Paint()..color = c.activeColor);
    }

    final center = point(c.fraction);
    final shadow = DanaviewShadows.subtle.first;
    canvas.drawCircle(
      center + shadow.offset,
      math.max(0, thumbRadius + shadow.spreadRadius / 2),
      shadow.toPaint(),
    );
    canvas.drawCircle(center, thumbRadius, Paint()..color = c.thumbColor);
    if (c.focused) {
      canvas.drawCircle(
        center,
        thumbRadius + 2.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = DanaviewColors.focusRing,
      );
    }
  }
}
