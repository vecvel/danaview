// OWNER: UX-10
//
// Typed timeline hits (ux.md §8.8) and the canvas geometry shared by the painter and the hit test
// (ux.md §8.6): lane bands, item bodies, trim handles, fade handles, keyframe diamonds and the
// transition chips at cuts.
//
// Coordinates are canvas-local: x is lanes-area x (0 at the right edge of the track headers, as in
// TimelineViewportController), y = 0 is the top of the lanes area (under the ruler). The ruler sits
// at y in [-rulerHeight, 0): `hitTestTimeline` answers there too (marker flags, the playhead knob
// in free mode, plain ruler), so the gesture arbiter (UX-12) needs one call for the whole timeline.
//
// Precedence inside a lane: keyframe diamond > transition chip > fade handle > trim handle > item
// body > main-lane gap > empty lane. Handles (diamonds, fades, trims) belong to selected items on
// unlocked lanes only (diamonds of every item while the Keyframes tool is open). In the ruler: the
// playhead knob itself > marker flag > the knob's touch target > ruler.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show TrimEdge;

import 'ruler.dart' show RulerPainter;
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_viewport.dart';

export 'package:vwish_editor_core/ops.dart' show TrimEdge;

/// The audio fade a fade handle sets.
enum FadeEdge {
  /// Fade-in (handle near the item's start).
  fadeIn,

  /// Fade-out (handle near the item's end).
  fadeOut,
}

/// What a pointer hit on the timeline (ux.md §8.8).
@immutable
sealed class TimelineHit {
  /// Creates a hit.
  const TimelineHit();
}

/// A trim handle of a selected item.
final class HitTrimHandle extends TimelineHit {
  /// Creates the hit.
  const HitTrimHandle({required this.item, required this.lane, required this.edge});

  /// The item.
  final ItemId item;

  /// Its lane.
  final TrackId lane;

  /// Which edge.
  final TrimEdge edge;

  @override
  bool operator ==(Object other) => other is HitTrimHandle && other.item == item && other.lane == lane && other.edge == edge;

  @override
  int get hashCode => Object.hash(item, lane, edge);

  @override
  String toString() => 'HitTrimHandle($item, $edge)';
}

/// A fade handle of a selected item with audio.
final class HitFadeHandle extends TimelineHit {
  /// Creates the hit.
  const HitFadeHandle({required this.item, required this.lane, required this.edge});

  /// The item.
  final ItemId item;

  /// Its lane.
  final TrackId lane;

  /// Which fade.
  final FadeEdge edge;

  @override
  bool operator ==(Object other) => other is HitFadeHandle && other.item == item && other.lane == lane && other.edge == edge;

  @override
  int get hashCode => Object.hash(item, lane, edge);

  @override
  String toString() => 'HitFadeHandle($item, $edge)';
}

/// A keyframe diamond.
final class HitKeyframe extends TimelineHit {
  /// Creates the hit.
  const HitKeyframe(this.ref, {required this.lane});

  /// The keyframe (item-local time).
  final KeyframeRef ref;

  /// The item's lane.
  final TrackId lane;

  @override
  bool operator ==(Object other) => other is HitKeyframe && other.ref == ref && other.lane == lane;

  @override
  int get hashCode => Object.hash(ref, lane);

  @override
  String toString() => 'HitKeyframe(${ref.item}, ${ref.property} @ ${ref.t})';
}

/// A transition chip (bowtie) or the "+" add-transition button at a cut.
final class HitTransition extends TimelineHit {
  /// Creates the hit.
  const HitTransition(this.ref, {required this.isAddButton});

  /// The cut.
  final TransitionRef ref;

  /// Whether it is the "+" (no transition yet).
  final bool isAddButton;

  @override
  bool operator ==(Object other) => other is HitTransition && other.ref == ref && other.isAddButton == isAddButton;

  @override
  int get hashCode => Object.hash(ref, isAddButton);

  @override
  String toString() => 'HitTransition(${ref.left}|${ref.right}${isAddButton ? ', add' : ''})';
}

/// The playhead knob in the ruler (free mode).
final class HitPlayheadKnob extends TimelineHit {
  /// Creates the hit.
  const HitPlayheadKnob();

  @override
  bool operator ==(Object other) => other is HitPlayheadKnob;

  @override
  int get hashCode => (HitPlayheadKnob).hashCode;

  @override
  String toString() => 'HitPlayheadKnob()';
}

/// A marker flag in the ruler.
final class HitMarker extends TimelineHit {
  /// Creates the hit.
  const HitMarker(this.id);

  /// The marker.
  final MarkerId id;

  @override
  bool operator ==(Object other) => other is HitMarker && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'HitMarker($id)';
}

/// The ruler away from flags and the knob.
final class HitRuler extends TimelineHit {
  /// Creates the hit.
  const HitRuler(this.time);

