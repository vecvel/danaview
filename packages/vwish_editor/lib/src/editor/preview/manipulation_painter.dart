// OWNER: UX-22
//
// ManipulationPainter (ux.md §7.3 "Handles", §7.4): paints the selected item's oriented outline,
// its corner and rotate handles, the snap guides and the size/angle readout pill.
//
// * Outline: 1.5 px `primaryLight`.
// * Corner handles: 12 px white circles with the kit's subtle shadow; hit radius 22 px on touch
//   and 10 px with a pointer.
// * Rotate handle: a 24 px `surfaceElevatedHigher` circle with the rotate glyph, 28 px outside the
//   top edge's midpoint (it flips below the bottom edge when the top one is near the top of the
//   view).
// * Every handle stays inside the preview rect: a handle that would land outside is clamped and
//   joined to its true position by a leader line.
// * Guides: 1 px `primaryLight` lines across the canvas while a snap holds.
// * Readout: "W 64% · 32°" while dragging, in a pill above the box (Figtree).
//
// [ManipulationHandles.layout] is the single placement used by the painter and by the overlay's
// hit testing, so what is drawn is exactly what is grabbed.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart' show IconData;
import 'package:vwish_editor_core/eval.dart' show ItemBox, Offset2;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'canvas_geometry.dart';

/// Which handle a point grabs.
enum ManipulationHandleKind {
  /// A corner: uniform scale from the centre.
  corner,

  /// The rotate handle.
  rotate,
}

/// One placed handle: its drawn [position] (kept inside the view) and its true [anchor] on the box.
@immutable
final class HandleSpot {
  /// Creates a spot.
  const HandleSpot(this.position, this.anchor);

  /// Where the handle is drawn and grabbed.
  final Offset position;

  /// Where it belongs on the box (the leader line's other end when clamped).
  final Offset anchor;

  /// Whether the handle was moved inside the view.
  bool get clamped => (position - anchor).distance > 0.5;
}

/// A grabbed handle.
@immutable
final class HandleHit {
  /// Creates a hit.
  const HandleHit(this.kind, [this.corner = -1]);

  /// Handle kind.
  final ManipulationHandleKind kind;

  /// Corner index (0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left) or -1.
  final int corner;

  @override
  bool operator ==(Object other) => other is HandleHit && other.kind == kind && other.corner == corner;

  @override
  int get hashCode => Object.hash(kind, corner);

  @override
  String toString() => 'HandleHit(${kind.name}${corner >= 0 ? ' $corner' : ''})';
}

/// The handles of one selected box placed in the view (ux.md §7.3).
@immutable
final class ManipulationHandles {
  const ManipulationHandles._({
    required this.outline,
    required this.center,
    required this.corners,
    required this.rotate,
    required this.hitRadius,
  });

  /// Drawn diameter of a corner handle.
  static const double cornerDiameter = 12;

  /// Drawn diameter of the rotate handle.
  static const double rotateDiameter = 24;

  /// Distance of the rotate handle outside the box edge.
  static const double rotateOffset = 28;

  /// Hit radius of handles on touch.
  static const double touchHitRadius = 22;

  /// Hit radius of handles with a pointer.
  static const double pointerHitRadius = 10;

