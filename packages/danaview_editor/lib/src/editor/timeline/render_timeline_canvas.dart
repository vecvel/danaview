// OWNER: UX-10
//
// RenderTimelineCanvas (ARCH §17.4, ux.md §8.6): one leaf RenderBox (its own repaint boundary)
// painting the lanes of a TimelineSnapshot for the current TimelineViewportController state.
//
// * Only the visible window is visited: visible lanes come from the lane stack (binary search over
//   scrollY), and per lane a binary search finds the first item ending after the window start;
//   iteration stops past the window end. Cost O(log n + visible). The window is the screen plus
//   ½ viewport of overscan on each side: on-screen items are painted, overscan items are only
//   offered to the thumbnail hook for prefetch.
// * Per item, in order: body, content (thumbnail strip / waveform through the UX-20 / UX-21 hooks,
//   or text excerpt), fades and the volume line, label chip, badges, state overlays (selected,
//   locked, hidden, offline, pending), keyframe diamonds (selected item, or every item while the
//   Keyframes tool is open) and fade handles. Then the cuts: bowtie chips and the main-lane "+".
// * Painting goes through `TimelineTiles` (UX-43 placeholder, a pass-through today) so tiling can
//   be enabled without editing this file.
// * Repaints from the viewport, the thumbnail/waveform hooks' `changes`, the interaction
//   controller (lifted items) and, only when a diamond would change its fill, the playhead.
// * `hitTestTimeline` (timeline_hit.dart) answers typed hits for the gesture arbiter (UX-12).
// * Semantics: one node per visible item (label, selected flag), decorated by UX-12's
//   `semanticsDecorator` (custom actions).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewRadius;

import '../caches/paragraph_cache.dart';
import '../state/editor_state.dart' show EditorSelection;
import 'timeline_hit.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_style.dart';
import 'timeline_tiles.dart';
import 'timeline_viewport.dart';

// -------------------------------------------------------------------------------------------------
// Hooks (UX-20 thumbnails, UX-21 waveforms, UX-13 interaction, UX-12 semantics)
// -------------------------------------------------------------------------------------------------

/// What a content hook needs to paint one clip. Coordinates are canvas-local (see
/// timeline_hit.dart); the canvas is already clipped to the clip body.
@immutable
final class TimelineClipPaint {
  /// Creates the context.
  const TimelineClipPaint({
    required this.lane,
    required this.item,
    required this.body,
    required this.visible,
    required this.pxPerSecond,
    required this.scrollTimeSec,
    required this.devicePixelRatio,
    required this.laneHeight,
    required this.style,
    this.overscan = false,
    this.flingVelocityX = 0,
  });

  /// The lane.
  final LaneModel lane;

  /// The item.
  final ItemModel item;

  /// The full body rect (may extend past the canvas).
  final Rect body;

  /// The part of [body] on screen (empty for overscan prefetch).
  final Rect visible;

  /// Zoom.
  final double pxPerSecond;

  /// Time at x = 0, in seconds.
  final double scrollTimeSec;

  /// Device pixel ratio (strip heights are bucketed from `laneHeight · dpr`).
  final double devicePixelRatio;

  /// Height of the lane in logical px.
  final double laneHeight;

  /// Colours.
  final TimelineStyle style;

  /// Whether the clip is in the overscan only (prefetch priority, nothing is painted).
  final bool overscan;

  /// Horizontal fling velocity (px/s); loads defer while it is fast (ux.md §17.3).
  final double flingVelocityX;

  /// Canvas x of timeline time [t].
  double xOf(TimeUs t) => (t / microsPerSecond - scrollTimeSec) * pxPerSecond;

  /// Timeline time at canvas x [x].
  TimeUs timeAt(double x) => ((scrollTimeSec + x / pxPerSecond) * microsPerSecond).round();
}

/// The thumbnail-strip painting hook (implemented by UX-20's ThumbnailCache).
///
/// Each paint calls [beginPaint], then [paintThumbnails] for every on-screen clip that shows
/// thumbnails and [prefetchThumbnails] for overscan clips, then [endPaint] (requests not touched
/// since [beginPaint] can be cancelled). [changes] notifies when tiles for visible clips arrive.
abstract mixin class TimelineThumbnailHook {
  /// Notifies when the canvas should repaint (arrivals for visible keys).
  Listenable get changes;

  /// A paint pass over [window] (the visible window with overscan) starts.
  void beginPaint(TimeRange window) {}

  /// Paints the strip cells of [clip.item] that are cached; returns false when nothing could be
  /// painted (the canvas then draws flat placeholder cells). Misses are requested at visible
  /// priority (deferred during a fast fling).
  bool paintThumbnails(Canvas canvas, TimelineClipPaint clip);

  /// Requests the strip of an overscan clip at prefetch priority; paints nothing.
  void prefetchThumbnails(TimelineClipPaint clip) {}

  /// The paint pass ended.
  void endPaint() {}
}

/// The waveform painting hook (implemented by UX-21's WaveformCache).
abstract mixin class TimelineWaveformHook {
  /// Notifies when the canvas should repaint (peaks for visible clips arrived).
  Listenable get changes;

  /// Paints the waveform of [clip.item] into [area] in [color] (speed, reverse and the volume
  /// envelope applied); returns false when the peaks are not ready (the canvas draws a centre
  /// line).
  bool paintWaveform(Canvas canvas, TimelineClipPaint clip, Rect area, Color color);
}

/// What the canvas reads from the interaction controller (UX-13 implements it): the items lifted
/// by a drag are drawn dimmed; their ghosts are drawn by the interaction layer.
abstract interface class TimelineCanvasInteraction implements Listenable {
  /// Items currently lifted (moved by a drag).
  Set<ItemId> get liftedItems;
}

/// What a semantics node describes.
@immutable
final class TimelineSemanticsTarget {
  /// Creates the target.
  const TimelineSemanticsTarget({required this.lane, required this.item, required this.selected});

  /// The lane.
  final LaneModel lane;

  /// The item.
  final ItemModel item;

  /// Whether the item is selected.
  final bool selected;
}

/// Adds custom actions to an item's semantics node (UX-12's timeline_semantics).
typedef TimelineSemanticsDecorator = void Function(TimelineSemanticsTarget target, SemanticsConfiguration config);

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Plain copy painted or announced by the canvas.
abstract final class TimelineCanvasStrings {
  /// Painted over clips whose media is missing.
  static const String missing = 'Missing';

  /// Semantics label of the canvas.
  static const String timeline = 'Timeline';

