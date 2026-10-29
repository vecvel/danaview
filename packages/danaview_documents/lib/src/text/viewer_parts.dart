// OWNER: HOM-23
//
// Pieces shared by the text viewer and the CSV grid: the "first 50 MB" notice with "Open in
// another app" (HOM plan §8.4), the options menu button, the loading state and the row metrics
// that follow the text scale.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../card/document_format.dart';
import '../card/document_out.dart';
import '../router/viewer_file.dart';

/// The text style of document rows and cells (Figtree from the theme, tabular figures).
TextStyle documentRowStyle(Color color) => TextStyle(
      fontSize: 13,
      height: 1.45,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// The height of one unwrapped row at the ambient text scale.
double documentRowExtent(BuildContext context, {double padding = 0}) => MediaQuery.textScalerOf(context).scale(13) * 1.45 + padding;

/// Tabs as four spaces (a Text lays out a tab as one narrow glyph).
String displayRow(String row) => row.contains('\t') ? row.replaceAll('\t', '    ') : row;

/// "Showing the first 50 MB" with "Open in another app" next to it.
class TruncationNotice extends StatelessWidget {
  /// A notice for [file], of which [shownBytes] of [totalBytes] are shown.
  const TruncationNotice({super.key, required this.file, required this.shownBytes, required this.totalBytes, this.fileOut});

  /// The file.
  final ViewerFile file;

  /// Bytes shown.
  final int shownBytes;

  /// Size of the file.
  final int totalBytes;

  /// Getting files out; the button hides without "Open in another app".
  final FileOutPort? fileOut;

  @override
  Widget build(BuildContext context) {
    final port = fileOut;
    final text = Text(
      'Showing the first ${formatByteSize(shownBytes)} of ${formatByteSize(totalBytes)}.',
      style: DanaviewTextStyles.bodySecondary,
    );
    final button = port != null && port.capabilities.canOpenIn
        ? Builder(
            builder: (context) => DanaviewButton.tonal(
              label: 'Open in another app',
              icon: Icons.open_in_new_rounded,
              semanticLabel: 'Open in another app',
              onPressed: () => openInAnotherApp(context, port, file),
            ),
          )
        : null;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: DanaviewColors.surface,
        border: Border(bottom: DanaviewBorders.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.sm),
        child: LayoutBuilder(
          builder: (context, c) {
            if (button == null) return Align(alignment: Alignment.centerLeft, child: text);
            // Side by side only when the button and a readable share of the sentence both fit at
            // the ambient text scale: the button grows with it, and a fixed 440 px cut left the
            // sentence a sliver at 568 px and 1.35 (wrapped into a 224 px tall notice that squeezed
            // the CSV grid below its header row).
            final fontSize = DanaviewTextStyles.bodySecondary.fontSize ?? 14;
            final scale = MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
            if (c.maxWidth < 440 * scale) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [text, const SizedBox(height: DanaviewSpacing.xs), button],
              );
            }
            return Row(children: [Expanded(child: text), const SizedBox(width: DanaviewSpacing.sm), button]);
          },
        ),
      ),
    );
  }
}

/// The round "View options" button that opens [entries].
class ViewerOptionsButton extends StatelessWidget {
  /// A menu button with [entries].
  const ViewerOptionsButton({super.key, required this.entries});

  /// The menu.
  final List<DanaviewMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    return DanaviewMenuAnchor(
      width: 240,
      alignment: DanaviewMenuAlignment.end,
      entries: entries,
      builder: (context, open, isOpen) => DanaviewIconButton(
        icon: Icons.more_horiz_rounded,
        size: 44,
        selected: isOpen,
        onPressed: open,
        semanticLabel: 'View options',
        tooltip: 'View options',
      ),
    );
  }
}

/// The centred spinner shown while a document loads.
class DocumentLoading extends StatelessWidget {
  /// A loading state.
  const DocumentLoading({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: DanaviewSpinner(semanticLabel: 'Opening the file'));
}
