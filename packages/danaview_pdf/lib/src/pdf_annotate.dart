// OWNER: HOM-29
// EXTENDED: HOM-30 (sign: [PdfAnnotateInput.place] and [PdfStampMovedEvent], the viewer's drag
// and resize of a selected signature stamp; [PdfStamp.withRect].)
//
// Annotate and highlight (HOM plan §8.5, D-98j; BUILD_PLAN HOM-29, HOM-29A) over the Pigeon
// surface: the HOM-29 amendment's `PdfAnnotateHostApi` (annotate mode of a viewer, the save job)
// and `PdfAnnotateEventsApi` (strokes and taps from the viewer), plus the frozen
// `PdfToolsHostApi.cancel` and progress events for the save.
//
// The contract every platform keeps (BUILD_STATE, S4 HOM-29):
//
// * the annotations of a session live in Dart (undo / redo, unsaved changes); the viewer shows
//   them as a preview on its in-memory document and never writes the file;
// * [PdfAnnotateEngine.save] writes the input's pages with the annotations as REAL, editable PDF
//   annotations (highlight, underline, strikeOut with one quadrilateral per line, ink with one path
//   per stroke, freeText, a text note) into a new file that must not exist yet; the source is
//   opened read-only; text stays text; the file's own annotations stay as they are;
// * an encrypted source (opened with its password) gives an encrypted output with that password;
// * a cancelled save fails with `cancelled` and leaves no file;
// * HOM-30's hooks: [PdfStamp] image stamps (kept as Stamp annotations whose appearance is the
//   image) and `burnIn` (annotations and stamps drawn into the page content; the page's own
//   annotations stay annotations).
//
// Geometry is page space in points, origin at the bottom-left of the page's crop box, unrotated.
// Nothing here logs a path, a name, a password or annotation text (rule 30).

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'pdf_document.dart';
import 'pdf_tools.dart';
import 'pdf_view.dart' show PdfRect;
import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// The kinds of annotation.
enum PdfAnnotationKind {
  /// Text markup: a highlight over the selected lines.
  highlight,

  /// Text markup: a line under the selected lines.
  underline,

  /// Text markup: a line through the selected lines.
  strikeOut,

  /// Freehand strokes.
  ink,

  /// A text box on the page.
  freeText,

  /// A note icon holding text.
  note;

  /// Markup over lines of text.
  bool get isMarkup => this == highlight || this == underline || this == strikeOut;
}

/// One annotation, in page space.
@immutable
final class PdfAnnotation {
  /// An annotation as given; prefer the named constructors.
  const PdfAnnotation({
    required this.kind,
    required this.pageIndex,
    this.rects = const [],
    this.strokes = const [],
    required this.colorArgb,
    this.lineWidth = 2,
    this.text,
  });

  /// Highlight, underline or strike-through over [lines] (one rect per line of text).
  const PdfAnnotation.markup(this.kind, this.pageIndex, List<PdfRect> lines, {required this.colorArgb})
      : rects = lines,
        strokes = const [],
        lineWidth = 0,
        text = null;

  /// Freehand [strokes] [lineWidth] points wide.
  const PdfAnnotation.ink(this.pageIndex, this.strokes, {required this.colorArgb, this.lineWidth = 2})
      : kind = PdfAnnotationKind.ink,
        rects = const [],
        text = null;

  /// A text box whose top-left corner is [topLeft], [width] points wide; the height fits [text].
  PdfAnnotation.freeText(this.pageIndex, Offset topLeft, this.text, {required this.colorArgb, double width = 200})
      : kind = PdfAnnotationKind.freeText,
        rects = [PdfRect(topLeft.dx, topLeft.dy, width, 0)],
        strokes = const [],
        lineWidth = 0;

  /// What it is.
  final PdfAnnotationKind kind;

  /// Its page (0-based).
  final int pageIndex;

  /// Markup: one rect per line; freeText: the box (its top edge and width; the height is fitted);
  /// note: the icon's corner.
  final List<PdfRect> rects;

