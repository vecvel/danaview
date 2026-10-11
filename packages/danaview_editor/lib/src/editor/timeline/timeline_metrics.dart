// OWNER: UX-09
//
// Timeline metrics (ux.md §6.2, §8.4, §8.6): lane heights by kind, height preset and text scale,
// ruler height, track header widths per layout kind, the vertical lane stack, the x <-> time
// conversions every timeline layer shares, and the fixed sizes of the painted timeline elements.
// Pure values: nothing here listens to anything.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextScaler;
import 'package:danaview_editor_core/model.dart' show TrackKind, TimeUs, microsPerSecond;

import '../layout/editor_layout.dart' show EditorLayoutKind;

/// The user's track height choice (timeline options and track menu: Compact / Normal / Large).
///
/// `EditModes.laneHeight` (UX-08) and the snapshot's lane models (UX-10) use this type.
enum LaneHeightPreset {
  /// Compact lanes.
  compact,

  /// Normal lanes (the default).
  normal,

  /// Large lanes (waveforms on video lanes, bigger thumbnails).
  large,
}

/// Lane heights, ruler height, header width and element sizes of the timeline at one text scale.
///
/// Build it with [TimelineMetrics.resolve] from the `MediaQuery` text scaler and the layout kind;
/// the constructor takes the scale factor directly (tests, previews).
@immutable
final class TimelineMetrics {
  /// Metrics for the text scale factor [textScale] (`1.0` = no scaling).
  const TimelineMetrics({
    this.textScale = 1.0,
    this.laneHeight = LaneHeightPreset.normal,
    this.headerWidth = compactHeaderWidth,
    this.touch = true,
  });

  /// Metrics for [textScaler] (already clamped to 0.85–1.35 by the app), the editor layout [kind]
  /// and the input type ([touch] is false for mouse and trackpad devices).
  factory TimelineMetrics.resolve({
    required TextScaler textScaler,
    required EditorLayoutKind kind,
    required bool touch,
    LaneHeightPreset laneHeight = LaneHeightPreset.normal,
  }) =>
      TimelineMetrics(
        textScale: scaleOf(textScaler),
        laneHeight: laneHeight,
        headerWidth: headerWidthFor(kind, touch: touch),
        touch: touch,
      );

  /// The scale factor of the 11 px timeline labels under [textScaler] (exact for non-linear
  /// scalers at that size).
  static double scaleOf(TextScaler textScaler) => textScaler.scale(labelFontSize) / labelFontSize;

  /// Text scale factor used by the text-derived sizes.
  final double textScale;

  /// The track height preset.
  final LaneHeightPreset laneHeight;

  /// Width of the track header column.
  final double headerWidth;

  /// Whether the primary input is touch (larger hit areas).
  final bool touch;

  // ---- Fixed sizes (ux.md §6.2, §8.5, §8.6, §8.9, §8.10) --------------------------------------

  /// Font size of ruler labels, clip labels and badges' counts.
  static const double labelFontSize = 11;

  /// Header column on compact layouts (icon-only `DanaviewPressable`).
  static const double compactHeaderWidth = 44;

  /// Header column on medium layouts.
  static const double mediumHeaderWidth = 132;

  /// Header column on expanded layouts with a pointer.
  static const double expandedPointerHeaderWidth = 168;

  /// Header column on expanded layouts with touch.
  static const double expandedTouchHeaderWidth = 220;

  /// Gap between two lanes (the 1 px `laneSeparator` line is painted in it).
  static const double laneGap = 1;

  /// Vertical inset of a clip body inside its lane.
  static const double clipInset = 2;

  /// Corner radius of clip bodies (`DanaviewRadius.xs`).
  static const double clipRadius = 6;

  /// A clip shows its label chip from this width.
  static const double labelMinClipWidth = 72;

  /// A clip shows its duration next to the label from this width.
  static const double durationMinClipWidth = 120;

  /// A clip shows badges from this width.
  static const double badgesMinClipWidth = 48;

  /// Size of one badge glyph.
  static const double badgeSize = 14;

  /// Size of a keyframe diamond.
  static const double keyframeDiamond = 7;