  /// The kind name used in item semantics.
  static String kindName(ItemVisualKind kind) => switch (kind) {
        ItemVisualKind.video => 'Video clip',
        ItemVisualKind.image => 'Image',
        ItemVisualKind.freeze => 'Freeze frame',
        ItemVisualKind.audio => 'Audio clip',
        ItemVisualKind.text => 'Text',
        ItemVisualKind.cue => 'Caption',
      };

  /// The semantics label of [item] on [lane].
  static String itemLabel(LaneModel lane, ItemModel item) {
    final parts = <String>[
      item.label.isEmpty ? kindName(item.kind) : '${kindName(item.kind)}, ${item.label}',
      'length ${Timecode.clock(item.duration)}',
      'starts at ${Timecode.clock(item.start)}',
      'track ${lane.displayName}',
      if (item.offline) 'media missing',
      if (item.pending) 'being prepared',
      if (lane.locked) 'track locked',
      if (lane.hidden) 'track hidden',
    ];
    return parts.join(', ');
  }
}

// -------------------------------------------------------------------------------------------------
// Painter
// -------------------------------------------------------------------------------------------------

/// What one canvas paint drew (debug builds; tests read it).
@immutable
final class TimelineCanvasPaintReport {
  /// Creates a report.
  const TimelineCanvasPaintReport({
    required this.lanes,
    required this.items,
    required this.overscanItems,
    required this.cuts,
    required this.diamonds,
    required this.filledDiamonds,
    required this.gaps,
    required this.labels,
    required this.badges,
    required this.thumbnailPlaceholders,
    required this.waveformFallbacks,
  });

  /// Display indices of the lanes painted.
  final List<int> lanes;

  /// Items painted (on screen).
  final List<ItemId> items;

  /// Items offered for prefetch only (overscan).
  final List<ItemId> overscanItems;

  /// Cuts painted (bowtie or "+"), with whether it was the "+".
  final List<(TransitionRef, bool)> cuts;

  /// Number of keyframe diamonds painted.
  final int diamonds;

  /// Number of diamonds painted filled (at the playhead).
  final int filledDiamonds;

  /// Gaps painted.
  final List<TimeRange> gaps;

  /// Label texts painted (chips and excerpts).
  final List<String> labels;

  /// Badge glyph counts per item.
  final Map<ItemId, int> badges;

  /// Clips painted with placeholder cells (no thumbnails yet).
  final int thumbnailPlaceholders;

  /// Clips painted with the waveform centre line (no peaks yet).
  final int waveformFallbacks;
}

/// Paints a snapshot for a viewport state (used by [RenderTimelineCanvas]; pure so tests can call
/// it on a recorder).
class TimelineCanvasPainter {
  /// Creates a painter.
  TimelineCanvasPainter({required this.style, required this.paragraphs, required this.metrics});

  /// Colours and font.
  final TimelineStyle style;

  /// Laid-out labels.
  final ParagraphCache paragraphs;

  /// Sizes (text scale).
  final TimelineMetrics metrics;

  static const double _chipRadius = 4;
  static const double _hatchStep = 6;

  /// Paints [geometry] into a canvas of [size] (canvas already translated to the canvas origin).
  TimelineCanvasPaintReport paint(
    Canvas canvas,
    Size size, {
    required TimelineCanvasGeometry geometry,
    EditorSelection selection = EditorSelection.empty,
    Set<ItemId> lifted = const {},
    bool showAllKeyframes = false,
    TimeUs? playhead,
    TimelineThumbnailHook? thumbnails,
    TimelineWaveformHook? waveforms,
    bool showThumbnails = true,
    bool showWaveforms = true,
    double devicePixelRatio = 1,
  }) {
    final viewport = geometry.viewport;
    final snapshot = geometry.snapshot;
    final w = size.width, h = size.height;
    final lanesPainted = <int>[];
    final itemsPainted = <ItemId>[];
    final overscan = <ItemId>[];
    final cutsPainted = <(TransitionRef, bool)>[];
    final gapsPainted = <TimeRange>[];
    final labels = <String>[];
    final badgeCounts = <ItemId, int>{};
    var diamonds = 0, filled = 0, placeholders = 0, fallbacks = 0;

    canvas.drawRect(Offset.zero & size, Paint()..color = style.laneBackground);
    if (!viewport.hasLayout || viewport.pxPerSecond <= 0 || snapshot.lanes.isEmpty || w <= 0) {
      return TimelineCanvasPaintReport(
        lanes: lanesPainted,
        items: itemsPainted,
        overscanItems: overscan,
        cuts: cutsPainted,
        diamonds: 0,
        filledDiamonds: 0,
        gaps: gapsPainted,
        labels: labels,
        badges: badgeCounts,
        thumbnailPlaceholders: 0,
        waveformFallbacks: 0,
      );
    }

    final screenStart = viewport.timeAt(0), screenEnd = viewport.timeAt(w);
    final windowStart = viewport.timeAt(-w / 2), windowEnd = viewport.timeAt(w * 1.5);
    final playheadFrame = playhead == null ? null : snapshot.frameRate.quantize(playhead);
    thumbnails?.beginPaint(TimeRange(math.max(0, windowStart), math.max(math.max(0, windowStart), windowEnd)));

    final (first, last) = geometry.visibleLanes(h);
    final separator = Paint()..color = style.laneSeparator;
    for (var li = first; li < last; li++) {
      final lane = snapshot.lanes[li];
      final band = geometry.laneRect(li, w);
      lanesPainted.add(li);
      canvas.drawRect(Rect.fromLTWH(0, band.bottom, w, TimelineMetrics.laneGap), separator);

      final dim = lane.hidden ? style.hiddenOpacity : (lane.locked ? style.lockedOpacity : 1.0);
      if (dim < 1) canvas.saveLayer(band, Paint()..color = Color.fromRGBO(0, 0, 0, dim));

      // Main-lane gaps (hatched, selectable).
      for (final gap in lane.gaps) {
        if (gap.end <= screenStart) continue;
        if (gap.start >= screenEnd) break;
        final r = Rect.fromLTRB(_clampX(viewport.xOf(gap.start), w), band.top + TimelineMetrics.clipInset,
            _clampX(viewport.xOf(gap.end), w), band.bottom - TimelineMetrics.clipInset);
        _hatch(canvas, r, style.gapHatch);
        final sel = selection.gap;
        if (sel != null && sel.track == lane.id && sel.range == gap) {
          _outline(canvas, RRect.fromRectAndRadius(r, const Radius.circular(TimelineMetrics.clipRadius)));
        }
        gapsPainted.add(gap);
      }

      // Items.
      for (var i = lane.firstItemEndingAfter(windowStart); i < lane.items.length; i++) {
        final item = lane.items[i];
        if (item.start >= windowEnd) break;
        final body = geometry.itemRect(li, item);
        final onScreen = item.end > screenStart && item.start < screenEnd;
        if (!onScreen) {
          overscan.add(item.id);
          if (thumbnails != null && showThumbnails && item.showsThumbnails && !item.offline) {
            thumbnails.prefetchThumbnails(_clipPaint(geometry, lane, li, item, body, Rect.zero, devicePixelRatio, overscan: true));
          }
          continue;
        }
        itemsPainted.add(item.id);
        final isSelected = selection.items.contains(item.id);
        final isLifted = lifted.contains(item.id);
        if (isLifted) canvas.saveLayer(body.inflate(2), Paint()..color = const Color.fromRGBO(0, 0, 0, 0.35));
        final r = _paintItem(
          canvas,
          size,
          geometry: geometry,
          lane: lane,
          laneIndex: li,
          item: item,
          body: body,
          selected: isSelected,
          showDiamonds: !lane.locked && (showAllKeyframes || isSelected),
          selectedKeyframe: selection.keyframe,
          playheadFrame: playheadFrame,
          thumbnails: showThumbnails ? thumbnails : null,
          waveforms: showWaveforms ? waveforms : null,
          dpr: devicePixelRatio,
          labels: labels,
        );
        if (isLifted) canvas.restore();
        diamonds += r.diamonds;
        filled += r.filled;
        if (r.badges > 0) badgeCounts[item.id] = r.badges;
        if (r.placeholder) placeholders++;
        if (r.waveFallback) fallbacks++;
      }

      // Cuts: bowties and the main-lane "+".
      if (lane.cuts.isNotEmpty) {
        final reach = TimelineMetrics.transitionChipSize / viewport.pxPerSecond * microsPerSecond;
        for (var c = lane.firstCutFrom(screenStart - reach.round()); c < lane.cuts.length; c++) {
          final cut = lane.cuts[c];
          if (cut.at > screenEnd + reach) break;
          if (cut.hasTransition) {
            _bowtie(canvas, geometry.cutChipRect(li, cut), selected: selection.transition == cut.ref);
            cutsPainted.add((cut.ref, false));
          } else if (geometry.showsAddButton(lane, cut)) {
            _addButton(canvas, geometry.cutChipRect(li, cut));
            cutsPainted.add((cut.ref, true));
          }
        }
      }
      if (dim < 1) canvas.restore();
    }
    thumbnails?.endPaint();
    return TimelineCanvasPaintReport(
      lanes: lanesPainted,
      items: itemsPainted,
      overscanItems: overscan,
      cuts: cutsPainted,
      diamonds: diamonds,
      filledDiamonds: filled,
      gaps: gapsPainted,
      labels: labels,
      badges: badgeCounts,
      thumbnailPlaceholders: placeholders,
      waveformFallbacks: fallbacks,
    );
  }

