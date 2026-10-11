// OWNER: UX-19
//
// TextOverlayPainter (D-05, ARCH §13.1): paints the text items and subtitle cues active at the
// playhead above the preview texture. The preview plan has no text layers; this painter is the
// preview's text renderer, and it lays text out with the same API-04 `TextLayoutEngine` that
// rasterizes the export sprites, so preview and export agree to the pixel.
//
// Per active item (visible text and subtitle lanes, bottom → top as in the composite; burn-in-off
// subtitle tracks are previewed too, hidden lanes are skipped):
//
// * text: `textLayoutSpecOf(item, canvas)` laid out by the engine; the block is centred at the
//   keyframe-evaluated position plus the text animation's offset, scaled by `scale × anim.scale`,
//   rotated clockwise by the evaluated rotation, painted with `opacity × anim.opacity` and the
//   typewriter's `revealCount` (`TextBlockLayout.paint(revealCount:)`, the same strips as the
//   sprite's glyph map). This is exactly how the export places a sprite layer (ARCH §10.3).
// * cue: `cueLayoutSpecOf(cue, track, canvas)` centred at core `cueCenter` (bottom/top margin or
//   custom Y).
//
// The scene is resolved from canvas px and painted through `CanvasGeometry` (scale + letterbox
// offset), clipped to the canvas rect. It repaints only when the playhead's frame changes (the
// painter listens to the frame-quantized `PlayheadController`) or the project changes; layouts are
// memoized per item instance, so a frame costs a lookup and a few `drawParagraph`s.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show TextBlockLayout, TextLayoutEngine;

import '../../debug/rebuild_counters.dart';
import 'canvas_geometry.dart';

/// One text block to paint at one time (canvas px).
@immutable
final class TextOverlayEntry {
  /// Creates an entry.
  const TextOverlayEntry({
    required this.item,
    required this.layout,
    required this.center,
    this.scale = 1,
    this.rotationDeg = 0,
    this.opacity = 1,
    this.revealCount,
    this.cue = false,
  });

  /// The item (text item or cue).
  final ItemId item;

  /// The laid-out block.
  final TextBlockLayout layout;

  /// Block centre in canvas px.
  final Offset2 center;

  /// Uniform scale (item scale × animation scale).
  final double scale;

  /// Clockwise rotation in degrees.
  final double rotationDeg;

  /// Opacity (item opacity × animation opacity).
  final double opacity;

  /// Typewriter: clusters shown, or null for all.
  final int? revealCount;

  /// Whether this is a subtitle cue.
  final bool cue;

  /// Paints the block on [canvas] in canvas-px coordinates.
  void paint(ui.Canvas canvas) {
    if (opacity <= 0 || scale == 0) return;
    final b = layout.blockSize;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (rotationDeg != 0) canvas.rotate(rotationDeg * math.pi / 180);
    if (scale != 1) canvas.scale(scale);
    layout.paint(canvas, ui.Offset(-b.width / 2, -b.height / 2), revealCount: revealCount, opacity: opacity);
    canvas.restore();
  }

  @override
  String toString() => 'TextOverlayEntry($item at $center ×$scale $rotationDeg° α$opacity reveal $revealCount)';
}

/// Resolves the text entries of a project at a time, memoizing layouts per item instance.
class TextOverlayScene {
  /// Creates a scene over [engine].
  TextOverlayScene(this.engine);

  /// The layout engine (shared with the handles and the export sprites).
  final TextLayoutEngine engine;

  final Expando<(CanvasSpec, TextBlockLayout)> _text = Expando<(CanvasSpec, TextBlockLayout)>('TextOverlayScene.text');
  final Expando<(CanvasSpec, SubtitleTrackData, TextBlockLayout)> _cues =
      Expando<(CanvasSpec, SubtitleTrackData, TextBlockLayout)>('TextOverlayScene.cue');

  /// The block of [item] on [canvas].
  TextBlockLayout layoutOfText(TextItem item, CanvasSpec canvas) {
    final cached = _text[item];
    if (cached != null && cached.$1 == canvas) return cached.$2;
    final l = engine.layoutSpec(textLayoutSpecOf(item, canvas));
    _text[item] = (canvas, l);
    return l;
  }

