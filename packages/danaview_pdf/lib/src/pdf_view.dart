// OWNER: HOM-24
// EXTENDED: HOM-29A (Android annotate input: the texture view turns its gestures into the annotate
// events while its view is in annotate mode, pdf_texture_annotate.dart).
//
// The PDF viewer view (ARCH v1.2 §8 "PDF viewer", V2-120) and its controller over the frozen Pigeon
// surface (pigeons/pdf_api.dart):
//
// - iOS / macOS: PDFKit's `PDFView` as a platform view (`UiKitView` / `AppKitView`, view type
//   [pdfViewType]); zoom, scrolling, selection and copy are PDFKit's own.
// - Android (HOM-25 native side): a `Texture` the plugin renders PdfRenderer tiles into. Dart owns
//   the viewport (scroll offset and zoom, laid out from the page sizes as one column with
//   [PdfTextureLayout.gap] between pages) and sends it with `setTextureViewport`.
//
// Search, page thumbnails and selection go through [PdfViewController]; view state changes arrive
// on the multiplexed event stream. Nothing here logs a name, a path, a query or document text
// (rule 30).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'pdf_document.dart';
import 'pdf_texture_annotate.dart';
import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// The platform view type of the Apple viewer.
const String pdfViewType = 'com.vecvel.danaview.pdf/view';

/// How a viewer lays out pages.
enum PdfDisplayMode {
  /// One column, scrolling continuously.
  continuous,

  /// One page at a time.
  singlePage,

  /// Two pages side by side.
  twoUpContinuous,
}

/// The state of a viewer.
@immutable
final class PdfViewState {
  /// A state.
  const PdfViewState({
    required this.viewId,
    required this.pageIndex,
    required this.pageCount,
    this.scale = 1,
    this.minScale = 0.25,
    this.maxScale = 8,
    this.hasSelection = false,
    this.displayMode = PdfDisplayMode.continuous,
  });

  /// The view.
  final int viewId;

  /// The page mostly on screen.
  final int pageIndex;

  /// Pages in the document.
  final int pageCount;

  /// Current zoom.
  final double scale;

  /// Smallest zoom.
  final double minScale;

  /// Largest zoom.
  final double maxScale;

  /// Text is selected.
  final bool hasSelection;

  /// The layout.
  final PdfDisplayMode displayMode;

  /// A copy with the given fields replaced.
  PdfViewState copyWith({int? pageIndex, double? scale, bool? hasSelection, PdfDisplayMode? displayMode}) => PdfViewState(
        viewId: viewId,
        pageIndex: pageIndex ?? this.pageIndex,
        pageCount: pageCount,
        scale: scale ?? this.scale,
        minScale: minScale,
        maxScale: maxScale,
        hasSelection: hasSelection ?? this.hasSelection,
        displayMode: displayMode ?? this.displayMode,
      );

  @override
  bool operator ==(Object other) =>
      other is PdfViewState &&
      other.viewId == viewId &&
      other.pageIndex == pageIndex &&
      other.pageCount == pageCount &&
      other.scale == scale &&
      other.hasSelection == hasSelection &&
      other.displayMode == displayMode;

  @override
  int get hashCode => Object.hash(viewId, pageIndex, pageCount, scale, hasSelection, displayMode);
}

/// A rectangle in page space (points, origin bottom-left).
@immutable
final class PdfRect {
  /// A rect.
  const PdfRect(this.x, this.y, this.width, this.height);

  /// Left.
  final double x;

  /// Bottom.
  final double y;

  /// Width.
  final double width;

  /// Height.
  final double height;
}

/// One search hit.
@immutable
final class PdfSearchHit {
  /// A hit.
  const PdfSearchHit({
    required this.index,
    required this.pageIndex,
    required this.rangeStart,
    required this.rangeLength,
    required this.snippet,
    required this.snippetMatchStart,
    required this.snippetMatchLength,
    this.bounds = const PdfRect(0, 0, 0, 0),
  });

  /// Position in the result list.
  final int index;

