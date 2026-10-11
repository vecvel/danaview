// OWNER: UX-16
//
// ToolTile (ux.md §9.2): one tile of the tool strip, the rail or a tool pane: icon over a one-line
// label, or the icon alone at ladder step 3 (`iconOnlyTools`, labels move to the tooltip and
// semantics).
//
// * Width `clamp(measuredLabel + 16, 64, 112)` measured at the current text scale (ux.md §6.7 rule
//   3); icon-only tiles are 52 wide. The strip scrolls and never wraps.
// * A disabled tile stays visible at 40 % opacity and stays tappable: the tap explains why it is
//   disabled (the toolbar shows the registry's reason in a toast). Semantics: button + label + hint
//   (the reason when disabled, else the shortcut).
// * Standard rounded corners (VwishRadius.md): tiles carry text, so they are never fully round.

import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../layout/priority_row_planner.dart' show measureTextWidth;
import 'toolbar_strings.dart';

/// What a tile shows and does.
@immutable
final class ToolTileData {
  /// Creates the data.
  const ToolTileData({
    required this.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.selected = false,
    this.tooltip,
    this.reason,
    this.shortcut,
  });

  /// Stable key (`split`, `text.font`, `tool.media`).
  final String key;

  /// Label.
  final String label;

  /// Icon.
  final IconData icon;

  /// Runs the tool, or explains why it is disabled.
  final VoidCallback onTap;

  /// Whether the tool can run now.
  final bool enabled;

  /// Whether the tool is active (its panel or tab is open).
  final bool selected;

  /// Tooltip ("Split (S)"); defaults to the label.
  final String? tooltip;

  /// Why the tool is disabled (null when enabled).
  final String? reason;

  /// The primary shortcut label, if any.
  final String? shortcut;

  @override
  bool operator ==(Object other) =>
      other is ToolTileData &&
      other.key == key &&
      other.label == label &&
      other.icon == icon &&
      other.enabled == enabled &&
      other.selected == selected &&
      other.tooltip == tooltip &&
      other.reason == reason &&
      other.shortcut == shortcut;

  @override
  int get hashCode => Object.hash(key, label, icon, enabled, selected, tooltip, reason, shortcut);

  @override
  String toString() => 'ToolTileData($key, enabled: $enabled${reason == null ? '' : ', $reason'})';
}

/// One tool tile (ux.md §9.2).
class ToolTile extends StatelessWidget {
  /// Creates a tile [height] tall; [width] defaults to [widthFor].
  const ToolTile({super.key, required this.data, required this.height, this.width, this.iconOnly = false});

  /// What it shows.
  final ToolTileData data;

  /// Height.
  final double height;

  /// Width, or null for [widthFor].
  final double? width;

  /// Icon only (ladder step 3).
  final bool iconOnly;

  /// Smallest tile width.
  static const double minWidth = 64;

  /// Largest tile width.
  static const double maxWidth = 112;

  /// Width of an icon-only tile.
  static const double iconOnlyWidth = 52;

  /// Icon size.
  static const double iconSize = 22;

  /// Label style (Figtree).
  static final TextStyle labelStyle = VwishTextStyles.micro.copyWith(fontFamily: VwishFonts.family, height: 1.2);

  /// Width of a tile labelled [label] at [textScaler] (ux.md §6.7 rule 3).
  static double widthFor(String label, TextScaler textScaler, {bool iconOnly = false}) {
    if (iconOnly) return iconOnlyWidth;
    return (measureTextWidth(label, labelStyle, textScaler: textScaler) + 16).clamp(minWidth, maxWidth).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final w = width ?? widthFor(data.label, textScaler, iconOnly: iconOnly);
    final labelHeight = textScaler.scale(labelStyle.fontSize ?? 11) * (labelStyle.height ?? 1.2);
    // The label shows only when it fits under the icon with 6 px padding above and below.
    final showLabel = !iconOnly && height >= iconSize + 4 + labelHeight + 12;
    final fg = data.selected ? VwishColors.primaryLight : VwishColors.textSecondary;
    final hint = data.reason ?? (data.shortcut == null ? null : ToolbarStrings.shortcutHint(data.shortcut!));
    final tooltip = data.tooltip ?? data.label;

    final tile = VwishPressable.builder(
      onTap: data.onTap,
      selected: data.selected,
      semanticLabel: data.label,
      tooltip: showLabel && tooltip == data.label ? null : tooltip,
      builder: (context, state) {
        final fill = data.selected
            ? VwishColors.primaryTonal
            : state.pressed
                ? VwishColors.pressed
                : state.hovered
                    ? VwishColors.hover
                    : const Color(0x00000000);
        return Container(
          width: w,
          height: height,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: VwishRadius.mdAll,
            border: state.focused ? Border.fromBorderSide(VwishBorders.focus) : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Opacity(
            opacity: data.enabled ? 1 : VwishColors.disabledOpacity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(data.icon, size: iconSize, color: fg),
                if (showLabel) ...[
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                      child: Text(
                    data.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: labelStyle.copyWith(color: data.selected ? VwishColors.primaryLight : VwishColors.textSecondary),
                  )),
                ],
              ],
            ),
          ),
        );
      },
    );
    return MergeSemantics(
      child: Semantics(
        hint: hint,
        child: tile,
      ),
    );
  }
}
