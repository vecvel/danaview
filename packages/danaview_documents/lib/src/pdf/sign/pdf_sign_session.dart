// OWNER: HOM-30
//
// Ties a sign session's model to the native viewer (HOM plan §8.5): puts the viewer into the
// annotate mode's `place` input, pushes the placed signatures (image stamps) and the selected one to
// the preview whenever they change, in order and without overlapping calls, and turns the viewer's
// events into edits: a tap on a placed signature selects it; a tap elsewhere on a page places the
// chosen signature there (several pages, several places) or, with none chosen yet, asks for one; a
// finished drag or resize of the selected signature replaces it. The model stays the truth: the
// viewer only shows it. Nothing here logs a path (rule 30).

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';

import 'pdf_sign_model.dart';

/// One sign session on one viewer.
final class PdfSignSession {
  /// A session of [model] on viewer [viewId] of a document with [pageSizes].
  PdfSignSession({
    required this.engine,
    required this.viewId,
    required this.model,
    required this.pageSizes,
    this.onNeedSignature,
    this.onError,
  });

  /// The viewer's place input (the ink fields are unused).
  static const PdfAnnotateMode mode = PdfAnnotateMode(input: PdfAnnotateInput.place, inkColorArgb: 0xFF111111, inkWidth: 1);

  /// The engine.
  final PdfAnnotateEngine engine;

  /// The viewer.
  final int viewId;

  /// The session's state.
  final PdfSignModel model;

  /// The document's pages.
  final List<PdfPageSize> pageSizes;

  /// A page was tapped before a signature was chosen.
  final void Function()? onNeedSignature;

  /// A preview call failed (the viewer went away, the platform refused).
  final void Function(PdfException error)? onError;

  StreamSubscription<PdfAnnotateEvent>? _events;
  Future<void> _queue = Future<void>.value();
  List<PdfAnnotateItem>? _sentItems;
  String? _sentSelected;
  bool _stopped = false;

  /// Puts the viewer into the place input and starts listening.
  Future<void> start() async {
    model.addListener(_sync);
    _events = engine.events(viewId).listen(handle);
    await engine.setMode(viewId, mode);
    _sentItems = const [];
    await engine.show(viewId, const []);
    if (model.items.isNotEmpty) _sync();
  }

  /// Leaves the place input (the preview goes); safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    model.removeListener(_sync);
    unawaited(_events?.cancel());
    try {
      await engine.setMode(viewId, null);
    } on PdfException {
      // The viewer is gone already.
    }
  }

  void _sync() {
    if (_stopped) return;
    final items = model.items;
    final selected = model.selectedId;
    if (identical(items, _sentItems) && selected == _sentSelected) return;
    _sentItems = items;
    _sentSelected = selected;
    _queue = _queue.then((_) async {
      if (_stopped) return;
      try {
        await engine.show(viewId, items, selectedId: selected);
      } on PdfException catch (e) {
        if (!_stopped) onError?.call(e);
      }
    });
  }

  /// Waits until every change so far reached the viewer (tests).
  Future<void> get settled => _queue;

  /// Applies a viewer event to the model.
  void handle(PdfAnnotateEvent event) {
    if (_stopped) return;
    switch (event) {
      case PdfAnnotateTapEvent(:final pageIndex, :final point, :final itemId):
        if (itemId != null && model.stampOf(itemId) != null) {
          model.select(itemId);
          return;
        }
        if (model.signature == null) {
          onNeedSignature?.call();
          return;
        }
        if (pageIndex < 0 || pageIndex >= pageSizes.length) return;
        model.place(pageIndex, point, pageSizes[pageIndex]);
      case PdfStampMovedEvent(:final itemId, :final rect):
        model.move(itemId, rect);
      case PdfInkStrokeEvent():
        break;
    }
  }
}