  static double _clampX(double x, double w) => x.clamp(-2 * TimelineMetrics.clipRadius, w + 2 * TimelineMetrics.clipRadius);

  TimelineClipPaint _clipPaint(TimelineCanvasGeometry g, LaneModel lane, int li, ItemModel item, Rect body, Rect visible, double dpr,
          {bool overscan = false}) =>
      TimelineClipPaint(
        lane: lane,
        item: item,
        body: body,
        visible: visible,
        pxPerSecond: g.viewport.pxPerSecond,
        scrollTimeSec: g.viewport.scrollTimeSec,
        devicePixelRatio: dpr,
        laneHeight: g.stack.heights[li],
        style: style,
        overscan: overscan,
        flingVelocityX: g.viewport.flingVelocityX,
      );

  ({int diamonds, int filled, int badges, bool placeholder, bool waveFallback}) _paintItem(
    Canvas canvas,
    Size size, {
    required TimelineCanvasGeometry geometry,
    required LaneModel lane,
    required int laneIndex,
    required ItemModel item,
    required Rect body,
    required bool selected,
    required bool showDiamonds,
    required KeyframeRef? selectedKeyframe,
    required TimeUs? playheadFrame,
    required TimelineThumbnailHook? thumbnails,
    required TimelineWaveformHook? waveforms,
    required double dpr,
    required List<String> labels,
  }) {
    final w = size.width;
    final drawn = Rect.fromLTRB(_clampX(body.left, w), body.top, _clampX(body.right, w), body.bottom);
    final visible = Rect.fromLTRB(math.max(0, body.left), body.top, math.min(w, body.right), body.bottom);
    final rrect = RRect.fromRectAndRadius(drawn, const Radius.circular(TimelineMetrics.clipRadius));
    var placeholder = false, waveFallback = false;

    // 1. Body.
    canvas.drawRRect(rrect, Paint()..color = item.offline ? style.offlineFill : style.clipFill(lane.kind));

    // 2. Content (clipped to the body).
    canvas.save();
    canvas.clipRRect(rrect);
    final textScale = metrics.textScale;
    if (item.offline) {
      _hatch(canvas, visible, style.offlineHatch);
    } else if (item.showsThumbnails) {
      final ctx = _clipPaint(geometry, lane, laneIndex, item, body, visible, dpr);
      final painted = thumbnails != null && thumbnails.paintThumbnails(canvas, ctx);
      if (!painted) {
        placeholder = true;
        _placeholderCells(canvas, body, visible, item.visual?.aspect ?? 16 / 9);
      }
      if (waveforms != null && item.hasAudio && lane.height == LaneHeightPreset.large) {
        final area = Rect.fromLTRB(body.left, body.bottom - body.height * 0.4, body.right, body.bottom);
        if (!waveforms.paintWaveform(canvas, ctx, area, style.audioWave)) {
          waveFallback = true;
          _centreLine(canvas, area, visible);
        }
      }
    } else if (item.kind == ItemVisualKind.audio) {
      final ctx = _clipPaint(geometry, lane, laneIndex, item, body, visible, dpr);
      final top = body.top + (lane.height == LaneHeightPreset.compact ? 0 : metrics.labelChipHeight + 4);
      final area = Rect.fromLTRB(body.left, math.min(top, body.bottom - 8), body.right, body.bottom - 2);
      if (waveforms == null || !waveforms.paintWaveform(canvas, ctx, area, style.audioWave)) {
        waveFallback = true;
        _centreLine(canvas, area, visible);
      }
    } else if (item.isTextLike && item.label.isNotEmpty) {
      final p = paragraphs.paragraph(
        item.label,
        TimelineTextStyle(fontFamily: style.fontFamily, fontSize: TimelineMetrics.labelFontSize * textScale, color: style.clipForeground(lane.kind)),
        maxWidth: visible.width - 12,
      );
      if (p != null) {
        canvas.drawParagraph(p, Offset(visible.left + 6, body.center.dy - p.height / 2));
        labels.add(item.label);
      }
    }
    if (lane.kind == TrackKind.overlay) {
      canvas.drawRect(Rect.fromLTRB(visible.left, body.top, visible.right, body.top + 3), Paint()..color = style.overlayAccent);
    }
    // Fades.
    if (item.fadeIn > 0 || item.fadeOut > 0) {
      final shade = Paint()..color = const Color(0x66000000);
      if (item.fadeIn > 0) {
        final x = geometry.viewport.xOf(item.start + item.fadeIn);
        canvas.drawPath(
            Path()
              ..moveTo(body.left, body.top)
              ..lineTo(x, body.top)
              ..lineTo(body.left, body.bottom)
              ..close(),
            shade);
      }
      if (item.fadeOut > 0) {
        final x = geometry.viewport.xOf(item.end - item.fadeOut);
        canvas.drawPath(
            Path()
              ..moveTo(body.right, body.top)
              ..lineTo(x, body.top)
              ..lineTo(body.right, body.bottom)
              ..close(),
            shade);
      }
    }
    // Volume line (selected items with audio).
    if (selected && item.hasAudio) _volumeLine(canvas, geometry, item, body, visible);
    canvas.restore();

    // 3. Label chip and 4. badges.
    final badges = _badgesOf(item);
    var badgeLeft = visible.right - 4;
    var badgesPainted = 0;
    final showsLabel = !item.isTextLike && body.width >= TimelineMetrics.labelMinClipWidth;
    if (body.width >= TimelineMetrics.badgesMinClipWidth && badges.isNotEmpty) {
      // With a label chip, badges get at most half of the clip; the rest collapses to a count.
      final room = showsLabel ? (visible.width - 8) / 2 : visible.width - 8;
      final r = _paintBadges(canvas, badges, right: visible.right - 4, top: body.top + 3, available: room);
      badgeLeft = r.left;
      badgesPainted = r.count;
    }
    if (showsLabel) {
      final withDuration = body.width >= TimelineMetrics.durationMinClipWidth;
      final text = item.label.isEmpty
          ? Timecode.clock(item.duration)
          : (withDuration ? '${item.label} · ${Timecode.clock(item.duration)}' : item.label);
      final left = visible.left + 4;
      final room = badgeLeft - 4 - left - 8;
      final p = paragraphs.paragraph(
        text,
        TimelineTextStyle(
          fontFamily: style.fontFamily,
          fontSize: TimelineMetrics.labelFontSize * textScale,
          color: style.labelForeground,
          tabularFigures: true,
        ),
        maxWidth: room,
      );
      if (p != null) {
        final chipH = math.min(metrics.labelChipHeight, body.height - 4);
        final chip = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, body.top + 3, math.min(p.maxIntrinsicWidth, p.width) + 8, chipH),
          const Radius.circular(_chipRadius),
        );
        canvas.drawRRect(chip, Paint()..color = style.labelChip);
        canvas.save();
        canvas.clipRRect(chip);
        canvas.drawParagraph(p, Offset(left + 4, chip.top + (chipH - p.height) / 2));
        canvas.restore();
        labels.add(text);
      }
    }

    // 5. State overlays.
    if (lane.locked) _hatch(canvas, visible, style.lockedHatch);
    if (item.offline) _offlineMark(canvas, visible, labels);
    if (selected) _outline(canvas, rrect);

    // 6. Keyframe diamonds and fade handles.
    var diamonds = 0, filled = 0;
    if (showDiamonds && item.hasKeyframes) {
      final y = TimelineCanvasGeometry.keyframeRowY(body);
      const half = TimelineMetrics.keyframeDiamond / 2;
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = style.mark;
      final fill = Paint()..color = style.mark;
      final selectedFill = Paint()..color = style.selection;
      final from = _firstKeyAtOrAfter(item, geometry.viewport.timeAt(-half) - item.start);
      for (var k = from; k < item.keyframeTimes.length; k++) {
        final t = item.keyframeAt(k);
        final x = geometry.viewport.xOf(t);
        if (x > size.width + half) break;
        final path = Path()
          ..moveTo(x, y - half)
          ..lineTo(x + half, y)
          ..lineTo(x, y + half)
          ..lineTo(x - half, y)
          ..close();
        final isSel = selectedKeyframe != null && selectedKeyframe.item == item.id && selectedKeyframe.t == item.keyframeTimes[k];
        final atPlayhead = playheadFrame != null && t == playheadFrame;
        if (isSel) {
          canvas.drawPath(path, selectedFill);
        } else if (atPlayhead) {
          canvas.drawPath(path, fill);
        } else {
          canvas.drawPath(path, Paint()..color = style.labelChip);
          canvas.drawPath(path, stroke);
        }
        diamonds++;
        if (atPlayhead) filled++;
      }
    }
    if (selected && item.hasAudio && !lane.locked) {
      final handleFill = Paint()..color = style.mark;
      final handleStroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = style.selection;
      for (final edge in FadeEdge.values) {
        final c = geometry.fadeHandleCentre(body, item, edge);
        canvas.drawCircle(c, TimelineCanvasGeometry.fadeHandleRadius, handleFill);
        canvas.drawCircle(c, TimelineCanvasGeometry.fadeHandleRadius, handleStroke);
      }
    }
    return (diamonds: diamonds, filled: filled, badges: badgesPainted, placeholder: placeholder, waveFallback: waveFallback);
  }

  static int _firstKeyAtOrAfter(ItemModel item, TimeUs local) {
    final keys = item.keyframeTimes;
    var lo = 0, hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[mid] < local) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _placeholderCells(Canvas canvas, Rect body, Rect visible, double aspect) {
    canvas.drawRect(visible, Paint()..color = style.videoFill);
    final cell = math.max(16.0, body.height * aspect);
    final line = Paint()..color = style.laneBackground.withAlpha(0x59);
    final firstIndex = ((visible.left - body.left) / cell).floor() + 1;
    for (var x = body.left + firstIndex * cell; x < visible.right; x += cell) {
      canvas.drawRect(Rect.fromLTWH(x, body.top, 1, body.height), line);
    }
  }

  void _centreLine(Canvas canvas, Rect area, Rect visible) {
    canvas.drawRect(
      Rect.fromLTWH(visible.left, area.center.dy - 0.5, visible.width, 1),
      Paint()..color = style.audioWave.withAlpha(0x66),
    );
  }

  void _volumeLine(Canvas canvas, TimelineCanvasGeometry g, ItemModel item, Rect body, Rect visible) {
    double yOf(double v) => body.top + 2 + (1 - (v / 2).clamp(0.0, 1.0)) * (body.height - 4);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = style.mark.withAlpha(0xCC);
    final keys = item.volumeKeys;
    if (keys.isEmpty) {
      final y = yOf(item.volume);
      canvas.drawLine(Offset(visible.left, y), Offset(visible.right, y), paint);
      return;
    }
    final path = Path()..moveTo(visible.left, yOf(keys.first.v));
    for (final k in keys) {
      path.lineTo(g.viewport.xOf(item.start + k.t).clamp(visible.left, visible.right), yOf(k.v));
    }
    path.lineTo(visible.right, yOf(keys.last.v));
    canvas.drawPath(path, paint);
  }

  /// Badge glyphs of [item] in paint order: (bit, text, isIcon).
  static List<(int, String, bool)> _badgesOf(ItemModel item) {
    final b = item.badges;
    if (b == 0) return const [];
    String icon(IconData d) => String.fromCharCode(d.codePoint);
    return [
      if (b & ItemBadges.speed != 0) (ItemBadges.speed, speedText(item.avgSpeed), false),
      if (b & ItemBadges.ramp != 0) (ItemBadges.ramp, icon(Icons.show_chart_rounded), true),
      if (b & ItemBadges.reversed != 0) (ItemBadges.reversed, icon(Icons.fast_rewind_rounded), true),
      if (b & ItemBadges.freeze != 0) (ItemBadges.freeze, icon(Icons.ac_unit_rounded), true),
      if (b & ItemBadges.muted != 0) (ItemBadges.muted, icon(Icons.volume_off_rounded), true),
      if (b & ItemBadges.fx != 0) (ItemBadges.fx, 'fx', false),
      if (b & ItemBadges.color != 0) (ItemBadges.color, icon(Icons.tune_rounded), true),
      if (b & ItemBadges.lut != 0) (ItemBadges.lut, icon(Icons.palette_rounded), true),
      if (b & ItemBadges.chroma != 0) (ItemBadges.chroma, icon(Icons.colorize_rounded), true),
      if (b & ItemBadges.mask != 0) (ItemBadges.mask, icon(Icons.filter_center_focus_rounded), true),
      if (b & ItemBadges.keyframes != 0) (ItemBadges.keyframes, icon(Icons.diamond_outlined), true),
      if (b & ItemBadges.pending != 0) (ItemBadges.pending, icon(Icons.hourglass_top_rounded), true),
    ];
  }

  /// `2x`, `0.5x`, `1.25x`.
  static String speedText(double rate) {
    final r = (rate * 100).round() / 100;
    final s = r == r.roundToDouble() ? r.toInt().toString() : r.toString();
    return '${s}x';
  }

  /// Paints badges right-aligned at [right]; collapses to a "+N" count when they do not fit in
  /// [available]. Returns the left edge and the number of badges painted (count chip included).
  ({double left, int count}) _paintBadges(Canvas canvas, List<(int, String, bool)> badges,
      {required double right, required double top, required double available}) {
    const size = TimelineMetrics.badgeSize, gap = 2.0;
    final glyph = TimelineTextStyle(
        fontFamily: Icons.tune_rounded.fontFamily ?? 'MaterialIcons', fontSize: 12, color: style.labelForeground, ellipsis: false);
    final text = TimelineTextStyle(
        fontFamily: style.fontFamily, fontSize: 9, fontWeight: FontWeight.w700, color: style.labelForeground, ellipsis: false);
    double widthOf((int, String, bool) b) => b.$3 ? size : math.max(size, paragraphs.widthOf(b.$2, text) + 4);
    var total = 0.0;
    for (final b in badges) {
      total += widthOf(b) + gap;
    }
    var shown = badges;
    if (total - gap > available) {
      // Keep as many as fit next to a "+N" chip.
      final countChip = math.max(size, paragraphs.widthOf('+${badges.length}', text) + 4);
      var used = countChip;
      var n = 0;
      for (final b in badges) {
        final bw = widthOf(b) + gap;
        if (used + bw > available) break;
        used += bw;
        n++;
      }
      if (countChip > available) return (left: right, count: 0);
      shown = [...badges.take(n), (0, '+${badges.length - n}', false)];
    }
    var x = right;
    final bg = Paint()..color = style.labelChip;
    for (final b in shown.reversed) {
      final bw = widthOf(b);
      final rect = Rect.fromLTWH(x - bw, top, bw, size);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(DanaviewRadius.xs)), bg);
      final p = paragraphs.paragraph(b.$2, b.$3 ? glyph : text);
      if (p != null) {
        canvas.save();
        canvas.clipRect(rect);
        canvas.drawParagraph(p, Offset(rect.center.dx - p.maxIntrinsicWidth / 2, rect.center.dy - p.height / 2));
        canvas.restore();
      }
      x -= bw + gap;
    }
    return (left: x + gap, count: shown.length);
  }

  void _offlineMark(Canvas canvas, Rect visible, List<String> labels) {
    if (visible.width < 24) return;
    final glyph = paragraphs.paragraph(
      String.fromCharCode(Icons.link_off_rounded.codePoint),
      TimelineTextStyle(fontFamily: Icons.link_off_rounded.fontFamily ?? 'MaterialIcons', fontSize: 14, color: style.labelForeground, ellipsis: false),
    );
    final text = paragraphs.paragraph(
      TimelineCanvasStrings.missing,
      TimelineTextStyle(fontFamily: style.fontFamily, fontSize: TimelineMetrics.labelFontSize * metrics.textScale, color: style.labelForeground),
      maxWidth: visible.width - 30,
    );
    final gw = glyph?.maxIntrinsicWidth ?? 0;
    final tw = text == null ? 0.0 : math.min(text.maxIntrinsicWidth, text.width);
    final chipW = math.min(visible.width - 4, gw + (text == null ? 0 : tw + 4) + 8);
    final chipH = math.min(visible.height - 4, math.max(16.0, (text?.height ?? 14) + 2));
    final chip = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(visible.center.dx, visible.bottom - chipH / 2 - 3), width: chipW, height: chipH),
      const Radius.circular(_chipRadius),
    );
    canvas.drawRRect(chip, Paint()..color = style.labelChip);
    canvas.save();
    canvas.clipRRect(chip);
    var x = chip.left + 4;
    if (glyph != null) {
      canvas.drawParagraph(glyph, Offset(x, chip.center.dy - glyph.height / 2));
      x += gw + 4;
    }
    if (text != null) {
      canvas.drawParagraph(text, Offset(x, chip.center.dy - text.height / 2));
      labels.add(TimelineCanvasStrings.missing);
    }
    canvas.restore();
  }

  void _outline(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = style.selection,
    );
  }

  void _hatch(Canvas canvas, Rect rect, Color color) {
    if (rect.width <= 0 || rect.height <= 0) return;
    final path = Path();
    // Lines aligned to the canvas origin so hatches do not crawl when only the clip moves.
    final start = ((rect.left - rect.height) / _hatchStep).floor() * _hatchStep;
    for (var x = start; x < rect.right; x += _hatchStep) {
      path
        ..moveTo(x, rect.bottom)
        ..lineTo(x + rect.height, rect.top);
    }
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
    canvas.restore();
  }

  void _bowtie(Canvas canvas, Rect rect, {required bool selected}) {
    final chip = RRect.fromRectAndRadius(rect, const Radius.circular(DanaviewRadius.xs));
    canvas.drawRRect(chip, Paint()..color = style.labelChip);
    final c = rect.center;
    const s = 5.0;
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - s, c.dy - s)
        ..lineTo(c.dx, c.dy)
        ..lineTo(c.dx - s, c.dy + s)
        ..close()
        ..moveTo(c.dx + s, c.dy - s)
        ..lineTo(c.dx, c.dy)
        ..lineTo(c.dx + s, c.dy + s)
        ..close(),
      Paint()..color = style.labelForeground,
    );
    canvas.drawRRect(
      chip,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2 : 1
        ..color = selected ? style.selection : style.labelForeground.withAlpha(0x40),
    );
  }

  void _addButton(Canvas canvas, Rect rect) {
    final c = rect.center;
    final r = rect.width / 2;
    canvas.drawCircle(c, r, Paint()..color = style.labelChip);
    canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = style.labelForeground.withAlpha(0x59),
    );
    final plus = Paint()
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = style.labelForeground;
    final a = r * 0.5;
    canvas.drawLine(Offset(c.dx - a, c.dy), Offset(c.dx + a, c.dy), plus);
    canvas.drawLine(Offset(c.dx, c.dy - a), Offset(c.dx, c.dy + a), plus);
  }
}