  /// Distance of the keyframe diamond row above the clip's bottom edge.
  static const double keyframeRowInset = 4;

  /// Width of a trim handle bar inside the clip edge.
  static const double trimHandleWidth = 12;

  /// Size of the transition "bowtie" chip on a cut.
  static const double transitionChipSize = 20;

  /// Diameter of the "+" add-transition circle.
  static const double addTransitionDiameter = 16;

  /// The "+" circle shows only when both neighbours are at least this wide.
  static const double addTransitionMinNeighbourWidth = 40;

  /// Width of a marker flag in the ruler.
  static const double markerFlagWidth = 10;

  /// Width of the playhead line.
  static const double playheadWidth = 2;

  /// Size of the playhead knob in the ruler (free mode).
  static const double playheadKnobWidth = 12;

  /// Height of the playhead knob in the ruler (free mode).
  static const double playheadKnobHeight = 18;

  /// Distance from a horizontal edge where drags auto-scroll.
  static const double autoScrollEdge = 48;

  // ---- Text-derived sizes (ux.md §6.2) --------------------------------------------------------

  /// Height of the ruler: `max(24, 8 + 11·s·1.2)`, rounded up to whole pixels.
  double get rulerHeight => math.max(24, 8 + labelFontSize * textScale * 1.2).ceilToDouble();

  /// Line height of an 11 px label at this scale.
  double get labelLineHeight => labelFontSize * textScale * 1.25;

  /// Height of a clip label chip (one label line plus 2 px padding above and below).
  double get labelChipHeight => (labelLineHeight + 4).ceilToDouble();

  /// Height of a lane of [kind] for the [preset] (default: this metrics' [laneHeight]).
  ///
  /// Video and overlay lanes: compact 52, normal 60, large 76. Audio lanes: 40, 48, 64. Text and
  /// subtitle lanes hold one line of text and follow the text scale: `max(32, 12 + 11·s·1.3)`.
  double laneHeightOf(TrackKind kind, {LaneHeightPreset? preset}) {
    final p = preset ?? laneHeight;
    return switch (kind) {
      TrackKind.video || TrackKind.overlay => switch (p) {
          LaneHeightPreset.compact => 52,
          LaneHeightPreset.normal => 60,
          LaneHeightPreset.large => 76,
        },
      TrackKind.audio => switch (p) {
          LaneHeightPreset.compact => 40,
          LaneHeightPreset.normal => 48,
          LaneHeightPreset.large => 64,
        },
      TrackKind.text || TrackKind.subtitle => math.max(32, 12 + labelFontSize * textScale * 1.3).ceilToDouble(),
    };
  }

  /// Width of the track header column for the layout [kind]: 44 on compact layouts, 132 on medium,
  /// 168 (pointer) or 220 (touch) on expanded.
  static double headerWidthFor(EditorLayoutKind kind, {required bool touch}) => switch (kind) {
        EditorLayoutKind.compactPortrait || EditorLayoutKind.compactLandscape => compactHeaderWidth,
        EditorLayoutKind.medium => mediumHeaderWidth,
        EditorLayoutKind.expanded => touch ? expandedTouchHeaderWidth : expandedPointerHeaderWidth,
      };

  /// Whether the header column is the compact icon-only one.
  bool get compactHeaders => headerWidth <= compactHeaderWidth;

  /// How far a trim handle's hit area extends outside the clip edge (12 px, 20 on touch).
  double get trimHitOutset => touch ? 20 : 12;

  /// Hit area of the add-transition "+" (32 px, 44 on touch), centred on the cut.
  double get addTransitionHitSize => touch ? 44 : 32;

  /// Snap threshold in pixels (8 px, 12 on touch).
  double get snapThresholdPx => touch ? 12 : 8;

  /// Smallest hit target for tappable painted elements (marker flags, knobs): 44 on touch, 24
  /// with a pointer.
  double get minHitSize => touch ? 44 : 24;

  /// A copy with the given fields replaced.
  TimelineMetrics copyWith({double? textScale, LaneHeightPreset? laneHeight, double? headerWidth, bool? touch}) => TimelineMetrics(
        textScale: textScale ?? this.textScale,
        laneHeight: laneHeight ?? this.laneHeight,
        headerWidth: headerWidth ?? this.headerWidth,
        touch: touch ?? this.touch,
      );

