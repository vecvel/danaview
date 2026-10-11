import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

/// "Step 2 of 3" with progress dots, for multi-step sheets such as the auto-captions flow.
///
/// [step] is 1-based and clamped into 1..[count]. The label is the single announcement for
/// assistive technology; the dots only decorate it. Dots wrap and the label ellipsizes, so the
/// indicator never overflows at any width or text scale.
class DanaviewStepIndicator extends StatelessWidget {
  const DanaviewStepIndicator({
    super.key,
    required this.step,
    required this.count,
    this.label,
    this.showLabel = true,
    this.semanticLabel,
  }) : assert(count >= 1, 'count must be at least 1');

  final int step;
  final int count;

  /// Replaces the default "Step 2 of 3" text.
  final String? label;
  final bool showLabel;

  /// Replaces the spoken text (defaults to the visible label, or "Step 2 of 3").
  final String? semanticLabel;

  static const double dotSize = 8;
  static const double activeWidth = 20;
  static const double gap = 6;

  /// Reached steps: 3:1 or better on every kit surface.
  static const Color reachedColor = DanaviewColors.primaryLight;

  /// Steps still ahead of the user (decorative; the label carries the state).
  static const Color upcomingColor = Color(0x47FFFFFF);

  int get _current => step.clamp(1, count);

  String get _defaultLabel => 'Step $_current of $count';

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final text = label ?? _defaultLabel;

    final dots = Wrap(
      spacing: gap,
      runSpacing: gap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 1; i <= count; i++)
          AnimatedContainer(
            duration: DanaviewMotion.normal,
            curve: DanaviewMotion.curve,
            width: i == current ? activeWidth : dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: i <= current ? reachedColor : upcomingColor,
              borderRadius: BorderRadius.circular(dotSize / 2),
            ),
          ),
      ],
    );

    return Semantics(
      container: true,
      label: semanticLabel ?? text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: dots),
            if (showLabel) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
