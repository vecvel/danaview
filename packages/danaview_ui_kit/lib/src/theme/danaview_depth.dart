import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'danaview_theme.dart';
import 'danaview_tokens.dart';

/// An iOS continuous-corner shape ([RoundedSuperellipseBorder]) that also paints the "hairline
/// depth" of §3: a near-transparent [side] and a [highlightWidth] inner line along the top edge in
/// [highlight]. The highlight follows the top corners and fades out down the sides.
///
/// Use it as the `shape` of a [ShapeDecoration] (see [DanaviewDepth]) or of a Material widget.
class DanaviewDepthBorder extends RoundedSuperellipseBorder {
  const DanaviewDepthBorder({
    super.side,
    super.borderRadius,
    this.highlight = const Color(0x00FFFFFF),
    this.highlightWidth = 1,
  });

  /// Inner top-edge highlight colour; transparent paints none.
  final Color highlight;
  final double highlightWidth;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (highlight.a > 0 && highlightWidth > 0 && rect.height > highlightWidth * 2) {
      final outer = getOuterPath(rect, textDirection: textDirection);
      final crescent = Path.combine(ui.PathOperation.difference, outer, outer.shift(Offset(0, highlightWidth)));
      canvas.drawPath(crescent, Paint()..color = highlight);
    }
    super.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  DanaviewDepthBorder copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
    Color? highlight,
    double? highlightWidth,
  }) {
    return DanaviewDepthBorder(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
      highlight: highlight ?? this.highlight,
      highlightWidth: highlightWidth ?? this.highlightWidth,
    );
  }

  @override
  ShapeBorder scale(double t) => DanaviewDepthBorder(
        side: side.scale(t),
        borderRadius: borderRadius * t,
        highlight: highlight,
        highlightWidth: highlightWidth * t,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is DanaviewDepthBorder) return _lerp(a, this, t);
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is DanaviewDepthBorder) return _lerp(this, b, t);
    return super.lerpTo(b, t);
  }

  static DanaviewDepthBorder _lerp(DanaviewDepthBorder a, DanaviewDepthBorder b, double t) => DanaviewDepthBorder(
        side: BorderSide.lerp(a.side, b.side, t),
        borderRadius: BorderRadiusGeometry.lerp(a.borderRadius, b.borderRadius, t),
        highlight: Color.lerp(a.highlight, b.highlight, t)!,
        highlightWidth: ui.lerpDouble(a.highlightWidth, b.highlightWidth, t)!,
      );

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is DanaviewDepthBorder &&
        other.side == side &&
        other.borderRadius == borderRadius &&
        other.highlight == highlight &&
        other.highlightWidth == highlightWidth;
  }

  @override
  int get hashCode => Object.hash(side, borderRadius, highlight, highlightWidth);

  @override
  String toString() => 'DanaviewDepthBorder($side, $borderRadius, highlight: $highlight)';
}

/// A circle with the same hairline and inner top highlight as [DanaviewDepthBorder]: round
/// toolbar buttons (34 pt) and other circular controls.
class DanaviewCircleDepthBorder extends CircleBorder {
  const DanaviewCircleDepthBorder({super.side, this.highlight = const Color(0x00FFFFFF), this.highlightWidth = 1});

  final Color highlight;
  final double highlightWidth;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (highlight.a > 0 && highlightWidth > 0 && rect.height > highlightWidth * 2) {
      final outer = getOuterPath(rect, textDirection: textDirection);
      final crescent = Path.combine(ui.PathOperation.difference, outer, outer.shift(Offset(0, highlightWidth)));
      canvas.drawPath(crescent, Paint()..color = highlight);
    }
    super.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  DanaviewCircleDepthBorder copyWith({BorderSide? side, double? eccentricity, Color? highlight}) =>
      DanaviewCircleDepthBorder(side: side ?? this.side, highlight: highlight ?? this.highlight, highlightWidth: highlightWidth);

  @override
  ShapeBorder scale(double t) =>
      DanaviewCircleDepthBorder(side: side.scale(t), highlight: highlight, highlightWidth: highlightWidth * t);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is DanaviewCircleDepthBorder) {
      return DanaviewCircleDepthBorder(side: BorderSide.lerp(a.side, side, t), highlight: Color.lerp(a.highlight, highlight, t)!);
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is DanaviewCircleDepthBorder) {
      return DanaviewCircleDepthBorder(side: BorderSide.lerp(side, b.side, t), highlight: Color.lerp(highlight, b.highlight, t)!);
    }
    return super.lerpTo(b, t);
  }

  @override
  bool operator ==(Object other) =>
      other is DanaviewCircleDepthBorder &&
      other.runtimeType == runtimeType &&
      other.side == side &&
      other.highlight == highlight &&
      other.highlightWidth == highlightWidth;

  @override
  int get hashCode => Object.hash(side, highlight, highlightWidth);

  @override
  String toString() => 'DanaviewCircleDepthBorder($side, highlight: $highlight)';
}

