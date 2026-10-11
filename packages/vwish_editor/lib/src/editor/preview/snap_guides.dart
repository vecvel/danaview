// OWNER: UX-22
//
// Snapping in the preview (ux.md §7.4). Pure geometry in canvas px:
//
// * Targets: the canvas centre X and Y, the canvas edges, and the title-safe margins (5 % inset)
//   while the "Safe area guides" mode is on.
// * A moved box snaps per axis: its centre to the centre lines, and its (rotated) bounds' edges to
//   the edges and margins; the closest candidate within the threshold wins. The threshold is
//   6 view px with a pointer and 10 on touch, converted to canvas px by the caller.
// * Rotation magnet: within ±3° of a multiple of 45° the angle snaps to it.
// * [SnapEngagement] fires `HapticFeedback.selectionClick()` when a snap *engages* (a guide that
//   was not shown before appears), never continuously.
// * Holding Alt/Option (with a keyboard) disables snapping; the global snapping mode does too.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback, HardwareKeyboard;
import 'package:vwish_editor_core/eval.dart' show ItemBox, Offset2, Rect2, Size2;

/// Orientation of a guide line.
enum SnapAxis {
  /// A vertical line at canvas x = position.
  vertical,

  /// A horizontal line at canvas y = position.
  horizontal,
}

/// What a guide marks.
enum SnapTargetKind {
  /// The canvas centre line.
  center,

  /// A canvas edge.
  edge,

  /// A title-safe margin.
  safeMargin,
}

/// One guide line spanning the canvas (ux.md §7.4).
@immutable
final class SnapGuide {
  /// Creates a guide.
  const SnapGuide(this.axis, this.position, this.kind);

  /// Orientation.
  final SnapAxis axis;

  /// Canvas px (x for vertical lines, y for horizontal ones).
  final double position;

  /// What the line marks.
  final SnapTargetKind kind;

  @override
  bool operator ==(Object other) => other is SnapGuide && other.axis == axis && other.position == position && other.kind == kind;

  @override
  int get hashCode => Object.hash(axis, position, kind);

  @override
  String toString() => 'SnapGuide(${axis.name} $position ${kind.name})';
}

/// The result of snapping a move: the correction to add to the box centre and the guides shown.
@immutable
final class SnapResult {
  /// Creates a result.
  const SnapResult(this.delta, this.guides);

  /// Nothing snapped.
  static const SnapResult none = SnapResult(Offset2.zero, <SnapGuide>{});

  /// Correction in canvas px to add to the moved centre.
  final Offset2 delta;

  /// Guides to draw while snapped.
  final Set<SnapGuide> guides;

  /// Whether anything snapped.
  bool get snapped => guides.isNotEmpty;

  @override
  String toString() => 'SnapResult($delta, $guides)';
}

/// The result of the rotation magnet.
@immutable
final class RotationSnap {
  /// Creates a result.
  const RotationSnap(this.degrees, {this.snapped = false});

  /// The (possibly snapped) angle in degrees.
  final double degrees;

  /// Whether it snapped to a multiple of 45°.
  final bool snapped;
}

/// Centre, edge and safe-margin snapping in the preview (ux.md §7.4).
@immutable
class SnapGuides {
  /// Creates the targets of a canvas of [canvas] px; [safeMargins] adds the title-safe lines.
  const SnapGuides({required this.canvas, this.safeMargins = false});

  /// Threshold in view px with a mouse, trackpad or stylus.
  static const double pointerThreshold = 6;

  /// Threshold in view px on touch.
  static const double touchThreshold = 10;

  /// Rotation magnet half-width in degrees.
  static const double rotationMagnet = 3;

  /// Rotation magnet step in degrees.
  static const double rotationStep = 45;

  /// Title-safe inset as a fraction of each side.
  static const double safeInset = 0.05;

  /// The view-px threshold for the input kind.
  static double thresholdFor({required bool touch}) => touch ? touchThreshold : pointerThreshold;

  /// Whether snapping is suppressed by a held Alt/Option key.
  static bool get altHeld {
    final keys = HardwareKeyboard.instance;
    return keys.isAltPressed;
  }

  /// Canvas size in px.
  final Size2 canvas;

  /// Whether the title-safe margins are targets.
  final bool safeMargins;

  /// Vertical target lines (x positions) with their kinds.
  List<SnapGuide> get verticalTargets => [
        SnapGuide(SnapAxis.vertical, canvas.width / 2, SnapTargetKind.center),
        const SnapGuide(SnapAxis.vertical, 0, SnapTargetKind.edge),
        SnapGuide(SnapAxis.vertical, canvas.width, SnapTargetKind.edge),
        if (safeMargins) ...[
          SnapGuide(SnapAxis.vertical, canvas.width * safeInset, SnapTargetKind.safeMargin),
          SnapGuide(SnapAxis.vertical, canvas.width * (1 - safeInset), SnapTargetKind.safeMargin),
        ],
      ];

