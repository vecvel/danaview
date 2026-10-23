// OWNER: HOM-23
//
// The in-app text viewer (HOM plan §8.4, V2-121; ARCH §10.1: a 50 MB log scrolls at the grid
// budget, first screen ≤ 300 ms on the low tier). The file is read and indexed off the UI isolate
// (TextDocument); only rows on screen are decoded and laid out. Unwrapped rows have a fixed extent
// so flings never measure off-screen rows; wrapped rows build lazily. The options menu changes the
// encoding (UTF-8, UTF-16 LE/BE, Latin-1) and line wrapping and offers "Open in another app".
// Read-only: nothing writes the file. Nothing logs a name, a path or text (rule 30).

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
import 'text_document.dart';
import 'text_encoding.dart';
import 'viewer_parts.dart';

/// Loads a text file for the viewers (TextDocument.load by default; tests inject one).
typedef TextDocumentLoader = Future<TextDocument> Function(String path);

/// Documents below this size are re-indexed on the UI isolate when the encoding changes.
const int _syncReindexBytes = 2 * 1024 * 1024;

/// Re-indexes [doc] as [kind] (on a background isolate for large files).
Future<TextDocument> reencodeDocument(TextDocument doc, TextEncodingKind kind) {
  if (doc.bytes.length < _syncReindexBytes) return Future.value(TextDocument.fromBytes(doc.bytes, fileSize: doc.fileSize, encoding: kind));
  return doc.withEncoding(kind);
}

/// The in-app text viewer of [file].
class TextViewer extends StatefulWidget {
  /// A viewer for [file]. [document] skips loading (already loaded); [onUnavailable] is called
  /// when the file can't be read (the router then shows the file card).
  const TextViewer({
    super.key,
    required this.file,
    this.document,
    this.loader,
    this.fileOut,
    this.onClose,
    this.onUnavailable,
    this.wrapLines,
  });

  /// The file.
  final ViewerFile file;

  /// The loaded document, when the caller has it.
  final TextDocument? document;

  /// Loads the file when [document] is null (default [TextDocument.load]).
  final TextDocumentLoader? loader;

  /// Getting files out ("Open in another app").
  final FileOutPort? fileOut;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// Called when the file can't be read.
  final VoidCallback? onUnavailable;

  /// Wrap long lines; defaults to on, except for `.log` files.
  final bool? wrapLines;

  @override
  State<TextViewer> createState() => _TextViewerState();
}

class _TextViewerState extends State<TextViewer> {
  TextDocument? _doc;
  late bool _wrap = widget.wrapLines ?? widget.file.extension != 'log';
  bool _failed = false;
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  final GlobalKey _menuKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    if (_doc == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final doc = await (widget.loader ?? TextDocument.load)(widget.file.path);
      if (mounted) setState(() => _doc = doc);
    } on Object {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onUnavailable?.call();
    }
  }

  Future<void> _setEncoding(TextEncodingKind kind) async {
    final doc = _doc;
    if (doc == null || doc.encoding == kind) return;
    final next = await reencodeDocument(doc, kind);
    if (mounted) setState(() => _doc = next);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  String? _subtitle(TextDocument? doc) {
    if (doc == null) return documentTypeLabel(widget.file);
    final lines = doc.rowCount == 1 ? '1 line' : '${formatCount(doc.rowCount)} lines';
    return '${doc.encoding.label} · $lines';
  }

  List<DanaviewMenuEntry> _menu(TextDocument? doc) {
    final port = widget.fileOut;
    return [
      const DanaviewMenuHeader('Encoding'),
      for (final k in TextEncodingKind.values)
        DanaviewMenuItem(label: k.label, selected: doc?.encoding == k, enabled: doc != null, onTap: () => unawaited(_setEncoding(k))),
      const DanaviewMenuDivider(),
      DanaviewMenuItem(label: 'Wrap lines', selected: _wrap, onTap: () => setState(() => _wrap = !_wrap)),
      if (port != null && port.capabilities.canOpenIn)
        DanaviewMenuItem(
          label: 'Open in another app',
          onTap: () => unawaited(openInAnotherApp(_menuKey.currentContext ?? context, port, widget.file)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return ColoredBox(
      color: DanaviewColors.background,
      child: Column(
        children: [
          DocumentTopBar(
            title: widget.file.displayName,
            subtitle: _subtitle(doc),
            onClose: widget.onClose,
            actions: [ViewerOptionsButton(key: _menuKey, entries: _menu(doc))],
          ),
          if (doc != null && doc.truncated)
            TruncationNotice(file: widget.file, shownBytes: doc.bytes.length, totalBytes: doc.fileSize, fileOut: widget.fileOut),
          Expanded(
            child: ClipRect(
              child: _failed
                  ? const DanaviewEmptyState(
                      icon: Icons.error_outline_rounded,
                      iconColor: DanaviewColors.textSecondary,
                      title: 'Can\'t show this file',
                      message: 'Danaview couldn\'t read it.')
                  : doc == null
                      ? const DocumentLoading()
                      : _body(context, doc),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, TextDocument doc) {
    const pad = DanaviewSpacing.md;
    final style = documentRowStyle(DanaviewColors.textPrimary);
    if (_wrap) {
      return RawScrollbar(
        controller: _vertical,
        thumbColor: DanaviewColors.trackBackground,
        radius: const Radius.circular(4),
        child: ListView.builder(
          key: const ValueKey('text-viewer-rows'),
          controller: _vertical,
          padding: const EdgeInsets.symmetric(horizontal: pad, vertical: DanaviewSpacing.sm),
          itemCount: doc.rowCount,
          itemBuilder: (context, i) => Text(displayRow(doc.row(i)), style: style),
        ),
      );
    }
    final extent = documentRowExtent(context);
    final charWidth = MediaQuery.textScalerOf(context).scale(13) * 0.62;
    final maxChars = doc.encoding.unitBytes == 2 ? doc.maxRowBytes ~/ 2 : doc.maxRowBytes;
    return LayoutBuilder(
      builder: (context, c) {
        final width = math.max(c.maxWidth, math.min(maxChars * charWidth + 2 * pad, 60000.0));
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
              child: ListView.builder(
                key: const ValueKey('text-viewer-rows'),
                controller: _vertical,
                padding: const EdgeInsets.symmetric(horizontal: pad, vertical: DanaviewSpacing.sm),
                itemExtent: extent,
                itemCount: doc.rowCount,
                itemBuilder: (context, i) => Text(
                  displayRow(doc.row(i)),
                  style: style,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
