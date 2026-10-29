// OWNER: HOM-29A
// EXTENDED: HOM-30A (the `place` input: move and resize the selected stamp).
//
// Annotate input of the texture viewer (Android, HOM-29A / HOM-30A). A Flutter `Texture` gets no
// touches natively, so on Android the PdfAnnotateEventsApi events the native viewer sends on Apple
// (HOM-29 / HOM-30) are made here, from the texture view's own gestures, and delivered through the
// same Dart events hub - the annotate engine and the documents UI can't tell the difference:
//
// - `PlatformPdfAnnotateEngine.setMode` / `show` also record the view's mode and items here
//   ([PdfTextureAnnotateInput]); the texture view listens for its view id.
// - ink: one finger draws (shown live over the texture), two fingers scroll and zoom; the finished
//   stroke goes out as `inkStroke` in page space. A single tap draws a dot.
// - select / text / erase / place: a tap goes out as `tapped` with the page point and the session
//   item under it (hit test as darwin PdfAnnotateCore.hitTest: markup lines and boxes contain the
//   point, ink passes within 12 logical px of it).
// - place: a one-finger drag that starts within 22 px of the selected stamp's handle (its lower
//   trailing corner on screen) resizes it, aspect kept, the opposite corner fixed, the shorter side
//   at least 12 pt; one that starts on the stamp moves it; both stay on its page and are shown live
//   through `PdfAnnotateHostApi.showAnnotations`; the final rect goes out once as `itemMoved`.
// - Other drags scroll and zoom as before. The native side draws the preview (and the stamp's
//   dashed mark and handle) over the tiles.
//
// Geometry mirrors the Kotlin viewer (viewer/PdfGeometry.kt): page space is points with the origin
// at the bottom-left of the unrotated crop box; displayed space is rotation applied, origin
// top-left. Nothing here logs (rule 30).

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import 'pdf_document.dart';
import 'pigeon/pdf_api.g.dart';

/// What one texture view is annotating.
@immutable
final class PdfTextureAnnotateState {
  /// The mode, the session items and the selection of a view.
  const PdfTextureAnnotateState({
    required this.mode,
    this.items = const [],
    this.selectedId,
    required this.events,
    required this.api,
  });

  /// The annotate mode.
  final PdfAnnotateModeMsg mode;

  /// The session's items, back to front.
  final List<PdfAnnotateItemMsg> items;

  /// The selected item.
  final String? selectedId;

  /// Where the view's events go (the engine's events hub).
  final PdfAnnotateEventsApi events;

  /// The plugin's annotate API (the live preview of a drag).
  final PdfAnnotateHostApi api;

  /// A copy with other items.
  PdfTextureAnnotateState withItems(List<PdfAnnotateItemMsg> items, String? selectedId) =>
      PdfTextureAnnotateState(mode: mode, items: items, selectedId: selectedId, events: events, api: api);
}

/// The annotate state of every texture view, by view id (set by `PlatformPdfAnnotateEngine`).
final class PdfTextureAnnotateInput {
  PdfTextureAnnotateInput._();

  /// The one registry.
  static final PdfTextureAnnotateInput instance = PdfTextureAnnotateInput._();

  final Map<int, ValueNotifier<PdfTextureAnnotateState?>> _views = {};

  /// The state of view [viewId] (null outside annotate mode).
  ValueListenable<PdfTextureAnnotateState?> watch(int viewId) => _views.putIfAbsent(viewId, () => ValueNotifier(null));

  /// View [viewId] enters [mode] (null leaves annotate mode).
  void setMode(int viewId, PdfAnnotateModeMsg? mode, {required PdfAnnotateEventsApi events, required PdfAnnotateHostApi api}) {
    final n = _views.putIfAbsent(viewId, () => ValueNotifier(null));
    final old = n.value;
    n.value = mode == null
        ? null
        : PdfTextureAnnotateState(mode: mode, items: old?.items ?? const [], selectedId: old?.selectedId, events: events, api: api);
  }

  /// View [viewId] shows [items] with [selectedId] selected (kept only while in annotate mode).
  void setItems(int viewId, List<PdfAnnotateItemMsg> items, String? selectedId) {
    final n = _views[viewId];
    final old = n?.value;
    if (n == null || old == null) return;
    n.value = old.withItems(List.unmodifiable(items), selectedId);
  }

