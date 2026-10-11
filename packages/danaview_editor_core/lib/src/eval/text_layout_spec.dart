// OWNER: CORE-07
//
// Renderer-neutral text layout input (domain.md §8, §12.5, ARCH §6.6, D-05): everything the
// Flutter `TextLayoutEngine` (API-04) needs to lay out a text item or a subtitle cue, resolved to
// canvas px. Layout itself is Flutter's (preview overlay, handles and export sprites share it);
// this file only says *what* to lay out. The canonical JSON ([TextLayoutSpec.toJson]) is part of
// the export sprite cache key (`SpriteRequest.layoutSpec`, CORE-29/31).
//
// Units: text sizes in the model are points at a 1,080 px canvas short side, so
// `px = pt · min(W, H) / 1080` ([TextLayoutSpec.scale]); letter spacing is em/100.

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../model/items.dart';
import '../model/settings.dart';
import '../model/subtitle.dart';
import '../model/text_style.dart';
import 'geometry.dart';

/// Line height multiplier of subtitle cues (the subtitle style has no line-height control).
const double cueLineHeight = 1.2;

/// Writing direction of a laid-out block. Specs carry [auto]: the paragraph direction is that of
/// the first strong character (ai.md §10.4), see [resolveTextDirection].
enum TextDirectionHint {
  /// Decided by the first strong character.
  auto,

  /// Left to right.
  ltr,

  /// Right to left.
  rtl,
}

/// A run of text with uniform inline style (cues may contain `<b>`/`<i>` spans).
@immutable
final class TextRun {
  /// Creates a run.
  const TextRun(this.text, {this.bold = false, this.italic = false});

  /// The characters of the run (may contain `\n`).
  final String text;

  /// Bold (in addition to the block's base weight).
  final bool bold;

  /// Italic (in addition to the block's base style).
  final bool italic;

  /// Canonical JSON.
  Map<String, Object?> toJson() => {'text': text, 'bold': bold, 'italic': italic};

  @override
  bool operator ==(Object other) => other is TextRun && other.text == text && other.bold == bold && other.italic == italic;

  @override
  int get hashCode => Object.hash(text, bold, italic);

  @override
  String toString() => 'TextRun(${text.length} chars, bold: $bold, italic: $italic)';
}

/// A background box behind the text block, in canvas px.
@immutable
final class TextBoxSpec {
  /// Creates a box.
  const TextBoxSpec({required this.color, required this.opacity, required this.paddingPx, required this.cornerRadiusPx});

  /// ARGB colour.
  final int color;

  /// Box opacity in [0, 1] (multiplies the colour's alpha).
  final double opacity;

  /// Padding around the text block.
  final double paddingPx;

  /// Corner radius.
  final double cornerRadiusPx;

  /// Canonical JSON.
  Map<String, Object?> toJson() =>
      {'color': color, 'opacity': opacity, 'paddingPx': paddingPx, 'cornerRadiusPx': cornerRadiusPx};

  @override
  bool operator ==(Object other) =>
      other is TextBoxSpec &&
      other.color == color &&
      other.opacity == opacity &&
      other.paddingPx == paddingPx &&
      other.cornerRadiusPx == cornerRadiusPx;

  @override
  int get hashCode => Object.hash(color, opacity, paddingPx, cornerRadiusPx);
}

/// A text outline, in canvas px.
@immutable
final class TextStrokeSpec {
  /// Creates an outline.
  const TextStrokeSpec({required this.color, required this.widthPx});

  /// ARGB colour.
  final int color;

  /// Outline width.
  final double widthPx;

  /// Canonical JSON.
  Map<String, Object?> toJson() => {'color': color, 'widthPx': widthPx};

  @override
  bool operator ==(Object other) => other is TextStrokeSpec && other.color == color && other.widthPx == widthPx;

  @override
  int get hashCode => Object.hash(color, widthPx);
}

