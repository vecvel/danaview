// OWNER: UX-16
//
// ColorField (ux.md §9.3): a colour swatch that opens DanaviewColorPicker in a sheet. Edits stream
// through [onChanged] bracketed by [onChangeStart]/[onChangeEnd] (every picker gesture, swatch or
// hex entry), so the caller can turn one gesture into one history entry (EditTransaction). The
// sheet keeps its own copy of the colour, so it follows the edits even though the route does not
// rebuild with the inspector.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Copy of the colour field.
abstract final class ColorFieldStrings {
  /// Default sheet title and semantics label.
  static const String color = 'Colour';

  /// Semantics hint of the swatch.
  static const String hint = 'Opens the colour picker';

  /// Semantics value ("#FF8800").
  static String value(Color color, {bool alpha = false}) => '#${DanaviewColorPicker.formatHex(color, includeAlpha: alpha)}';
}

/// A swatch that opens DanaviewColorPicker (ux.md §9.3).
class ColorField extends StatelessWidget {
  /// Creates the field.
  const ColorField({
    super.key,
    required this.color,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.label = ColorFieldStrings.color,
    this.showOpacity = false,
    this.onEyedropper,
    this.enabled = true,
    this.size = 32,
  });

  /// The colour.
  final Color color;

  /// Every edit.
  final ValueChanged<Color> onChanged;

  /// An edit gesture starts.
  final ValueChanged<Color>? onChangeStart;

  /// An edit gesture ends.
  final ValueChanged<Color>? onChangeEnd;

  /// Sheet title and semantics label.
  final String label;

  /// Shows the opacity strip.
  final bool showOpacity;

  /// Picks a colour from the preview (eyedropper, UX-23), or null.
  final FutureOr<Color?> Function()? onEyedropper;

  /// Whether the swatch opens the picker.
  final bool enabled;

  /// Swatch size.
  final double size;

  /// Opens the picker sheet.
  Future<void> open(BuildContext context) {
    final current = ValueNotifier<Color>(color);
    return showDanaviewSheet<void>(
      context,
      title: label,
      builder: (context) => ValueListenableBuilder<Color>(
        valueListenable: current,
        builder: (context, value, _) => DanaviewColorPicker(
          color: value,
          showOpacity: showOpacity,
          onEyedropper: onEyedropper,
          semanticLabel: label,
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
          onChanged: (c) {
            current.value = c;
            onChanged(c);
          },
        ),
      ),
    ).whenComplete(current.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final target = context.isTouchPlatform ? DanaviewSpacing.minTapTarget : 0.0;
    return DanaviewPressable(
      onTap: enabled ? () => open(context) : null,
      enabled: enabled,
      semanticLabel: '$label, ${ColorFieldStrings.value(color, alpha: showOpacity)}',
      tooltip: label,
      borderRadius: DanaviewRadius.smAll,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: target, minHeight: target),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox(
            width: size,
            height: size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: DanaviewRadius.smAll,
                border: const Border.fromBorderSide(DanaviewBorders.hairline),
                boxShadow: DanaviewShadows.subtle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
