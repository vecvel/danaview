// OWNER: HOM-29
//
// The annotate toolbar under the PDF pages (HOM plan §8.5; Cinema B, DESIGN_SYSTEM §7–§8): a row of
// capsule tools (Select, Pen, Text, Eraser) where only the active tool is red, and below it what
// the tool needs: Highlight / Underline / Strike through for the text selection with the markup
// colours; the pen's colours and widths; the text colours; a hint for the eraser; and Edit text /
// Delete for a selected mark. Colour swatches and width dots are neutral: the chosen one carries a
// check or a raised tile, never an outline. Every control is at least 44 pt, labelled for screen
// readers, without hover or press tints; icon-only capsules on narrow windows, labelled ones from
// 600 px. Nothing here logs annotation text (rule 30).

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import 'pdf_annotate_model.dart';

/// Windows at least this wide show labelled tools.
const double pdfAnnotateWideToolbar = 600;

/// The spoken names of the model's colours.
const Map<int, String> pdfAnnotateColorNames = {
  0xFFFFD60A: 'Yellow',
  0xFF34C759: 'Green',
  0xFF5AC8FA: 'Blue',
  0xFFFF6FB5: 'Pink',
  0xFFE53935: 'Red',
  0xFF1C1C1E: 'Black',
  0xFF1E6FE5: 'Blue',
  0xFF2E9E44: 'Green',
};

/// The label and icon of [tool].
(String, IconData) pdfAnnotateToolLook(PdfAnnotateTool tool) => switch (tool) {
      PdfAnnotateTool.select => ('Select', Icons.highlight_alt_rounded),
      PdfAnnotateTool.pen => ('Pen', Icons.draw_rounded),
      PdfAnnotateTool.text => ('Text', Icons.title_rounded),
      PdfAnnotateTool.eraser => ('Eraser', Icons.auto_fix_normal_rounded),
    };

/// The toolbar of an annotate session.
class PdfAnnotateToolbar extends StatelessWidget {
  /// The toolbar of [model]; [hasTextSelection] enables the markup actions.
  const PdfAnnotateToolbar({
    super.key,
    required this.model,
    required this.hasTextSelection,
    required this.onMarkup,
    required this.onDeleteSelected,
    required this.onEditSelected,
    this.enabled = true,
  });

  /// The session.
  final PdfAnnotateModel model;

  /// The viewer has a text selection.
  final bool hasTextSelection;

  /// Marks the selected text with highlight, underline or strike-through.
  final ValueChanged<PdfAnnotationKind> onMarkup;

  /// Deletes the selected mark.
  final VoidCallback onDeleteSelected;

  /// Edits the selected text box.
  final VoidCallback onEditSelected;