/// A drop shadow, in canvas px; the offset is resolved from the model's distance and angle
/// (90° = straight down).
@immutable
final class TextShadowSpec {
  /// Creates a shadow.
  const TextShadowSpec({required this.color, required this.opacity, required this.blurPx, required this.offset});

  /// ARGB colour.
  final int color;

  /// Shadow opacity in [0, 1].
  final double opacity;

  /// Blur radius.
  final double blurPx;

  /// Offset of the shadow from the text (y down).
  final Offset2 offset;

  /// Canonical JSON.
  Map<String, Object?> toJson() =>
      {'color': color, 'opacity': opacity, 'blurPx': blurPx, 'dx': offset.dx, 'dy': offset.dy};

  @override
  bool operator ==(Object other) =>
      other is TextShadowSpec &&
      other.color == color &&
      other.opacity == opacity &&
      other.blurPx == blurPx &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(color, opacity, blurPx, offset);
}

/// What to lay out for one text item or subtitle cue, resolved to canvas px of a canvas of
/// [canvasWidth] × [canvasHeight] (domain.md §12.5).
///
/// Layout is computed on the full text (typewriter reveals never reflow lines). The block is
/// wrapped at [maxWidthPx]; [maxLines] (cues only) limits the line count.
@immutable
final class TextLayoutSpec {
  /// Creates a spec.
  TextLayoutSpec({
    required List<TextRun> runs,
    required this.fontFamily,
    required this.fontSizePx,
    this.bold = false,
    this.italic = false,
    required this.color,
    this.letterSpacingPx = 0,
    this.lineHeight = 1.2,
    this.align = TextAlignH.center,
    required this.maxWidthPx,
    this.maxLines,
    this.box,
    this.stroke,
    this.shadow,
    this.direction = TextDirectionHint.auto,
    required this.scale,
    required this.canvasWidth,
    required this.canvasHeight,
  }) : runs = List.unmodifiable(runs);

  /// Styled runs in order (the plain text is their concatenation).
  final List<TextRun> runs;

  /// Content-font id (D-30); the layout engine falls back to Figtree for unknown ids.
  final String fontFamily;

  /// Font size in canvas px.
  final double fontSizePx;

  /// Base weight is bold.
  final bool bold;

  /// Base style is italic.
  final bool italic;

  /// ARGB text colour.
  final int color;

  /// Extra space between letters in canvas px (`em/100 × fontSizePx`).
  final double letterSpacingPx;

  /// Line height multiplier.
  final double lineHeight;

  /// Line alignment.
  final TextAlignH align;

  /// Wrap width in canvas px.
  final double maxWidthPx;

  /// Maximum number of lines (subtitle cues), or null.
  final int? maxLines;

  /// Optional background box.
  final TextBoxSpec? box;

  /// Optional outline.
  final TextStrokeSpec? stroke;

  /// Optional drop shadow.
  final TextShadowSpec? shadow;

  /// Paragraph direction (always [TextDirectionHint.auto] from the spec builders).
  final TextDirectionHint direction;

  /// Canvas px per point (`min(W, H) / 1080`).
  final double scale;

  /// Canvas width in px.
  final int canvasWidth;

  /// Canvas height in px.
  final int canvasHeight;

  /// The plain text (runs concatenated, markup removed).
  String get text => runs.length == 1 ? runs.first.text : runs.map((r) => r.text).join();

  /// Number of grapheme clusters of [text] (the typewriter's `n`; whitespace and line breaks
  /// count as clusters, `\r\n` as one).
  int get graphemeCount => textGraphemeCount(text);

  /// The direction of the first strong character of [text] (ltr when there is none).
  TextDirectionHint get resolvedDirection => resolveTextDirection(text);

