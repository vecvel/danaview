import 'package:flutter/material.dart';

import '../theme/danaview_depth.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

/// A rounded surface with §3 hairline depth: continuous corners, a 0.5 pt near-transparent
/// hairline and a 1 px inner top highlight, drawn over the content so clipped thumbnails keep it.
///
/// Use [DanaviewSurface.card] for a card or panel on the black background (§8).
class DanaviewSurface extends StatelessWidget {
  const DanaviewSurface({
    super.key,
    required this.child,
    this.color = DanaviewColors.surfaceElevated,
    this.borderRadius = DanaviewRadius.lgAll,
    this.border = true,
    this.borderColor = DanaviewColors.hairline,
    this.shadow = DanaviewShadow.none,
    this.padding,
    this.margin,
    this.clip = true,
    this.width,
    this.height,
    this.constraints,
    this.highlight = DanaviewColors.highlight,
  });

  /// A card or panel on the background: [DanaviewColors.surface], radius 16 (pass
  /// [DanaviewRadius.mediaAll] for media cards, [DanaviewRadius.controlAll] for grouped lists)
  /// and the two-layer card shadow.
  const DanaviewSurface.card({
    super.key,
    required this.child,
    this.color = DanaviewColors.surface,
    this.borderRadius = DanaviewRadius.cardAll,
    this.border = true,
    this.borderColor = DanaviewColors.hairline,
    this.shadow = DanaviewShadow.card,
    this.padding,
    this.margin,
    this.clip = true,
    this.width,
    this.height,
    this.constraints,
    this.highlight = DanaviewColors.highlight,
  });

  final Widget child;

  /// Must be opaque; the default text/icon color is derived from it.
  final Color color;
  final BorderRadius borderRadius;
  final bool border;
  final Color borderColor;
  final DanaviewShadow shadow;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool clip;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;

  /// Inner top-edge highlight; drawn only with [border]. Transparent turns it off.
  final Color highlight;

  @override
  Widget build(BuildContext context) {
    final foreground = DanaviewColors.foregroundOn(color);
    final shadows = shadow.boxShadows;
    return Container(
      width: width,
      height: height,
      margin: margin,
      constraints: constraints,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: ShapeDecoration(
        color: color,
        shape: DanaviewDepth.shape(borderRadius),
        shadows: shadows.isEmpty ? null : shadows,
      ),
      foregroundDecoration: border
          ? ShapeDecoration(
              shape: DanaviewDepthBorder(
                borderRadius: borderRadius,
                side: BorderSide(color: borderColor, width: DanaviewBorders.width),
                highlight: highlight,
              ),
            )
          : null,
      padding: padding,
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: foreground),
          child: child,
        ),
      ),
    );
  }
}