  /// The page.
  final int pageIndex;

  /// UTF-16 offset of the match in the page text.
  final int rangeStart;

  /// UTF-16 length of the match.
  final int rangeLength;

  /// The match with words around it, one line (shown, never logged).
  final String snippet;

  /// Where the match starts in [snippet].
  final int snippetMatchStart;

  /// Length of the match in [snippet].
  final int snippetMatchLength;

  /// The match's bounds on its page.
  final PdfRect bounds;

  /// The text before the match in [snippet].
  String get before => snippet.substring(0, snippetMatchStart.clamp(0, snippet.length));

  /// The match in [snippet].
  String get match {
    final start = snippetMatchStart.clamp(0, snippet.length);
    return snippet.substring(start, (start + snippetMatchLength).clamp(start, snippet.length));
  }

  /// The text after the match in [snippet].
  String get after => snippet.substring((snippetMatchStart + snippetMatchLength).clamp(0, snippet.length));

  // Never prints the snippet (rule 30).
  @override
  String toString() => 'PdfSearchHit($index, page $pageIndex)';
}

/// The hits of one search.
@immutable
final class PdfSearchResult {
  /// A result.
  const PdfSearchResult(this.hits, {this.truncated = false});

  /// Hits in reading order.
  final List<PdfSearchHit> hits;

  /// More hits exist than were returned.
  final bool truncated;
}

/// Drives one viewer. Implementations: [PlatformPdfViewController]; tests fake it.
abstract interface class PdfViewController {
  /// The view.
  int get viewId;

  /// State changes (page, zoom, selection) of this view.
  Stream<PdfViewState> get states;

  /// The current state.
  Future<PdfViewState> state();

  /// Shows page [pageIndex].
  Future<void> goToPage(int pageIndex);

  /// Sets the zoom (clamped).
  Future<void> setScale(double scale);

  /// Fits the page width.
  Future<void> zoomToFit();

  /// Changes the layout.
  Future<void> setDisplayMode(PdfDisplayMode mode);

  /// Finds [query]; a newer search cancels this one (`cancelled`).
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500});

  /// Cancels a running search.
  Future<void> cancelSearch();

  /// Scrolls to [hit] and highlights it.
  Future<void> showSearchHit(PdfSearchHit hit);

  /// Removes search highlights.
  Future<void> clearSearch();

  /// The selected text, or null.
  Future<String?> selectedText();

  /// Copies the selection; false when nothing is selected or the file forbids it.
  Future<bool> copySelection();

  /// Clears the selection.
  Future<void> clearSelection();
}

PdfDisplayModeMsg _modeMsg(PdfDisplayMode m) => PdfDisplayModeMsg.values.byName(m.name);

/// The Dart state of a Pigeon view state.
PdfViewState pdfViewStateOf(PdfViewStateMsg m) => PdfViewState(
      viewId: m.viewId,
      pageIndex: m.pageIndex,
      pageCount: m.pageCount,
      scale: m.scale,
      minScale: m.minScale,
      maxScale: m.maxScale,
      hasSelection: m.hasSelection,
      displayMode: PdfDisplayMode.values.byName(m.displayMode.name),
    );

/// [PdfViewController] over the plugin.
class PlatformPdfViewController implements PdfViewController {
  /// A controller of [viewId] over the default engine, or [api] / [events] (tests).
  PlatformPdfViewController(this.viewId, {PdfViewHostApi? api, PdfEventHub? events})
      : api = api ?? PdfViewHostApi(),
        _events = events ?? PdfEventHub.forInstance();

  @override
  final int viewId;

  /// The host API.
  @protected
  final PdfViewHostApi api;

  final PdfEventHub _events;

  @override
  Stream<PdfViewState> get states =>
      _events.events.where((e) => e.kind != PdfEventKindMsg.toolProgress && e.viewState?.viewId == viewId).map((e) => pdfViewStateOf(e.viewState!));

  @override
  Future<PdfViewState> state() async => pdfViewStateOf(await guardPdf(() => api.state(viewId)));

