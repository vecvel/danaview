// OWNER: HOM-29
//
// Ties an annotate session's model to the native viewer (HOM plan §8.5): pushes the tool's mode and
// the model's items (and the selected one) to the viewer's preview whenever they change, in order
// and without overlapping calls; turns the viewer's events into edits (an ink stroke becomes an ink
// annotation in the pen's colour and width; a tap selects, places or edits a text box, or erases,
// by tool); and marks the text selection (one markup annotation per page, one undo step). The
// model stays the truth: the viewer only shows it. Nothing here logs annotation text (rule 30).

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:danaview_pdf/danaview_pdf.dart';

import 'pdf_annotate_model.dart';

/// Asks for a text box's text ([initial] when editing); null when cancelled.
typedef PdfAnnotateTextPrompt = Future<String?> Function(String? initial);

/// One annotate session on one viewer.
final class PdfAnnotateSession {
  /// A session of [model] on viewer [viewId] of a document with [pageSizes].
  PdfAnnotateSession({
    required this.engine,
    required this.viewId,
    required this.model,
    required this.pageSizes,
    required this.askText,
    this.onError,
  });

  /// The engine.
  final PdfAnnotateEngine engine;

  /// The viewer.
  final int viewId;

  /// The session's state.
  final PdfAnnotateModel model;

  /// The document's pages (text boxes are fitted to their page).
  final List<PdfPageSize> pageSizes;

  /// Asks for text.
  final PdfAnnotateTextPrompt askText;

  /// A preview call failed (the viewer went away, the platform refused).
  final void Function(PdfException error)? onError;

  /// Text boxes are at most this wide (points).
  static const double textBoxWidth = 200;

  StreamSubscription<PdfAnnotateEvent>? _events;
  Future<void> _queue = Future<void>.value();
  PdfAnnotateMode? _sentMode;
  List<PdfAnnotateItem>? _sentItems;
  String? _sentSelected;
  bool _stopped = false;
  bool _prompting = false;

  /// Puts the viewer into annotate mode and starts listening.
  Future<void> start() async {
    model.addListener(_sync);
    _events = engine.events(viewId).listen(handle);
    _sentMode = model.mode;
    await engine.setMode(viewId, _sentMode);
    _sentItems = const [];
    await engine.show(viewId, const []);
  }

  /// Leaves annotate mode (the preview goes); safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    model.removeListener(_sync);
    unawaited(_events?.cancel());
    // Queued pushes check [_stopped] before every call, and the channel keeps call order, so no
    // preview reaches the viewer after this.
    try {
      await engine.setMode(viewId, null);
    } on PdfException {
      // The viewer is gone already.
    }
  }

  void _sync() {
    if (_stopped) return;
    final mode = model.mode;
    final items = model.items;
    final selected = model.selectedId;
    final sendMode = mode != _sentMode;
    final sendItems = !identical(items, _sentItems) || selected != _sentSelected;
    if (!sendMode && !sendItems) return;
    if (sendMode) _sentMode = mode;
    if (sendItems) {
      _sentItems = items;
      _sentSelected = selected;
    }
    _queue = _queue.then((_) async {
      if (_stopped) return;
      try {
        if (sendMode) await engine.setMode(viewId, mode);
        if (sendItems && !_stopped) await engine.show(viewId, items, selectedId: selected);
      } on PdfException catch (e) {
        if (!_stopped) onError?.call(e);
      }
    });
  }

  /// Waits until every change so far reached the viewer (tests).
  Future<void> get settled => _queue;

  /// Applies a viewer event to the model.
  Future<void> handle(PdfAnnotateEvent event) async {
    if (_stopped) return;
    switch (event) {
      case PdfInkStrokeEvent(:final pageIndex, :final points):
        if (model.tool != PdfAnnotateTool.pen || points.isEmpty) return;
        model.add(PdfAnnotation.ink(pageIndex, [points], colorArgb: model.penColor, lineWidth: model.penWidth));
      case PdfAnnotateTapEvent(:final pageIndex, :final point, :final itemId):
        switch (model.tool) {
          case PdfAnnotateTool.select:
            model.select(itemId);
          case PdfAnnotateTool.eraser:
            if (itemId != null) model.remove(itemId);
          case PdfAnnotateTool.text:
            final existing = itemId == null ? null : model.annotationOf(itemId);
            if (existing != null && existing.kind == PdfAnnotationKind.freeText) {
              model.select(itemId);
              await editText(itemId!);
            } else {
              await addText(pageIndex, point);
            }
          case PdfAnnotateTool.pen:
            break;
        }
    }
  }

  /// Asks for text and places a text box with its top-left corner at [point] on [pageIndex].
  Future<void> addText(int pageIndex, Offset point) async {
    if (_prompting) return;
    _prompting = true;
    try {
      final text = (await askText(null))?.trim();
      if (text == null || text.isEmpty || _stopped) return;
      final pageWidth = pageIndex < pageSizes.length ? pageSizes[pageIndex].width : point.dx + textBoxWidth;
      final width = (pageWidth - point.dx - 8).clamp(40.0, textBoxWidth);
      final id = model.add(PdfAnnotation.freeText(pageIndex, point, text, colorArgb: model.textColor, width: width));
      model.select(id);
    } finally {
      _prompting = false;
    }
  }

  /// Edits the text of text box [id] (one undo step); an emptied box is removed.
  Future<void> editText(String id) async {
    final current = model.annotationOf(id);
    if (current == null || current.kind != PdfAnnotationKind.freeText || _prompting) return;
    _prompting = true;
    try {
      final text = (await askText(current.text))?.trim();
      if (text == null || _stopped || text == current.text) return;
      if (text.isEmpty) {
        model.remove(id);
      } else {
        model.replace(id, current.withText(text));
      }
    } finally {
      _prompting = false;
    }
  }

  /// Marks the viewer's text selection with [kind] in the markup colour: one annotation per page,
  /// one undo step. Returns how many pages were marked (0 without a selection).
  Future<int> markup(PdfAnnotationKind kind) async {
    final lines = await engine.selectionLines(viewId);
    final marks = [
      for (final l in lines)
        if (l.rects.isNotEmpty) PdfAnnotation.markup(kind, l.pageIndex, l.rects, colorArgb: model.markupColor),
    ];
    model.addAll(marks);
    return marks.length;
  }
}