  /// Places the handles of [box] in a view of [view] size through [geometry]. [scalable] and
  /// [rotatable] drop the corner and rotate handles (subtitle tracks only move).
  factory ManipulationHandles.layout({
    required CanvasGeometry geometry,
    required ItemBox box,
    required Size view,
    required bool touch,
    bool scalable = true,
    bool rotatable = true,
  }) {
    final outline = geometry.cornersOf(box);
    final center = geometry.centerOf(box);
    Offset clampInside(Offset p, double r) => Offset(
          p.dx.clamp(r, math.max(r, view.width - r)),
          p.dy.clamp(r, math.max(r, view.height - r)),
        );
    final corners = scalable
        ? [for (final c in outline) HandleSpot(clampInside(c, cornerDiameter / 2), c)]
        : const <HandleSpot>[];
    HandleSpot? rotate;
    if (rotatable) {
      // Outward normal of the top edge (towards "up" of the box, away from its centre).
      final topMid = (outline[0] + outline[1]) / 2;
      final bottomMid = (outline[2] + outline[3]) / 2;
      var up = topMid - center;
      if (up.distance < 1e-6) {
        final edge = outline[1] - outline[0];
        up = Offset(edge.dy, -edge.dx);
      }
      final n = up / (up.distance == 0 ? 1 : up.distance);
      var anchor = topMid;
      var at = topMid + n * rotateOffset;
      const r = rotateDiameter / 2;
      if (at.dy < r + 2 || at.dx < r + 2 || at.dx > view.width - r - 2) {
        // Flip below the bottom edge when the top one is near the top of the view.
        final below = bottomMid - n * rotateOffset;
        if (below.dy <= view.height - r - 2) {
          anchor = bottomMid;
          at = below;
        }
      }
      rotate = HandleSpot(clampInside(at, r), anchor);
    }
    return ManipulationHandles._(
      outline: outline,
      center: center,
      corners: corners,
      rotate: rotate,
      hitRadius: touch ? touchHitRadius : pointerHitRadius,
    );
  }

  /// The box corners in view coordinates (unclamped).
  final List<Offset> outline;

  /// The box centre in view coordinates.
  final Offset center;

  /// Corner handles (empty when not scalable).
  final List<HandleSpot> corners;

  /// The rotate handle, or null.
  final HandleSpot? rotate;

  /// Hit radius for this input kind.
  final double hitRadius;

  /// The handle at the view point [p], nearest first; null when none is within reach.
  HandleHit? hitTest(Offset p) {
    HandleHit? best;
    var bestD = double.infinity;
    final rot = rotate;
    if (rot != null) {
      final d = (rot.position - p).distance;
      if (d <= math.max(hitRadius, rotateDiameter / 2) && d < bestD) {
        best = const HandleHit(ManipulationHandleKind.rotate);
        bestD = d;
      }
    }
    for (var i = 0; i < corners.length; i++) {
      final d = (corners[i].position - p).distance;
      if (d <= hitRadius && d < bestD) {
        best = HandleHit(ManipulationHandleKind.corner, i);
        bestD = d;
      }
    }
    return best;
  }

  /// The outline path in view coordinates.
  Path get outlinePath => Path()
    ..moveTo(outline[0].dx, outline[0].dy)
    ..lineTo(outline[1].dx, outline[1].dy)
    ..lineTo(outline[2].dx, outline[2].dy)
    ..lineTo(outline[3].dx, outline[3].dy)
    ..close();
}

/// The readout shown while dragging: "W 64% · 32°".
String manipulationReadout({required double scale, required double rotationDeg}) {
  final pct = (scale * 100).round();
  final deg = rotationDeg.round();
  return 'W $pct% · $deg°';
}

/// Paints selection boxes and handles (ux.md §7.3).
class ManipulationPainter extends CustomPainter {
  /// Creates the painter. [handles] null paints only [guides]; [guides] are view-space segments.
  ManipulationPainter({
    this.handles,
    this.guides = const [],
    this.readout,
    this.showHandles = true,
    this.textScale = 1,
  });

  /// The selected box's handles, or null.
  final ManipulationHandles? handles;

  /// Snap guide segments in view coordinates.
  final List<(Offset, Offset)> guides;

  /// The size/angle readout while dragging, or null.
  final String? readout;

  /// Whether to draw handles (false while a two-finger gesture hides them).
  final bool showHandles;

  /// Text scale of the readout.
  final double textScale;

  /// Outline colour.
  static const Color outlineColor = VwishColors.primaryLight;

  /// Outline width.
  static const double outlineWidth = 1.5;

  /// Rotate glyph.
  static const IconData rotateIcon = Icons.rotate_right_rounded;