  /// Ink strokes, each a list of page points.
  final List<List<Offset>> strokes;

  /// Colour as 0xAARRGGBB (the text colour of a text box).
  final int colorArgb;

  /// Ink width in points.
  final double lineWidth;

  /// The text of a text box or note.
  final String? text;

  /// This annotation with [text].
  PdfAnnotation withText(String text) =>
      PdfAnnotation(kind: kind, pageIndex: pageIndex, rects: rects, strokes: strokes, colorArgb: colorArgb, lineWidth: lineWidth, text: text);

  @override
  bool operator ==(Object other) =>
      other is PdfAnnotation &&
      other.kind == kind &&
      other.pageIndex == pageIndex &&
      listEquals(other.rects.map(_rectKey).toList(), rects.map(_rectKey).toList()) &&
      listEquals(other.strokes.map((s) => s.length).toList(), strokes.map((s) => s.length).toList()) &&
      _sameStrokes(other.strokes, strokes) &&
      other.colorArgb == colorArgb &&
      other.lineWidth == lineWidth &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, pageIndex, rects.length, strokes.length, colorArgb, lineWidth, text);

  // Never prints the text (rule 30).
  @override
  String toString() => 'PdfAnnotation(${kind.name}, page $pageIndex)';
}

(double, double, double, double) _rectKey(PdfRect r) => (r.x, r.y, r.width, r.height);

bool _sameStrokes(List<List<Offset>> a, List<List<Offset>> b) {
  for (var i = 0; i < a.length; i++) {
    if (!listEquals(a[i], b[i])) return false;
  }
  return true;
}

/// An image stamp (HOM-30's visual signature) in page space.
@immutable
final class PdfStamp {
  /// The image at [imagePath] filling [rect] on [pageIndex], turned [rotationDegrees] clockwise.
  const PdfStamp({required this.pageIndex, required this.rect, required this.imagePath, this.rotationDegrees = 0});

  /// Its page.
  final int pageIndex;

  /// Where it goes.
  final PdfRect rect;

  /// A PNG (transparency kept) or JPEG file.
  final String imagePath;

  /// Clockwise around the rect's centre.
  final double rotationDegrees;

  /// This stamp at [rect] (moved or resized).
  PdfStamp withRect(PdfRect rect) => PdfStamp(pageIndex: pageIndex, rect: rect, imagePath: imagePath, rotationDegrees: rotationDegrees);

  @override
  bool operator ==(Object other) =>
      other is PdfStamp &&
      other.pageIndex == pageIndex &&
      _rectKey(other.rect) == _rectKey(rect) &&
      other.imagePath == imagePath &&
      other.rotationDegrees == rotationDegrees;

  @override
  int get hashCode => Object.hash(pageIndex, _rectKey(rect), imagePath, rotationDegrees);

  // Never prints the path (rule 30).
  @override
  String toString() => 'PdfStamp(page $pageIndex)';
}

/// One item of an annotate session: an annotation or a stamp, with the session's id.
@immutable
final class PdfAnnotateItem {
  /// An annotation item.
  const PdfAnnotateItem.annotation(this.id, PdfAnnotation this.annotation) : stamp = null;

  /// A stamp item (HOM-30).
  const PdfAnnotateItem.stamp(this.id, PdfStamp this.stamp) : annotation = null;

  /// The session's id (hit tests answer it).
  final String id;

  /// The annotation, or null for a stamp.
  final PdfAnnotation? annotation;

  /// The stamp, or null for an annotation.
  final PdfStamp? stamp;

  /// Its page.
  int get pageIndex => annotation?.pageIndex ?? stamp!.pageIndex;

  @override
  bool operator ==(Object other) => other is PdfAnnotateItem && other.id == id && other.annotation == annotation && other.stamp == stamp;

  @override
  int get hashCode => Object.hash(id, annotation, stamp);

  @override
  String toString() => 'PdfAnnotateItem($id, ${annotation ?? stamp})';
}

/// What a touch does on an annotating viewer.
enum PdfAnnotateInput {
  /// Scroll, zoom and select text; a tap reports the item under it.
  select,

