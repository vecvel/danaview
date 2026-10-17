// OWNER: UX-10
//
// ParagraphCache (ux.md §8.6 "Text", §17.5): an LRU of 512 laid-out `ui.Paragraph`s for the
// timeline canvas (clip labels, durations, text/cue excerpts, badge glyphs), keyed by
// (text, style, width bucket). Widths are bucketed to 8 px and rounded down, so a cached label is
// never wider than the space it was asked for and a clip resized by a few pixels reuses its
// paragraph. Cleared on a text-scale change and on memory pressure.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FontWeight, TextDirection;

/// The style of one cached paragraph: everything that changes its layout or colour.
///
/// Values are compared by value, so two equal styles share cache entries.
@immutable
final class TimelineTextStyle {
  /// Creates a style. [ellipsis] cuts the text with `…` at the laid-out width.
  const TimelineTextStyle({
    required this.fontFamily,
    required this.fontSize,
    required this.color,
    this.fontWeight = FontWeight.w500,
    this.tabularFigures = false,
    this.ellipsis = true,
  });

  /// Font family (`DanaviewFonts.family`; `MaterialIcons` for badge glyphs; `Ahem` in goldens).
  final String fontFamily;

  /// Font size in logical px (already multiplied by the text scale).
  final double fontSize;

  /// Text colour.
  final ui.Color color;

  /// Weight.
  final FontWeight fontWeight;

  /// Whether digits use tabular figures (durations).
  final bool tabularFigures;

  /// Whether overflowing text ends with `…` (otherwise it is clipped by the width).
  final bool ellipsis;

  /// A copy with the given fields replaced.
  TimelineTextStyle copyWith({String? fontFamily, double? fontSize, ui.Color? color, FontWeight? fontWeight, bool? tabularFigures, bool? ellipsis}) =>
      TimelineTextStyle(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        fontWeight: fontWeight ?? this.fontWeight,
        tabularFigures: tabularFigures ?? this.tabularFigures,
        ellipsis: ellipsis ?? this.ellipsis,
      );

  @override
  bool operator ==(Object other) =>
      other is TimelineTextStyle &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.color == color &&
      other.fontWeight == fontWeight &&
      other.tabularFigures == tabularFigures &&
      other.ellipsis == ellipsis;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, color, fontWeight, tabularFigures, ellipsis);

  @override
  String toString() => 'TimelineTextStyle($fontFamily ${fontSize}px $fontWeight)';
}

/// Laid-out one-line paragraphs of the timeline canvas, LRU of [capacity] (512) keyed by
/// (text, style, width bucket).
class ParagraphCache {
  /// Creates an empty cache.
  ParagraphCache({this.capacity = defaultCapacity}) : assert(capacity > 0);

  /// The default number of paragraphs kept (ux.md §17.5).
  static const int defaultCapacity = 512;

  /// Width buckets are multiples of this many px.
  static const double widthBucketPx = 8;

  /// Most paragraphs kept.
  final int capacity;

  final LinkedHashMap<(String, TimelineTextStyle, double), ui.Paragraph> _entries = LinkedHashMap();
  double? _textScale;

  /// Cache hits since creation (debug and tests).
  int hits = 0;

  /// Cache misses (paragraphs built) since creation (debug and tests).
  int misses = 0;

  /// Number of cached paragraphs.
  int get length => _entries.length;

  /// The layout width used for a requested [maxWidth]: rounded down to a multiple of
  /// [widthBucketPx]; infinite widths stay infinite (no ellipsis). Widths under one bucket give 0
  /// (nothing fits).
  static double bucketWidth(double maxWidth) {
    if (!maxWidth.isFinite) return double.infinity;
    if (maxWidth < widthBucketPx) return 0;
    return (maxWidth / widthBucketPx).floorToDouble() * widthBucketPx;
  }

  /// Whether ([text], [style], [maxWidth]'s bucket) is cached (does not touch the LRU order).
  bool contains(String text, TimelineTextStyle style, {double maxWidth = double.infinity}) =>
      _entries.containsKey((text, style, bucketWidth(maxWidth)));

  /// The paragraph of [text] in [style], on one line, laid out at [maxWidth]'s bucket (ellipsized
  /// when [TimelineTextStyle.ellipsis]). Returns null when the bucket is 0 (no room for any text).
  ui.Paragraph? paragraph(String text, TimelineTextStyle style, {double maxWidth = double.infinity}) {
    final width = bucketWidth(maxWidth);
    if (width <= 0) return null;
    final key = (text, style, width);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      hits++;
      return hit;
    }
    misses++;
    final p = _build(text, style, width);
    _entries[key] = p;
    while (_entries.length > capacity) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return p;
  }

  /// The natural (unconstrained) width of [text] in [style].
  double widthOf(String text, TimelineTextStyle style) => paragraph(text, style)!.maxIntrinsicWidth;

  static ui.Paragraph _build(String text, TimelineTextStyle style, double width) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      maxLines: 1,
      ellipsis: style.ellipsis && width.isFinite ? '…' : null,
      textDirection: TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: style.color,
        fontFamily: style.fontFamily,
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontFeatures: style.tabularFigures ? const [ui.FontFeature.tabularFigures()] : null,
      ))
      ..addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: width));
  }

  /// Records the current text scale; a change clears the cache (ux.md §17.5).
  void setTextScale(double scale) {
    if (_textScale != null && _textScale != scale) clear();
    _textScale = scale;
  }

  /// Memory pressure: drops every paragraph.
  void onMemoryPressure() => clear();

  /// Drops every paragraph.
  void clear() {
    for (final p in _entries.values) {
      p.dispose();
    }
    _entries.clear();
  }

  /// Releases the paragraphs.
  void dispose() => clear();

  @override
  String toString() => 'ParagraphCache(${_entries.length}/$capacity, hits: $hits, misses: $misses, '
      'max width bucket: ${_entries.keys.fold<double>(0, (m, k) => k.$3.isFinite ? math.max(m, k.$3) : m)})';
}