  /// Canonical JSON (fixed key order, colours as ARGB ints): the sprite cache key input.
  Map<String, Object?> toJson() => {
        'runs': [for (final r in runs) r.toJson()],
        'fontFamily': fontFamily,
        'fontSizePx': fontSizePx,
        'bold': bold,
        'italic': italic,
        'color': color,
        'letterSpacingPx': letterSpacingPx,
        'lineHeight': lineHeight,
        'align': align.name,
        'maxWidthPx': maxWidthPx,
        'maxLines': maxLines,
        'box': box?.toJson(),
        'stroke': stroke?.toJson(),
        'shadow': shadow?.toJson(),
        'direction': direction.name,
        'scale': scale,
        'canvasWidth': canvasWidth,
        'canvasHeight': canvasHeight,
      };

  @override
  bool operator ==(Object other) =>
      other is TextLayoutSpec &&
      const ListEquality<TextRun>().equals(other.runs, runs) &&
      other.fontFamily == fontFamily &&
      other.fontSizePx == fontSizePx &&
      other.bold == bold &&
      other.italic == italic &&
      other.color == color &&
      other.letterSpacingPx == letterSpacingPx &&
      other.lineHeight == lineHeight &&
      other.align == align &&
      other.maxWidthPx == maxWidthPx &&
      other.maxLines == maxLines &&
      other.box == box &&
      other.stroke == stroke &&
      other.shadow == shadow &&
      other.direction == direction &&
      other.scale == scale &&
      other.canvasWidth == canvasWidth &&
      other.canvasHeight == canvasHeight;

  @override
  int get hashCode => Object.hash(Object.hashAll(runs), fontFamily, fontSizePx, bold, italic, color, letterSpacingPx,
      lineHeight, align, maxWidthPx, maxLines, box, stroke, shadow, direction, scale, canvasWidth, canvasHeight);
}

/// Number of grapheme clusters (user-perceived characters, `package:characters`) of [text]: what
/// the typewriter animation reveals one at a time (emoji ZWJ sequences, flags and combining marks
/// count once).
int textGraphemeCount(String text) => text.characters.length;

/// The first [count] grapheme clusters of [text] (the typewriter's visible prefix).
String graphemePrefix(String text, int count) => count <= 0 ? '' : text.characters.take(count).toString();

/// The direction of the first strong character of [text] (ai.md §10.4): rtl for Hebrew, Arabic,
/// Syriac, Thaana, N'Ko and the other right-to-left blocks, ltr for any other letter, ltr when no
/// strong character exists.
TextDirectionHint resolveTextDirection(String text) {
  for (final r in text.runes) {
    if (_isRtl(r)) return TextDirectionHint.rtl;
    if (_isLetter(r)) return TextDirectionHint.ltr;
  }
  return TextDirectionHint.ltr;
}

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

bool _isLetter(int rune) => _letter.hasMatch(String.fromCharCode(rune));

bool _isRtl(int r) =>
    (r >= 0x0590 && r <= 0x08FF) || // Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic ext.
    (r >= 0xFB1D && r <= 0xFDFF) || // Hebrew and Arabic presentation forms A
    (r >= 0xFE70 && r <= 0xFEFF) || // Arabic presentation forms B
    (r >= 0x10800 && r <= 0x10FFF) || // historic RTL scripts
    (r >= 0x1E800 && r <= 0x1EFFF); // Adlam, Mende Kikakui, Arabic mathematical

/// Parses the inline markup of a subtitle cue (ARCH §10.1: `<b>…</b>` and `<i>…</i>` only, case
/// insensitive, nesting allowed) into styled runs. Unknown tags are kept as literal text, unmatched
/// closing tags are dropped and unclosed tags run to the end. Adjacent runs of equal style merge.
List<TextRun> parseCueMarkup(String source) {
  final runs = <TextRun>[];
  var bold = 0;
  var italic = 0;
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    final text = buf.toString();
    buf.clear();
    final b = bold > 0;
    final i = italic > 0;
    if (runs.isNotEmpty && runs.last.bold == b && runs.last.italic == i) {
      runs[runs.length - 1] = TextRun(runs.last.text + text, bold: b, italic: i);
    } else {
      runs.add(TextRun(text, bold: b, italic: i));
    }
  }

  var i = 0;
  while (i < source.length) {
    final ch = source.codeUnitAt(i);
    if (ch == 0x3C /* < */) {
      final m = _tag.matchAsPrefix(source, i);
      if (m != null) {
        final closing = m[1] == '/';
        final isBold = m[2]!.toLowerCase() == 'b';
        flush();
        if (isBold) {
          bold = closing ? (bold > 0 ? bold - 1 : 0) : bold + 1;
        } else {
          italic = closing ? (italic > 0 ? italic - 1 : 0) : italic + 1;
        }
        i = m.end;
        continue;
      }
    }
    buf.writeCharCode(ch);
    i++;
  }
  flush();
  return runs;
}