  /// Draw ink (PencilKit on iOS; the pointer on macOS); two fingers scroll.
  ink,

  /// A tap reports where to place a text box.
  text,

  /// A tap reports the item under it, to remove.
  erase,

  /// HOM-30 sign: a tap reports its page point and the item under it (place or select a stamp);
  /// a drag on the selected stamp moves it, one on its corner handle resizes it (aspect kept),
  /// reported once at the end as a [PdfStampMovedEvent]; other drags scroll.
  place,
}

/// The annotate mode of a viewer.
@immutable
final class PdfAnnotateMode {
  /// [input] with the live ink look.
  const PdfAnnotateMode({required this.input, required this.inkColorArgb, required this.inkWidth});

  /// What a touch does.
  final PdfAnnotateInput input;

  /// The ink colour, 0xAARRGGBB.
  final int inkColorArgb;

  /// The ink width in page points.
  final double inkWidth;

  @override
  bool operator ==(Object other) =>
      other is PdfAnnotateMode && other.input == input && other.inkColorArgb == inkColorArgb && other.inkWidth == inkWidth;

  @override
  int get hashCode => Object.hash(input, inkColorArgb, inkWidth);
}

/// Line rects of a text selection on one page.
@immutable
final class PdfPageRects {
  /// [rects] on [pageIndex].
  const PdfPageRects(this.pageIndex, this.rects);

  /// The page.
  final int pageIndex;

  /// One rect per line.
  final List<PdfRect> rects;
}

/// Something an annotating viewer reports.
@immutable
sealed class PdfAnnotateEvent {
  const PdfAnnotateEvent(this.viewId, this.pageIndex);

  /// The viewer.
  final int viewId;

  /// The page.
  final int pageIndex;
}

/// A finished ink stroke.
final class PdfInkStrokeEvent extends PdfAnnotateEvent {
  /// [points] on [pageIndex].
  const PdfInkStrokeEvent(super.viewId, super.pageIndex, this.points);

  /// Page points.
  final List<Offset> points;
}

/// A tap.
final class PdfAnnotateTapEvent extends PdfAnnotateEvent {
  /// A tap at [point] on [pageIndex]; [itemId] is the session item under it.
  const PdfAnnotateTapEvent(super.viewId, super.pageIndex, this.point, this.itemId);

  /// The page point.
  final Offset point;

  /// The session item under the tap, or null.
  final String? itemId;
}

/// HOM-30: the user moved or resized stamp [itemId] (input [PdfAnnotateInput.place]).
final class PdfStampMovedEvent extends PdfAnnotateEvent {
  /// Stamp [itemId] now fills [rect] on [pageIndex].
  const PdfStampMovedEvent(super.viewId, super.pageIndex, this.itemId, this.rect);

  /// The session item.
  final String itemId;

  /// Its new rect in page space.
  final PdfRect rect;
}

/// Annotate mode of viewers and the annotate save. Implementations: [PlatformPdfAnnotateEngine];
/// tests fake it.
abstract interface class PdfAnnotateEngine {
  /// Puts viewer [viewId] into annotate [mode], or back to plain viewing with null.
  Future<void> setMode(int viewId, PdfAnnotateMode? mode);

  /// Shows [items] on viewer [viewId] as a preview; [selectedId] is marked.
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId});

  /// The text selection of viewer [viewId], line by line (empty without one).
  Future<List<PdfPageRects>> selectionLines(int viewId);

  /// What viewer [viewId] reports while annotating.
  Stream<PdfAnnotateEvent> events(int viewId);

  /// Writes [input] with [annotations] (and HOM-30's [stamps]; with [burnIn] drawn into the page)
  /// into the new file [outPath].
  PdfToolJob save(
    PdfToolInput input, {
    required List<PdfAnnotation> annotations,
    List<PdfStamp> stamps = const [],
    bool burnIn = false,
    required String outPath,
  });
}

