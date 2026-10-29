import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_depth.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_pressable.dart';

/// [toolbar] is the §7 round toolbar button: a 34 pt `surfaceElevated` circle with a 6 % top
/// highlight and a 17 pt glyph (use `DanaviewIconButton.toolbar`).
enum DanaviewIconButtonVariant { plain, filled, tonal, primary, toolbar }

class DanaviewIconButton extends StatelessWidget {
  const DanaviewIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.variant = DanaviewIconButtonVariant.plain,
    this.size = 40,
    this.iconSize,
    this.color,
    this.tooltip,
    this.semanticLabel,
    this.selected = false,
    this.onLongPress,
  });

  /// §7 round toolbar button: 34 pt [DanaviewColors.surfaceElevated] circle, 17 pt glyph, 44 pt
  /// hit area on touch. [accent] colours the glyph [DanaviewColors.primaryLight] (the add/import
  /// button). Give it a [tooltip].
  const DanaviewIconButton.toolbar({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.semanticLabel,
    this.selected = false,
    this.onLongPress,
    bool accent = false,
  })  : variant = DanaviewIconButtonVariant.toolbar,
        size = toolbarSize,
        iconSize = 17,
        color = accent ? DanaviewColors.primaryLight : null;

  /// Visual diameter of [DanaviewIconButton.toolbar].
  static const double toolbarSize = 34;

  final IconData icon;
  final VoidCallback? onPressed;
  final DanaviewIconButtonVariant variant;

  /// Visual circle diameter; the hit area is at least 44 on touch platforms.
  final double size;
  final double? iconSize;

  final Color? color;
  final String? tooltip;
  final String? semanticLabel;
  final bool selected;
  final VoidCallback? onLongPress;

  Color get _background {
    if (selected && variant == DanaviewIconButtonVariant.plain) return DanaviewColors.primaryTonal;
    return switch (variant) {
      DanaviewIconButtonVariant.plain => const Color(0x00FFFFFF),
      DanaviewIconButtonVariant.filled || DanaviewIconButtonVariant.toolbar => DanaviewColors.surfaceElevated,
      DanaviewIconButtonVariant.tonal => DanaviewColors.primaryTonal,
      DanaviewIconButtonVariant.primary => DanaviewColors.primary,
    };
  }

  Color get _foreground {
    if (color != null) return color!;
    return switch (variant) {
      DanaviewIconButtonVariant.plain => selected ? DanaviewColors.primaryLight : DanaviewColors.textPrimary,
      DanaviewIconButtonVariant.tonal => DanaviewColors.primaryLight,
      DanaviewIconButtonVariant.filled || DanaviewIconButtonVariant.primary => DanaviewColors.foregroundOn(_background),
      DanaviewIconButtonVariant.toolbar => selected ? DanaviewColors.primaryLight : DanaviewColors.textPrimary,
    };
  }

  /// Raised circles (filled, toolbar) get the hairline and top highlight; primary gets the
  /// strong highlight; plain and tonal are a bare fill.
  ShapeDecoration _decoration(Color fill) {
    return switch (variant) {
      DanaviewIconButtonVariant.filled || DanaviewIconButtonVariant.toolbar => DanaviewDepth.circle(color: fill),
      DanaviewIconButtonVariant.primary =>
        DanaviewDepth.circle(color: fill, side: BorderSide.none, highlight: DanaviewColors.highlightStrong),
      _ => ShapeDecoration(color: fill, shape: const CircleBorder()),
    };
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null || onLongPress != null;
    final hit = context.isTouchPlatform ? math.max(size, DanaviewSpacing.minTapTarget) : size;
    final background = _background;
    final foreground = _foreground;

    return DanaviewPressable.builder(
      onTap: onPressed,
      onLongPress: onLongPress,
      tooltip: tooltip,
      semanticLabel: semanticLabel ?? tooltip,
      selected: selected ? true : null,
      builder: (context, state) {
        final circle = AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: _decoration(danaviewInteractiveFill(background, state)),
          foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, circle: true),
          child: Icon(icon, size: iconSize ?? size * 0.5, color: foreground),
        );
        return danaviewDimmed(
          enabled,
          SizedBox(width: hit, height: hit, child: Center(child: circle)),
        );
      },
    );
  }
}