// -------------------------------------------------------------------------------------------------
// Widget
// -------------------------------------------------------------------------------------------------

/// The lanes of the timeline (ux.md §8.6): a leaf render object that sizes to its constraints and
/// repaints (never rebuilds) when the viewport, the caches or the interaction change.
class TimelineCanvas extends LeafRenderObjectWidget {
  /// Creates the canvas.
  const TimelineCanvas({
    super.key,
    required this.snapshot,
    required this.viewport,
    this.selection = EditorSelection.empty,
    this.thumbnails,
    this.waveforms,
    this.paragraphs,
    this.style,
    this.metrics,
    this.interaction,
    this.playhead,
    this.showAllKeyframes = false,
    this.showThumbnails = true,
    this.showWaveforms = true,
    this.tiles = const TimelineTiles.disabled(),
    this.semanticsDecorator,
  });

  /// What to paint.
  final TimelineSnapshot snapshot;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  /// The selection (outlines, handles, diamonds).
  final EditorSelection selection;

  /// Thumbnail hook (UX-20), or null for placeholder cells.
  final TimelineThumbnailHook? thumbnails;

  /// Waveform hook (UX-21), or null for centre lines.
  final TimelineWaveformHook? waveforms;

  /// Label paragraphs to share (default: one cache per canvas).
  final ParagraphCache? paragraphs;