  /// Time under the pointer (not quantized).
  final TimeUs time;

  @override
  bool operator ==(Object other) => other is HitRuler && other.time == time;

  @override
  int get hashCode => time.hashCode;

  @override
  String toString() => 'HitRuler($time)';
}

/// An item body.
final class HitItem extends TimelineHit {
  /// Creates the hit.
  const HitItem({required this.item, required this.lane, required this.time, required this.selected, this.locked = false});

  /// The item.
  final ItemId item;

  /// Its lane.
  final TrackId lane;

  /// Time under the pointer (not quantized).
  final TimeUs time;

  /// Whether the item is selected.
  final bool selected;

  /// Whether the lane is locked (a tap shows "This track is locked").
  final bool locked;

  @override
  bool operator ==(Object other) =>
      other is HitItem && other.item == item && other.lane == lane && other.time == time && other.selected == selected && other.locked == locked;

  @override
  int get hashCode => Object.hash(item, lane, time, selected, locked);

  @override
  String toString() => 'HitItem($item${selected ? ', selected' : ''}${locked ? ', locked' : ''})';
}

/// A gap of the main lane.
final class HitGap extends TimelineHit {
  /// Creates the hit.
  const HitGap({required this.lane, required this.gap});

  /// The lane.
  final TrackId lane;

  /// The empty span.
  final TimeRange gap;

  @override
  bool operator ==(Object other) => other is HitGap && other.lane == lane && other.gap == gap;

  @override
  int get hashCode => Object.hash(lane, gap);

  @override
  String toString() => 'HitGap($lane, $gap)';
}

/// Empty lane background ([lane] set) or the space between/below lanes ([lane] null).
final class HitEmpty extends TimelineHit {
  /// Creates the hit.
  const HitEmpty({this.lane, required this.time});

  /// The lane, or null outside every lane.
  final TrackId? lane;

  /// Time under the pointer (not quantized).
  final TimeUs time;

  @override
  bool operator ==(Object other) => other is HitEmpty && other.lane == lane && other.time == time;

  @override
  int get hashCode => Object.hash(lane, time);

  @override
  String toString() => 'HitEmpty($lane, $time)';
}

// -------------------------------------------------------------------------------------------------
// Geometry
// -------------------------------------------------------------------------------------------------

/// Where the parts of a snapshot are drawn for one viewport state (canvas-local coordinates).
///
/// Build once per (snapshot, metrics); it reads zoom and scroll from the viewport live.
class TimelineCanvasGeometry {
  /// Geometry of [snapshot] laid out with [metrics], scrolled by [viewport].
  TimelineCanvasGeometry({required this.snapshot, required this.metrics, required this.viewport})
      : stack = TimelineLaneStack.of(snapshot.laneKinds, metrics, presets: snapshot.laneHeights);

  /// The snapshot.
  final TimelineSnapshot snapshot;

  /// Sizes.
  final TimelineMetrics metrics;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  /// The lane stack (content coordinates).
  final TimelineLaneStack stack;

  /// Canvas-local top of lane [index].
  double laneTop(int index) => stack.tops[index] - viewport.scrollY;

  /// Canvas-local band of lane [index] spanning [width].
  Rect laneRect(int index, double width) => Rect.fromLTWH(0, laneTop(index), width, stack.heights[index]);

  /// Index of the lane at canvas-local [y], or null.
  int? laneAt(double y) => stack.indexAt(y + viewport.scrollY);

  /// Visible lanes `[first, last)` for a canvas of [height].
  (int, int) visibleLanes(double height) => stack.visibleRange(viewport.scrollY, height);

  /// The body rect of [item] on lane [lane].
  Rect itemRect(int lane, ItemModel item) {
    final top = laneTop(lane) + TimelineMetrics.clipInset;
    final bottom = laneTop(lane) + stack.heights[lane] - TimelineMetrics.clipInset;
    return Rect.fromLTRB(viewport.xOf(item.start), top, viewport.xOf(item.end), bottom);
  }

  /// The drawn trim handle of [edge] of an item with body [body]: a 12 px bar inside the edge, or
  /// outside it when the body is narrower than three handles.
  static Rect trimHandleRect(Rect body, TrimEdge edge) {
    const w = TimelineMetrics.trimHandleWidth;
    final outside = body.width < 3 * w;
    return switch (edge) {
      TrimEdge.start => outside
          ? Rect.fromLTRB(body.left - w, body.top, body.left, body.bottom)
          : Rect.fromLTRB(body.left, body.top, body.left + w, body.bottom),
      TrimEdge.end => outside
          ? Rect.fromLTRB(body.right, body.top, body.right + w, body.bottom)
          : Rect.fromLTRB(body.right - w, body.top, body.right, body.bottom),
    };
  }

