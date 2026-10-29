// OWNER: HOM-28
//
// "Add files" of the merge screen (HOM plan §8.5): a kit sheet listing the library's PDFs and
// photos (newest first, the app root supplies them), filtered by a name search, with a check per
// row and Add. Rows already in the merge are marked as such but can be added again. Kit components
// only (rule 31), 44 px rows, no hover or press tints.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import 'pdf_tool_launcher.dart';

/// Shows the picker over [candidates]; resolves to the picked items in list order (empty when
/// dismissed).
Future<List<PdfMergeItem>> showPdfMergePicker(BuildContext context, {required List<PdfMergeItem> candidates, List<PdfMergeItem> current = const []}) async {
  final picked = await showDanaviewSheet<List<PdfMergeItem>>(
    context,
    title: 'Add files',
    builder: (sheetContext) => PdfMergePickerBody(
      candidates: candidates,
      current: current,
      onDone: (items) => Navigator.of(sheetContext).pop(items),
    ),
  );
  return picked ?? const [];
}

/// The body of the merge picker.
class PdfMergePickerBody extends StatefulWidget {
  /// A picker over [candidates]; [current] are already in the merge.
  const PdfMergePickerBody({super.key, required this.candidates, required this.onDone, this.current = const []});

  /// PDFs and photos to choose from.
  final List<PdfMergeItem> candidates;

  /// Already in the merge.
  final List<PdfMergeItem> current;

  /// Called with the picked items.
  final ValueChanged<List<PdfMergeItem>> onDone;

  @override
  State<PdfMergePickerBody> createState() => _PdfMergePickerBodyState();
}

class _PdfMergePickerBodyState extends State<PdfMergePickerBody> {
  final TextEditingController _query = TextEditingController();
  final List<PdfMergeItem> _picked = [];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PdfMergeItem> get _shown {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return [
      for (final c in widget.candidates)
        if (c.displayName.toLowerCase().contains(q)) c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final height = MediaQuery.sizeOf(context).height * 0.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DanaviewSearchField(controller: _query, hint: 'Search PDFs and photos', semanticLabel: 'Search PDFs and photos', onChanged: (_) => setState(() {})),
        const SizedBox(height: DanaviewSpacing.sm),
        SizedBox(
          height: height.clamp(160.0, 520.0),
          child: shown.isEmpty
              ? const Center(
                  child: DanaviewEmptyState(
                    icon: Icons.picture_as_pdf_outlined,
                    iconColor: DanaviewColors.textSecondary,
                    title: 'No PDFs or photos',
                    message: 'Import some into Danaview first.',
                  ),
                )
              : ClipRect(
                  child: ListView.builder(
                    key: const ValueKey('pdf-merge-picker-list'),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final c = shown[i];
                      final picked = _picked.contains(c);
                      final already = widget.current.contains(c);
                      return DanaviewListTile(
                        key: ValueKey('pdf-merge-pick-$i'),
                        leading: DanaviewIconTile(c.isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined),
                        title: c.displayName,
                        subtitle: already ? 'Already in the merge' : (c.isImage ? 'Photo' : 'PDF'),
                        selected: picked,
                        toggled: picked,
                        trailing: picked ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primaryLight) : null,
                        semanticLabel: c.displayName,
                        onTap: () => setState(() => picked ? _picked.remove(c) : _picked.add(c)),
                      );
                    },
                  ),
                ),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        DanaviewButton.primary(
          key: const ValueKey('pdf-merge-picker-add'),
          label: _picked.isEmpty ? 'Add' : 'Add ${_picked.length}',
          expand: true,
          semanticLabel: 'Add',
          onPressed: _picked.isEmpty ? null : () => widget.onDone(List.of(_picked)),
        ),
      ],
    );
  }
}