  /// False while a save runs.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: DanaviewColors.surface, border: Border(top: DanaviewBorders.hairline)),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= pdfAnnotateWideToolbar;
            final gutter = wide ? DanaviewSpacing.pageGutter(c.maxWidth) : DanaviewSpacing.xs;
            return Padding(
              padding: EdgeInsets.fromLTRB(gutter, DanaviewSpacing.xs, gutter, DanaviewSpacing.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _tools(wide),
                  const SizedBox(height: DanaviewSpacing.xxs),
                  _options(context, wide),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _tools(bool wide) {
    final tools = [
      for (final tool in PdfAnnotateTool.values)
        PdfAnnotateToolCapsule(
          key: ValueKey('pdf-annotate-tool-${tool.name}'),
          tool: tool,
          selected: model.tool == tool,
          showLabel: wide,
          onTap: enabled ? () => model.tool = tool : null,
        ),
    ];
    if (wide) return Wrap(spacing: DanaviewSpacing.sm, runSpacing: DanaviewSpacing.xs, children: tools);
    return Row(children: [for (final t in tools) Expanded(child: Center(child: t))]);
  }

  Widget _options(BuildContext context, bool wide) {
    final children = <Widget>[];
    final selected = model.selected;
    if (selected != null) {
      if (selected.annotation?.kind == PdfAnnotationKind.freeText) {
        children.add(_action('pdf-annotate-edit', Icons.edit_rounded, 'Edit text', enabled ? onEditSelected : null, wide));
      }
      children.add(_action('pdf-annotate-delete', Icons.delete_outline_rounded, 'Delete', enabled ? onDeleteSelected : null, wide));
    }
    switch (model.tool) {
      case PdfAnnotateTool.select:
        final can = enabled && hasTextSelection;
        children
          ..add(_action('pdf-annotate-highlight', Icons.border_color_rounded, 'Highlight', can ? () => onMarkup(PdfAnnotationKind.highlight) : null, wide))
          ..add(_action('pdf-annotate-underline', Icons.format_underlined_rounded, 'Underline', can ? () => onMarkup(PdfAnnotationKind.underline) : null, wide))
          ..add(_action(
              'pdf-annotate-strike', Icons.format_strikethrough_rounded, 'Strike through', can ? () => onMarkup(PdfAnnotationKind.strikeOut) : null, wide))
          ..addAll(_swatches(PdfAnnotateModel.markupColors, model.markupColor, (c) => model.markupColor = c, 'markup'));
        if (!hasTextSelection && selected == null) children.add(_hint('Select text to mark it'));
      case PdfAnnotateTool.pen:
        children
          ..addAll(_swatches(PdfAnnotateModel.inkColors, model.penColor, (c) => model.penColor = c, 'pen'))
          ..addAll([
            for (final (i, w) in PdfAnnotateModel.penWidths.indexed)
              PdfAnnotateWidthDot(
                key: ValueKey('pdf-annotate-width-$i'),
                width: w,
                label: const ['Fine', 'Medium', 'Bold'][i],
                selected: model.penWidth == w,
                onTap: enabled ? () => model.penWidth = w : null,
              ),
          ]);
      case PdfAnnotateTool.text:
        children.addAll(_swatches(PdfAnnotateModel.inkColors, model.textColor, (c) => model.textColor = c, 'text'));
        if (selected == null) children.add(_hint('Tap the page to add text'));
      case PdfAnnotateTool.eraser:
        children.add(_hint('Tap a mark to remove it'));
    }
    return Wrap(
      spacing: DanaviewSpacing.xs,
      runSpacing: DanaviewSpacing.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  List<Widget> _swatches(List<int> colors, int current, ValueChanged<int> pick, String group) => [
        for (final c in colors)
          PdfAnnotateSwatch(
            key: ValueKey('pdf-annotate-$group-color-${c.toRadixString(16)}'),
            color: Color(c),
            label: pdfAnnotateColorNames[c] ?? 'Colour',
            selected: current == c,
            onTap: enabled ? () => pick(c) : null,
          ),
      ];

  Widget _action(String key, IconData icon, String label, VoidCallback? onTap, bool wide) {
    if (wide) {
      return DanaviewButton.secondary(key: ValueKey(key), label: label, icon: icon, size: DanaviewButtonSize.sm, semanticLabel: label, onPressed: onTap);
    }
    return DanaviewIconButton.toolbar(key: ValueKey(key), icon: icon, tooltip: label, semanticLabel: label, onPressed: onTap);
  }

  Widget _hint(String text) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.footnote.copyWith(color: DanaviewColors.textSecondary)),
          ),
        ),
      );
}

/// One tool: a capsule, red only when it is the active tool.
class PdfAnnotateToolCapsule extends StatelessWidget {
  /// The capsule of [tool].
  const PdfAnnotateToolCapsule({super.key, required this.tool, required this.selected, required this.onTap, this.showLabel = false});

  /// The tool.
  final PdfAnnotateTool tool;

  /// It is the active tool.
  final bool selected;

  /// Picks it.
  final VoidCallback? onTap;