  /// The block of [cue] of a track styled by [data] on [canvas].
  TextBlockLayout layoutOfCue(SubtitleCue cue, SubtitleTrackData data, CanvasSpec canvas) {
    final cached = _cues[cue];
    if (cached != null && cached.$1 == canvas && identical(cached.$2, data)) return cached.$3;
    final l = engine.layoutSpec(cueLayoutSpecOf(cue, data, canvas));
    _cues[cue] = (canvas, data, l);
    return l;
  }

  /// The entries active at [t], bottom → top.
  List<TextOverlayEntry> entriesAt(EditProject project, TimeUs t) {
    final out = <TextOverlayEntry>[];
    final settings = project.settings;
    final canvas = settings.canvas;
    final size = canvas.sizePx;
    for (final track in project.tracks) {
      if (track.hidden) continue;
      if (track.kind != TrackKind.text && track.kind != TrackKind.subtitle) continue;
      final item = activeItemOf(track, t);
      if (item == null) continue;
      switch (item) {
        case TextItem():
          final layout = layoutOfText(item, canvas);
          final local = t - item.start;
          final anim = evaluateTextAnimation(item, t, canvas);
          out.add(TextOverlayEntry(
            item: item.id,
            layout: layout,
            center: positionToCanvas(evaluate(item, PropertyKeys.position, local), size) + anim.offset,
            scale: evaluate(item, PropertyKeys.scale, local) * anim.scale,
            rotationDeg: evaluate(item, PropertyKeys.rotation, local),
            opacity: (evaluate(item, PropertyKeys.opacity, local) * anim.opacity).clamp(0.0, 1.0),
            revealCount: anim.revealCount,
          ));
        case SubtitleCue():
          final data = track.subtitle;
          if (data == null) continue;
          final layout = layoutOfCue(item, data, canvas);
          final b = layout.blockSize;
          out.add(TextOverlayEntry(
            item: item.id,
            layout: layout,
            center: cueCenter(Size2(b.width, b.height), data.position, size),
            cue: true,
          ));
        case MediaClip():
          break;
      }
    }
    return out;
  }

  /// Drops every memoized layout (memory pressure) and the engine's cache.
  void trim() => engine.trim();
}

/// The item of [track] active at [t] (`start ≤ t < end`; items are sorted and disjoint).
TimelineItem? activeItemOf(Track track, TimeUs t) {
  final items = track.items;
  var lo = 0;
  var hi = items.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (items[mid].start <= t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo == 0) return null;
  final item = items[lo - 1];
  return t < item.end ? item : null;
}

/// Paints text layouts at the playhead (D-05).
class TextOverlayPainter extends CustomPainter {
  /// Creates the painter of [project] at [playhead] through [geometry]; it repaints when the
  /// playhead's frame changes.
  TextOverlayPainter({
    required this.scene,
    required this.project,
    required this.playhead,
    required this.geometry,
  }) : super(repaint: playhead);

  /// The scene (engine and memoized layouts).
  final TextOverlayScene scene;

  /// The project shown (the working copy while a gesture runs), or null.
  final EditProject? project;

  /// The frame-quantized playhead.
  final ValueListenable<TimeUs> playhead;

  /// Letterbox mapping.
  final CanvasGeometry geometry;

  /// Counter name of one overlay paint (`EditorRebuildCounters`).
  static const String paintCounter = 'TextOverlayPaint';

  @override
  void paint(Canvas canvas, Size size) {
    EditorRebuildCounters.count(paintCounter);
    final p = project;
    if (p == null || geometry.isEmpty) return;
    final entries = scene.entriesAt(p, playhead.value);
    if (entries.isEmpty) return;
    paintEntries(canvas, geometry, entries);
  }

  /// Paints [entries] (canvas px) into the view of [geometry], clipped to the canvas rect.
  static void paintEntries(Canvas canvas, CanvasGeometry geometry, List<TextOverlayEntry> entries) {
    canvas.save();
    canvas.clipRect(geometry.viewRect);
    canvas.translate(geometry.viewRect.left, geometry.viewRect.top);
    canvas.scale(geometry.scale);
    for (final e in entries) {
      e.paint(canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TextOverlayPainter oldDelegate) =>
      !identical(oldDelegate.project, project) ||
      oldDelegate.geometry != geometry ||
      !identical(oldDelegate.scene, scene) ||
      !identical(oldDelegate.playhead, playhead);
}
