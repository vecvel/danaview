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

  @override
  Widget build(BuildContext context) {
    final fg = solid ? DanaviewColors.foregroundOn(color) : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.16),
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