  // ---- x <-> time (ux.md §8.4) -----------------------------------------------------------------

  /// The x (lanes-area local, px) of [t] for a view whose left edge shows [scrollTimeSec] at
  /// [pxPerSecond].
  static double xOfTime(TimeUs t, {required double scrollTimeSec, required double pxPerSecond}) =>
      (t / microsPerSecond - scrollTimeSec) * pxPerSecond;

  /// The time (µs, rounded to the nearest µs) at lanes-area x [x]; inverse of [xOfTime].
  static TimeUs timeAtX(double x, {required double scrollTimeSec, required double pxPerSecond}) =>
      ((scrollTimeSec + x / pxPerSecond) * microsPerSecond).round();

  /// Width in px of a span of [duration] µs at [pxPerSecond].
  static double widthOf(TimeUs duration, double pxPerSecond) => duration / microsPerSecond * pxPerSecond;

  /// The span (µs, rounded) covered by [px] pixels at [pxPerSecond].
  static TimeUs durationOfWidth(double px, double pxPerSecond) => (px / pxPerSecond * microsPerSecond).round();

  @override
  bool operator ==(Object other) =>
      other is TimelineMetrics &&
      other.textScale == textScale &&
      other.laneHeight == laneHeight &&
      other.headerWidth == headerWidth &&
      other.touch == touch;

  @override
  int get hashCode => Object.hash(textScale, laneHeight, headerWidth, touch);

  @override
  String toString() => 'TimelineMetrics(s: $textScale, $laneHeight, header: $headerWidth, touch: $touch)';
}

/// The vertical stack of lanes (display order, top to bottom) with [TimelineMetrics.laneGap]
/// between neighbours. Content y = 0 is the top of the first lane, under the ruler.
@immutable
final class TimelineLaneStack {
  /// A stack of lanes with the given [heights].
  TimelineLaneStack(List<double> heights)
      : heights = List.unmodifiable(heights),
        tops = List.unmodifiable(_tops(heights));

  /// The stack of [kinds] laid out with [metrics] (each lane at its own [presets] entry when given).
  factory TimelineLaneStack.of(List<TrackKind> kinds, TimelineMetrics metrics, {List<LaneHeightPreset?>? presets}) {
    assert(presets == null || presets.length == kinds.length);
    return TimelineLaneStack([
      for (var i = 0; i < kinds.length; i++) metrics.laneHeightOf(kinds[i], preset: presets?[i]),
    ]);
  }

  static List<double> _tops(List<double> heights) {
    final out = <double>[];
    var y = 0.0;
    for (final h in heights) {
      out.add(y);
      y += h + TimelineMetrics.laneGap;
    }
    return out;
  }

  /// Lane heights, top to bottom.
  final List<double> heights;

  /// Top y of each lane in content coordinates.
  final List<double> tops;

  /// Number of lanes.
  int get length => heights.length;

  /// Height of all lanes and the gaps between them.
  double get contentHeight => heights.isEmpty ? 0 : tops.last + heights.last;

  /// Bottom y of lane [index].
  double bottomOf(int index) => tops[index] + heights[index];

  /// Index of the lane containing content y [y], or null in a gap, above the first or below the last
  /// lane. Binary search.
  int? indexAt(double y) {
    if (heights.isEmpty || y < 0) return null;
    var lo = 0, hi = tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return y < bottomOf(lo) ? lo : null;
  }

  /// Indices `[first, last)` of the lanes intersecting the content band `[scrollY, scrollY +
  /// viewportHeight)`. Binary search; empty when nothing is visible.
  (int first, int last) visibleRange(double scrollY, double viewportHeight) {
    if (heights.isEmpty || viewportHeight <= 0) return (0, 0);
    final top = scrollY, bottom = scrollY + viewportHeight;
    // First lane whose bottom is below `top`.
    var lo = 0, hi = heights.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (bottomOf(mid) <= top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final first = lo;
    // First lane whose top is at or below `bottom`.
    lo = first;
    hi = heights.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (tops[mid] < bottom) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (first, lo);
  }
}
