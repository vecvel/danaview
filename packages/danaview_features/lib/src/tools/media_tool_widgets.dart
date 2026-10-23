import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_widgets.dart';

/// Page chrome shared by the media tools: opaque top bar and a centred scrolling column.
class MediaToolPage extends StatelessWidget {
  const MediaToolPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.onBack,
    this.actions = const [],
    required this.children,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: title, subtitle: subtitle, onBack: onBack, actions: actions),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = DanaviewSpacing.pageInsets(constraints.maxWidth);
            return ListView(
              padding: insets.copyWith(
                top: DanaviewSpacing.lg,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              children: children,
            );
          },
        ),
      ),
    );
  }
}

/// An opaque card of [MediaInfoRow]s separated by hairlines.
class MediaInfoGroup extends StatelessWidget {
  const MediaInfoGroup({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return DanaviewSurface(
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const DanaviewRowDivider(indent: 12),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// A label and its value side by side, the value end-aligned; stacked when the row is too
/// narrow for both. Long values wrap up to [valueMaxLines] lines.
class MediaInfoRow extends StatelessWidget {
  const MediaInfoRow(this.label, this.value, {super.key, this.valueMaxLines = 4, this.valueColor});

  final String label;
  final String value;
  final int valueMaxLines;
  final Color? valueColor;

  static const _labelStyle = TextStyle(fontSize: 14, height: 1.3, color: DanaviewColors.textSecondary);

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.3,
      color: valueColor ?? DanaviewColors.textPrimary,
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final labelText = Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: _labelStyle);
            if (constraints.maxWidth < 240 * scale) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  labelText,
                  const SizedBox(height: 2),
                  Text(value, maxLines: valueMaxLines, overflow: TextOverflow.ellipsis, style: valueStyle),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: (constraints.maxWidth * 0.38).clamp(96.0, 180.0), child: labelText),
                const SizedBox(width: DanaviewSpacing.md),
                Expanded(
                  child: Text(
                    value,
                    maxLines: valueMaxLines,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: valueStyle,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Small print under a section.
class MediaToolFootnote extends StatelessWidget {
  const MediaToolFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
      child: Text(text, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.4)),
    );
  }
}

/// A value with minus/plus steps above a slider, for picking numbers by touch or keyboard.
class MediaStepperSlider extends StatelessWidget {
  const MediaStepperSlider({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.semanticFormatter,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final String Function(double value)? semanticFormatter;

  /// Snaps to the step grid and drops float noise (0.1 + 0.2 must stay 0.3).
  double _snap(double v) {
    final snapped = min + ((v - min) / step).round() * step;
    return double.parse(snapped.clamp(min, max).toStringAsFixed(4));
  }

  @override
  Widget build(BuildContext context) {
    final current = value.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.caption.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(valueLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.title),
                  ],
                ),
              ),
            ),
            const SizedBox(width: DanaviewSpacing.sm),
            DanaviewIconButton(
              icon: Icons.remove_rounded,
              variant: DanaviewIconButtonVariant.filled,
              size: 36,
              iconSize: 20,
              tooltip: 'Less',
              semanticLabel: 'Decrease $label',
              onPressed: current > min ? () => onChanged(_snap(current - step)) : null,
            ),
            const SizedBox(width: DanaviewSpacing.xs),
            DanaviewIconButton(
              icon: Icons.add_rounded,
              variant: DanaviewIconButtonVariant.filled,
              size: 36,
              iconSize: 20,
              tooltip: 'More',
              semanticLabel: 'Increase $label',
              onPressed: current < max ? () => onChanged(_snap(current + step)) : null,
            ),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        DanaviewSlider(
          value: current,
          min: min,
          max: max,
          divisions: math.max(1, ((max - min) / step).round()),
          semanticLabel: label,
          semanticFormatter: semanticFormatter ?? (_) => valueLabel,
          onChanged: (v) {
            final snapped = _snap(v);
            if (snapped != value) onChanged(snapped);
          },
        ),
      ],
    );
  }
}

/// The headline answer of a tool: an eyebrow, a large value, a caption and optional stats.
class MediaResultCard extends StatelessWidget {
  const MediaResultCard({
    super.key,
    required this.eyebrow,
    required this.value,
    required this.caption,
    this.stats = const [],
    this.accent = DanaviewColors.primaryLight,
  });

  final String eyebrow;
  final String value;
  final String caption;
  final List<({String label, String value})> stats;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DanaviewSurface(
      shadow: DanaviewShadow.subtle,
      padding: const EdgeInsets.all(DanaviewSpacing.lg),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.micro.copyWith(color: accent, fontWeight: FontWeight.w600, letterSpacing: 0.8),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.largeTitle.copyWith(fontSize: 30, height: 1.15),
            ),
            const SizedBox(height: 4),
            Text(caption, style: DanaviewTextStyles.bodySecondary),
            if (stats.isNotEmpty) ...[
              const SizedBox(height: DanaviewSpacing.md),
              Wrap(
                spacing: DanaviewSpacing.sm,
                runSpacing: DanaviewSpacing.sm,
                children: [for (final stat in stats) _Stat(label: stat.label, value: stat.value)],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(color: DanaviewColors.surfaceElevatedHigher, borderRadius: DanaviewRadius.mdAll),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.micro),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.label.copyWith(fontSize: 14),
          ),
        ],
      ),
    );
  }
}