/// Checks an annotate save before it reaches an engine.
void validateAnnotateSave(PdfToolInput input, List<PdfAnnotation> annotations, List<PdfStamp> stamps, String outPath) {
  PdfException invalid(String m) => PdfException(PdfErrorCode.invalidArgument, m);
  if (input.isImage) throw invalid('annotate needs a PDF');
  if (outPath.isEmpty || outPath == input.path) throw invalid('bad output');
  if (annotations.isEmpty && stamps.isEmpty) throw invalid('nothing to save');
  for (final a in annotations) {
    if (a.pageIndex < 0) throw invalid('page out of range');
    switch (a.kind) {
      case PdfAnnotationKind.highlight || PdfAnnotationKind.underline || PdfAnnotationKind.strikeOut:
        if (a.rects.isEmpty || a.rects.any((r) => r.width <= 0 || r.height <= 0)) throw invalid('markup needs line rects');
      case PdfAnnotationKind.ink:
        if (a.strokes.isEmpty || a.strokes.any((s) => s.isEmpty)) throw invalid('ink needs strokes');
      case PdfAnnotationKind.freeText || PdfAnnotationKind.note:
        if (a.rects.isEmpty || (a.text ?? '').trim().isEmpty) throw invalid('text needs a box and text');
    }
  }
  for (final s in stamps) {
    if (s.pageIndex < 0 || s.rect.width <= 0 || s.rect.height <= 0 || s.imagePath.isEmpty) throw invalid('bad stamp');
  }
}

PdfRectMsg _rectMsg(PdfRect r) => PdfRectMsg(x: r.x, y: r.y, width: r.width, height: r.height);

PdfRect _rect(PdfRectMsg m) => PdfRect(m.x, m.y, m.width, m.height);

/// The Pigeon message of [a].
PdfAnnotationMsg pdfAnnotationMsg(PdfAnnotation a) => PdfAnnotationMsg(
      kind: PdfAnnotationKindMsg.values[a.kind.index],
      pageIndex: a.pageIndex,
      rects: [for (final r in a.rects) _rectMsg(r)],
      strokes: [
        for (final s in a.strokes) PdfInkStrokeMsg(points: [for (final p in s) ...[p.dx, p.dy]]),
      ],
      colorArgb: a.colorArgb,
      lineWidth: a.lineWidth,
      text: a.text,
    );

PdfSignatureStampMsg _stampMsg(PdfStamp s) =>
    PdfSignatureStampMsg(pageIndex: s.pageIndex, rect: _rectMsg(s.rect), imagePath: s.imagePath, rotationDegrees: s.rotationDegrees);

List<Offset> _points(List<double> flat) => [for (var i = 0; i + 1 < flat.length; i += 2) Offset(flat[i], flat[i + 1])];

/// The one Dart end of `PdfAnnotateEventsApi` per engine instance, fanned out by view.
final class _AnnotateEventsHub implements PdfAnnotateEventsApi {
  _AnnotateEventsHub(this._instanceName);

  static final Map<String, _AnnotateEventsHub> _hubs = {};

  static _AnnotateEventsHub forInstance(String instanceName) => _hubs.putIfAbsent(instanceName, () => _AnnotateEventsHub(instanceName));

  final String _instanceName;
  bool _registered = false;
  final StreamController<PdfAnnotateEvent> _events = StreamController<PdfAnnotateEvent>.broadcast();

  Stream<PdfAnnotateEvent> get events {
    if (!_registered) {
      _registered = true;
      PdfAnnotateEventsApi.setUp(this, messageChannelSuffix: _instanceName);
    }
    return _events.stream;
  }

  @override
  void inkStroke(int viewId, int pageIndex, List<double> points) {
    final p = _points(points);
    if (p.isNotEmpty) _events.add(PdfInkStrokeEvent(viewId, pageIndex, p));
  }

  @override
  void tapped(int viewId, int pageIndex, double x, double y, String? itemId) =>
      _events.add(PdfAnnotateTapEvent(viewId, pageIndex, Offset(x, y), itemId));