  /// Forgets view [viewId] (the view went).
  void forget(int viewId) => _views.remove(viewId)?.dispose();
}

/// Page-space ↔ displayed-space geometry of one page (viewer/PdfGeometry.kt).
abstract final class PdfPageSpace {
  /// Page point [p] (y up) as a displayed point (origin top-left, rotation applied).
  static Offset toDisplay(PdfPageSize page, Offset p) => switch (page.rotation) {
        90 => Offset(p.dy, p.dx),
        180 => Offset(page.width - p.dx, p.dy),
        270 => Offset(page.height - p.dy, page.width - p.dx),
        _ => Offset(p.dx, page.height - p.dy),
      };

  /// Displayed point [d] as a page point: the inverse of [toDisplay].
  static Offset fromDisplay(PdfPageSize page, Offset d) => switch (page.rotation) {
        90 => Offset(d.dy, d.dx),
        180 => Offset(page.width - d.dx, d.dy),
        270 => Offset(page.width - d.dy, page.height - d.dx),
        _ => Offset(d.dx, page.height - d.dy),
      };

  /// A page-space rect ([PdfRectMsg]: x, y bottom-left, width, height) as a displayed rect.
  static Rect rectToDisplay(PdfPageSize page, PdfRectMsg r) =>
      Rect.fromPoints(toDisplay(page, Offset(r.x, r.y)), toDisplay(page, Offset(r.x + r.width, r.y + r.height)));

  /// A displayed rect as a page-space rect.
  static PdfRectMsg rectFromDisplay(PdfPageSize page, Rect d) {
    final r = Rect.fromPoints(fromDisplay(page, d.topLeft), fromDisplay(page, d.bottomRight));
    return PdfRectMsg(x: r.left, y: r.top, width: r.width, height: r.height);
  }
}

/// The annotate gestures' pure rules (hit test, stamp move / resize), shared with the tests.
abstract final class PdfTextureAnnotateRules {
  /// A tap reaches items this far away (logical px), as on Apple.
  static const double tapReach = 12;

  /// The resize handle answers this far from its centre (logical px).
  static const double handleReach = 22;

  /// A resized stamp keeps its shorter side at least this long (points).
  static const double minStampSide = 12;

  /// Text boxes: font size, padding and line height, as the native writers fit them.
  static const double _fontSize = 14;
  static const double _padding = 4;

  /// The page-space box a text item covers (its top edge and width; the height estimated as the
  /// writer fits it).
  static PdfRectMsg freeTextBox(PdfAnnotationMsg a) {
    final r = a.rects.first;
    final width = math.max(r.width, 40.0);
    final text = a.text ?? '';
    final perLine = math.max(1, ((width - 2 * _padding) / (_fontSize * 0.5)).floor());
    var lines = 0;
    for (final paragraph in text.split('\n')) {
      lines += math.max(1, (paragraph.length / perLine).ceil());
    }
    final height = (lines * _fontSize * 1.15 * 1.25).ceilToDouble() + 2 * _padding;
    final top = r.y + r.height;
    return PdfRectMsg(x: r.x, y: top - height, width: width, height: height);
  }

