import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// One row when the buttons fit at natural width, otherwise stacked full-width.
class DanaviewButtonBar extends MultiChildRenderObjectWidget {
  const DanaviewButtonBar({
    super.key,
    required super.children,
    this.spacing = 8,
    this.fill = true,
    this.reverseWhenStacked = true,
  });

  final double spacing;

  /// Row mode shares the width equally; false keeps natural widths, trailing-aligned.
  final bool fill;
  final bool reverseWhenStacked;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderDanaviewButtonBar(
      spacing: spacing,
      fill: fill,
      reverseWhenStacked: reverseWhenStacked,
      textDirection: Directionality.of(context),
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderDanaviewButtonBar)
      ..spacing = spacing
      ..fill = fill
      ..reverseWhenStacked = reverseWhenStacked
      ..textDirection = Directionality.of(context);
  }
}

class _DanaviewButtonBarParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderDanaviewButtonBar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DanaviewButtonBarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DanaviewButtonBarParentData> {
  _RenderDanaviewButtonBar({
    required double spacing,
    required bool fill,
    required bool reverseWhenStacked,
    required TextDirection textDirection,
  })  : _spacing = spacing,
        _fill = fill,
        _reverseWhenStacked = reverseWhenStacked,
        _textDirection = textDirection;

  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  bool _fill;
  set fill(bool value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  bool _reverseWhenStacked;
  set reverseWhenStacked(bool value) {
    if (value == _reverseWhenStacked) return;
    _reverseWhenStacked = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DanaviewButtonBarParentData) {
      child.parentData = _DanaviewButtonBarParentData();
    }
  }

  List<RenderBox> get _children {
    final result = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      result.add(child);
      child = childAfter(child);
    }
    return result;
  }

  double _rowWidth(List<RenderBox> children) {
    if (children.isEmpty) return 0;
    final widths = children.map((c) => c.getMaxIntrinsicWidth(double.infinity));
    final total = _fill
        ? widths.reduce(math.max) * children.length
        : widths.fold<double>(0, (sum, w) => sum + w);
    return total + _spacing * (children.length - 1);
  }

  bool _fitsInRow(List<RenderBox> children, double maxWidth) => _rowWidth(children) <= maxWidth;

  @override
  double computeMinIntrinsicWidth(double height) {
    return _children.fold<double>(0, (w, c) => math.max(w, c.getMinIntrinsicWidth(double.infinity)));
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _rowWidth(_children);

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  double _intrinsicHeight(double width) {
    final children = _children;
    if (children.isEmpty) return 0;
    if (_fitsInRow(children, width)) {
      return children.fold<double>(0, (h, c) => math.max(h, c.getMaxIntrinsicHeight(double.infinity)));
    }
    return children.fold<double>(0, (h, c) => h + c.getMaxIntrinsicHeight(width)) +
        _spacing * (children.length - 1);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = _children;
    if (children.isEmpty) return constraints.smallest;
    final maxWidth = constraints.maxWidth;
    final ltr = _textDirection == TextDirection.ltr;

    Size layoutChild(RenderBox child, BoxConstraints c) {
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    if (!maxWidth.isFinite || _fitsInRow(children, maxWidth)) {
      final count = children.length;
      final childConstraints = _fill && maxWidth.isFinite
          ? BoxConstraints.tightFor(width: (maxWidth - _spacing * (count - 1)) / count)
          : const BoxConstraints();
      final sizes = [for (final child in children) layoutChild(child, childConstraints)];
      final rowHeight = sizes.fold<double>(0, (h, s) => math.max(h, s.height));
      final contentWidth = sizes.fold<double>(0, (w, s) => w + s.width) + _spacing * (count - 1);
      final width = maxWidth.isFinite ? maxWidth : contentWidth;
      if (!dry) {
        final leadingSpace = width - contentWidth;
        var offset = 0.0;
        for (var i = 0; i < count; i++) {
          final w = sizes[i].width;
          final x = ltr ? leadingSpace + offset : contentWidth - offset - w;
          (children[i].parentData! as _DanaviewButtonBarParentData).offset =
              Offset(x, (rowHeight - sizes[i].height) / 2);
          offset += w + _spacing;
        }
      }
      return constraints.constrain(Size(width, rowHeight));
    }

    final ordered = _reverseWhenStacked ? children.reversed.toList() : children;
    var y = 0.0;
    for (final child in ordered) {
      final childSize = layoutChild(child, BoxConstraints.tightFor(width: maxWidth));
      if (!dry) (child.parentData! as _DanaviewButtonBarParentData).offset = Offset(0, y);
      y += childSize.height + _spacing;
    }
    return constraints.constrain(Size(maxWidth, y - _spacing));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