  /// Builds the guide segments of [segments] (canvas px) in the view of [geometry].
  static List<(Offset, Offset)> viewGuides(CanvasGeometry geometry, List<(Offset2, Offset2)> segments) =>
      [for (final (a, b) in segments) (geometry.toView2(a), geometry.toView2(b))];

  @override
  void paint(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = VwishColors.primaryLight
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final (a, b) in guides) {
      canvas.drawLine(a, b, guidePaint);
    }
    final h = handles;
    if (h == null) return;
    canvas.drawPath(
      h.outlinePath,
      Paint()
        ..color = outlineColor
        ..strokeWidth = outlineWidth
        ..style = PaintingStyle.stroke,
    );
    if (showHandles) {
      final leader = Paint()
        ..color = VwishColors.primaryLight.withValues(alpha: 0.7)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      final shadow = VwishShadows.subtle.first;
      for (final c in h.corners) {
        if (c.clamped) canvas.drawLine(c.anchor, c.position, leader);
        canvas.drawCircle(
          c.position + shadow.offset,
          ManipulationHandles.cornerDiameter / 2 + 1,
          Paint()
            ..color = shadow.color
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma.clamp(0.0, 4.0)),
        );
        canvas.drawCircle(c.position, ManipulationHandles.cornerDiameter / 2, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(
          c.position,
          ManipulationHandles.cornerDiameter / 2,
          Paint()
            ..color = VwishColors.primaryLight
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      final r = h.rotate;
      if (r != null) {
        canvas.drawLine(r.anchor, r.position, leader);
        canvas.drawCircle(
          r.position + shadow.offset,
          ManipulationHandles.rotateDiameter / 2,
          Paint()
            ..color = shadow.color
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma.clamp(0.0, 4.0)),
        );
        canvas.drawCircle(r.position, ManipulationHandles.rotateDiameter / 2, Paint()..color = VwishColors.surfaceElevatedHigher);
        canvas.drawCircle(
          r.position,
          ManipulationHandles.rotateDiameter / 2,
          Paint()
            ..color = VwishColors.borderBright
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        final glyph = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(rotateIcon.codePoint),
            style: TextStyle(
              fontFamily: rotateIcon.fontFamily,
              package: rotateIcon.fontPackage,
              fontSize: 16,
              color: VwishColors.textPrimary,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        glyph.paint(canvas, r.position - Offset(glyph.width / 2, glyph.height / 2));
        glyph.dispose();
      }
    }
    final text = readout;
    if (text != null) _paintReadout(canvas, size, h, text);
  }

  void _paintReadout(Canvas canvas, Size size, ManipulationHandles h, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: VwishFonts.family,
          fontSize: 12 * textScale,
          fontWeight: FontWeight.w600,
          color: VwishColors.textPrimary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: math.max(0, size.width - 16));
    final w = tp.width + 16;
    final ht = tp.height + 8;
    var top = h.outline.map((p) => p.dy).reduce(math.min) - ht - 12;
    if (top < 4) top = h.outline.map((p) => p.dy).reduce(math.max) + 12;
    top = top.clamp(4.0, math.max(4.0, size.height - ht - 4)).toDouble();
    final left = (h.center.dx - w / 2).clamp(4.0, math.max(4.0, size.width - w - 4)).toDouble();
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(left, top, w, ht), const Radius.circular(VwishRadius.sm));
    canvas.drawRRect(rect, Paint()..color = VwishColors.surfaceElevatedHigher);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = VwishColors.hairline
        ..style = PaintingStyle.stroke,
    );
    tp.paint(canvas, Offset(left + 8, top + 4));
    tp.dispose();
  }

  @override
  bool shouldRepaint(ManipulationPainter oldDelegate) =>
      oldDelegate.handles != handles ||
      oldDelegate.readout != readout ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.textScale != textScale ||
      !_sameGuides(oldDelegate.guides, guides);

  static bool _sameGuides(List<(Offset, Offset)> a, List<(Offset, Offset)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
