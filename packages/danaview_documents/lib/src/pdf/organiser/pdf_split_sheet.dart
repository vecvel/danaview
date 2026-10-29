// OWNER: HOM-28
//
// The Split sheet of the page organiser (HOM plan §8.5 "split by page ranges, every N pages"):
// two capsule tab pills pick the mode; "Page ranges" takes "1-3, 5, 8-10" (one new file per range,
// checked as typed), "Every N pages" a number with steppers. The sheet says how many files it
// makes and resolves to the ranges (0-based, `[start, end)`), or null when dismissed.

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How the sheet splits.
enum PdfSplitMode {
  /// Typed ranges.
  ranges,

  /// Every N pages.
  everyN,
}

/// Shows the Split sheet for a document of [pageCount] pages.
Future<List<PdfPageRange>?> showPdfSplitSheet(BuildContext context, {required int pageCount}) => showDanaviewSheet<List<PdfPageRange>>(
      context,
      title: 'Split',
      builder: (sheetContext) => PdfSplitForm(pageCount: pageCount, onDone: (ranges) => Navigator.of(sheetContext).pop(ranges)),
    );

/// The body of the Split sheet.
class PdfSplitForm extends StatefulWidget {
  /// A form for [pageCount] pages; [onDone] gets the ranges.
  const PdfSplitForm({super.key, required this.pageCount, required this.onDone});

  /// Pages of the document.
  final int pageCount;

  /// Called with the chosen ranges.
  final ValueChanged<List<PdfPageRange>> onDone;

  @override
  State<PdfSplitForm> createState() => _PdfSplitFormState();
}

class _PdfSplitFormState extends State<PdfSplitForm> {
  PdfSplitMode _mode = PdfSplitMode.ranges;
  final TextEditingController _text = TextEditingController();
  int _every = 1;

  @override
  void initState() {
    super.initState();
    _every = widget.pageCount > 1 ? (widget.pageCount / 2).ceil() : 1;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  List<PdfPageRange>? get _ranges => switch (_mode) {
        PdfSplitMode.ranges => parsePageRanges(_text.text, widget.pageCount),
        PdfSplitMode.everyN => rangesEvery(_every, widget.pageCount),
      };

  String? get _error {
    if (_mode != PdfSplitMode.ranges || _text.text.trim().isEmpty) return null;
    return _ranges == null ? 'Use pages 1 to ${widget.pageCount}, like 1-3, 5' : null;
  }

  @override
  Widget build(BuildContext context) {
    final ranges = _ranges;
    final count = ranges?.length ?? 0;
    // One range over every page would only copy the file.
    final whole = count == 1 && ranges!.single == PdfPageRange(0, widget.pageCount);
    final summary = count == 0
        ? 'Pages 1 to ${widget.pageCount}'
        : whole
            ? 'That’s the whole file'
            : (count == 1 ? 'Makes 1 new file' : 'Makes $count new files');
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: DanaviewSpacing.sm,
            runSpacing: DanaviewSpacing.xs,
            children: [
              DanaviewTabPill(
                key: const ValueKey('pdf-split-ranges'),
                label: 'Page ranges',
                selected: _mode == PdfSplitMode.ranges,
                onTap: () => setState(() => _mode = PdfSplitMode.ranges),
              ),
              DanaviewTabPill(
                key: const ValueKey('pdf-split-every'),
                label: 'Every N pages',
                selected: _mode == PdfSplitMode.everyN,
                onTap: () => setState(() => _mode = PdfSplitMode.everyN),
              ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.md),
          if (_mode == PdfSplitMode.ranges)
            DanaviewTextField(
              key: const ValueKey('pdf-split-field'),
              controller: _text,
              hint: 'e.g. 1-3, 5, 8-10',
              semanticLabel: 'Page ranges',
              errorText: _error,
              keyboardType: TextInputType.text,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,;\-– to]'))],
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                final r = _ranges;
                if (r != null && !(r.length == 1 && r.single == PdfPageRange(0, widget.pageCount))) widget.onDone(r);
              },
            )
          else
            DanaviewNumberField(
              key: const ValueKey('pdf-split-every-field'),
              value: _every.toDouble(),
              min: 1,
              max: widget.pageCount.toDouble(),
              fractionDigits: 0,
              unit: _every == 1 ? 'page' : 'pages',
              semanticLabel: 'Pages per file',
              onChanged: (v) => setState(() => _every = v.round().clamp(1, widget.pageCount)),
            ),
          const SizedBox(height: DanaviewSpacing.sm),
          Semantics(liveRegion: true, child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.bodySecondary)),
          const SizedBox(height: DanaviewSpacing.lg),
          DanaviewButton.primary(
            key: const ValueKey('pdf-split-go'),
            label: 'Split',
            expand: true,
            semanticLabel: 'Split',
            onPressed: count > 0 && !whole ? () => widget.onDone(ranges!) : null,
          ),
        ],
      ),
    );
  }
}
