// OWNER: UX-13
//
// Snapping UI over the core `SnapIndex` (ux.md §8.9, ARCH §17.4).
//
// * One `TimelineSnapping` per drag: the index is built once at drag start from the committed
//   project (`SnapIndex.build`, excluding the dragged items and their link partners), then every
//   pointer move asks it for the nearest target of the proposed time (or of both edges of a moved
//   group). Lookups are a binary search; nothing is allocated unless a target is in reach.
// * The threshold is 8 px with a pointer and 12 px on touch (`TimelineMetrics.snapThresholdPx`),
//   converted to time at the current zoom on every lookup, so zooming during a drag stays right.
// * The engaged target is the `guide` (a line across the lanes and a time pill in the ruler).
//   Each *new* engagement (another time or kind than the previous one) calls `onEngage` once:
//   the interaction plays `HapticFeedback.selectionClick` there. Leaving the reach clears the guide
//   without a haptic.
// * Snapping is off while Alt/Option is held (`TimelineDragUpdate.snapDisabled`) and while the
//   project's snapping mode is off (the N key, `toggleSnapping`); a disabled lookup also clears
//   the guide.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

export 'package:danaview_editor_core/ops.dart' show SnapHit, SnapIndex, SnapKind, SnapSide;

/// The engaged snap target shown by the interaction layer.
@immutable
final class SnapGuide {
  /// Creates a guide at [time] of [kind].
  const SnapGuide(this.time, this.kind);

  /// Where the guide line is drawn.
  final TimeUs time;

  /// What was snapped to.
  final SnapKind kind;

  @override
  bool operator ==(Object other) => other is SnapGuide && other.time == time && other.kind == kind;

  @override
  int get hashCode => Object.hash(time, kind);

  @override
  String toString() => 'SnapGuide(${kind.name} @ $time)';
}

/// The snapping state of one drag (ux.md §8.9).
class TimelineSnapping {
  /// Creates the snapping over [index]; [thresholdPx] is the reach in pixels; [onEngage] runs on
  /// each new engagement (haptic).
  TimelineSnapping(this.index, {required this.thresholdPx, this.onEngage});

  /// Builds the index of [project] for a drag of [dragged] (link partners are excluded too).
  ///
  /// [markers] is off for marker drags (the dragged marker would hold itself in place).
  factory TimelineSnapping.forDrag(
    EditProject project, {
    Set<ItemId> dragged = const {},
    TimeUs? playhead,
    bool markers = true,
    required double thresholdPx,
    VoidCallback? onEngage,
  }) {
    final exclude = dragged.isEmpty ? const <ItemId>{} : SelectionRules.expand(project, dragged);
    final index = SnapIndex.build(project, exclude: exclude, playhead: playhead, markers: markers);
    return TimelineSnapping(index, thresholdPx: thresholdPx, onEngage: onEngage);
  }

  /// Snap reach with a pointer (ux.md §8.9).
  static const double pointerThresholdPx = 8;

  /// Snap reach on touch (ux.md §8.9).
  static const double touchThresholdPx = 12;

  /// The reach for a pointer of the given kind.
  static double thresholdFor({required bool touch}) => touch ? touchThresholdPx : pointerThresholdPx;

  /// [px] as time at [pxPerSecond] (at least 1 µs).
  static TimeUs toleranceUs(double px, double pxPerSecond) =>
      pxPerSecond <= 0 || !pxPerSecond.isFinite ? 0 : math.max(1, (px / pxPerSecond * microsPerSecond).round());

  /// The targets.
  final SnapIndex index;

  /// Reach in pixels.
  final double thresholdPx;

  /// Called on each new engagement.
  final VoidCallback? onEngage;

  SnapGuide? _guide;
  int _engagements = 0;

  /// The engaged target, or null.
  SnapGuide? get guide => _guide;

  /// How many times a new target was engaged during this drag (tests, haptics).
  int get engagements => _engagements;

  /// [t] snapped to the nearest target within reach at [pxPerSecond]; [t] unchanged (and the
  /// guide cleared) when nothing is in reach or [enabled] is false.
  TimeUs snapTime(TimeUs t, {required double pxPerSecond, bool enabled = true}) {
    if (!enabled || index.isEmpty) return _engage(null, t);
    final hit = index.nearest(t, toleranceUs(thresholdPx, pxPerSecond));
    return _engage(hit, hit?.time ?? t);
  }

  /// The shift that lands the nearer edge of [range] on a target within reach (0 when none, or
  /// when [enabled] is false).
  TimeUs snapRange(TimeRange range, {required double pxPerSecond, bool enabled = true}) {
    if (!enabled || index.isEmpty) {
      _engage(null, 0);
      return 0;
    }
    final snap = index.nearestForRange(range, toleranceUs(thresholdPx, pxPerSecond));
    _engage(snap?.hit, 0);
    return snap?.delta ?? 0;
  }

  /// Clears the guide (the drag ended).
  void release() => _guide = null;

  TimeUs _engage(SnapHit? hit, TimeUs result) {
    final next = hit == null ? null : SnapGuide(hit.time, hit.kind);
    if (next != null && next != _guide) {
      _engagements++;
      onEngage?.call();
    }
    _guide = next;
    return result;
  }
}