  /// Colours and font (default [TimelineStyle.standard]).
  final TimelineStyle? style;

  /// Sizes (default: from `MediaQuery`'s text scaler, touch layout).
  final TimelineMetrics? metrics;

  /// Lifted items (UX-13).
  final TimelineCanvasInteraction? interaction;

  /// The playhead: diamonds at it are filled; the knob is hit-tested in free mode.
  final ValueListenable<TimeUs>? playhead;

  /// Whether every item shows its diamonds (Keyframes tool open).
  final bool showAllKeyframes;

  /// Timeline option "Show thumbnails".
  final bool showThumbnails;

  /// Timeline option "Show waveforms".
  final bool showWaveforms;

  /// Picture-tile cache (UX-43; disabled pass-through).
  final TimelineTiles tiles;

  /// Adds custom semantics actions to item nodes (UX-12).
  final TimelineSemanticsDecorator? semanticsDecorator;

  TimelineMetrics _metricsOf(BuildContext context) =>
      metrics ?? TimelineMetrics(textScale: TimelineMetrics.scaleOf(MediaQuery.textScalerOf(context)));

  double _dprOf(BuildContext context) => MediaQuery.maybeDevicePixelRatioOf(context) ?? View.of(context).devicePixelRatio;

  @override
  RenderTimelineCanvas createRenderObject(BuildContext context) => RenderTimelineCanvas(
        snapshot: snapshot,
        viewport: viewport,
        selection: selection,
        thumbnails: thumbnails,
        waveforms: waveforms,
        paragraphs: paragraphs,
        style: style ?? TimelineStyle.standard,
        metrics: _metricsOf(context),
        interaction: interaction,
        playhead: playhead,
        showAllKeyframes: showAllKeyframes,
        showThumbnails: showThumbnails,
        showWaveforms: showWaveforms,
        tiles: tiles,
        semanticsDecorator: semanticsDecorator,
        devicePixelRatio: _dprOf(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderTimelineCanvas renderObject) {
    renderObject
      ..snapshot = snapshot
      ..viewport = viewport
      ..selection = selection
      ..thumbnails = thumbnails
      ..waveforms = waveforms
      ..paragraphs = paragraphs
      ..style = style ?? TimelineStyle.standard
      ..metrics = _metricsOf(context)
      ..interaction = interaction
      ..playhead = playhead
      ..showAllKeyframes = showAllKeyframes
      ..showThumbnails = showThumbnails
      ..showWaveforms = showWaveforms
      ..tiles = tiles
      ..semanticsDecorator = semanticsDecorator
      ..devicePixelRatio = _dprOf(context);
  }
}

// -------------------------------------------------------------------------------------------------
// Render object
// -------------------------------------------------------------------------------------------------

/// Paints the visible window of the timeline (ARCH §17.4).
class RenderTimelineCanvas extends RenderBox {
  /// Creates the render object.
  RenderTimelineCanvas({
    required TimelineSnapshot snapshot,
    required TimelineViewportController viewport,
    EditorSelection selection = EditorSelection.empty,
    TimelineThumbnailHook? thumbnails,
    TimelineWaveformHook? waveforms,
    ParagraphCache? paragraphs,
    TimelineStyle? style,
    TimelineMetrics metrics = const TimelineMetrics(),
    TimelineCanvasInteraction? interaction,
    ValueListenable<TimeUs>? playhead,
    bool showAllKeyframes = false,
    bool showThumbnails = true,
    bool showWaveforms = true,
    TimelineTiles tiles = const TimelineTiles.disabled(),
    TimelineSemanticsDecorator? semanticsDecorator,
    double devicePixelRatio = 1,
  })  : _snapshot = snapshot,
        _viewport = viewport,
        _selection = selection,
        _thumbnails = thumbnails,
        _waveforms = waveforms,
        _sharedParagraphs = paragraphs,
        _style = style ?? TimelineStyle.standard,
        _metrics = metrics,
        _interaction = interaction,
        _playhead = playhead,
        _showAllKeyframes = showAllKeyframes,
        _showThumbnails = showThumbnails,
        _showWaveforms = showWaveforms,
        _tiles = tiles,
        _semanticsDecorator = semanticsDecorator,
        _dpr = devicePixelRatio;

