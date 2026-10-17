import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_glyph.dart';

class DanaviewEmptyState extends StatelessWidget {
  const DanaviewEmptyState({
    super.key,
    this.icon,
    this.glyph,
    required this.title,
    this.message,
    this.actions = const [],
    this.iconColor = DanaviewColors.primaryLight,
  }) : assert(icon != null || glyph != null, 'Pass an icon or a glyph');

  final IconData? icon;

  /// Drawn instead of [icon] when set.
  final DanaviewGlyphKind? glyph;
  final String title;
  final String? message;

  final List<Widget> actions;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Padding(
        padding: const EdgeInsets.all(DanaviewSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.14),
                borderRadius: DanaviewRadius.lgAll,
              ),
              child: danaviewIconOrGlyph(icon, glyph, size: 26, color: iconColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.title,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: DanaviewTextStyles.bodySecondary,
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return Center(child: content);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
              minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
            ),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}
