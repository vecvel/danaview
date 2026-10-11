// OWNER: API-04
//
// The one text layout implementation (ARCH §10.3, §13.1, D-05): the preview overlay (UX-19),
// manipulation handles (via [TextMetricsProvider]) and export sprites (TextSpriteRasterizer) all
// lay out a core `TextLayoutSpec` here with `ui.Paragraph`, so they agree to the pixel.
//
// Geometry of a laid-out block (layout px = project-canvas px of the spec):
// * the **text** is laid out at `maxWidthPx`, then re-laid out at its longest line (rounded up)
//   so alignment is relative to the tight text width (as `TextPainter` with
//   `TextWidthBasis.longestLine`);
// * the **block** is the text plus the background box padding on every side (no padding without
//   a box). [TextLayoutEngine.measure] returns the block size; the block centre is the item's
//   position (and a cue's `cueCenter`);
// * the **raster extent** adds a symmetric margin for the outline, the shadow (offset + 3σ of its
//   blur, cast from the outlined text) and glyph overhang (0.1 em: italics, stacked marks), so a
//   sprite centred on the block holds every painted pixel.
//
// Painting order: box (RRect, colour × opacity) → text shadow → outline (stroke paragraph,
// `2 × widthPx` round-joined stroke, so the outline extends `widthPx` outside the glyphs) → fill.
//
// Fonts: `fontFamily` is a content-font id resolved by the injected [FontResolver] (UX-30's
// FontCatalog; unknown ids → Figtree). [TextLayoutEngine.fallbackFamilies] adds explicit
// fallbacks before the system one (tests load a host Unicode font to stand in for it).
//
// V-A11 (Figtree script coverage and fallback), measured on the bundled Figtree-Regular.ttf cmap
// (391 code points): Basic Latin 95/95, Latin-1 95/96, Latin Extended-A 109/128, Latin
// Extended-B 7/208, combining marks 15/112, Latin Extended Additional (Vietnamese) 9/256;
// **none** of Greek, Cyrillic, Hebrew, Arabic, Devanagari, Thai, CJK, kana, Hangul or emoji.
// Every missing character is drawn by Flutter's per-character system font fallback (iOS
// CoreText cascade; Android's system font chain incl. Noto CJK and Noto Color Emoji), in the
// preview overlay and in export sprites alike, because both are laid out and painted by this
// engine on the same device: layout parity holds; only the fallback typeface differs between
// devices, as in any Flutter text. Burned-in captions in CJK/Arabic/Devanagari therefore render
// correctly (tests: text_sprite_rasterizer_test "scripts and fallback"); stacked Vietnamese
// diacritics mix Figtree base letters with fallback marks, which UX-30 can fix by preferring
// Inter (full Vietnamese) for those languages.
//
// Typewriter reveal regions: each grapheme cluster (`package:characters`) owns a set of strips
// that tile the plane: per line, the cluster's boxes extended vertically to the line band
// (first line up to −∞, last line down to +∞, midpoint between lines) and horizontally to the
// midpoint between neighbouring boxes (the line's first and last box out to ∓∞). A pixel belongs
// to the strip containing its centre, so the box, outline and shadow reveal together with their
// nearest glyph and the box "grows" with the typed text. The sprite's u16 glyph map and the
// preview's [TextBlockLayout.revealClip] use the same strips.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart' show TextAlignH;

/// Maps a content-font id to a font family; unknown ids resolve to Figtree (ARCH §10.3, D-30).
typedef FontResolver = String Function(String fontId);

/// Family name of the default content font when no catalog is injected.
const String figtreeFamily = 'Figtree';

/// The resolver used without a catalog: every id → [figtreeFamily].
String figtreeOnlyResolver(String fontId) => figtreeFamily;

/// Glyph overhang allowance of the raster extent, in em.
const double glyphOverhangEm = 0.1;

/// One grapheme cluster of a laid-out block (ARCH §10.3, D-05).
@immutable
final class GlyphBox {
  /// Creates a glyph box.
  const GlyphBox({required this.index, required this.start, required this.end, required this.boxes, required this.lines});

