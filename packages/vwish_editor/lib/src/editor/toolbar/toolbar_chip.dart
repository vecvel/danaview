// OWNER: UX-16
//
// The leading chip of the toolbar (ux.md §9.2): `[✕ Video clip]`, a selected VwishChoiceChip with
// `Icons.close_rounded` that clears the selection (or closes a tool tab such as Audio). Its
// semantics hint says what a tap does.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'toolbar_model.dart';

/// The leading chip of a context set or a tool tab.
class ToolbarChipView extends StatelessWidget {
  /// Creates the chip.
  const ToolbarChipView({super.key, required this.chip, this.maxWidth = 168});

  /// What it shows and does.
  final ToolbarChip chip;

  /// Largest width (the label ellipsizes).
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: MergeSemantics(
        child: Semantics(
          hint: chip.hint,
          child: VwishChoiceChip(
            label: chip.label,
            selected: true,
            icon: Icons.close_rounded,
            onTap: chip.onTap,
          ),
        ),
      ),
    );
  }
}