final RegExp _tag = RegExp(r'<(/?)([bBiI])>');

/// The layout spec of [item] on [canvas] (domain.md §8): one run of the item's text, the style
/// resolved to canvas px (`pt · min(W, H)/1080`), the wrap width `style.maxWidth · W`.
TextLayoutSpec textLayoutSpecOf(TextItem item, CanvasSpec canvas) {
  final size = canvas.sizePx;
  final ppp = pxPerPointOf(size);
  final s = item.style;
  final fontPx = s.fontSizePt * ppp;
  return TextLayoutSpec(
    runs: [TextRun(item.text)],
    fontFamily: s.fontFamily,
    fontSizePx: fontPx,
    bold: s.bold,
    italic: s.italic,
    color: s.color,
    letterSpacingPx: s.letterSpacing / 100 * fontPx,
    lineHeight: s.lineHeight,
    align: s.align,
    maxWidthPx: s.maxWidth * size.width,
    box: _box(s.background, ppp),
    stroke: _stroke(s.stroke, ppp),
    shadow: _shadow(s.shadow, ppp),
    scale: ppp,
    canvasWidth: canvas.widthPx,
    canvasHeight: canvas.heightPx,
  );
}

/// The layout spec of [cue] styled by its track's [data] on [canvas] (domain.md §8): runs from the
/// cue's inline `<b>`/`<i>` markup ([parseCueMarkup]), the subtitle style resolved to canvas px,
/// `maxLines` from the style and line height [cueLineHeight].
TextLayoutSpec cueLayoutSpecOf(SubtitleCue cue, SubtitleTrackData data, CanvasSpec canvas) {
  final size = canvas.sizePx;
  final ppp = pxPerPointOf(size);
  final s = data.style;
  return TextLayoutSpec(
    runs: parseCueMarkup(cue.text),
    fontFamily: s.fontFamily,
    fontSizePx: s.fontSizePt * ppp,
    bold: s.bold,
    italic: s.italic,
    color: s.color,
    lineHeight: cueLineHeight,
    align: s.align,
    maxWidthPx: s.maxWidth * size.width,
    maxLines: s.maxLines,
    box: _box(s.background, ppp),
    stroke: _stroke(s.outline, ppp),
    shadow: _shadow(s.shadow, ppp),
    scale: ppp,
    canvasWidth: canvas.widthPx,
    canvasHeight: canvas.heightPx,
  );
}

TextBoxSpec? _box(BoxStyle? b, double ppp) => b == null
    ? null
    : TextBoxSpec(color: b.color, opacity: b.opacity, paddingPx: b.paddingPt * ppp, cornerRadiusPx: b.cornerRadiusPt * ppp);

TextStrokeSpec? _stroke(StrokeStyle? s, double ppp) =>
    s == null ? null : TextStrokeSpec(color: s.color, widthPx: s.widthPt * ppp);

TextShadowSpec? _shadow(ShadowStyle? s, double ppp) {
  if (s == null) return null;
  final (cos, sin) = cosSinDeg(s.angleDeg);
  final d = s.distancePt * ppp;
  return TextShadowSpec(color: s.color, opacity: s.opacity, blurPx: s.blurPt * ppp, offset: Offset2(d * cos, d * sin));
}
