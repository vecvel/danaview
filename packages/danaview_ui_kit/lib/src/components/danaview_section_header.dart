import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import 'danaview_button.dart';

class DanaviewSectionHeader extends StatelessWidget {
  const DanaviewSectionHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.action,
    EdgeInsetsGeometry? padding,
    this.large = false,
    this.actionLabel,
    this.onAction,
  }) : padding = padding ?? (large ? const EdgeInsets.fromLTRB(0, 24, 0, 8) : const EdgeInsets.fromLTRB(4, 16, 4, 8));

  /// A §8 Home/tab section header: 20/700 white title, 24 above and 8 below, with an optional
  /// `primaryLight` text action ("See all", "New", "Add").
  const DanaviewSectionHeader.large(
    this.title, {
    super.key,
    this.subtitle,
    this.action,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(0, 24, 0, 8),
  }) : large = true;

  final String title;
  final String? subtitle;

  /// Trailing widget (e.g. a small ghost DanaviewButton). It gets whatever the title doesn't
  /// need, and at least half the width. Takes precedence over [actionLabel].
  final Widget? action;
  final EdgeInsetsGeometry padding;

  /// Uses [DanaviewTextStyles.sectionHeader] (20/700 white) instead of the compact 13/600 grey
  /// group label.
  final bool large;

  /// Label of a `primaryLight` text action ([DanaviewButton.text]) at the end of the header.
  final String? actionLabel;
  final VoidCallback? onAction;

  TextStyle get _style => large ? DanaviewTextStyles.sectionHeader : _titleStyle;

  Widget? get _action {
    if (action != null) return action;
    if (actionLabel == null) return null;
    return DanaviewButton.text(label: actionLabel!, size: DanaviewButtonSize.sm, onPressed: onAction);
  }

  static const TextStyle _titleStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: DanaviewColors.textSecondary,
  );

  double _titleWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: DefaultTextStyle.of(context).style.merge(_style)),
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
    final action = _action;
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style),
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
