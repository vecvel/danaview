import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../components/danaview_glyph.dart';
import '../components/danaview_pressable.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

// Brighter fills (primary, accents) darken on interaction so their white labels keep >= 4.5:1;
// dark surfaces lighten, which only increases contrast.
Color danaviewInteractiveFill(Color base, DanaviewPressState state) {
  final darken = Color.alphaBlend(base, DanaviewColors.background).computeLuminance() > 0.1;
  if (state.pressed) {
    return Color.alphaBlend(darken ? const Color(0x29000000) : DanaviewColors.pressed, base);
  }
  if (state.hovered || state.focused) {
    return Color.alphaBlend(darken ? const Color(0x1A000000) : DanaviewColors.hover, base);
  }
  return base;
}

/// Grows the layout to the 44pt minimum height on touch platforms; the visual stays centered.
Widget danaviewTapTarget(BuildContext context, Widget child) {
  if (!context.isTouchPlatform) return child;
  return DanaviewMinHeightCenter(minHeight: DanaviewSpacing.minTapTarget, child: child);
}

/// [glyph] when set, else [icon]: lets the IconData-based components draw a [DanaviewGlyph] too.
Widget danaviewIconOrGlyph(IconData? icon, DanaviewGlyphKind? glyph, {required double size, required Color color}) {
  if (glyph != null) return DanaviewGlyph(glyph, size: size, color: color);
  return Icon(icon, size: size, color: color);
}

Widget danaviewDimmed(bool enabled, Widget child) {
  return enabled ? child : Opacity(opacity: DanaviewColors.disabledOpacity, child: child);
}

/// Overlays and routes sit outside any Scaffold, so they need their own text defaults.
Widget danaviewOverlayScope(BuildContext context, Widget child) {
  final base = Theme.of(context).textTheme.bodyLarge ?? DanaviewTextStyles.body;
  return Material(
    type: MaterialType.transparency,
    textStyle: base.merge(DanaviewTextStyles.body),
    child: child,
  );
}

/// Passes width constraints through untouched and centers the child in at least [minHeight].
class DanaviewMinHeightCenter extends SingleChildRenderObjectWidget {
  const DanaviewMinHeightCenter({super.key, required this.minHeight, super.child});

  final double minHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMinHeightCenter(minHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMinHeightCenter).minHeight = minHeight;
  }
}

class _RenderMinHeightCenter extends RenderShiftedBox {
  _RenderMinHeightCenter(this._minHeight) : super(null);

  double _minHeight;
  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) => constraints.copyWith(minHeight: 0);

  Size _sizeFor(BoxConstraints constraints, Size childSize) {
    return constraints.constrain(Size(childSize.width, math.max(childSize.height, _minHeight)));
  }

  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(_minHeight, child?.getMinIntrinsicHeight(width) ?? 0);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(_minHeight, child?.getMaxIntrinsicHeight(width) ?? 0);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final childSize = child?.getDryLayout(_childConstraints(constraints)) ?? Size.zero;
    return _sizeFor(constraints, childSize);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = _sizeFor(constraints, Size.zero);
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Offset(
      (size.width - child.size.width) / 2,
      (size.height - child.size.height) / 2,
    );
  }
}