  TimelineSnapshot _snapshot;
  TimelineViewportController _viewport;
  EditorSelection _selection;
  TimelineThumbnailHook? _thumbnails;
  TimelineWaveformHook? _waveforms;
  ParagraphCache? _sharedParagraphs;
  ParagraphCache? _ownParagraphs;
  TimelineStyle _style;
  TimelineMetrics _metrics;
  TimelineCanvasInteraction? _interaction;
  ValueListenable<TimeUs>? _playhead;
  bool _showAllKeyframes;
  bool _showThumbnails;
  bool _showWaveforms;
  TimelineTiles _tiles;
  TimelineSemanticsDecorator? _semanticsDecorator;
  double _dpr;
  TimelineCanvasGeometry? _geometry;

  // Diamonds painted last time (to repaint on playhead moves only when a fill changes).
  final List<ItemModel> _diamondItems = [];
  int _filledKey = 0;

  // Stable semantics nodes per item.
  final Map<ItemId, SemanticsNode> _semanticsNodes = {};

  /// What the last paint drew (debug builds; null in release).
  TimelineCanvasPaintReport? debugLastPaint;

  /// Number of paints (debug builds), for repaint tests.
  int debugPaintCount = 0;

  ParagraphCache get _paragraphs => _sharedParagraphs ?? (_ownParagraphs ??= ParagraphCache());

