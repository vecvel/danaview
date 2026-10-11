// OWNER: CORE-31
//
// Export sprite requests (ARCH §10.3, §14.1 step 4, D-05, D-06): what the sprite pre-pass
// (API-04 `SpritePrepass`) must rasterize before an export compiles.
//
// One request per text item on a visible text lane and per cue of a visible subtitle lane whose
// burn-in is on (the export settings' per-track override, else `SubtitleTrackData.burnIn`). Each
// request carries the item's `TextLayoutSpec` JSON (project-canvas px, CORE-07) and its **raster
// scale** `exportScale × maxAnimatedScale(item)`:
//
// * `exportScale` = plan (output) px per project px (`CanvasMapping.fit(...).scale`);
// * `maxAnimatedScale` = the largest `xf.s` the item reaches: its static scale or the largest
//   in-range scale keyframe (up to 8×), times the text animation's largest scale (≤ 1); cues 1;
// * reduced so the sprite's longer side stays within `min(maxTextureSize, 2 × output long side)`.
//   The sprite size is the laid-out block ([TextMetricsProvider], i.e. API-04's
//   `TextLayoutEngine`) or, without one, [estimateTextBlockSize] (a conservative estimate). The
//   rasterizer may reduce the scale further when the real raster (stroke, shadow) is larger and
//   reports the scale it used in `SpriteFile.sscale`.
//
// Units (normative for API-04 and `compileExport`): `SpriteRequest.scale` and `SpriteFile.sscale`
// are sprite px per **layout px** (project-canvas px of the spec). A plan's sprite asset carries
// `sscale` per **plan canvas** px, i.e. `SpriteFile.sscale / exportScale`, and layers get
// `base = (sw, sh) / plan sscale`. Sprites are rasterized with the laid-out block centred
// (symmetric padding), so the sprite centre is the block centre.
//
// The content key (the `.vsprite` file name) is `sha1` of the canonical JSON of
// `{spec, scale, canvas: [w, h], fontsVersion, reveal}`; equal content shares one file.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../eval/geometry.dart';
import '../eval/text_animation_eval.dart';
import '../eval/text_layout_spec.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/text_style.dart';
import '../model/track.dart';
import 'sprite_request.dart';

/// Version of the bundled content fonts; part of every sprite key (bump when fonts change).
const int contentFontsVersion = 1;

/// Default `capabilities.maxTextureSize` when the caller has none (a common low-end GLES limit).
const int defaultMaxTextureSize = 4096;

/// Average advance of one grapheme as a fraction of the font size, used by
/// [estimateTextBlockSize] (generous for Latin text in Figtree; CJK is about 1.0).
const double estimatedAdvanceEm = 0.62;

/// The model channel of transform scale keyframes.
const String _scaleChannel = 'transform.scale';

/// The largest `xf.s` [item] reaches over its range: the largest in-range scale keyframe (or the
/// static scale without one) times the largest text-animation scale (≤ 1, so 1).
double maxAnimatedScale(TextItem item) {
  var m = item.transform.scale;
  final track = item.keyframes[_scaleChannel];
  if (track != null) {
    var any = false;
    var best = 0.0;
    for (final k in track.keys) {
      if (k.t < 0 || k.t >= item.duration) continue;
      if (!any || k.v > best) best = k.v;
      any = true;
    }
    if (any) m = best;
  }
  // Text animations scale from 0.6 up to 1 (never above), so they never raise the maximum.
  return m > 0 ? m : 0.01;
}

/// A conservative size of [spec] laid out, in layout px, for the raster-scale clamp when no
/// [TextMetricsProvider] is available: each explicit line wraps at `maxWidthPx` with
/// [estimatedAdvanceEm] per grapheme; lines × `lineHeight × fontSizePx` tall (at most
/// `maxLines`); plus the box padding, the outline and the shadow extent on every side.
Size2 estimateTextBlockSize(TextLayoutSpec spec) {
  final font = spec.fontSizePx;
  final advance = font * estimatedAdvanceEm + spec.letterSpacingPx;
  final wrap = spec.maxWidthPx > 0 ? spec.maxWidthPx : double.infinity;
  var width = 0.0;
  var lines = 0;
  for (final line in spec.text.split('\n')) {
    final w = textGraphemeCount(line) * advance;
    if (w <= wrap) {
      lines += 1;
      if (w > width) width = w;
    } else {
      lines += (w / wrap).ceil();
      width = wrap;
    }
  }
  final maxLines = spec.maxLines;
  if (maxLines != null && lines > maxLines) lines = maxLines;
  if (lines < 1) lines = 1;
  var pad = 0.0;
  final box = spec.box;
  if (box != null) pad += box.paddingPx;
  final stroke = spec.stroke;
  if (stroke != null) pad += stroke.widthPx;
  final shadow = spec.shadow;
  if (shadow != null) {
    final dx = shadow.offset.dx.abs();
    final dy = shadow.offset.dy.abs();
    pad += (dx > dy ? dx : dy) + shadow.blurPx;
  }
  final height = lines * spec.lineHeight * font;
  return Size2(width + 2 * pad, height + 2 * pad);
}

