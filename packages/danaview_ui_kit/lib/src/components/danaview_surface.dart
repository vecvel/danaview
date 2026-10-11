import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    final foreground = DanaviewColors.foregroundOn(color);
    return Container(
      width: width,
      height: height,
      margin: margin,
      constraints: constraints,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        boxShadow: shadow.boxShadows,
      ),
      foregroundDecoration: border
          ? BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: borderColor, width: DanaviewBorders.width),
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
