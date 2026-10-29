// OWNER: HOM-29
//
// A fake PdfAnnotateEngine for the annotate widget tests: records every mode, preview and save,
// answers the text selection the test sets, lets the test send viewer events (ink strokes, taps),
// and runs saves at once or when the test says (with progress and cancel), or fails them.

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';

/// One recorded save.
final class AnnotateSave {
  /// A save of [annotations] from [input] to [outPath].
  AnnotateSave(this.input, this.annotations, this.stamps, this.burnIn, this.outPath);

  /// The source.
  final PdfToolInput input;

  /// The annotations written.
  final List<PdfAnnotation> annotations;

  /// HOM-30's stamps.
  final List<PdfStamp> stamps;

  /// Burned in.
  final bool burnIn;

  /// The staged output.
  final String outPath;
}

/// A fake engine.
final class FakePdfAnnotateEngine implements PdfAnnotateEngine {
  /// Modes per call (null: annotate mode ended), with their viewer.
  final List<(int, PdfAnnotateMode?)> modes = [];

  /// Previews per call.
  final List<(int, List<PdfAnnotateItem>, String?)> shown = [];

  /// Saves per call.
  final List<AnnotateSave> saves = [];

  /// What [selectionLines] answers.
  List<PdfPageRects> selection = const [];

  /// When true, saves wait for [finish] or a cancel.
  bool hold = false;

  /// The next save fails with this.
  PdfException? failWith;

  /// The next setMode fails with this.
  PdfException? failMode;

  final StreamController<PdfAnnotateEvent> _events = StreamController<PdfAnnotateEvent>.broadcast();
  final List<(Completer<PdfToolResult>, String)> _held = [];
  int _jobs = 0;

  /// The last mode sent.
  PdfAnnotateMode? get mode => modes.isEmpty ? null : modes.last.$2;

  /// The items of the last preview.
  List<PdfAnnotateItem> get preview => shown.isEmpty ? const [] : shown.last.$2;

  /// The selected id of the last preview.
  String? get previewSelected => shown.isEmpty ? null : shown.last.$3;

  /// Sends a viewer event.
  void emit(PdfAnnotateEvent event) => _events.add(event);

  /// Completes the held saves.
  void finish() {
    for (final (c, out) in _held) {
      if (!c.isCompleted) c.complete(PdfToolResult(outPaths: [out], pageCounts: const [3], sizesBytes: const [2048]));
    }
    _held.clear();
  }

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) async {
    if (failMode case final e? when mode != null) {
      failMode = null;
      throw e;
    }
    modes.add((viewId, mode));
  }

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) async => shown.add((viewId, items, selectedId));

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async => selection;

  @override
  Stream<PdfAnnotateEvent> events(int viewId) => _events.stream.where((e) => e.viewId == viewId);

  @override
  PdfToolJob save(PdfToolInput input, {required List<PdfAnnotation> annotations, List<PdfStamp> stamps = const [], bool burnIn = false, required String outPath}) {
    saves.add(AnnotateSave(input, annotations, stamps, burnIn, outPath));
    final id = 'annotate${++_jobs}';
    if (failWith case final e?) {
      failWith = null;
      return PdfToolJobHandle.failed(id, e);
    }
    final c = Completer<PdfToolResult>();
    final handle = PdfToolJobHandle(
      id: id,
      run: c.future,
      onCancel: () async {
        if (!c.isCompleted) c.completeError(const PdfException(PdfErrorCode.cancelled, 'cancelled'));
      },
    );
    if (hold) {
      _held.add((c, outPath));
    } else {
      c.complete(PdfToolResult(outPaths: [outPath], pageCounts: const [3], sizesBytes: const [2048]));
    }
    return handle;
  }
}
