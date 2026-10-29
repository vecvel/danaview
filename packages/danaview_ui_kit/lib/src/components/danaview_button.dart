import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_depth.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_glyph.dart';
import 'danaview_pressable.dart';

/// §8 buttons. [primary] is the one filled red control per view; [secondary] is the neutral
/// raised sibling; [text] is the `primaryLight` text action ("See all", "New", "Add").
enum DanaviewButtonVariant { primary, secondary, tonal, ghost, destructive, text }

enum DanaviewButtonSize {
  sm,
  md,
  lg,

  /// Matches a text or search field beside it: [DanaviewSpacing.controlHeight] tall with the
  /// field's corner radius and md typography.
  field,
}

class DanaviewButton extends StatelessWidget {
  const DanaviewButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = DanaviewButtonVariant.secondary,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  });

  const DanaviewButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.primary;

  const DanaviewButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.secondary;

  const DanaviewButton.tonal({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.tonal;

  const DanaviewButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.ghost;

  /// Text action (§8): `primaryLight` 15/600 label, no background. Keeps the 44 pt target.
  const DanaviewButton.text({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.text;

  const DanaviewButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.size = DanaviewButtonSize.md,
    this.icon,
    this.glyph,
    this.trailingIcon,
    this.expand = false,
    this.tooltip,
    this.semanticLabel,
  }) : variant = DanaviewButtonVariant.destructive;

  final String label;
  final VoidCallback? onPressed;
  final DanaviewButtonVariant variant;
  final DanaviewButtonSize size;
  final IconData? icon;

  /// Drawn instead of [icon] when set.
  final DanaviewGlyphKind? glyph;
  final IconData? trailingIcon;

  /// Fills the available width; requires bounded width constraints.
  final bool expand;
  final String? tooltip;
  final String? semanticLabel;

  static ({Color fill, Color foreground}) _colorsFor(DanaviewButtonVariant variant) {
    return switch (variant) {
      DanaviewButtonVariant.primary => (
          fill: DanaviewColors.primary,
          foreground: DanaviewColors.foregroundOn(DanaviewColors.primary),
        ),
      DanaviewButtonVariant.secondary => (
          fill: DanaviewColors.surfaceElevated,
          foreground: DanaviewColors.foregroundOn(DanaviewColors.surfaceElevated),
        ),
      DanaviewButtonVariant.tonal => (fill: DanaviewColors.primaryTonal, foreground: DanaviewColors.primaryLight),
      DanaviewButtonVariant.ghost => (fill: const Color(0x00FFFFFF), foreground: DanaviewColors.textPrimary),
      DanaviewButtonVariant.destructive => (fill: DanaviewColors.destructiveSoft, foreground: DanaviewColors.destructive),
      DanaviewButtonVariant.text => (fill: const Color(0x00FFFFFF), foreground: DanaviewColors.primaryLight),
    };
  }

  /// The resting frame of [variant]: hairline depth on secondary, the raised highlight and shadow
  /// on primary, a bare continuous-corner fill on the rest.
  static ShapeDecoration _frame(DanaviewButtonVariant variant, Color fill, BorderRadius radius) {
    return switch (variant) {
      DanaviewButtonVariant.primary => DanaviewDepth.primary(color: fill, borderRadius: radius),
      DanaviewButtonVariant.secondary => DanaviewDepth.raised(color: fill, borderRadius: radius),
      _ => ShapeDecoration(color: fill, shape: DanaviewDepth.shape(radius)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final colors = _colorsFor(variant);
    final (height, hPad, fontSize, iconSize, gap, radius) = switch (size) {
      DanaviewButtonSize.sm => (32.0, 12.0, 13.0, 16.0, 6.0, DanaviewRadius.thumbAll),
      DanaviewButtonSize.md => (40.0, 16.0, 15.0, 18.0, 8.0, DanaviewRadius.controlAll),
      DanaviewButtonSize.lg => (48.0, 20.0, 15.0, 20.0, 8.0, DanaviewRadius.controlAll),
      DanaviewButtonSize.field => (DanaviewSpacing.controlHeight, 16.0, 15.0, 18.0, 8.0, DanaviewRadius.controlAll),
    };
    final fg = colors.foreground;

    return DanaviewPressable.builder(
      onTap: onPressed,
      tooltip: tooltip,
      semanticLabel: semanticLabel,
      builder: (context, state) {
        Widget visual = AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          constraints: BoxConstraints(minHeight: height, minWidth: height),
          // A text action sits close to its edge (section headers, toasts).
          padding: EdgeInsets.symmetric(horizontal: variant == DanaviewButtonVariant.text ? 6 : hPad, vertical: 4),
          decoration: _frame(variant, danaviewInteractiveFill(colors.fill, state), radius),
          foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: radius),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null || glyph != null) ...[
                danaviewIconOrGlyph(icon, glyph, size: iconSize, color: fg),
                SizedBox(width: gap),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    letterSpacing: -0.1,
                    color: fg,
                  ),
                ),
              ),
              if (trailingIcon != null) ...[
                SizedBox(width: gap),
                Icon(trailingIcon, size: iconSize, color: fg),
              ],
            ],
          ),
        );
        visual = expand
            ? SizedBox(width: double.infinity, child: visual)
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
                child: visual,
              );
        return danaviewDimmed(enabled, danaviewTapTarget(context, visual));
      },
    );
  }
}
