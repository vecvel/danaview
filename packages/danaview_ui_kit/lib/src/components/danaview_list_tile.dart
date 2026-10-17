import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
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

  @override
  Widget build(BuildContext context) {
    final interactive = enabled && (onTap != null || onLongPress != null);
    final titleColor = destructive ? DanaviewColors.errorLight : DanaviewColors.textPrimary;

    return DanaviewPressable.builder(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      enabled: enabled,
      isButton: interactive,
      selected: selected ? true : null,
      toggled: toggled,
      semanticLabel: semanticLabel,
      pressedScale: 1,
      builder: (context, state) {
        final background = selected
            ? DanaviewColors.primarySoft
            : state.pressed
                ? DanaviewColors.hover
                : (state.hovered || state.focused)
                    ? DanaviewColors.hairlineSubtle
                    : const Color(0x00FFFFFF);
        return danaviewDimmed(
          enabled,
          AnimatedContainer(
            duration: DanaviewMotion.fast,
            curve: DanaviewMotion.curve,
            constraints: BoxConstraints(minHeight: dense ? 44 : 52),
            padding: padding ?? EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : 8),
            decoration: BoxDecoration(color: background, borderRadius: DanaviewRadius.mdAll),
            foregroundDecoration: BoxDecoration(
              borderRadius: DanaviewRadius.mdAll,
              border: Border.fromBorderSide(
                state.focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: Colors.transparent),
              ),
            ),
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
                          fontSize: dense ? 14 : 15,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
                            color: DanaviewColors.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: DanaviewColors.textMuted),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

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
