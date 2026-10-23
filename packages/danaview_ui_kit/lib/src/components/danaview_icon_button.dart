import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_pressable.dart';

enum DanaviewIconButtonVariant { plain, filled, tonal, primary }

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
      DanaviewIconButtonVariant.filled => DanaviewColors.surfaceElevatedHigher,
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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: danaviewInteractiveFill(background, state),
          ),
          foregroundDecoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.fromBorderSide(
              state.focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: Colors.transparent),
            ),
          ),
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