  /// The geometry of the current snapshot, metrics and viewport.
  TimelineCanvasGeometry get geometry =>
      _geometry ??= TimelineCanvasGeometry(snapshot: _snapshot, metrics: _metrics, viewport: _viewport);

  /// Height of all lanes (content height for the viewport).
  double get contentHeight => geometry.stack.contentHeight;

  /// The snapshot.
  TimelineSnapshot get snapshot => _snapshot;
  set snapshot(TimelineSnapshot value) {
    if (identical(value, _snapshot)) return;
    _snapshot = value;
    _geometry = null;
    _tiles.invalidate();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// The viewport.
  TimelineViewportController get viewport => _viewport;
  set viewport(TimelineViewportController value) {
    if (identical(value, _viewport)) return;
    if (attached) _viewport.removeListener(_onViewport);
    _viewport = value;
    _geometry = null;
    if (attached) _viewport.addListener(_onViewport);
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// The selection.
  EditorSelection get selection => _selection;
  set selection(EditorSelection value) {
    if (value == _selection) return;
    _selection = value;
    _tiles.invalidate();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// Thumbnail hook.
  TimelineThumbnailHook? get thumbnails => _thumbnails;
  set thumbnails(TimelineThumbnailHook? value) {
    if (identical(value, _thumbnails)) return;
    if (attached) _thumbnails?.changes.removeListener(_onContent);
    _thumbnails = value;
    if (attached) _thumbnails?.changes.addListener(_onContent);
    _onContent();
  }

  /// Waveform hook.
  TimelineWaveformHook? get waveforms => _waveforms;
  set waveforms(TimelineWaveformHook? value) {
    if (identical(value, _waveforms)) return;
    if (attached) _waveforms?.changes.removeListener(_onContent);
    _waveforms = value;
    if (attached) _waveforms?.changes.addListener(_onContent);
    _onContent();
  }

  /// A shared paragraph cache, or null for the canvas's own.
  ParagraphCache? get paragraphs => _sharedParagraphs;
  set paragraphs(ParagraphCache? value) {
    if (identical(value, _sharedParagraphs)) return;
    _sharedParagraphs = value;
    markNeedsPaint();
  }

  /// Colours and font.
  TimelineStyle get style => _style;
  set style(TimelineStyle value) {
    if (value == _style) return;
    _style = value;
    _tiles.invalidate();
    markNeedsPaint();
  }

  /// Sizes.
  TimelineMetrics get metrics => _metrics;
  set metrics(TimelineMetrics value) {
    if (value == _metrics) return;
    _metrics = value;
    _geometry = null;
    _paragraphs.setTextScale(value.textScale);
    _tiles.invalidate();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// Lifted items source.
  TimelineCanvasInteraction? get interaction => _interaction;
  set interaction(TimelineCanvasInteraction? value) {
    if (identical(value, _interaction)) return;
    if (attached) _interaction?.removeListener(markNeedsPaint);
    _interaction = value;
    if (attached) _interaction?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// The playhead.
  ValueListenable<TimeUs>? get playhead => _playhead;
  set playhead(ValueListenable<TimeUs>? value) {
    if (identical(value, _playhead)) return;
    if (attached) _playhead?.removeListener(_onPlayhead);
    _playhead = value;
    if (attached) _playhead?.addListener(_onPlayhead);
    markNeedsPaint();
  }

  /// Whether every item shows diamonds.
  bool get showAllKeyframes => _showAllKeyframes;
  set showAllKeyframes(bool value) {
    if (value == _showAllKeyframes) return;
    _showAllKeyframes = value;
    _tiles.invalidate();
    markNeedsPaint();
  }

  /// "Show thumbnails".
  bool get showThumbnails => _showThumbnails;
  set showThumbnails(bool value) {
    if (value == _showThumbnails) return;
    _showThumbnails = value;
    _onContent();
  }

  /// "Show waveforms".
  bool get showWaveforms => _showWaveforms;
  set showWaveforms(bool value) {
    if (value == _showWaveforms) return;
    _showWaveforms = value;
    _onContent();
  }

  /// The tile cache.
  TimelineTiles get tiles => _tiles;
  set tiles(TimelineTiles value) {
    if (identical(value, _tiles)) return;
    // The tile cache belongs to whoever passed it (UX-43); the canvas never disposes it.
    _tiles = value;
    markNeedsPaint();
  }

  /// Semantics decorator.
  TimelineSemanticsDecorator? get semanticsDecorator => _semanticsDecorator;
  set semanticsDecorator(TimelineSemanticsDecorator? value) {
    if (identical(value, _semanticsDecorator)) return;
    _semanticsDecorator = value;
    markNeedsSemanticsUpdate();
  }

  /// Device pixel ratio.
  double get devicePixelRatio => _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    _tiles.invalidate();
    markNeedsPaint();
  }

  void _onViewport() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void _onContent() {
    _tiles.invalidate();
    markNeedsPaint();
  }

  void _onPlayhead() {
    if (_diamondItems.isEmpty) return;
    if (_filledKeyOf(_playhead?.value) != _filledKey) markNeedsPaint();
  }

  int _filledKeyOf(TimeUs? playhead) {
    if (playhead == null) return 0;
    final t = _snapshot.frameRate.quantize(playhead);
    for (final item in _diamondItems) {
      if (t < item.start || t >= item.end) continue;
      final local = t - item.start;
      final k = TimelineCanvasPainter._firstKeyAtOrAfter(item, local);
      if (k < item.keyframeTimes.length && item.keyframeTimes[k] == local) return Object.hash(item.id, local);
    }
    return 0;
  }

  /// The typed hit at canvas-local [local] (y < 0 is the ruler band; see timeline_hit.dart).
  TimelineHit hitTestTimeline(Offset local) => TimelineHitTester.hitTest(
        local,
        geometry: geometry,
        rulerHeight: _metrics.rulerHeight,
        selected: _selection.items,
        showAllKeyframes: _showAllKeyframes,
        playhead: _playhead?.value,
      );

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest.isFinite
      ? constraints.biggest
      : constraints.constrain(Size(constraints.maxWidth.isFinite ? constraints.maxWidth : 0, contentHeight));

  @override
  double computeMinIntrinsicHeight(double width) => contentHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => contentHeight;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewport.addListener(_onViewport);
    _thumbnails?.changes.addListener(_onContent);
    _waveforms?.changes.addListener(_onContent);
    _interaction?.addListener(markNeedsPaint);
    _playhead?.addListener(_onPlayhead);
  }

  @override
  void detach() {
    _viewport.removeListener(_onViewport);
    _thumbnails?.changes.removeListener(_onContent);
    _waveforms?.changes.removeListener(_onContent);
    _interaction?.removeListener(markNeedsPaint);
    _playhead?.removeListener(_onPlayhead);
    super.detach();
  }

  @override
  void dispose() {
    _ownParagraphs?.dispose();
    _semanticsNodes.clear();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final g = geometry;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.clipRect(Offset.zero & size);
    final window = Rect.fromLTWH(_viewport.scrollTimeSec * _viewport.pxPerSecond, _viewport.scrollY, size.width, size.height);
    TimelineCanvasPaintReport? report;
    _tiles.paint(canvas, window, (c, _) {
      report = TimelineCanvasPainter(style: _style, paragraphs: _paragraphs, metrics: _metrics).paint(
        c,
        size,
        geometry: g,
        selection: _selection,
        lifted: _interaction?.liftedItems ?? const {},
        showAllKeyframes: _showAllKeyframes,
        playhead: _playhead?.value,
        thumbnails: _thumbnails,
        waveforms: _waveforms,
        showThumbnails: _showThumbnails,
        showWaveforms: _showWaveforms,
        devicePixelRatio: _dpr,
      );
    });
    canvas.restore();
    _rememberDiamonds(report);
    assert(() {
      debugLastPaint = report;
      debugPaintCount++;
      return true;
    }());
  }

  void _rememberDiamonds(TimelineCanvasPaintReport? report) {
    _diamondItems.clear();
    if (report == null || report.diamonds == 0) {
      _filledKey = 0;
      return;
    }
    for (final id in report.items) {
      final item = _snapshot.item(id);
      if (item != null && item.hasKeyframes && (_showAllKeyframes || _selection.items.contains(id))) _diamondItems.add(item);
    }
    _filledKey = _filledKeyOf(_playhead?.value);
  }

  // ---- Semantics ---------------------------------------------------------------------------------

  /// The items whose semantics nodes are built: on-screen items of the visible lanes, with their
  /// on-screen rects (canvas-local).
  List<(TimelineSemanticsTarget, Rect)> visibleSemanticsTargets() {
    final out = <(TimelineSemanticsTarget, Rect)>[];
    if (!hasSize || !_viewport.hasLayout || _viewport.pxPerSecond <= 0) return out;
    final g = geometry;
    final bounds = Offset.zero & size;
    final start = _viewport.timeAt(0), end = _viewport.timeAt(size.width);
    final (first, last) = g.visibleLanes(size.height);
    for (var li = first; li < last; li++) {
      final lane = _snapshot.lanes[li];
      for (var i = lane.firstItemEndingAfter(start); i < lane.items.length; i++) {
        final item = lane.items[i];
        if (item.start >= end) break;
        final rect = g.itemRect(li, item).intersect(bounds);
        if (rect.isEmpty) continue;
        out.add((TimelineSemanticsTarget(lane: lane, item: item, selected: _selection.items.contains(item.id)), rect));
      }
    }
    return out;
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true
      ..textDirection = TextDirection.ltr
      ..label = TimelineCanvasStrings.timeline;
  }

  @override
  void assembleSemanticsNode(SemanticsNode node, SemanticsConfiguration config, Iterable<SemanticsNode> children) {
    final targets = visibleSemanticsTargets();
    final keep = <ItemId>{};
    final nodes = <SemanticsNode>[];
    var order = 0;
    for (final (target, rect) in targets) {
      final id = target.item.id;
      keep.add(id);
      final child = _semanticsNodes.putIfAbsent(id, () => SemanticsNode(key: ValueKey<String>('timeline-item-$id')));
      final cfg = SemanticsConfiguration()
        ..isSelected = target.selected
        ..isButton = true
        ..textDirection = TextDirection.ltr
        ..sortKey = OrdinalSortKey((order++).toDouble())
        ..label = TimelineCanvasStrings.itemLabel(target.lane, target.item);
      _semanticsDecorator?.call(target, cfg);
      child
        ..rect = rect
        ..updateWith(config: cfg);
      nodes.add(child);
    }
    _semanticsNodes.removeWhere((id, _) => !keep.contains(id));
    node.updateWith(config: config, childrenInInversePaintOrder: nodes);
  }

  @override
  void clearSemantics() {
    super.clearSemantics();
    _semanticsNodes.clear();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<TimelineSnapshot>('snapshot', _snapshot))
      ..add(DiagnosticsProperty<EditorSelection>('selection', _selection))
      ..add(FlagProperty('showAllKeyframes', value: _showAllKeyframes, ifTrue: 'all keyframes'));
  }
}
