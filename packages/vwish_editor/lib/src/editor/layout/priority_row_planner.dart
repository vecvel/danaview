// OWNER: UX-07
//
// PriorityRowPlanner (ux.md §6.7 rule 2): bars that hold a variable number of controls (transport,
// top bar extras, panel headers) show the mandatory items, then optional items by priority while
// they fit, and put the rest in a "more" menu. The same algorithm as the player's controls row
// (`_buildControlsRow` in vwish_controls_overlay.dart), extracted and made pure so every editor bar
// plans the same way and the planner is unit-tested over the width matrix.
//
// Widths are measured at the current text scale ([measureTextWidth]), never guessed.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// One control of a bar.
@immutable
final class PriorityRowItem<T> {
  /// Creates an item. Lower [priority] values are kept first; [mandatory] items always show.
  const PriorityRowItem(this.id, {required this.extent, this.priority = 0, this.mandatory = false});

  /// The control.
  final T id;

  /// Width it takes in the row, padding included.
  final double extent;

  /// Keep order among optional items (lower first).
  final int priority;

  /// Always shown (and never moved to "more").
  final bool mandatory;
}

/// The planned row.
@immutable
final class PriorityRowPlan<T> {
  /// Creates a plan.
  const PriorityRowPlan({required this.shown, required this.overflow, required this.showMore, required this.used});

  /// Items shown, in the order they were given.
  final List<T> shown;

  /// Items moved to "more", by priority.
  final List<T> overflow;

  /// Whether the "more" control shows.
  final bool showMore;

  /// Width taken by the shown items (and the "more" control).
  final double used;
}

/// The priority planner of ux.md §6.7.
abstract final class PriorityRowPlanner {
  /// Plans [items] into [width]. When everything fits (and [forceMore] is false) every item shows
  /// and there is no "more". Otherwise the mandatory items and the "more" control ([moreExtent])
  /// are placed first, then optional items by priority (ties keep their order) while they fit; an
  /// item that doesn't fit is skipped and smaller ones after it are still tried. "More" is
  /// dropped again when nothing overflows.
  static PriorityRowPlan<T> plan<T>({
    required List<PriorityRowItem<T>> items,
    required double width,
    required double moreExtent,
    bool forceMore = false,
  }) {
    final total = items.fold<double>(0, (sum, i) => sum + i.extent);
    if (!forceMore && total <= width + 1e-6) {
      return PriorityRowPlan(shown: [for (final i in items) i.id], overflow: const [], showMore: false, used: total);
    }
    final keep = <int>{};
    var used = moreExtent;
    for (var i = 0; i < items.length; i++) {
      if (items[i].mandatory) {
        keep.add(i);
        used += items[i].extent;
      }
    }
    final optional = [
      for (var i = 0; i < items.length; i++)
        if (!items[i].mandatory) i,
    ]..sort((a, b) {
        final byPriority = items[a].priority.compareTo(items[b].priority);
        return byPriority != 0 ? byPriority : a.compareTo(b);
      });
    final overflow = <T>[];
    for (final i in optional) {
      if (used + items[i].extent <= width + 1e-6) {
        keep.add(i);
        used += items[i].extent;
      } else {
        overflow.add(items[i].id);
      }
    }
    final showMore = forceMore || overflow.isNotEmpty;
    if (!showMore) used -= moreExtent;
    return PriorityRowPlan(
      shown: [
        for (var i = 0; i < items.length; i++)
          if (keep.contains(i)) items[i].id,
      ],
      overflow: List.unmodifiable(overflow),
      showMore: showMore,
      used: math.max(0, used),
    );
  }
}

/// Width of [text] in [style] under [textScaler] (one line), rounded up to whole pixels; the same
/// measurement the player uses for its time label.
double measureTextWidth(String text, TextStyle style,
    {TextScaler textScaler = TextScaler.noScaling, TextDirection textDirection = TextDirection.ltr}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width.ceilToDouble();
}