/// The raster scale of a sprite of [block] layout px wanted at [wanted] sprite px per layout px:
/// reduced so the longer sprite side stays within `min(maxTextureSize, 2 × outputLongSide)`.
double clampRasterScale(double wanted, Size2 block, {required int maxTextureSize, required double outputLongSide}) {
  final limit = maxTextureSize < 2 * outputLongSide ? maxTextureSize.toDouble() : 2 * outputLongSide;
  final side = block.longSide;
  if (!(side > 0) || side * wanted <= limit) return wanted;
  return limit / side;
}

/// The content key of a sprite (file header).
String spriteKeyOf(TextLayoutSpec spec, double scale, int canvasWidth, int canvasHeight, int fontsVersion, bool reveal) {
  final json = jsonEncode({
    'spec': spec.toJson(),
    'scale': scale,
    'canvas': [canvasWidth, canvasHeight],
    'fontsVersion': fontsVersion,
    'reveal': reveal,
  });
  return sha1.convert(utf8.encode(json)).toString();
}

/// Whether [item] needs a glyph-order map (a typewriter in-animation that takes time).
bool needsReveal(TextItem item) =>
    item.animation.inKind == TextAnimKind.typewriter && textAnimationSpans(item).inDuration > 0;

/// Whether the cues of subtitle [track] are burned into an export, given the export settings'
/// per-track [burnIn] overrides (default: the track's own `burnIn`). Hidden lanes never burn.
bool burnsIn(Track track, Map<TrackId, bool> burnIn) {
  if (track.kind != TrackKind.subtitle || track.hidden) return false;
  return burnIn[track.id] ?? track.subtitle?.burnIn ?? true;
}

/// The sprite requests of an export of [project] onto an output canvas of [canvas] px with
/// [exportScale] plan px per project px (file header), in track then item order. [burnIn]
/// overrides the subtitle tracks' burn-in defaults; [metrics] measures laid-out text (API-04),
/// else [estimateTextBlockSize] is used.
List<SpriteRequest> collectSpriteRequests(
  EditProject project,
  Size2 canvas,
  double exportScale, {
  int maxTextureSize = defaultMaxTextureSize,
  Map<TrackId, bool> burnIn = const {},
  TextMetricsProvider? metrics,
  int fontsVersion = contentFontsVersion,
}) {
  final out = <SpriteRequest>[];
  final cw = canvas.width.round();
  final ch = canvas.height.round();
  final longSide = canvas.longSide;
  final spec0 = project.settings.canvas;
  SpriteRequest request(String id, SpriteSource source, TextLayoutSpec spec, double animScale, bool reveal) {
    final block = metrics?.measure(spec) ?? estimateTextBlockSize(spec);
    final scale = clampRasterScale(exportScale * animScale, block, maxTextureSize: maxTextureSize, outputLongSide: longSide);
    return SpriteRequest(
      key: spriteKeyOf(spec, scale, cw, ch, fontsVersion, reveal),
      itemId: id,
      source: source,
      layoutSpec: spec.toJson(),
      scale: scale,
      canvasWidth: cw,
      canvasHeight: ch,
      fontsVersion: fontsVersion,
      reveal: reveal,
    );
  }

  for (final track in project.tracks) {
    if (track.hidden) continue;
    if (track.kind == TrackKind.text) {
      for (final item in track.items) {
        if (item is! TextItem) continue;
        out.add(request(item.id, SpriteSource.text, textLayoutSpecOf(item, spec0), maxAnimatedScale(item), needsReveal(item)));
      }
    } else if (track.kind == TrackKind.subtitle && burnsIn(track, burnIn)) {
      final data = track.subtitle;
      if (data == null) continue;
      for (final item in track.items) {
        if (item is! SubtitleCue) continue;
        out.add(request(item.id, SpriteSource.cue, cueLayoutSpecOf(item, data, spec0), 1, false));
      }
    }
  }
  return out;
}

/// `exportScale` of a project canvas [project] shown on an output canvas [output] (letterbox fit:
/// `min(W/w, H/h)`).
double exportScaleOf(CanvasSpec project, Size2 output) {
  final p = project.sizePx;
  final sx = output.width / p.width;
  final sy = output.height / p.height;
  return sx < sy ? sx : sy;
}
