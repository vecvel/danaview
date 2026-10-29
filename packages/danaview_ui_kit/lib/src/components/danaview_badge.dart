import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

class DanaviewBadge extends StatelessWidget {
  const DanaviewBadge(
    this.label, {
    super.key,
    this.color = DanaviewColors.primaryLight,
    this.icon,
    this.solid = false,
  });

  final String label;

  final Color color;
  final IconData? icon;
  final bool solid;

  /// The tinted fill behind a non-solid badge: [color] at 10 %, the same strength as
  /// [DanaviewColors.destructiveSoft]. At 16 % the red ([DanaviewColors.primaryLight]) and grey
  /// ([DanaviewColors.textSecondary]) labels fell to 4.2–4.4:1 on raised cards; at 10 % every badge
  /// colour keeps 4.5:1 on [DanaviewColors.surfaceElevated].
  static Color tintFor(Color color) => color.withValues(alpha: 0.10);

  @override
  Widget build(BuildContext context) {
    final fg = solid ? DanaviewColors.foregroundOn(color) : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: solid ? color : tintFor(color),
        borderRadius: DanaviewRadius.xsAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.3,
                letterSpacing: 0.1,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
