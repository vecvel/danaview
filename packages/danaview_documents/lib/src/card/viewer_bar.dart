// OWNER: HOM-23
//
// The top bar of the in-app document viewers and the file card (ARCH §1.4: kit components only,
// Figtree, dark solid surface with a hairline, targets ≥ 44 px, no overflow at 280 px and text
// scale 1.35): a round back button, the name and a one-line detail that ellipsize, then the
// viewer's actions.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

/// A document viewer's top bar.
class DocumentTopBar extends StatelessWidget {
  /// A bar titled [title]; [onClose] shows the back button.
  const DocumentTopBar({super.key, required this.title, this.subtitle, this.onClose, this.actions = const []});

  /// The file name.
  final String title;

  /// One line under the name (type, size, encoding, …).
  final String? subtitle;

  /// Closes the viewer; null hides the back button.
  final VoidCallback? onClose;

  /// Trailing actions (round icon buttons or a menu anchor).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: DanaviewColors.surface,
        border: Border(bottom: DanaviewBorders.hairline),
      ),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs, vertical: DanaviewSpacing.xs),
            child: Row(
              children: [
                if (onClose != null)
                  DanaviewIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    iconSize: 18,
                    size: 44,
                    onPressed: onClose,
                    semanticLabel: 'Back',
                    tooltip: 'Back',
                  )
                else
                  const SizedBox(width: DanaviewSpacing.sm),
                const SizedBox(width: DanaviewSpacing.xs),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.label.copyWith(fontSize: 15)),
                        if (subtitle != null)
                          Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: DanaviewSpacing.xs),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
