import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_depth.dart';
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
    this.iconColor = DanaviewColors.textPrimary,
  }) : assert(icon != null || glyph != null, 'Pass an icon or a glyph');

  final IconData? icon;

  /// Drawn instead of [icon] when set.
  final DanaviewGlyphKind? glyph;
  final String title;
  final String? message;

  /// Use one secondary button (§8); the view's one primary button lives elsewhere.
  final List<Widget> actions;

  /// Glyph colour inside the neutral tile; white by default.
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    // Full width (owner rule: no max-width caps); the text wraps inside the page gutter.
    final content = Padding(
        padding: const EdgeInsets.all(DanaviewSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // §8: a 48 pt neutral icon tile, never a coloured square.
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: DanaviewDepth.iconTile(borderRadius: DanaviewRadius.controlAll),
              child: danaviewIconOrGlyph(icon, glyph, size: 24, color: iconColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.rowTitle,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: DanaviewTextStyles.subhead,
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