  @override
  Future<void> goToPage(int pageIndex) => guardPdf(() => api.goToPage(viewId, pageIndex));

  @override
  Future<void> setScale(double scale) => guardPdf(() => api.setScale(viewId, scale));

  @override
  Future<void> zoomToFit() => guardPdf(() => api.zoomToFit(viewId));

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) => guardPdf(() => api.setDisplayMode(viewId, _modeMsg(mode)));

  @override
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500}) async {
    final r = await guardPdf(() => api.search(viewId, PdfSearchOptionsMsg(query: query, caseSensitive: caseSensitive, maxHits: maxHits)));
    return PdfSearchResult(
      [
        for (final h in r.hits)
          PdfSearchHit(
            index: h.index,
            pageIndex: h.pageIndex,
            rangeStart: h.rangeStart,
            rangeLength: h.rangeLength,
            snippet: h.snippet,
            snippetMatchStart: h.snippetMatchStart,
            snippetMatchLength: h.snippetMatchLength,
            bounds: PdfRect(h.bounds.x, h.bounds.y, h.bounds.width, h.bounds.height),
          ),
      ],
      truncated: r.truncated,
    );
  }

  @override
  Future<void> cancelSearch() => guardPdf(() => api.cancelSearch(viewId));

  @override
  Future<void> showSearchHit(PdfSearchHit hit) => guardPdf(
        () => api.showSearchHit(
          viewId,
          PdfSearchHitMsg(
            index: hit.index,
            pageIndex: hit.pageIndex,
            rangeStart: hit.rangeStart,
            rangeLength: hit.rangeLength,
            snippet: hit.snippet,
            snippetMatchStart: hit.snippetMatchStart,
            snippetMatchLength: hit.snippetMatchLength,
            bounds: PdfRectMsg(x: hit.bounds.x, y: hit.bounds.y, width: hit.bounds.width, height: hit.bounds.height),
          ),
        ),
      );

  @override
  Future<void> clearSearch() => guardPdf(() => api.clearSearch(viewId));

  @override
  Future<String?> selectedText() => guardPdf(() => api.selectedText(viewId));

  @override
  Future<bool> copySelection() => guardPdf(() => api.copySelection(viewId));

  @override
  Future<void> clearSelection() => guardPdf(() => api.clearSelection(viewId));
}

/// The native viewer of an open document.
class PdfView extends StatelessWidget {
  /// A viewer of [document] (open and unlocked) starting at [initialPage].
  const PdfView({
    super.key,
    required this.document,
    this.initialPage = 0,
    this.displayMode = PdfDisplayMode.continuous,
    this.onCreated,
    this.platform,
    this.semanticLabel = 'Document pages',
  });

  /// The document; its handle must stay open until the view exists.
  final PdfDocumentInfo document;

  /// The first page shown.
  final int initialPage;

  /// The layout.
  final PdfDisplayMode displayMode;

  /// Called with the controller once the native view exists.
  final ValueChanged<PdfViewController>? onCreated;

  /// Overrides [defaultTargetPlatform] (tests).
  final TargetPlatform? platform;

  /// What screen readers announce.
  final String semanticLabel;

  Map<String, Object> get _params => {'handle': document.handle, 'page': initialPage, 'displayMode': displayMode.name};

  static final Set<Factory<OneSequenceGestureRecognizer>> _gestures = {
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  @override
  Widget build(BuildContext context) {
    final Widget view;
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.iOS:
        view = UiKitView(
          viewType: pdfViewType,
          creationParams: _params,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: _gestures,
          onPlatformViewCreated: (id) => onCreated?.call(PlatformPdfViewController(id)),
        );
      case TargetPlatform.macOS:
        view = AppKitView(
          viewType: pdfViewType,
          creationParams: _params,
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: _gestures,
          onPlatformViewCreated: (id) => onCreated?.call(PlatformPdfViewController(id)),
        );
      case TargetPlatform.android:
        view = PdfTextureView(document: document, initialPage: initialPage, displayMode: displayMode, onCreated: onCreated);
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        // Windows and Linux show the file card instead (D-98k); the router never gets here.
        view = const SizedBox.expand();
    }
    return Semantics(container: true, label: semanticLabel, child: view);
  }
}