  /// Cluster index in logical (typing) order: the typewriter reveals clusters `< n`.
  final int index;

  /// UTF-16 start offset in the plain text.
  final int start;

  /// UTF-16 end offset (exclusive).
  final int end;

  /// `ui.Paragraph.getBoxesForRange(start, end)` in **block** coordinates (offset by the box
  /// padding); empty for clusters without extent (line breaks).
  final List<ui.TextBox> boxes;

  /// Line index of each box.
  final List<int> lines;

  /// Union of [boxes] (block coordinates), or null without boxes.
  ui.Rect? get bounds {
    if (boxes.isEmpty) return null;
    var r = boxes.first.toRect();
    for (final b in boxes.skip(1)) {
      r = r.expandToInclude(b.toRect());
    }
    return r;
  }
}

/// A reveal strip: pixels whose centre lies in [rect] belong to glyph [glyph] (ARCH §10.3, D-06).
@immutable
final class RevealStrip {
  /// Creates a strip.
  const RevealStrip(this.glyph, this.rect);

  /// Glyph (cluster) index.
  final int glyph;

  /// Region in block coordinates; may extend to ±infinity.
  final ui.Rect rect;
}

/// A laid-out text block (file header; ARCH §10.3, §13.1, D-05).
final class TextBlockLayout {
  TextBlockLayout._({
    required this.spec,
    required this.paragraph,
    required this.strokeParagraph,
    required this.textSize,
    required this.padding,
    required this.margin,
    required this.direction,
    required this.lines,
  });

  /// What was laid out.
  final TextLayoutSpec spec;

  /// The fill paragraph (carries the shadow when there is no outline).
  final ui.Paragraph paragraph;

  /// The outline paragraph (same layout; carries the shadow), or null without an outline.
  final ui.Paragraph? strokeParagraph;

  /// Tight text size (layout px).
  final ui.Size textSize;

  /// Background box padding (0 without a box).
  final double padding;

  /// Symmetric raster margin around the block (outline, shadow, overhang).
  final double margin;

  /// Resolved paragraph direction.
  final ui.TextDirection direction;

  /// Grapheme clusters in logical order (computed on first use: export sprites without a reveal
  /// never need them).
  late final List<GlyphBox> glyphs = TextLayoutEngine._glyphsOf(spec.text, paragraph, padding, lines);

  /// Line metrics of [paragraph] (paragraph coordinates; add [textOffset] for block coordinates).
  final List<ui.LineMetrics> lines;

  /// Reveal strips tiling the plane (block coordinates; computed on first use).
  late final List<RevealStrip> revealStrips = TextLayoutEngine._stripsOf(glyphs, lines, padding);

  /// Block size: text plus box padding (what [TextLayoutEngine.measure] returns).
  ui.Size get blockSize => ui.Size(textSize.width + 2 * padding, textSize.height + 2 * padding);

  /// Offset of the paragraph inside the block.
  ui.Offset get textOffset => ui.Offset(padding, padding);

  /// Raster extent: the block plus [margin] on every side.
  ui.Size get rasterSize => ui.Size(blockSize.width + 2 * margin, blockSize.height + 2 * margin);

  /// Number of grapheme clusters (the typewriter's `n`).
  int get glyphCount => _glyphCount ??= textGraphemeCount(spec.text);
  int? _glyphCount;

