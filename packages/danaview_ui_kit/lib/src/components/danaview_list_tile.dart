import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_depth.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_glyph.dart';
import 'danaview_pressable.dart';

class DanaviewListTile extends StatelessWidget {
  const DanaviewListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.dense = false,
    this.enabled = true,
    this.destructive = false,
    this.showChevron = false,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.padding,
    this.semanticLabel,
    this.toggled,
    this.value,
    this.borderRadius,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Keep compact (icon, switch, short text); it is not width-constrained.
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool dense;
  final bool enabled;
  final bool destructive;
  final bool showChevron;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final EdgeInsetsGeometry? padding;
  final String? semanticLabel;
  final bool? toggled;

  /// Trailing value in [DanaviewColors.textSecondary] before the chevron (a count, a size, the
  /// current setting), as in a §8 grouped-list row.
  final String? value;

  /// Shape of the selection and focus fill. Defaults to [DanaviewRadius.controlAll]; rows inside a
  /// [DanaviewGroupedList] are square because the list clips them.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final interactive = enabled && (onTap != null || onLongPress != null);
    final titleColor = destructive ? DanaviewColors.destructive : DanaviewColors.textPrimary;
    final radius = borderRadius ?? DanaviewRadius.controlAll;

    return DanaviewPressable.builder(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      enabled: enabled,
      isButton: interactive,
      selected: selected ? true : null,
      toggled: toggled,
      semanticLabel: semanticLabel,
      builder: (context, state) {
        final background = selected
            ? DanaviewColors.primarySoft
            // Owner rule: no hover or press fill; only hardware-keyboard focus tints.
            : state.focused
                ? DanaviewColors.hairlineSubtle
                : const Color(0x00FFFFFF);
        return danaviewDimmed(
          enabled,
          AnimatedContainer(
            duration: DanaviewMotion.fast,
            curve: DanaviewMotion.curve,
            constraints: BoxConstraints(minHeight: dense ? 44 : 52),
            padding: padding ?? EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : 8),
            decoration: ShapeDecoration(color: background, shape: DanaviewDepth.shape(radius)),
            foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: radius),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: dense ? 15 : 17,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          letterSpacing: -0.2,
                          height: 1.25,
                          color: titleColor,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: subtitleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: dense ? 12 : 13,
                            height: 1.3,
                            color: DanaviewColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 8),
                  // Sized to its text (at most 40 % of the screen), so the title keeps the rest.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
                    child: Text(
                      value!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: DanaviewTextStyles.subhead.copyWith(
                        fontSize: dense ? 15 : 17,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
                if (showChevron) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: DanaviewColors.chevron),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A tinted square behind a coloured glyph. Kept for existing screens; §7 list tiles are neutral,
/// so new and restyled rows use [DanaviewIconTile].
class DanaviewTileIcon extends StatelessWidget {
  const DanaviewTileIcon(
    IconData this.icon, {
    super.key,
    this.color = DanaviewColors.primaryLight,
    this.backgroundColor,
    this.size = 32,
  }) : glyph = null;

  const DanaviewTileIcon.glyph(
    DanaviewGlyphKind this.glyph, {
    super.key,
    this.color = DanaviewColors.primaryLight,
    this.backgroundColor,
    this.size = 32,
  }) : icon = null;

  final IconData? icon;
  final DanaviewGlyphKind? glyph;
  final Color color;

  final Color? backgroundColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.16),
        borderRadius: DanaviewRadius.smAll,
      ),
      child: danaviewIconOrGlyph(icon, glyph, size: size * 0.56, color: color),
    );
  }
}

/// The §7 "premium" list icon tile: a neutral [size] (28 pt) tile in
/// [DanaviewColors.surfaceElevatedHigher], radius 8, 10 % hairline, 12 % top highlight and a white
/// 15 pt glyph. Always neutral, never a coloured square. Use it as a [DanaviewListTile.leading].
class DanaviewIconTile extends StatelessWidget {
  const DanaviewIconTile(
    IconData this.icon, {
    super.key,
    this.color = DanaviewColors.textPrimary,
    this.size = 28,
    this.iconSize,
  }) : glyph = null;

  const DanaviewIconTile.glyph(
    DanaviewGlyphKind this.glyph, {
    super.key,
    this.color = DanaviewColors.textPrimary,
    this.size = 28,
    this.iconSize,
  }) : icon = null;

  final IconData? icon;
  final DanaviewGlyphKind? glyph;

  /// Glyph colour; white by default ([DanaviewColors.primaryLight] only for an active state).
  final Color color;
  final double size;

  /// Defaults to 15 at 28 pt and scales with [size].
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    // The radius scales with the tile so a 48 pt tile keeps the same corner shape (8 at 28 pt).
    final radius = BorderRadius.all(Radius.circular(DanaviewRadius.tile * size / 28));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: DanaviewDepth.iconTile(borderRadius: radius),
      child: danaviewIconOrGlyph(icon, glyph, size: iconSize ?? size * 15 / 28, color: color),
    );
  }
}

/// A §8 grouped list: a [DanaviewColors.surface] card, radius 12, holding rows separated by
/// 0.5 pt inset dividers (white 6 %) that start after the icon tile. Rows are usually
/// [DanaviewListTile]s with a [DanaviewIconTile] leading, a `value` and `showChevron`; pass them
/// `borderRadius: BorderRadius.zero` (the card clips them).
class DanaviewGroupedList extends StatelessWidget {
  const DanaviewGroupedList({
    super.key,
    required this.children,
    this.dividerIndent = 52,
    this.color = DanaviewColors.surface,
    this.borderRadius = DanaviewRadius.controlAll,
    this.margin,
  });

  final List<Widget> children;

  /// Start inset of each divider: row padding 12 + icon tile 28 + gap 12. Use 12 for rows
  /// without a leading tile.
  final double dividerIndent;
  final Color color;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(color: color, shape: DanaviewDepth.shape(borderRadius)),
      foregroundDecoration: ShapeDecoration(shape: DanaviewDepth.border(borderRadius: borderRadius)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Padding(
                padding: EdgeInsetsDirectional.only(start: dividerIndent),
                child: const SizedBox(
                  height: DanaviewBorders.width,
                  child: ColoredBox(color: DanaviewColors.divider),
                ),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}
