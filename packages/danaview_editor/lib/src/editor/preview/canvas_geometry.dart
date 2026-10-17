// OWNER: UX-22
//
// CanvasGeometry (ux.md §7.2): the letterbox mapping between the preview view (logical px of the
// overlay) and the project canvas (canvas px). The preview surface (UX-18), the text overlay
// (UX-19), the manipulation overlay and the crop/mask/eyedropper modes (UX-23) all map through one
// instance, so handles, text and the native texture line up to the pixel.
//
// * `viewRect` is the canvas fitted (contain) and centred in the view; letterbox bars are outside
//   it. `scale` is view px per canvas px (uniform: the aspect is preserved).
// * Item boxes come from core `boxAt`/`itemBoxAt` (keyframes and text animation evaluated at the
//   playhead); [CanvasGeometry.boxPath], [CanvasGeometry.cornersOf] and [CanvasGeometry.hits]
//   place them in the view. Core math stays in canvas px (`Offset2`); this file converts at the edge.

import 'dart:math' as math;
import 'dart:ui' show Offset, Path, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/eval.dart' show ItemBox, Offset2, Size2;

/// Letterbox mapping between the view and the canvas (ux.md §7.2).
@immutable
class CanvasGeometry {
  /// Creates the mapping of a canvas of [canvasPx] shown in [viewRect] (the letterboxed rect in
  /// the overlay's coordinates).
  const CanvasGeometry({required this.canvasPx, required this.viewRect});

  /// The canvas of [canvasPx] fitted (contain) and centred in a view of [view] (letterbox).
  factory CanvasGeometry.letterbox(Size canvasPx, Size view) {
    if (!(canvasPx.width > 0 && canvasPx.height > 0) || !(view.width > 0 && view.height > 0)) {
      return CanvasGeometry(canvasPx: canvasPx, viewRect: Offset.zero & Size.zero);
    }
    final s = math.min(view.width / canvasPx.width, view.height / canvasPx.height);
    final w = canvasPx.width * s;
    final h = canvasPx.height * s;
    return CanvasGeometry(
      canvasPx: canvasPx,
      viewRect: Rect.fromLTWH((view.width - w) / 2, (view.height - h) / 2, w, h),
    );
  }

  /// The canvas size in canvas px.
  final Size canvasPx;

  /// The canvas' rect in the view (logical px).
  final Rect viewRect;

  /// Whether the mapping has an area (a zero-sized view or canvas maps nothing).
  bool get isEmpty => !(viewRect.width > 0 && viewRect.height > 0 && canvasPx.width > 0);

  /// View px per canvas px.
  double get scale => canvasPx.width > 0 ? viewRect.width / canvasPx.width : 0;

  /// The canvas size as core geometry.
  Size2 get canvasSize2 => Size2(canvasPx.width, canvasPx.height);

  /// The view point of the canvas point [canvas].
  Offset toView(Offset canvas) => Offset(viewRect.left + canvas.dx * scale, viewRect.top + canvas.dy * scale);

  /// The canvas point of the view point [view].
  Offset toCanvas(Offset view) {
    final s = scale;
    if (s == 0) return Offset.zero;
    return Offset((view.dx - viewRect.left) / s, (view.dy - viewRect.top) / s);
  }

  /// The view point of a core canvas point.
  Offset toView2(Offset2 canvas) => toView(Offset(canvas.dx, canvas.dy));

  /// The core canvas point of the view point [view].
  Offset2 toCanvas2(Offset view) {
    final c = toCanvas(view);
    return Offset2(c.dx, c.dy);
  }

  /// A view length (logical px) in canvas px.
  double viewToCanvasLength(double view) => scale == 0 ? 0 : view / scale;

  /// A canvas length in view px.
  double canvasToViewLength(double canvas) => canvas * scale;

  /// The four corners of [box] in view coordinates, in base-local order: top-left, top-right,
  /// bottom-right, bottom-left (before flips).
  List<Offset> cornersOf(ItemBox box) => [for (final c in box.corners) toView2(c)];

  /// The centre of [box] in view coordinates.
  Offset centerOf(ItemBox box) => toView2(box.center);

  /// The oriented rect of [box] in view coordinates.
  Path boxPath(ItemBox box) {
    final cs = cornersOf(box);
    return Path()
      ..moveTo(cs[0].dx, cs[0].dy)
      ..lineTo(cs[1].dx, cs[1].dy)
      ..lineTo(cs[2].dx, cs[2].dy)
      ..lineTo(cs[3].dx, cs[3].dy)
      ..close();
  }

  /// Whether the view point [view] lies inside [box] grown by [slop] view px.
  bool hits(ItemBox box, Offset view, {double slop = 0}) =>
      box.contains(toCanvas2(view), slop: viewToCanvasLength(slop));

  @override
  bool operator ==(Object other) => other is CanvasGeometry && other.canvasPx == canvasPx && other.viewRect == viewRect;

  @override
  int get hashCode => Object.hash(canvasPx, viewRect);

  @override
  String toString() => 'CanvasGeometry($canvasPx in $viewRect)';
}