  /// The hit area of a trim handle: the drawn handle extended outward by the trim outset.
  Rect trimHitRect(Rect body, TrimEdge edge) {
    final r = trimHandleRect(body, edge);
    final out = metrics.trimHitOutset;
    return edge == TrimEdge.start ? Rect.fromLTRB(r.left - out, r.top, r.right, r.bottom) : Rect.fromLTRB(r.left, r.top, r.right + out, r.bottom);
  }

  /// Radius of a drawn fade handle.
  static const double fadeHandleRadius = 4;

  /// Centre of the fade handle of [edge] of [item] with body [body] (top edge, at the end of the
  /// fade ramp).
  Offset fadeHandleCentre(Rect body, ItemModel item, FadeEdge edge) {
    final y = body.top + fadeHandleRadius + 2;
    return switch (edge) {
      FadeEdge.fadeIn => Offset(math.min(body.right, viewport.xOf(item.start + item.fadeIn)), y),
      FadeEdge.fadeOut => Offset(math.max(body.left, viewport.xOf(item.end - item.fadeOut)), y),
    };
  }

  /// Centre y of the keyframe diamond row of an item with body [body].
  static double keyframeRowY(Rect body) => body.bottom - TimelineMetrics.keyframeRowInset - TimelineMetrics.keyframeDiamond / 2;

  /// Centre of the chip at [cut] on lane [lane].
  Offset cutCentre(int lane, CutModel cut) => Offset(viewport.xOf(cut.at), laneTop(lane) + stack.heights[lane] / 2);

  /// Whether the "+" add-transition button shows at [cut] of [laneModel]: main lane, no
  /// transition, unlocked, and both neighbours at least 40 px wide.
  bool showsAddButton(LaneModel laneModel, CutModel cut) {
    if (!laneModel.isMain || cut.hasTransition || laneModel.locked) return false;
    final left = laneModel.items[cut.leftIndex], right = laneModel.items[cut.leftIndex + 1];
    final pps = viewport.pxPerSecond;
    return TimelineMetrics.widthOf(left.duration, pps) >= TimelineMetrics.addTransitionMinNeighbourWidth &&
        TimelineMetrics.widthOf(right.duration, pps) >= TimelineMetrics.addTransitionMinNeighbourWidth;
  }

  /// The drawn rect of the bowtie chip or "+" circle at [cut].
  Rect cutChipRect(int lane, CutModel cut) {
    final c = cutCentre(lane, cut);
    final size = cut.hasTransition ? TimelineMetrics.transitionChipSize : TimelineMetrics.addTransitionDiameter;
    return Rect.fromCenter(center: c, width: size, height: size);
  }

  /// The hit area at [cut]: the bowtie chip grown to the minimum hit size, or the "+" target (32
  /// px, 44 on touch).
  Rect cutHitRect(int lane, CutModel cut) {
    final c = cutCentre(lane, cut);
    final size = cut.hasTransition
        ? math.max(TimelineMetrics.transitionChipSize, metrics.minHitSize)
        : metrics.addTransitionHitSize;
    return Rect.fromCenter(center: c, width: size, height: math.min(size, stack.heights[lane]));
  }

  /// Half the hit size of keyframe diamonds and fade handles.
  double get handleReach => metrics.touch ? 22 : 8;
}

// -------------------------------------------------------------------------------------------------
// Hit testing
// -------------------------------------------------------------------------------------------------