/// Ready-made decorations for the §3 "hairline depth" recipes, all with continuous corners.
///
/// Feature code builds surfaces with these instead of hand-rolled [BoxDecoration]s:
/// `Container(decoration: DanaviewDepth.card(), ...)`. Clip content to the same shape with
/// [DanaviewDepth.clip] (or `ClipRSuperellipse(borderRadius: ...)`).
abstract final class DanaviewDepth {
  /// A plain continuous-corner shape with an optional [side]; no highlight.
  static OutlinedBorder shape(BorderRadiusGeometry borderRadius, {BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(borderRadius: borderRadius, side: side);

  /// A continuous-corner shape with the hairline and the inner top highlight.
  static DanaviewDepthBorder border({
    BorderRadiusGeometry borderRadius = DanaviewRadius.cardAll,
    BorderSide side = DanaviewBorders.hairline,
    Color highlight = DanaviewColors.highlight,
  }) =>
      DanaviewDepthBorder(borderRadius: borderRadius, side: side, highlight: highlight);

  /// Card or panel on the black background: [DanaviewColors.surface], 7 % hairline, 6 % top
  /// highlight and the two-layer card shadow. Radius 16 by default; media cards pass
  /// [DanaviewRadius.mediaAll], grouped lists [DanaviewRadius.controlAll].
  static ShapeDecoration card({
    Color color = DanaviewColors.surface,
    BorderRadiusGeometry borderRadius = DanaviewRadius.cardAll,
    BorderSide side = DanaviewBorders.hairline,
    Color highlight = DanaviewColors.highlight,
    List<BoxShadow> shadows = DanaviewShadows.card,
  }) =>
      ShapeDecoration(
        color: color,
        shadows: shadows.isEmpty ? null : shadows,
        shape: DanaviewDepthBorder(borderRadius: borderRadius, side: side, highlight: highlight),
      );

  /// An item raised on a card (field, secondary button, idle pill, toast):
  /// [DanaviewColors.surfaceElevated], hairline and 6 % highlight, no shadow. Radius 12.
  static ShapeDecoration raised({
    Color color = DanaviewColors.surfaceElevated,
    BorderRadiusGeometry borderRadius = DanaviewRadius.controlAll,
    BorderSide side = DanaviewBorders.hairline,
    Color highlight = DanaviewColors.highlight,
    List<BoxShadow> shadows = DanaviewShadows.none,
  }) =>
      card(color: color, borderRadius: borderRadius, side: side, highlight: highlight, shadows: shadows);

  /// The one filled red control: [DanaviewColors.primary], 18 % top highlight and the raised
  /// shadow. Radius 12.
  static ShapeDecoration primary({
    Color color = DanaviewColors.primary,
    BorderRadiusGeometry borderRadius = DanaviewRadius.controlAll,
    List<BoxShadow> shadows = DanaviewShadows.raised,
  }) =>
      card(
        color: color,
        borderRadius: borderRadius,
        side: BorderSide.none,
        highlight: DanaviewColors.highlightStrong,
        shadows: shadows,
      );

  /// A round control (34 pt toolbar button): [color] circle with a 6 % top highlight and an
  /// optional hairline.
  static ShapeDecoration circle({
    Color color = DanaviewColors.surfaceElevated,
    BorderSide side = DanaviewBorders.hairline,
    Color highlight = DanaviewColors.highlight,
    List<BoxShadow> shadows = DanaviewShadows.none,
  }) =>
      ShapeDecoration(
        color: color,
        shadows: shadows.isEmpty ? null : shadows,
        shape: DanaviewCircleDepthBorder(side: side, highlight: highlight),
      );

  /// The neutral list icon tile (§7): [DanaviewColors.surfaceElevatedHigher], radius 8, 10 %
  /// hairline and 12 % top highlight.
  static ShapeDecoration iconTile({
    Color color = DanaviewColors.surfaceElevatedHigher,
    BorderRadiusGeometry borderRadius = DanaviewRadius.tileAll,
  }) =>
      card(
        color: color,
        borderRadius: borderRadius,
        side: DanaviewBorders.tile,
        highlight: DanaviewColors.highlightTile,
        shadows: DanaviewShadows.none,
      );

  /// The keyboard-only focus ring (2 pt, [DanaviewColors.focusRing]) as a foreground decoration
  /// on a control of [borderRadius]. When [focused] is false the ring is transparent, so an
  /// [AnimatedContainer] fades it in.
  static ShapeDecoration focusRing({
    required bool focused,
    BorderRadiusGeometry borderRadius = DanaviewRadius.controlAll,
    bool circle = false,
  }) {
    final side = focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: const Color(0x00FF5A62));
    return ShapeDecoration(
      shape: circle ? CircleBorder(side: side) : RoundedSuperellipseBorder(borderRadius: borderRadius, side: side),
    );
  }

  /// Clips [child] to a continuous-corner shape of [borderRadius]; use it for thumbnails and
  /// strips inside a card (inner radius = outer radius - padding).
  static Widget clip({required BorderRadius borderRadius, required Widget child}) =>
      ClipRSuperellipse(borderRadius: borderRadius, child: child);
}