  @override
  void itemMoved(int viewId, String itemId, int pageIndex, PdfRectMsg rect) {
    if (rect.width > 0 && rect.height > 0) _events.add(PdfStampMovedEvent(viewId, pageIndex, itemId, _rect(rect)));
  }
}

/// [PdfAnnotateEngine] over the plugin.
final class PlatformPdfAnnotateEngine implements PdfAnnotateEngine {
  /// An engine over the default plugin instance, or the given APIs and event sources (tests).
  PlatformPdfAnnotateEngine({
    PdfAnnotateHostApi? annotateApi,
    PdfToolsHostApi? toolsApi,
    PdfEventHub? events,
    Stream<PdfAnnotateEvent>? annotateEvents,
  })  : _annotate = annotateApi ?? PdfAnnotateHostApi(),
        _tools = toolsApi ?? PdfToolsHostApi(),
        _events = events ?? PdfEventHub.forInstance(),
        _annotateEvents = annotateEvents;

  final PdfAnnotateHostApi _annotate;
  final PdfToolsHostApi _tools;
  final PdfEventHub _events;
  final Stream<PdfAnnotateEvent>? _annotateEvents;
  int _next = 0;

  /// What a native [PdfAnnotateEventsApi] message becomes (tests drive it).
  @visibleForTesting
  static PdfAnnotateEventsApi debugHub([String instanceName = '']) => _AnnotateEventsHub.forInstance(instanceName);

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) => guardPdf(
        () => _annotate.setAnnotateMode(
          viewId,
          mode == null
              ? null
              : PdfAnnotateModeMsg(input: PdfAnnotateInputMsg.values[mode.input.index], inkColorArgb: mode.inkColorArgb, inkWidth: mode.inkWidth),
        ),
      );

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) => guardPdf(
        () => _annotate.showAnnotations(
          viewId,
          [
            for (final i in items)
              PdfAnnotateItemMsg(
                id: i.id,
                annotation: i.annotation == null ? null : pdfAnnotationMsg(i.annotation!),
                stamp: i.stamp == null ? null : _stampMsg(i.stamp!),
              ),
          ],
          selectedId,
        ),
      );

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async {
    final lines = await guardPdf(() => _annotate.selectionLines(viewId));
    return [for (final l in lines) PdfPageRects(l.pageIndex, [for (final r in l.rects) _rect(r)])];
  }

  @override
  Stream<PdfAnnotateEvent> events(int viewId) =>
      (_annotateEvents ?? _AnnotateEventsHub.forInstance('').events).where((e) => e.viewId == viewId);

  @override
  PdfToolJob save(
    PdfToolInput input, {
    required List<PdfAnnotation> annotations,
    List<PdfStamp> stamps = const [],
    bool burnIn = false,
    required String outPath,
  }) {
    final id = 'pa${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${++_next}';
    try {
      validateAnnotateSave(input, annotations, stamps, outPath);
    } on PdfException catch (e) {
      return PdfToolJobHandle.failed(id, e);
    }
    final progress = _events.events
        .where((e) => e.kind == PdfEventKindMsg.toolProgress && e.toolProgress?.jobId == id)
        .map((e) => PdfToolProgress(fraction: e.toolProgress!.fraction, pagesDone: e.toolProgress!.pagesDone, pagesTotal: e.toolProgress!.pagesTotal));
    final request = PdfAnnotateSaveRequestMsg(
      jobId: id,
      input: PdfToolInputMsg(path: input.path, password: input.password, isImage: false),
      annotations: [for (final a in annotations) pdfAnnotationMsg(a)],
      stamps: [for (final s in stamps) _stampMsg(s)],
      burnIn: burnIn,
      outPath: outPath,
    );
    return PdfToolJobHandle(
      id: id,
      run: guardPdf(() => _annotate.save(request))
          .then((r) => PdfToolResult(outPaths: r.outPaths, pageCounts: r.pageCounts, sizesBytes: r.sizesBytes)),
      onCancel: () => guardPdf(() => _tools.cancel(id)),
      progress: progress,
    );
  }
}