  /// Paints the block with its top-left corner at [origin] (layout px in [canvas]'s current
  /// transform). With [revealCount], only the strips of clusters `< revealCount` are painted
  /// (typewriter; the same rule as the sprite's glyph map). [opacity] multiplies everything.
  void paint(ui.Canvas canvas, ui.Offset origin, {int? revealCount, double opacity = 1}) {
    if (opacity <= 0) return;
    if (revealCount != null && revealCount <= 0) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    if (revealCount != null && revealCount < glyphCount) canvas.clipPath(revealClip(revealCount));
    final layer = opacity < 1;
    if (layer) {
      final r = ui.Offset(-margin, -margin) & rasterSize;
      canvas.saveLayer(r, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)));
    }
    final box = spec.box;
    if (box != null) {
      final paint = ui.Paint()..color = _withOpacity(box.color, box.opacity);
      final s = blockSize;
      canvas.drawRRect(
          ui.RRect.fromRectAndRadius(ui.Offset.zero & s, ui.Radius.circular(box.cornerRadiusPx.clamp(0.0, s.shortestSide / 2))),
          paint);
    }
    final stroke = strokeParagraph;
    if (stroke != null) canvas.drawParagraph(stroke, textOffset);
    canvas.drawParagraph(paragraph, textOffset);
    if (layer) canvas.restore();
    canvas.restore();
  }

  /// The clip of the first [count] clusters' reveal strips, bounded by the raster extent (block
  /// coordinates).
  ui.Path revealClip(int count) {
    final bounds = ui.Offset(-margin - 1, -margin - 1) & ui.Size(rasterSize.width + 2, rasterSize.height + 2);
    final path = ui.Path();
    for (final s in revealStrips) {
      if (s.glyph >= count) continue;
      final r = s.rect.intersect(bounds);
      if (r.width > 0 && r.height > 0) path.addRect(r);
    }
    return path;
  }

  /// The glyph owning block point [p] (the strip containing it), or null outside every strip
  /// (only for text without visible clusters).
  int? glyphAt(ui.Offset p) {
    int? best;
    for (final s in revealStrips) {
      if (_containsHalfOpen(s.rect, p) && (best == null || s.glyph < best)) best = s.glyph;
    }
    return best;
  }
}

bool _containsHalfOpen(ui.Rect r, ui.Offset p) => p.dx >= r.left && p.dx < r.right && p.dy >= r.top && p.dy < r.bottom;

ui.Color _withOpacity(int argb, double opacity) {
  final a = ((argb >> 24) & 0xFF) * opacity.clamp(0.0, 1.0);
  return ui.Color((a.round() << 24) | (argb & 0xFFFFFF));
}

/// Lays out `TextLayoutSpec`s with `ui.Paragraph` (file header; ARCH §10.3, API-04). Also the
/// [TextMetricsProvider] of handles, hit tests and the raster-scale clamp.
class TextLayoutEngine implements TextMetricsProvider {
  /// Creates the engine. [fontResolver] resolves content-font ids (default: everything is
  /// Figtree); [fallbackFamilies] are tried before the system fallback; [cacheSize] bounds the
  /// layout cache (ARCH §18.3: 512 paragraphs).
  TextLayoutEngine({FontResolver? fontResolver, this.fallbackFamilies = const [], this.cacheSize = 512})
      : fontResolver = fontResolver ?? figtreeOnlyResolver;

  /// Font id → family.
  final FontResolver fontResolver;

  /// Families tried before the system fallback.
  final List<String> fallbackFamilies;

  /// Maximum number of cached layouts.
  final int cacheSize;

  final LinkedHashMap<TextLayoutSpec, TextBlockLayout> _cache = LinkedHashMap<TextLayoutSpec, TextBlockLayout>();

  /// Layouts computed (cache misses).
  int layouts = 0;

  /// Drops cached layouts (memory pressure).
  void trim() => _cache.clear();

  /// Lays out the `TextLayoutSpec` JSON [spec] (`SpriteRequest.layoutSpec`).
  TextBlockLayout layout(Map<String, Object?> spec) => layoutSpec(textLayoutSpecFromJson(spec));

  /// Lays out [spec] (cached by value).
  TextBlockLayout layoutSpec(TextLayoutSpec spec) {
    final hit = _cache.remove(spec);
    if (hit != null) {
      _cache[spec] = hit;
      return hit;
    }
    final l = _layout(spec);
    layouts++;
    _cache[spec] = l;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return l;
  }

  @override
  Size2 measure(TextLayoutSpec spec) {
    final s = layoutSpec(spec).blockSize;
    return Size2(s.width, s.height);
  }

