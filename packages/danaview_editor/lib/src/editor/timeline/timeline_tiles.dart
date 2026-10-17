// OWNER: UX-43
//
// Placeholder (D-33) created by UX-01. UX-43 replaces this file:
// the timeline picture-tile cache, built only if QA-04 shows a timeline budget miss (ARCH §17.4,
// §18.2). Until then it is a disabled pass-through: `RenderTimelineCanvas` (UX-10) always paints
// through `TimelineTiles.paint`, which calls the direct painter, so enabling tiles later needs no
// edit of the canvas.

import 'dart:ui' show Canvas, Rect;

/// Paints the timeline content of [window] (timeline coordinates) onto [canvas].
///
/// See ARCH §17.4.
typedef TimelinePainter = void Function(Canvas canvas, Rect window);

/// Picture-tile cache in front of the timeline painter (UX-43). This placeholder never caches.
///
/// See ARCH §17.4, BUILD_PLAN UX-43.
final class TimelineTiles {
  /// The disabled pass-through.
  const TimelineTiles.disabled();

  /// Whether tiles are cached (always false until UX-43 lands).
  bool get enabled => false;

  /// Paints [window] through the cache; the pass-through calls [paintDirect] once.
  void paint(Canvas canvas, Rect window, TimelinePainter paintDirect) => paintDirect(canvas, window);

  /// Drops cached tiles (edits, zoom, thumbnail or waveform arrival). No-op here.
  void invalidate() {}

  /// Releases cached pictures. No-op here.
  void dispose() {}
}
