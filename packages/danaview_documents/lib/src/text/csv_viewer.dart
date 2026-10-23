// OWNER: HOM-23
//
// The read-only CSV/TSV grid (HOM plan §8.4): the delimiter is sniffed (`,` `;` tab; the menu can
// change it), the first record is a fixed header row, body rows have a fixed extent and are parsed
// only when shown, and the grid scrolls sideways with the header. Same 50 MB cap, encodings and
// "Open in another app" as the text viewer. Nothing writes the file; nothing logs (rule 30).

import 'dart:async';
import 'dart:math' as math;

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../card/document_format.dart';
import '../card/document_out.dart';
import '../card/viewer_bar.dart';
import '../router/viewer_file.dart';
import 'csv_table.dart';
import 'text_document.dart';
import 'text_encoding.dart';
import 'text_viewer.dart';
import 'viewer_parts.dart';

/// Documents below this size are indexed as a table on the UI isolate.
const int _syncTableBytes = 2 * 1024 * 1024;

Future<CsvTable> _buildTable(TextDocument doc, {CsvDelimiter? delimiter, required CsvDelimiter preferred}) =>
    doc.bytes.length < _syncTableBytes
        ? Future.value(CsvTable.build(doc, delimiter: delimiter, preferred: preferred))
        : CsvTable.buildAsync(doc, delimiter: delimiter, preferred: preferred);

/// The CSV/TSV grid of [file].
class CsvViewer extends StatefulWidget {
  /// A grid for [file]. [table] skips loading; [onUnavailable] is called when the file can't be
  /// read.
  const CsvViewer({super.key, required this.file, this.table, this.loader, this.fileOut, this.onClose, this.onUnavailable});

  /// The file.
  final ViewerFile file;

  /// The indexed table, when the caller has it.
  final CsvTable? table;

  /// Loads the file when [table] is null (default [TextDocument.load]).
  final TextDocumentLoader? loader;

  /// Getting files out ("Open in another app").
  final FileOutPort? fileOut;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// Called when the file can't be read.
  final VoidCallback? onUnavailable;

  @override
  State<CsvViewer> createState() => _CsvViewerState();
}

class _CsvViewerState extends State<CsvViewer> {
  CsvTable? _table;
  bool _failed = false;
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  final GlobalKey _menuKey = GlobalKey();

  CsvDelimiter get _preferred => widget.file.isTabSeparated ? CsvDelimiter.tab : CsvDelimiter.comma;

  @override
  void initState() {
    super.initState();
    _table = widget.table;
    if (_table == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final doc = await (widget.loader ?? TextDocument.load)(widget.file.path);
      final table = await _index(doc);
      if (mounted) setState(() => _table = table);
    } on Object {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onUnavailable?.call();
    }
  }

  Future<CsvTable> _index(TextDocument doc, {CsvDelimiter? delimiter}) => _buildTable(doc, delimiter: delimiter, preferred: _preferred);

  Future<void> _change({TextEncodingKind? encoding, CsvDelimiter? delimiter}) async {
    final t = _table;
    if (t == null) return;
    final doc = encoding == null ? t.document : await reencodeDocument(t.document, encoding);
    final next = await _index(doc, delimiter: delimiter ?? t.delimiter);
    if (mounted) setState(() => _table = next);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  List<DanaviewMenuEntry> _menu(CsvTable? t) {
    final port = widget.fileOut;
    return [
      const DanaviewMenuHeader('Separator'),
      for (final d in CsvDelimiter.values)
        DanaviewMenuItem(label: d.label, selected: t?.delimiter == d, enabled: t != null, onTap: () => unawaited(_change(delimiter: d))),
      const DanaviewMenuDivider(),
      const DanaviewMenuHeader('Encoding'),
      for (final k in TextEncodingKind.values)
        DanaviewMenuItem(
            label: k.label, selected: t?.document.encoding == k, enabled: t != null, onTap: () => unawaited(_change(encoding: k))),
      if (port != null && port.capabilities.canOpenIn) ...[
        const DanaviewMenuDivider(),
        DanaviewMenuItem(
          label: 'Open in another app',
          onTap: () => unawaited(openInAnotherApp(_menuKey.currentContext ?? context, port, widget.file)),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = _table;
    final subtitle = t == null
        ? documentTypeLabel(widget.file)
        : '${t.delimiter.label} · ${t.rowCount == 1 ? '1 row' : '${formatCount(t.rowCount)} rows'} · ${t.document.encoding.label}';
    return ColoredBox(
      color: DanaviewColors.background,
      child: Column(
        children: [
          DocumentTopBar(
            title: widget.file.displayName,
            subtitle: subtitle,
            onClose: widget.onClose,
            actions: [ViewerOptionsButton(key: _menuKey, entries: _menu(t))],
          ),
          if (t != null && t.document.truncated)
            TruncationNotice(
                file: widget.file, shownBytes: t.document.bytes.length, totalBytes: t.document.fileSize, fileOut: widget.fileOut),
          Expanded(
            child: ClipRect(
              child: _failed
                  ? const DanaviewEmptyState(
                      icon: Icons.error_outline_rounded,
                      iconColor: DanaviewColors.textSecondary,
                      title: 'Can\'t show this file',
                      message: 'Danaview couldn\'t read it.')
                  : t == null
                      ? const DocumentLoading()
                      : _grid(context, t),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, CsvTable t) {
    if (t.columnCount == 0) {
      return const DanaviewEmptyState(icon: Icons.grid_on_outlined, iconColor: DanaviewColors.textSecondary, title: 'This table is empty');
    }
    final scaler = MediaQuery.textScalerOf(context);
    const cellPad = DanaviewSpacing.md;
    final rowExtent = documentRowExtent(context, padding: 2 * DanaviewSpacing.sm);
    final charWidth = scaler.scale(13) * 0.58;
    final widths = [
      for (final chars in t.columnChars) (chars * charWidth + 2 * cellPad).clamp(scaler.scale(64), scaler.scale(320)).toDouble()
    ];
    final total = widths.fold<double>(0, (a, b) => a + b);
    final header = t.header;

    Widget cells(List<String> fields, TextStyle style, {FontWeight? weight}) => Row(
          children: [
            for (var c = 0; c < widths.length; c++)
              SizedBox(
                width: widths[c],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: cellPad),
                  child: Text(
                    c < fields.length ? displayRow(fields[c]).replaceAll('\n', ' ') : '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: weight == null ? style : style.copyWith(fontWeight: weight),
                  ),
                ),
              ),
          ],
        );

    return LayoutBuilder(
      builder: (context, c) {
        final width = math.max(c.maxWidth, total);
        return RawScrollbar(
          controller: _vertical,
          thumbColor: DanaviewColors.trackBackground,
          radius: const Radius.circular(4),
          notificationPredicate: (n) => n.depth == 1,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: c.maxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Container(
                      height: rowExtent,
                      alignment: Alignment.centerLeft,
                      decoration: const BoxDecoration(
                        color: DanaviewColors.surfaceElevated,
                        border: Border(bottom: DanaviewBorders.hairline),
                      ),
                      child: cells(header, documentRowStyle(DanaviewColors.textPrimary), weight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: const ValueKey('csv-viewer-rows'),
                      controller: _vertical,
                      itemExtent: rowExtent,
                      itemCount: t.rowCount,
                      itemBuilder: (context, i) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: i.isOdd ? DanaviewColors.surface : DanaviewColors.background,
                          border: const Border(bottom: DanaviewBorders.subtle),
                        ),
                        child: Align(alignment: Alignment.centerLeft, child: cells(t.row(i), documentRowStyle(DanaviewColors.textPrimary))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