  /// The paragraph style and text styles of [spec] (exposed so tests can build the reference
  /// paragraph independently).
  ui.ParagraphStyle paragraphStyleOf(TextLayoutSpec spec) => ui.ParagraphStyle(
        textAlign: switch (spec.align) {
          TextAlignH.left => ui.TextAlign.left,
          TextAlignH.center => ui.TextAlign.center,
          TextAlignH.right => ui.TextAlign.right,
        },
        textDirection: directionOf(spec),
        maxLines: spec.maxLines,
        ellipsis: spec.maxLines == null ? null : '…',
      );

  /// The resolved paragraph direction of [spec].
  static ui.TextDirection directionOf(TextLayoutSpec spec) {
    final d = spec.direction == TextDirectionHint.auto ? spec.resolvedDirection : spec.direction;
    return d == TextDirectionHint.rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr;
  }

  /// The text style of a run of [spec] with [bold]/[italic] added to the base style; [foreground]
  /// replaces the colour (outline pass); [shadow] adds the spec's shadow.
  ui.TextStyle textStyleOf(TextLayoutSpec spec, {bool bold = false, bool italic = false, ui.Paint? foreground, bool shadow = false}) {
    final sh = spec.shadow;
    return ui.TextStyle(
      color: foreground == null ? ui.Color(spec.color) : null,
      foreground: foreground,
      fontFamily: fontResolver(spec.fontFamily),
      fontFamilyFallback: fallbackFamilies.isEmpty ? null : fallbackFamilies,
      fontSize: spec.fontSizePx,
      fontWeight: spec.bold || bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      fontStyle: spec.italic || italic ? ui.FontStyle.italic : ui.FontStyle.normal,
      letterSpacing: spec.letterSpacingPx,
      height: spec.lineHeight,
      shadows: shadow && sh != null
          ? [ui.Shadow(color: _withOpacity(sh.color, sh.opacity), offset: ui.Offset(sh.offset.dx, sh.offset.dy), blurRadius: sh.blurPx)]
          : null,
    );
  }

  /// Builds and lays out a paragraph of [spec] at [width].
  ui.Paragraph buildParagraph(TextLayoutSpec spec, double width, {ui.Paint? foreground, bool shadow = false}) {
    final b = ui.ParagraphBuilder(paragraphStyleOf(spec))..pushStyle(textStyleOf(spec, foreground: foreground, shadow: shadow));
    for (final r in spec.runs) {
      if (r.bold || r.italic) {
        b
          ..pushStyle(textStyleOf(spec, bold: r.bold, italic: r.italic, foreground: foreground, shadow: shadow))
          ..addText(r.text)
          ..pop();
      } else {
        b.addText(r.text);
      }
    }
    return b.build()..layout(ui.ParagraphConstraints(width: width));
  }

  /// The tight layout width of [spec]: the longest line at `maxWidthPx`, rounded up (capped at
  /// `maxWidthPx`).
  double tightWidthOf(TextLayoutSpec spec) {
    final p = buildParagraph(spec, _wrapOf(spec));
    final w = _tight(spec, p);
    p.dispose();
    return w;
  }

  static double _wrapOf(TextLayoutSpec spec) => spec.maxWidthPx > 0 ? spec.maxWidthPx : double.infinity;

  static double _tight(TextLayoutSpec spec, ui.Paragraph p) {
    final wrap = _wrapOf(spec);
    final w = math.max(0.0, p.longestLine.ceilToDouble());
    return wrap.isFinite ? math.min(w, wrap) : w;
  }

  TextBlockLayout _layout(TextLayoutSpec spec) {
    final hasShadow = spec.shadow != null;
    final stroke = spec.stroke;
    final strokeOn = stroke != null && stroke.widthPx > 0;
    // Lay out at the wrap width, then re-lay out the same paragraph at its tight width.
    final fill = buildParagraph(spec, _wrapOf(spec), shadow: hasShadow && !strokeOn);
    final width = _tight(spec, fill);
    if (fill.width != width) fill.layout(ui.ParagraphConstraints(width: width));
    ui.Paragraph? outline;
    if (strokeOn) {
      outline = buildParagraph(
        spec,
        width,
        shadow: hasShadow,
        foreground: ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * stroke.widthPx
          ..strokeJoin = ui.StrokeJoin.round
          ..strokeCap = ui.StrokeCap.round
          ..color = ui.Color(stroke.color),
      );
    }
    final padding = spec.box?.paddingPx ?? 0;
    final textSize = ui.Size(width, fill.height);
    final lines = fill.computeLineMetrics();
    final margin = rasterMarginOf(spec);
    return TextBlockLayout._(
      spec: spec,
      paragraph: fill,
      strokeParagraph: outline,
      textSize: textSize,
      padding: padding,
      margin: margin,
      direction: directionOf(spec),
      lines: lines,
    );
  }