/// The page layout of a texture view: one column, pages fitted to the widest page, [gap] points
/// between pages.
@immutable
final class PdfTextureLayout {
  /// The layout of [pages].
  PdfTextureLayout(List<PdfPageSize> pages)
      : _tops = _offsets(pages),
        width = pages.fold(0, (w, p) => math.max(w, p.displayWidth));

  /// Points between pages.
  static const double gap = 8;

  static List<double> _offsets(List<PdfPageSize> pages) {
    final out = <double>[];
    var y = 0.0;
    for (final p in pages) {
      out.add(y);
      y += p.displayHeight + gap;
    }
    out.add(math.max(0, y - gap));
    return out;
  }

  final List<double> _tops;

  /// Width of the column in points.
  final double width;

  /// Height of the column in points.
  double get height => _tops.last;

  /// Number of pages.
  int get pageCount => _tops.length - 1;

  /// Top of page [index] in points.
  double topOf(int index) => _tops[index.clamp(0, math.max(0, pageCount - 1))];

  /// The page at document height [y] (points).
  int pageAt(double y) {
    var lo = 0;
    var hi = pageCount - 1;
    if (hi < 0) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// The Android viewer: a texture the plugin renders into, with Dart-owned scrolling and zoom.
class PdfTextureView extends StatefulWidget {
  /// A texture viewer of [document].
  const PdfTextureView(
      {super.key, required this.document, this.initialPage = 0, this.displayMode = PdfDisplayMode.continuous, this.onCreated, this.api});

  /// The open document.
  final PdfDocumentInfo document;

  /// The first page shown.
  final int initialPage;

  /// The layout (texture views lay out [PdfDisplayMode.continuous]; others are passed on).
  final PdfDisplayMode displayMode;

  /// Called with the controller once the texture exists.
  final ValueChanged<PdfViewController>? onCreated;

  /// The host API (tests).
  final PdfViewHostApi? api;

  @override
  State<PdfTextureView> createState() => _PdfTextureViewState();
}

class _PdfTextureViewState extends State<PdfTextureView> {
  late final PdfViewHostApi _api = widget.api ?? PdfViewHostApi();
  late final PdfTextureLayout _layout = PdfTextureLayout(widget.document.pageSizes);
  _TextureController? _controller;
  int? _textureId;
  Size _size = Size.zero;
  double _dpr = 1;
  double _zoom = 1; // 1 = fit width
  double _offsetY = 0;
  double _offsetX = 0;
  double _startZoom = 1;
  bool _creating = false;
  final StreamController<PdfViewState> _states = StreamController<PdfViewState>.broadcast();

  double get _fit => _layout.width <= 0 || _size.width <= 0 ? 1 : _size.width / _layout.width;

  /// Logical px per point.
  double get _scale => _fit * _zoom;

  // HOM-29A: annotate mode of this view (set by the annotate engine) and the gesture in progress.
  ValueListenable<PdfTextureAnnotateState?>? _annotateSource;
  PdfTextureAnnotateState? _annotate;
  int _pointers = 0;
  Offset? _downAt;
  List<Offset>? _stroke; // local logical px
  _StampDrag? _drag;

  @override
  void dispose() {
    final id = _controller?.viewId;
    _annotateSource?.removeListener(_onAnnotate);
    if (id != null) PdfTextureAnnotateInput.instance.forget(id);
    if (id != null) unawaited(guardPdf(() => _api.disposeTextureView(id)).catchError((Object _) {}));
    unawaited(_states.close());
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating || _textureId != null || _size.isEmpty) return;
    _creating = true;
    try {
      final created = await guardPdf(
        () => _api.createTextureView(
          PdfTextureViewRequestMsg(
            handle: widget.document.handle,
            widthPx: (_size.width * _dpr).round(),
            heightPx: (_size.height * _dpr).round(),
            initialPage: widget.initialPage,
            displayMode: _modeMsg(widget.displayMode),
          ),
        ),
      );
      if (!mounted) {
        unawaited(guardPdf(() => _api.disposeTextureView(created.viewId)).catchError((Object _) {}));
        return;
      }
      final controller = _TextureController(this, created.viewId, _api);
      _annotateSource = PdfTextureAnnotateInput.instance.watch(created.viewId)..addListener(_onAnnotate);
      _annotate = _annotateSource!.value;
      setState(() {
        _textureId = created.textureId;
        _controller = controller;
        _offsetY = _layout.topOf(widget.initialPage);
      });
      _push();
      widget.onCreated?.call(controller);
    } on PdfException {
      // The host shows the file card when no viewer appears (ViewerContext.unavailable).
    } finally {
      _creating = false;
    }
  }

  void _clamp() {
    final visibleH = _size.height / _scale;
    final visibleW = _size.width / _scale;
    _offsetY = _offsetY.clamp(0.0, math.max(0.0, _layout.height - visibleH));
    _offsetX = _offsetX.clamp(0.0, math.max(0.0, _layout.width - visibleW));
  }

  PdfViewState _state() => PdfViewState(
        viewId: _controller?.viewId ?? -1,
        pageIndex: _layout.pageAt(_offsetY + _size.height / _scale / 3),
        pageCount: widget.document.pageCount,
        scale: _scale * _dpr,
        minScale: _fit * _dpr,
        maxScale: _fit * _dpr * 8,
      );

  void _push() {
    final controller = _controller;
    if (controller == null || _size.isEmpty) return;
    _clamp();
    final viewport = PdfViewportMsg(
      widthPx: (_size.width * _dpr).round(),
      heightPx: (_size.height * _dpr).round(),
      offsetX: _offsetX,
      offsetY: _offsetY,
      scale: _scale * _dpr,
    );
    unawaited(guardPdf(() => _api.setTextureViewport(controller.viewId, viewport)).catchError((Object _) {}));
    if (!_states.isClosed) _states.add(_state());
  }

  void _goTo(int page) {
    _offsetY = _layout.topOf(page);
    _push();
  }

  void _setZoom(double zoom) {
    final centreY = _offsetY + _size.height / _scale / 2;
    _zoom = zoom.clamp(1.0, 8.0);
    _offsetY = centreY - _size.height / _scale / 2;
    _push();
  }

  // ---- HOM-29A / HOM-30A: annotate input (pdf_texture_annotate.dart) ----

  void _onAnnotate() {
    if (!mounted) return;
    setState(() {
      _annotate = _annotateSource?.value;
      _stroke = null;
      _drag = null;
    });
  }

  /// [local] (logical px) in column points.
  Offset _column(Offset local) => Offset(_offsetX + local.dx / _scale, _offsetY + local.dy / _scale);

  /// Page [index]'s displayed rect in column points.
  Rect _pageRect(int index) {
    final p = widget.document.pageSizes[index];
    return Rect.fromLTWH((_layout.width - p.displayWidth) / 2, _layout.topOf(index), p.displayWidth, p.displayHeight);
  }

  /// The page under [local] and the page-space point there (on [page] when given), or null
  /// between pages.
  (int, Offset)? _pagePoint(Offset local, {int? page}) {
    if (widget.document.pageSizes.isEmpty) return null;
    final c = _column(local);
    final index = page ?? _layout.pageAt(c.dy);
    final r = _pageRect(index);
    if (page == null && !r.contains(c)) return null;
    return (index, PdfPageSpace.fromDisplay(widget.document.pageSizes[index], c - r.topLeft));
  }

  void _annotateTap(Offset local) {
    final a = _annotate;
    final id = _controller?.viewId;
    if (a == null || id == null) return;
    final hit = _pagePoint(local);
    if (hit == null) return;
    final (page, p) = hit;
    if (a.mode.input == PdfAnnotateInputMsg.ink) {
      a.events.inkStroke(id, page, [p.dx, p.dy]);
      return;
    }
    final item = PdfTextureAnnotateRules.hitTest(a.items, page, p, PdfTextureAnnotateRules.tapReach / _scale);
    a.events.tapped(id, page, p.dx, p.dy, item);
  }

  void _beginAnnotateDrag(Offset local) {
    final a = _annotate;
    if (a == null) return;
    final start = _downAt ?? local;
    if (a.mode.input == PdfAnnotateInputMsg.ink) {
      if (_pagePoint(start) == null) return;
      setState(() => _stroke = [start, if (local != start) local]);
      return;
    }
    if (a.mode.input != PdfAnnotateInputMsg.place) return;
    final selected = a.items.where((i) => i.id == a.selectedId && i.stamp != null).firstOrNull;
    final stamp = selected?.stamp;
    if (selected == null || stamp == null || stamp.pageIndex < 0 || stamp.pageIndex >= widget.document.pageSizes.length) return;
    final page = stamp.pageIndex;
    final pageRect = _pageRect(page);
    final rect = PdfPageSpace.rectToDisplay(widget.document.pageSizes[page], stamp.rect).shift(pageRect.topLeft);
    final onScreen = Rect.fromLTRB(
      (rect.left - _offsetX) * _scale,
      (rect.top - _offsetY) * _scale,
      (rect.right - _offsetX) * _scale,
      (rect.bottom - _offsetY) * _scale,
    );
    final onHandle = (start - onScreen.bottomRight).distance <= PdfTextureAnnotateRules.handleReach;
    if (!onHandle && !onScreen.contains(start)) return;
    _drag = _StampDrag(selected, page, start, rect, pageRect, resize: onHandle);
  }

  void _updateAnnotateDrag(Offset local) {
    final stroke = _stroke;
    if (stroke != null) {
      setState(() => stroke.add(local));
      return;
    }
    final d = _drag;
    final a = _annotate;
    final id = _controller?.viewId;
    if (d == null || a == null || id == null) return;
    final next = d.resize
        ? PdfTextureAnnotateRules.resize(d.startRect, _column(local), d.pageRect)
        : PdfTextureAnnotateRules.move(d.startRect, (local - d.start) / _scale, d.pageRect);
    final rect = PdfPageSpace.rectFromDisplay(widget.document.pageSizes[d.page], next.shift(-d.pageRect.topLeft));
    d.rect = rect;
    final s = d.item.stamp!;
    final moved = PdfAnnotateItemMsg(
      id: d.item.id,
      stamp: PdfSignatureStampMsg(pageIndex: s.pageIndex, rect: rect, imagePath: s.imagePath, rotationDegrees: s.rotationDegrees),
    );
    final items = [for (final i in a.items) i.id == d.item.id ? moved : i];
    unawaited(guardPdf(() => a.api.showAnnotations(id, items, a.selectedId)).catchError((Object _) {}));
  }

  void _endAnnotateDrag() {
    if (_pointers > 0) {
      // A second finger joined: the gesture becomes a scroll / zoom; nothing is drawn or moved.
      _cancelAnnotateDrag();
      return;
    }
    final a = _annotate;
    final id = _controller?.viewId;
    final stroke = _stroke;
    final drag = _drag;
    _drag = null;
    if (stroke != null) setState(() => _stroke = null);
    if (a == null || id == null) return;
    if (stroke != null) {
      final first = _pagePoint(stroke.first);
      if (first == null) return;
      final page = first.$1;
      final points = <double>[];
      for (final p in stroke) {
        final q = _pagePoint(p, page: page)!.$2;
        points
          ..add(q.dx)
          ..add(q.dy);
      }
      a.events.inkStroke(id, page, points);
    } else if (drag != null && drag.rect != null) {
      a.events.itemMoved(id, drag.item.id, drag.page, drag.rect!);
    }
  }

  void _cancelAnnotateDrag() {
    final drag = _drag;
    final a = _annotate;
    final id = _controller?.viewId;
    _drag = null;
    if (_stroke != null) setState(() => _stroke = null);
    if (drag != null && drag.rect != null && a != null && id != null) {
      // Put the stamp back where it was.
      unawaited(guardPdf(() => a.api.showAnnotations(id, a.items, a.selectedId)).catchError((Object _) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        if (size != _size && size.isFinite) {
          _size = size;
          if (_textureId == null) {
            scheduleMicrotask(_create);
          } else {
            scheduleMicrotask(_push);
          }
        }
        final id = _textureId;
        final annotating = _annotate != null;
        final stroke = _stroke;
        final mode = _annotate?.mode;
        return GestureDetector(
          onScaleStart: (d) {
            _startZoom = _zoom;
            if (annotating && d.pointerCount == 1) _beginAnnotateDrag(d.localFocalPoint);
          },
          onScaleUpdate: (d) {
            if (_stroke != null || _drag != null) {
              if (d.pointerCount == 1) return _updateAnnotateDrag(d.localFocalPoint);
              _cancelAnnotateDrag();
            }
            if (d.pointerCount > 1) {
              _setZoom(_startZoom * d.scale);
            } else {
              _offsetY -= d.focalPointDelta.dy / _scale;
              _offsetX -= d.focalPointDelta.dx / _scale;
              _push();
            }
          },
          onScaleEnd: (_) => _endAnnotateDrag(),
          onTapUp: annotating ? (d) => _annotateTap(d.localPosition) : null,
          onDoubleTap: annotating ? null : () => _setZoom(_zoom > 1 ? 1 : 2),
          child: Listener(
            onPointerDown: (e) {
              _pointers++;
              if (_pointers == 1) _downAt = e.localPosition;
            },
            onPointerUp: (_) => _pointers = math.max(0, _pointers - 1),
            onPointerCancel: (_) => _pointers = math.max(0, _pointers - 1),
            child: ClipRect(
              child: CustomPaint(
                foregroundPainter:
                    stroke == null || mode == null ? null : _LiveInkPainter(stroke, Color(mode.inkColorArgb), mode.inkWidth * _scale),
                child: id == null ? const SizedBox.expand() : Texture(textureId: id),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A one-finger drag of the selected stamp in `place` mode (HOM-30A).
final class _StampDrag {
  _StampDrag(this.item, this.page, this.start, this.startRect, this.pageRect, {required this.resize});

  final PdfAnnotateItemMsg item;
  final int page;

  /// Where the drag started (local logical px).
  final Offset start;

  /// The stamp's and its page's displayed rects in column points when the drag started.
  final Rect startRect;
  final Rect pageRect;
  final bool resize;

  /// The stamp's rect now (page space), once it moved.
  PdfRectMsg? rect;
}

/// The stroke being drawn, over the texture (HOM-29A).
class _LiveInkPainter extends CustomPainter {
  _LiveInkPainter(this.points, this.color, this.width);

  final List<Offset> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(width, 1)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (points.length == 1) path.lineTo(points.first.dx + 0.01, points.first.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LiveInkPainter old) => true;
}

/// A texture view's controller: navigation and zoom are Dart's, the rest goes to the plugin.
class _TextureController extends PlatformPdfViewController {
  _TextureController(this._view, int viewId, PdfViewHostApi api) : super(viewId, api: api);

  final _PdfTextureViewState _view;

  @override
  Stream<PdfViewState> get states => _view._states.stream;

  @override
  Future<PdfViewState> state() async => _view._state();

  @override
  Future<void> goToPage(int pageIndex) async => _view._goTo(pageIndex);

  @override
  Future<void> setScale(double scale) async => _view._setZoom(scale / (_view._fit * _view._dpr));

  @override
  Future<void> zoomToFit() async => _view._setZoom(1);

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) async {}

  @override
  Future<void> showSearchHit(PdfSearchHit hit) async {
    _view._goTo(hit.pageIndex);
    await super.showSearchHit(hit);
  }
}