  /// The page-space bounds of [item].
  static PdfRectMsg? boundsOf(PdfAnnotateItemMsg item) {
    final s = item.stamp;
    if (s != null) return s.rect;
    final a = item.annotation;
    if (a == null) return null;
    switch (a.kind) {
      case PdfAnnotationKindMsg.ink:
        double? l, b, r, t;
        for (final s in a.strokes) {
          for (var i = 0; i + 1 < s.points.length; i += 2) {
            final x = s.points[i], y = s.points[i + 1];
            l = l == null ? x : math.min(l, x);
            r = r == null ? x : math.max(r, x);
            b = b == null ? y : math.min(b, y);
            t = t == null ? y : math.max(t, y);
          }
        }
        if (l == null) return null;
        final pad = a.lineWidth / 2;
        return PdfRectMsg(x: l - pad, y: b! - pad, width: r! - l + 2 * pad, height: t! - b + 2 * pad);
      case PdfAnnotationKindMsg.freeText:
        return a.rects.isEmpty ? null : freeTextBox(a);
      case PdfAnnotationKindMsg.note:
        return a.rects.isEmpty ? null : PdfRectMsg(x: a.rects.first.x, y: a.rects.first.y, width: 24, height: 24);
      case PdfAnnotationKindMsg.highlight:
      case PdfAnnotationKindMsg.underline:
      case PdfAnnotationKindMsg.strikeOut:
        if (a.rects.isEmpty) return null;
        var u = Rect.fromLTWH(a.rects.first.x, a.rects.first.y, a.rects.first.width, a.rects.first.height);
        for (final r in a.rects.skip(1)) {
          u = u.expandToInclude(Rect.fromLTWH(r.x, r.y, r.width, r.height));
        }
        return PdfRectMsg(x: u.left, y: u.top, width: u.width, height: u.height);
    }
  }

  static bool _contains(PdfRectMsg r, Offset p, double inflate) =>
      p.dx >= r.x - inflate && p.dx <= r.x + r.width + inflate && p.dy >= r.y - inflate && p.dy <= r.y + r.height + inflate;

  /// The id of the topmost of [items] on [pageIndex] under page point [p]; [tolerance] in points.
  static String? hitTest(List<PdfAnnotateItemMsg> items, int pageIndex, Offset p, double tolerance) {
    for (final item in items.reversed) {
      final page = item.annotation?.pageIndex ?? item.stamp?.pageIndex;
      if (page != pageIndex) continue;
      final a = item.annotation;
      if (a != null && a.kind == PdfAnnotationKindMsg.ink) {
        final reach = tolerance + a.lineWidth / 2;
        for (final s in a.strokes) {
          final pts = s.points;
          if (pts.length == 2 && (Offset(pts[0], pts[1]) - p).distance <= reach) return item.id;
          for (var i = 0; i + 3 < pts.length; i += 2) {
            if (_distance(p, Offset(pts[i], pts[i + 1]), Offset(pts[i + 2], pts[i + 3])) <= reach) return item.id;
          }
        }
      } else if (a != null &&
          (a.kind == PdfAnnotationKindMsg.highlight || a.kind == PdfAnnotationKindMsg.underline || a.kind == PdfAnnotationKindMsg.strikeOut)) {
        if (a.rects.any((r) => _contains(r, p, tolerance / 2))) return item.id;
      } else {
        final b = boundsOf(item);
        if (b != null && _contains(b, p, tolerance / 2)) return item.id;
      }
    }
    return null;
  }

  static double _distance(Offset p, Offset a, Offset b) {
    final d = b - a;
    final l2 = d.dx * d.dx + d.dy * d.dy;
    if (l2 == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * d.dx + (p.dy - a.dy) * d.dy) / l2).clamp(0.0, 1.0);
    return (p - (a + d * t)).distance;
  }

  /// [rect] (displayed points) moved by [delta], kept inside [page] (displayed points).
  static Rect move(Rect rect, Offset delta, Rect page) {
    final moved = rect.shift(delta);
    final dx = moved.left < page.left ? page.left - moved.left : (moved.right > page.right ? page.right - moved.right : 0.0);
    final dy = moved.top < page.top ? page.top - moved.top : (moved.bottom > page.bottom ? page.bottom - moved.bottom : 0.0);
    return moved.shift(Offset(dx, dy));
  }

  /// [rect] (displayed points) resized from its top-left corner towards [corner], aspect kept,
  /// the shorter side at least [minStampSide], inside [page].
  static Rect resize(Rect rect, Offset corner, Rect page) {
    final w0 = rect.width, h0 = rect.height;
    if (w0 <= 0 || h0 <= 0) return rect;
    var s = math.max((corner.dx - rect.left) / w0, (corner.dy - rect.top) / h0);
    s = math.max(s, minStampSide / math.min(w0, h0));
    s = math.min(s, math.min((page.right - rect.left) / w0, (page.bottom - rect.top) / h0));
    return Rect.fromLTWH(rect.left, rect.top, w0 * s, h0 * s);
  }
}