  /// Symmetric raster margin of [spec] (file header).
  static double rasterMarginOf(TextLayoutSpec spec) {
    final s = spec.stroke?.widthPx ?? 0;
    var shadow = 0.0;
    final sh = spec.shadow;
    if (sh != null) {
      final sigma = sh.blurPx > 0 ? sh.blurPx * 0.57735 + 0.5 : 0.0;
      shadow = math.max(sh.offset.dx.abs(), sh.offset.dy.abs()) + 3 * sigma;
    }
    return s + shadow + glyphOverhangEm * spec.fontSizePx + 1;
  }

  static List<GlyphBox> _glyphsOf(String text, ui.Paragraph p, double padding, List<ui.LineMetrics> lines) {
    final out = <GlyphBox>[];
    var start = 0;
    var index = 0;
    for (final c in text.characters) {
      final end = start + c.length;
      final raw = p.getBoxesForRange(start, end);
      final boxes = <ui.TextBox>[];
      final lineOf = <int>[];
      for (final b in raw) {
        if (b.right - b.left <= 0 && b.bottom - b.top <= 0) continue;
        boxes.add(ui.TextBox.fromLTRBD(b.left + padding, b.top + padding, b.right + padding, b.bottom + padding, b.direction));
        lineOf.add(_lineOfBox(b, lines));
      }
      out.add(GlyphBox(index: index, start: start, end: end, boxes: boxes, lines: lineOf));
      start = end;
      index++;
    }
    return out;
  }

  static int _lineOfBox(ui.TextBox b, List<ui.LineMetrics> lines) {
    final cy = (b.top + b.bottom) / 2;
    var best = 0;
    var bestD = double.infinity;
    for (final l in lines) {
      final top = l.baseline - l.ascent;
      final bottom = l.baseline + l.descent;
      final d = cy < top ? top - cy : (cy > bottom ? cy - bottom : 0.0);
      if (d < bestD) {
        bestD = d;
        best = l.lineNumber;
      }
    }
    return best;
  }

  static List<RevealStrip> _stripsOf(List<GlyphBox> glyphs, List<ui.LineMetrics> lines, double padding) {
    // Boxes per line, with their glyph.
    final perLine = <int, List<(int, ui.TextBox)>>{};
    for (final g in glyphs) {
      for (var i = 0; i < g.boxes.length; i++) {
        (perLine[g.lines[i]] ??= []).add((g.index, g.boxes[i]));
      }
    }
    if (perLine.isEmpty) return const [];
    final lineIds = perLine.keys.toList()..sort();
    // Vertical bands (block coordinates) from the boxes of each line.
    final tops = <int, double>{};
    final bottoms = <int, double>{};
    for (final id in lineIds) {
      final bs = perLine[id]!;
      tops[id] = bs.map((e) => e.$2.top).reduce(math.min);
      bottoms[id] = bs.map((e) => e.$2.bottom).reduce(math.max);
    }
    final out = <RevealStrip>[];
    for (var li = 0; li < lineIds.length; li++) {
      final id = lineIds[li];
      final top = li == 0 ? double.negativeInfinity : (bottoms[lineIds[li - 1]]! + tops[id]!) / 2;
      final bottom = li == lineIds.length - 1 ? double.infinity : (bottoms[id]! + tops[lineIds[li + 1]]!) / 2;
      // Horizontal partition: sort by left; boundaries at midpoints between neighbours.
      final bs = perLine[id]!
        ..sort((a, b) {
          final c = a.$2.left.compareTo(b.$2.left);
          return c != 0 ? c : a.$1.compareTo(b.$1);
        });
      // Merge boxes with identical extent (ligatures) keeping the earliest glyph.
      final cells = <(int, double, double)>[];
      for (final (g, b) in bs) {
        if (cells.isNotEmpty && (cells.last.$2 - b.left).abs() < 1e-6 && (cells.last.$3 - b.right).abs() < 1e-6) {
          if (g < cells.last.$1) cells[cells.length - 1] = (g, b.left, b.right);
          continue;
        }
        cells.add((g, b.left, b.right));
      }
      for (var i = 0; i < cells.length; i++) {
        final (g, l, r) = cells[i];
        final left = i == 0 ? double.negativeInfinity : (cells[i - 1].$3 + l) / 2;
        final right = i == cells.length - 1 ? double.infinity : (r + cells[i + 1].$2) / 2;
        if (right <= left) continue;
        out.add(RevealStrip(g, ui.Rect.fromLTRB(left, top, right, bottom)));
      }
    }
    return out;
  }
}

