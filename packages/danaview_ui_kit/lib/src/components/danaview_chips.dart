import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_menu.dart';
import 'danaview_pressable.dart';

class DanaviewChoiceChip extends StatelessWidget {
  const DanaviewChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    final fill = selected ? DanaviewColors.primary : DanaviewColors.surfaceElevatedHigher;
    final fg = selected ? DanaviewColors.foregroundOn(DanaviewColors.primary) : DanaviewColors.textSecondary;
    return DanaviewPressable.builder(
      onTap: active ? onTap : null,
      selected: selected,
      builder: (context, state) {
        final visual = AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: danaviewInteractiveFill(fill, state), borderRadius: DanaviewRadius.smAll),
          foregroundDecoration: BoxDecoration(
            borderRadius: DanaviewRadius.smAll,
            border: Border.fromBorderSide(
              state.focused
                  ? DanaviewBorders.focus
                  : selected
                      ? DanaviewBorders.hairline.copyWith(color: Colors.transparent)
                      : DanaviewBorders.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    height: 1.2,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        );
        return danaviewDimmed(active, danaviewTapTarget(context, visual));
      },
    );
  }
}

class DanaviewChipGroup extends StatelessWidget {
  const DanaviewChipGroup({
    super.key,
    required this.children,
    this.spacing = 8,
    this.runSpacing,
    this.alignment = WrapAlignment.start,
  });

  final List<Widget> children;
  final double spacing;

  /// Defaults to 8 on desktop and 0 on touch, where chips already carry a 44pt hit area.
  final double? runSpacing;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing ?? (context.isTouchPlatform ? 0 : 8),
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

/// Equal-width segments. When the option icons would not fit the segments drop them, and when even
/// a bare label would not fit it falls back to wrapping [DanaviewChoiceChip]s.
class DanaviewSegmentedControl<T> extends StatelessWidget {
  const DanaviewSegmentedControl({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });

  final T value;
  final List<DanaviewOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool enabled;

  static const double _inset = 3;
  static const double _hPad = 10;
  static const double _iconWidth = 15 + 6;
  static const TextStyle _labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.2);

  double _neededSegmentWidth(BuildContext context, {required bool icons}) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style.merge(_labelStyle);
    var widest = 0.0;
    for (final option in options) {
      final painter = TextPainter(
        text: TextSpan(text: option.label, style: base),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width + (icons && option.icon != null ? _iconWidth : 0));
      painter.dispose();
    }
    return widest + _hPad * 2;
  }

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final needed = _neededSegmentWidth(context, icons: true);
    final bare = options.any((o) => o.icon != null) ? _neededSegmentWidth(context, icons: false) : needed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final segment = width.isFinite ? (width - _inset * 2) / options.length : 0.0;
        if (!width.isFinite || segment < bare) return _buildChips();
        return _buildSegments(context, width, segment, icons: segment >= needed);
      },
    );
  }

  Widget _buildChips() {
    return DanaviewChipGroup(
      children: [
        for (final option in options)
          DanaviewChoiceChip(
            label: option.label,
            icon: option.icon,
            selected: option.value == value,
            enabled: enabled && option.enabled,
            onTap: () => onChanged(option.value),
          ),
      ],
    );
  }

  Widget _buildSegments(BuildContext context, double width, double segment, {required bool icons}) {
    final index = options.indexWhere((o) => o.value == value);
    final height = context.isTouchPlatform ? DanaviewSpacing.minTapTarget : 36.0;
    final selectedFg = DanaviewColors.foregroundOn(DanaviewColors.primary);
    return danaviewDimmed(
      enabled,
      Container(
        width: width,
        height: height,
        // Horizontal inset only: the segments span the full height so each one is a full-height
        // tap target and screen-reader frame (44 px on touch); the vertical inset is drawn inside
        // the segment and the indicator, so the control looks the same.
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        decoration: const BoxDecoration(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.mdAll,
        ),
        foregroundDecoration: const BoxDecoration(borderRadius: DanaviewRadius.mdAll, border: DanaviewBorders.all),
        child: Stack(
          children: [
            if (index >= 0)
              AnimatedPositioned(
                duration: DanaviewMotion.normal,
                curve: DanaviewMotion.curve,
                left: segment * index,
                top: _inset,
                bottom: _inset,
                width: segment,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: DanaviewColors.primary,
                    borderRadius: BorderRadius.all(Radius.circular(DanaviewRadius.md - _inset)),
                  ),
                ),
              ),
            Row(
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(
                    child: _Segment(
                      option: options[i],
                      showIcon: icons,
                      selected: i == index,
                      foreground: i == index ? selectedFg : DanaviewColors.textSecondary,
                      onTap: enabled && options[i].enabled ? () => onChanged(options[i].value) : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.showIcon,
    required this.selected,
    required this.foreground,
    required this.onTap,
  });

  final DanaviewOption<T> option;
  final bool showIcon;
  final bool selected;
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DanaviewPressable.builder(
      onTap: onTap,
      selected: selected,
      semanticLabel: option.label,
      builder: (context, state) {
        // Owner rule: no hover or press tint; only hardware-keyboard focus tints.
        final tint = !selected && state.focused;
        final inner = AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSegmentedControl._hPad),
          decoration: BoxDecoration(
            color: tint ? DanaviewColors.hover : const Color(0x00FFFFFF),
            borderRadius: const BorderRadius.all(Radius.circular(DanaviewRadius.md - DanaviewSegmentedControl._inset)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIcon && option.icon != null) ...[
                Icon(option.icon, size: 15, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: DanaviewMotion.fast,
                  style: DefaultTextStyle.of(context)
                      .style
                      .merge(DanaviewSegmentedControl._labelStyle.copyWith(color: foreground)),
                  // The pressable carries the label; the text is not read a second time.
                  child: ExcludeSemantics(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: DanaviewSegmentedControl._inset),
          child: inner,
        );
      },
    );
  }
}
