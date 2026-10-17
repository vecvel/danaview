import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';

class DanaviewSectionHeader extends StatelessWidget {
  const DanaviewSectionHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
  });

  final String title;
  final String? subtitle;

  /// Trailing widget (e.g. a small ghost DanaviewButton). It gets whatever the title doesn't
  /// need, and at least half the width.
  final Widget? action;
  final EdgeInsetsGeometry padding;

  static const TextStyle _titleStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: DanaviewColors.textSecondary,
  );

  double _titleWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: DefaultTextStyle.of(context).style.merge(_titleStyle)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.caption,
          ),
        ],
      ],
    );

    return Padding(
      padding: padding,
      child: action == null
          ? Align(alignment: AlignmentDirectional.centerStart, child: text)
          : LayoutBuilder(
              builder: (context, constraints) {
                final available = constraints.maxWidth;
                final maxAction = available.isFinite
                    ? math.max(available / 2, available - 12 - _titleWidth(context))
                    : double.infinity;
                return Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxAction),
                      child: action,
                    ),
                  ],
                );
              },
            ),
    );
  }
}