/// Decodes the canonical JSON of a `TextLayoutSpec` (`TextLayoutSpec.toJson`, CORE-07).
/// Throws [FormatException] when a field is missing or has the wrong type.
TextLayoutSpec textLayoutSpecFromJson(Map<String, Object?> j) {
  T req<T>(Map<String, Object?> m, String k) {
    final v = m[k];
    if (v is T) return v;
    throw FormatException('TextLayoutSpec: "$k" must be a $T');
  }

  double dbl(Map<String, Object?> m, String k) => req<num>(m, k).toDouble();
  Map<String, Object?>? obj(String k) {
    final v = j[k];
    if (v == null) return null;
    if (v is Map<String, Object?>) return v;
    throw FormatException('TextLayoutSpec: "$k" must be an object');
  }

  T byName<T extends Enum>(List<T> values, String k) {
    final name = req<String>(j, k);
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException('TextLayoutSpec: unknown $k "$name"');
  }

  final runs = <TextRun>[
    for (final r in req<List<Object?>>(j, 'runs'))
      if (r is Map<String, Object?>)
        TextRun(req<String>(r, 'text'), bold: req<bool>(r, 'bold'), italic: req<bool>(r, 'italic'))
      else
        throw const FormatException('TextLayoutSpec: a run must be an object'),
  ];
  final box = obj('box');
  final stroke = obj('stroke');
  final shadow = obj('shadow');
  final maxLines = j['maxLines'];
  if (maxLines != null && maxLines is! int) throw const FormatException('TextLayoutSpec: "maxLines" must be an int');
  return TextLayoutSpec(
    runs: runs,
    fontFamily: req<String>(j, 'fontFamily'),
    fontSizePx: dbl(j, 'fontSizePx'),
    bold: req<bool>(j, 'bold'),
    italic: req<bool>(j, 'italic'),
    color: req<int>(j, 'color'),
    letterSpacingPx: dbl(j, 'letterSpacingPx'),
    lineHeight: dbl(j, 'lineHeight'),
    align: byName(TextAlignH.values, 'align'),
    maxWidthPx: dbl(j, 'maxWidthPx'),
    maxLines: maxLines as int?,
    box: box == null
        ? null
        : TextBoxSpec(
            color: req<int>(box, 'color'),
            opacity: dbl(box, 'opacity'),
            paddingPx: dbl(box, 'paddingPx'),
            cornerRadiusPx: dbl(box, 'cornerRadiusPx')),
    stroke: stroke == null ? null : TextStrokeSpec(color: req<int>(stroke, 'color'), widthPx: dbl(stroke, 'widthPx')),
    shadow: shadow == null
        ? null
        : TextShadowSpec(
            color: req<int>(shadow, 'color'),
            opacity: dbl(shadow, 'opacity'),
            blurPx: dbl(shadow, 'blurPx'),
            offset: Offset2(dbl(shadow, 'dx'), dbl(shadow, 'dy'))),
    direction: byName(TextDirectionHint.values, 'direction'),
    scale: dbl(j, 'scale'),
    canvasWidth: req<int>(j, 'canvasWidth'),
    canvasHeight: req<int>(j, 'canvasHeight'),
  );
}
