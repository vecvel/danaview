import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_list_tile.dart';
import 'danaview_pressable.dart';

class DanaviewSwitch extends StatelessWidget {
  const DanaviewSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor = DanaviewColors.primary,
    this.semanticLabel,
  });

  static const double _trackWidth = 50;
  static const double _trackHeight = 30;
  static const double _thumb = 26;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final touch = context.isTouchPlatform;
    return DanaviewPressable.builder(
      onTap: enabled ? () => onChanged!(!value) : null,
      isButton: false,
      toggled: value,
      semanticLabel: semanticLabel,
      builder: (context, state) {
        const radius = BorderRadius.all(Radius.circular(_trackHeight / 2));
        final track = AnimatedContainer(
          duration: DanaviewMotion.normal,
          curve: DanaviewMotion.curve,
          width: _trackWidth,
          height: _trackHeight,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            // §8: active track primary, inactive track white 18 %.
            color: value ? activeColor : DanaviewColors.trackBackground,
            borderRadius: radius,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.fromBorderSide(
              state.focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: Colors.transparent),
            ),
          ),
          child: AnimatedAlign(
            duration: DanaviewMotion.normal,
            curve: DanaviewMotion.curve,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: DanaviewMotion.fast,
              curve: DanaviewMotion.curve,
              // Owner rule: no press effect, so the thumb does not stretch while held.
              width: _thumb,
              height: _thumb,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.all(Radius.circular(_thumb / 2)),
                boxShadow: DanaviewShadows.subtle,
              ),
            ),
          ),
        );
        return danaviewDimmed(
          enabled,
          SizedBox(
            width: _trackWidth,
            height: touch ? DanaviewSpacing.minTapTarget : _trackHeight,
            child: Center(child: track),
          ),
        );
      },
    );
  }
}

class DanaviewSwitchRow extends StatelessWidget {
  const DanaviewSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return DanaviewListTile(
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      leading: leading,
      dense: dense,
      enabled: onChanged != null,
      toggled: value,
      onTap: onChanged == null ? null : () => onChanged(!value),
      // The row owns semantics, focus and dimming; the switch is only the visual.
      trailing: ExcludeSemantics(
        child: ExcludeFocus(
          child: IgnorePointer(
            ignoring: onChanged == null,
            child: DanaviewSwitch(value: value, onChanged: onChanged ?? (_) {}),
          ),
        ),
      ),
    );
  }
}