  /// Shows its name next to the glyph.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = pdfAnnotateToolLook(tool);
    final fill = selected ? DanaviewColors.primary : DanaviewColors.surfaceElevated;
    final fg = selected ? DanaviewColors.onPrimary : DanaviewColors.textPrimary;
    final enabled = onTap != null;
    return DanaviewPressable.builder(
      onTap: onTap,
      enabled: enabled,
      selected: selected,
      semanticLabel: label,
      tooltip: showLabel ? null : label,
      builder: (context, state) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget, minWidth: DanaviewSpacing.minTapTarget),
        child: Center(
          widthFactor: 1,
          child: Opacity(
            opacity: enabled ? 1 : DanaviewColors.disabledOpacity,
            child: Container(
              constraints: const BoxConstraints(minHeight: 34, minWidth: 48),
              padding: EdgeInsets.symmetric(horizontal: showLabel ? DanaviewSpacing.md : DanaviewSpacing.sm, vertical: 6),
              decoration: ShapeDecoration(
                color: fill,
                shape: DanaviewDepthBorder(
                  borderRadius: DanaviewRadius.capsuleAll,
                  side: DanaviewBorders.hairline,
                  highlight: selected ? DanaviewColors.highlightStrong : DanaviewColors.highlight,
                ),
              ),
              foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: DanaviewRadius.capsuleAll),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: fg),
                  if (showLabel) ...[
                    const SizedBox(width: DanaviewSpacing.xs),
                    Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.subhead.copyWith(color: fg, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A colour swatch: a 28 pt disc in a 44 pt target; the chosen one shows a check.
class PdfAnnotateSwatch extends StatelessWidget {
  /// A swatch of [color] named [label].
  const PdfAnnotateSwatch({super.key, required this.color, required this.label, required this.selected, required this.onTap});

  /// The colour.
  final Color color;

  /// Its spoken name.
  final String label;

  /// It is the chosen colour.
  final bool selected;

  /// Picks it.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final check = color.computeLuminance() > 0.4 ? DanaviewColors.textOnLight : DanaviewColors.textPrimary;
    return DanaviewPressable.builder(
      onTap: onTap,
      enabled: onTap != null,
      selected: selected,
      semanticLabel: label,
      tooltip: label,
      builder: (context, state) => SizedBox.square(
        dimension: DanaviewSpacing.minTapTarget,
        child: Center(
          child: Container(
            width: 28,
            height: 28,
            // A dark disc (black ink) gets a lighter neutral edge so it reads on the dark bar.
            decoration: DanaviewDepth.circle(
              color: color,
              side: color.computeLuminance() < 0.05 ? const BorderSide(color: Color(0x4DFFFFFF)) : DanaviewBorders.hairline,
            ),
            foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, circle: true),
            child: selected ? Icon(Icons.check_rounded, size: 16, color: check) : null,
          ),
        ),
      ),
    );
  }
}

/// A pen width: a dot of that width in a 44 pt target; the chosen one sits on a raised tile.
class PdfAnnotateWidthDot extends StatelessWidget {
  /// The dot of [width] points named [label].
  const PdfAnnotateWidthDot({super.key, required this.width, required this.label, required this.selected, required this.onTap});

  /// Width in points.
  final double width;

  /// Its spoken name.
  final String label;

  /// It is the chosen width.
  final bool selected;

  /// Picks it.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dot = (width * 2.2).clamp(4.0, 16.0);
    return DanaviewPressable.builder(
      onTap: onTap,
      enabled: onTap != null,
      selected: selected,
      semanticLabel: '$label pen',
      tooltip: '$label pen',
      builder: (context, state) => SizedBox.square(
        dimension: DanaviewSpacing.minTapTarget,
        child: Center(
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: selected ? DanaviewDepth.iconTile(borderRadius: DanaviewRadius.capsuleAll) : null,
            foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, circle: true),
            child: Container(
              width: dot,
              height: dot,
              decoration: const BoxDecoration(color: DanaviewColors.textPrimary, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