/// Hit tests a timeline (ux.md §8.8) from its geometry, the selection and the playhead.
abstract final class TimelineHitTester {
  /// The hit at canvas-local [p] for a canvas of [width]. [selected] are the selected items;
  /// [showAllKeyframes] makes every item's diamonds hittable (Keyframes tool open); [playhead]
  /// enables the knob in free mode; [rulerHeight] is the ruler band above y = 0.
  static TimelineHit hitTest(
    Offset p, {
    required TimelineCanvasGeometry geometry,
    required double rulerHeight,
    Set<ItemId> selected = const {},
    bool showAllKeyframes = false,
    TimeUs? playhead,
  }) {
    final viewport = geometry.viewport;
    final metrics = geometry.metrics;
    final snapshot = geometry.snapshot;
    final time = viewport.timeAt(p.dx);

    if (p.dy < 0) {
      if (p.dy < -rulerHeight) return HitEmpty(time: time);
      // Ruler: knob, then marker flags, then the knob's larger target.
      final knobX = playhead != null && !viewport.centerLocked ? viewport.xOf(playhead) : null;
      if (knobX != null && (p.dx - knobX).abs() <= TimelineMetrics.playheadKnobWidth / 2 + 1) return const HitPlayheadKnob();
      final marker = RulerPainter.markerAt(snapshot.markers, p.dx, viewport, hitSize: metrics.minHitSize);
      if (marker != null) return HitMarker(marker.id);
      if (knobX != null && (p.dx - knobX).abs() <= metrics.minHitSize / 2) return const HitPlayheadKnob();
      return HitRuler(time);
    }

    final laneIndex = geometry.laneAt(p.dy);
    if (laneIndex == null) return HitEmpty(time: time);
    final lane = snapshot.lanes[laneIndex];
    final editable = !lane.locked;
    final reach = geometry.handleReach;
    // Items whose handles can be under the pointer.
    final from = lane.firstItemEndingAfter(viewport.timeAt(p.dx - math.max(reach, metrics.trimHitOutset + TimelineMetrics.trimHandleWidth)));
    final to = viewport.timeAt(p.dx + math.max(reach, metrics.trimHitOutset + TimelineMetrics.trimHandleWidth));

    if (editable) {
      // 1. Keyframe diamonds.
      HitKeyframe? bestKey;
      var bestKeyDist = double.infinity;
      for (var i = from; i < lane.items.length && lane.items[i].start <= to; i++) {
        final item = lane.items[i];
        if (!item.hasKeyframes || !(showAllKeyframes || selected.contains(item.id))) continue;
        final body = geometry.itemRect(laneIndex, item);
        final y = TimelineCanvasGeometry.keyframeRowY(body);
        if ((p.dy - y).abs() > reach) continue;
        for (var k = 0; k < item.keyframeTimes.length; k++) {
          final x = viewport.xOf(item.keyframeAt(k));
          final d = (Offset(x, y) - p).distance;
          if (d <= reach && d < bestKeyDist) {
            bestKeyDist = d;
            bestKey = HitKeyframe(KeyframeRef(item.id, item.keyframeProperties[k], item.keyframeTimes[k]), lane: lane.id);
          }
        }
      }
      if (bestKey != null) return bestKey;
    }

    // 2. Transition chips at cuts.
    if (lane.cuts.isNotEmpty) {
      final half = math.max(metrics.minHitSize, metrics.addTransitionHitSize) / 2;
      for (var c = lane.firstCutFrom(viewport.timeAt(p.dx - half)); c < lane.cuts.length; c++) {
        final cut = lane.cuts[c];
        if (viewport.xOf(cut.at) - half > p.dx) break;
        if (!cut.hasTransition && !geometry.showsAddButton(lane, cut)) continue;
        if (geometry.cutHitRect(laneIndex, cut).contains(p)) return HitTransition(cut.ref, isAddButton: !cut.hasTransition);
      }
    }

    if (editable) {
      // 3. Fade handles and 4. trim handles of selected items.
      _HandleCandidate? best;
      for (var i = from; i < lane.items.length && lane.items[i].start <= to; i++) {
        final item = lane.items[i];
        if (!selected.contains(item.id)) continue;
        final body = geometry.itemRect(laneIndex, item);
        if (item.hasAudio) {
          for (final edge in FadeEdge.values) {
            final c = geometry.fadeHandleCentre(body, item, edge);
            final d = (c - p).distance;
            if (d <= reach && (best == null || best.rank > 0 || d < best.distance)) {
              best = _HandleCandidate(HitFadeHandle(item: item.id, lane: lane.id, edge: edge), d, 0);
            }
          }
        }
        for (final edge in TrimEdge.values) {
          final r = geometry.trimHitRect(body, edge);
          if (!r.contains(p)) continue;
          final edgeX = edge == TrimEdge.start ? body.left : body.right;
          final d = (p.dx - edgeX).abs();
          if (best == null || (best.rank == 1 && d < best.distance)) {
            best = _HandleCandidate(HitTrimHandle(item: item.id, lane: lane.id, edge: edge), d, 1);
          }
        }
      }
      if (best != null) return best.hit;
    }

    // 5. Item body.
    final index = lane.itemIndexAt(time);
    if (index != null) {
      final item = lane.items[index];
      final body = geometry.itemRect(laneIndex, item);
      if (p.dy >= body.top && p.dy < body.bottom) {
        return HitItem(item: item.id, lane: lane.id, time: time, selected: selected.contains(item.id), locked: lane.locked);
      }
    }

    // 6. Main-lane gap.
    final gap = lane.gapAt(time);
    if (gap != null) return HitGap(lane: lane.id, gap: gap);

    // 7. Empty lane.
    return HitEmpty(lane: lane.id, time: time);
  }
}

// A handle candidate while hit testing: lower rank wins, then smaller distance.
@immutable
final class _HandleCandidate {
  /// Creates a candidate.
  const _HandleCandidate(this.hit, this.distance, this.rank);

  /// The hit.
  final TimelineHit hit;

  /// Distance from the pointer.
  final double distance;

  /// 0 for fade handles, 1 for trim handles.
  final int rank;
}