  /// Horizontal target lines (y positions) with their kinds.
  List<SnapGuide> get horizontalTargets => [
        SnapGuide(SnapAxis.horizontal, canvas.height / 2, SnapTargetKind.center),
        const SnapGuide(SnapAxis.horizontal, 0, SnapTargetKind.edge),
        SnapGuide(SnapAxis.horizontal, canvas.height, SnapTargetKind.edge),
        if (safeMargins) ...[
          SnapGuide(SnapAxis.horizontal, canvas.height * safeInset, SnapTargetKind.safeMargin),
          SnapGuide(SnapAxis.horizontal, canvas.height * (1 - safeInset), SnapTargetKind.safeMargin),
        ],
      ];

  /// Snaps [box] (already moved to its unsnapped position) to the targets within [threshold]
  /// canvas px. Box centres snap to centre lines; the box bounds' edges snap to edges and margins.
  SnapResult snapMove(ItemBox box, double threshold, {bool horizontal = true, bool vertical = true}) {
    if (!(threshold > 0)) return SnapResult.none;
    final b = box.bounds;
    final guides = <SnapGuide>{};
    var dx = 0.0;
    var dy = 0.0;
    if (horizontal) {
      final x = _best(verticalTargets, [b.center.dx], [b.left, b.right], threshold);
      if (x != null) {
        dx = x.$1;
        guides.addAll(x.$2);
      }
    }
    if (vertical) {
      final y = _best(horizontalTargets, [b.center.dy], [b.top, b.bottom], threshold);
      if (y != null) {
        dy = y.$1;
        guides.addAll(y.$2);
      }
    }
    if (guides.isEmpty) return SnapResult.none;
    return SnapResult(Offset2(dx, dy), guides);
  }

  /// The best correction along one axis, and the guides that line up after it.
  static (double, Set<SnapGuide>)? _best(List<SnapGuide> targets, List<double> centers, List<double> edges, double threshold) {
    double? best;
    for (final t in targets) {
      final values = t.kind == SnapTargetKind.center ? centers : edges;
      for (final v in values) {
        final d = t.position - v;
        if (d.abs() <= threshold && (best == null || d.abs() < best.abs())) best = d;
      }
    }
    if (best == null) return null;
    final shown = <SnapGuide>{};
    for (final t in targets) {
      final values = t.kind == SnapTargetKind.center ? centers : edges;
      for (final v in values) {
        if ((t.position - (v + best)).abs() < 0.5) shown.add(t);
      }
    }
    return (best, shown);
  }

  /// The rotation magnet: [degrees] within ±[rotationMagnet] of a multiple of 45° snaps to it.
  static RotationSnap snapRotation(double degrees) {
    final nearest = (degrees / rotationStep).roundToDouble() * rotationStep;
    if ((degrees - nearest).abs() <= rotationMagnet) return RotationSnap(nearest == 0 ? 0 : nearest, snapped: true);
    return RotationSnap(degrees);
  }

  /// The guide lines of [guides] as view-independent canvas segments (start, end) spanning the
  /// canvas.
  List<(Offset2, Offset2)> segmentsOf(Iterable<SnapGuide> guides) => [
        for (final g in guides)
          g.axis == SnapAxis.vertical
              ? (Offset2(g.position, 0), Offset2(g.position, canvas.height))
              : (Offset2(0, g.position), Offset2(canvas.width, g.position)),
      ];

  @override
  bool operator ==(Object other) => other is SnapGuides && other.canvas == canvas && other.safeMargins == safeMargins;

  @override
  int get hashCode => Object.hash(canvas, safeMargins);
}

/// Fires a selection haptic when a snap engages (a new guide appears), never continuously.
class SnapEngagement {
  /// Creates the tracker; [haptic] defaults to `HapticFeedback.selectionClick`.
  SnapEngagement({VoidCallback? haptic}) : _haptic = haptic ?? _click;

  static void _click() => HapticFeedback.selectionClick();

  final VoidCallback _haptic;
  Set<SnapGuide> _shown = const {};
  bool _rotation = false;

  /// Engagements so far (tests).
  int engagements = 0;

  /// Records the guides of the latest update; fires the haptic when one appears.
  void guides(Set<SnapGuide> now) {
    if (now.any((g) => !_shown.contains(g))) _fire();
    _shown = now;
  }

  /// Records whether the rotation magnet holds; fires when it engages.
  void rotation(bool snapped) {
    if (snapped && !_rotation) _fire();
    _rotation = snapped;
  }

  /// Forgets everything (gesture end).
  void reset() {
    _shown = const {};
    _rotation = false;
  }

  void _fire() {
    engagements++;
    _haptic();
  }
}

/// The bounds of [box] in canvas px (re-exported helper for painters).
Rect2 boundsOf(ItemBox box) => box.bounds;

/// Normalizes [deg] into (-180, 180].
double normalizeDegrees(double deg) {
  var d = deg % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// The angle in degrees (clockwise, y down) of [v].
double angleOf(Offset2 v) => math.atan2(v.dy, v.dx) * 180 / math.pi;
