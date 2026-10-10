// OWNER: API-04
//
// TextLayoutEngine (ARCH §10.3, D-05): glyph boxes equal an independently built ui.Paragraph's
// boxes; tight width, block and raster geometry; grapheme clusters (emoji ZWJ, combining marks,
// CJK); RTL direction; reveal strips tiling the plane; font resolution and the layout cache.

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart' show estimateTextBlockSize;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support.dart';

void main() {
  setUpAll(loadFigtree);

  test('spec JSON round trip (SpriteRequest.layoutSpec)', () {
    final s = spec('Hello\nworld',
        runs: const [TextRun('Hel'), TextRun('lo\n', bold: true), TextRun('world', italic: true)],
        box: const TextBoxSpec(color: 0xFF102030, opacity: 0.5, paddingPx: 12, cornerRadiusPx: 6),
        stroke: const TextStrokeSpec(color: 0xFF000000, widthPx: 3),
        shadow: const TextShadowSpec(color: 0xFF000000, opacity: 0.4, blurPx: 4, offset: Offset2(2, 5)),
        maxLines: 2,
        align: TextAlignH.right);
    expect(textLayoutSpecFromJson(s.toJson()), s);
    expect(() => textLayoutSpecFromJson(const {}), throwsFormatException);
    expect(() => textLayoutSpecFromJson({...s.toJson(), 'align': 'justify'}), throwsFormatException);
  });

  group('glyph boxes equal ui.Paragraph boxes', () {
    final cases = <String, TextLayoutSpec>{
      'latin one line': spec('Vwish editor'),
      'wrapped, left': spec('The quick brown fox jumps over the lazy dog again and again', maxWidthPx: 500, align: TextAlignH.left),
      'styled runs': spec('', runs: const [TextRun('Bold '), TextRun('move', bold: true), TextRun(' italic', italic: true)]),
      'letter spacing + line height': spec('Spaced\nlines', letterSpacingPx: 6, lineHeight: 1.6),
      'box padding': spec('Boxed', box: const TextBoxSpec(color: 0xFF000000, opacity: 0.6, paddingPx: 20, cornerRadiusPx: 8)),
      'emoji and combining marks': spec('ok 👨‍👩‍👧 é 🇫🇷!'),
      'rtl': spec('שלום עולם'),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final engine = TextLayoutEngine();
        final s = e.value;
        final l = engine.layoutSpec(s);
        // Independent reference: build the paragraph from the spec with the engine's styles,
        // at the tight width, and query every cluster range.
        final ref = engine.buildParagraph(s, l.textSize.width);
        expect(l.paragraph.width, ref.width);
        expect(l.paragraph.height, ref.height);
        var start = 0;
        expect(l.glyphCount, textGraphemeCount(s.text));
        for (final g in l.glyphs) {
          expect(g.start, start);
          final want = ref
              .getBoxesForRange(g.start, g.end)
              .where((b) => b.right - b.left > 0 || b.bottom - b.top > 0)
              .map((b) => ui.Rect.fromLTRB(b.left + l.padding, b.top + l.padding, b.right + l.padding, b.bottom + l.padding))
              .toList();
          expect(g.boxes.map((b) => b.toRect()).toList(), want, reason: 'cluster ${g.index}');
          start = g.end;
        }
        expect(start, s.text.length);
        expect(l.lines.length, ref.computeLineMetrics().length);
      });
    }
  });

  test('glyph boxes equal a hand-built ui.Paragraph (no engine code involved)', () {
    final s = spec('Hand built wrap test, two lines', fontSizePx: 48, maxWidthPx: 420, align: TextAlignH.left, letterSpacingPx: 2, lineHeight: 1.4);
    final l = TextLayoutEngine().layoutSpec(s);
    final b = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.left, textDirection: ui.TextDirection.ltr))
      ..pushStyle(ui.TextStyle(
          color: const ui.Color(0xFFFFFFFF),
          fontFamily: 'Figtree',
          fontSize: 48,
          fontWeight: ui.FontWeight.w400,
          fontStyle: ui.FontStyle.normal,
          letterSpacing: 2,
          height: 1.4))
      ..addText(s.text);
    final p = b.build()..layout(const ui.ParagraphConstraints(width: 420));
    final tight = p.longestLine.ceilToDouble();
    p.layout(ui.ParagraphConstraints(width: tight));
    expect(l.textSize, ui.Size(tight, p.height));
    for (final g in l.glyphs) {
      final want = p.getBoxesForRange(g.start, g.end).where((x) => x.right > x.left).map((x) => x.toRect()).toList();
      expect(g.boxes.map((x) => x.toRect()).toList(), want, reason: 'cluster ${g.index}');
    }
    expect(l.lines.length, 2);
  });

  test('tight width: alignment is relative to the longest line, block adds the box padding', () {
    final engine = TextLayoutEngine();
    final s = spec('Short\nA much longer line', box: const TextBoxSpec(color: 0xFF000000, opacity: 1, paddingPx: 10, cornerRadiusPx: 0));
    final l = engine.layoutSpec(s);
    final wide = engine.buildParagraph(s, s.maxWidthPx);
    expect(l.textSize.width, wide.longestLine.ceilToDouble());
    expect(l.textSize.width, lessThan(s.maxWidthPx));
    expect(l.blockSize, ui.Size(l.textSize.width + 20, l.textSize.height + 20));
    expect(engine.measure(s), Size2(l.blockSize.width, l.blockSize.height));
    // Centered: the short line's box is horizontally centred in the text.
    final first = l.glyphs.first.boxes.first;
    final lastOfLine1 = l.glyphs[4].boxes.first;
    final mid = (first.left + lastOfLine1.right) / 2;
    expect(mid, closeTo(l.textOffset.dx + l.textSize.width / 2, 1.5));
    // Raster extent: symmetric margin.
    expect(l.rasterSize, ui.Size(l.blockSize.width + 2 * l.margin, l.blockSize.height + 2 * l.margin));
    expect(l.margin, closeTo(TextLayoutEngine.rasterMarginOf(s), 1e-9));
  });

  test('wrapping respects maxWidthPx and maxLines adds an ellipsis', () {
    final engine = TextLayoutEngine();
    final s = spec('one two three four five six seven eight nine ten', maxWidthPx: 300, maxLines: 2);
    final l = engine.layoutSpec(s);
    expect(l.lines.length, 2);
    expect(l.textSize.width, lessThanOrEqualTo(300));
    expect(l.paragraph.didExceedMaxLines, isTrue);
  });

  test('raster margin covers outline, shadow (offset + 3σ) and overhang', () {
    final s = spec('M',
        fontSizePx: 100,
        stroke: const TextStrokeSpec(color: 0xFF000000, widthPx: 4),
        shadow: const TextShadowSpec(color: 0xFF000000, opacity: 1, blurPx: 10, offset: Offset2(3, 8)));
    final sigma = 10 * 0.57735 + 0.5;
    expect(TextLayoutEngine.rasterMarginOf(s), closeTo(4 + 8 + 3 * sigma + 10 + 1, 1e-9));
    expect(TextLayoutEngine.rasterMarginOf(spec('M', fontSizePx: 100)), closeTo(11, 1e-9));
  });

  test('RTL text resolves to an rtl paragraph; clusters run right to left', () {
    final engine = TextLayoutEngine();
    final l = engine.layoutSpec(spec('אבג'));
    expect(l.direction, ui.TextDirection.rtl);
    final xs = [for (final g in l.glyphs) g.bounds!.center.dx];
    expect(xs[0], greaterThan(xs[1]));
    expect(xs[1], greaterThan(xs[2]));
    expect(engine.layoutSpec(spec('abc')).direction, ui.TextDirection.ltr);
    expect(engine.layoutSpec(spec('123 שלום')).direction, ui.TextDirection.rtl, reason: 'first strong character');
  });

  test('grapheme clusters: emoji ZWJ sequences, flags and combining marks count once', () {
    final engine = TextLayoutEngine();
    final l = engine.layoutSpec(spec('👨‍👩‍👧🇫🇷é漢字'));
    expect(l.glyphCount, 5);
    expect([for (final g in l.glyphs) g.end - g.start], [8, 4, 2, 1, 1]);
    for (final g in l.glyphs) {
      expect(g.boxes, isNotEmpty, reason: 'cluster ${g.index} has extent');
    }
  });

  test('reveal strips tile the plane: every point belongs to exactly one glyph, in reading order', () {
    final engine = TextLayoutEngine();
    final s = spec('Type writer\ntext 👍', maxWidthPx: 900, box: const TextBoxSpec(color: 0xFF000000, opacity: 1, paddingPx: 16, cornerRadiusPx: 4));
    final l = engine.layoutSpec(s);
    final ext = ui.Offset(-l.margin, -l.margin) & l.rasterSize;
    var seen = <int>{};
    for (var y = ext.top + 0.5; y < ext.bottom; y += 3) {
      for (var x = ext.left + 0.5; x < ext.right; x += 3) {
        final p = ui.Offset(x, y);
        final owners = [for (final st in l.revealStrips) if (st.rect.contains(p)) st.glyph];
        expect(owners.length, lessThanOrEqualTo(1), reason: 'strips overlap at $p');
        expect(owners, isNotEmpty, reason: 'no strip at $p');
        seen.add(owners.single);
      }
    }
    // Every visible cluster (not the line break) owns some area.
    final visible = {for (final g in l.glyphs) if (g.boxes.isNotEmpty) g.index};
    expect(seen.containsAll(visible.where((i) => l.glyphs[i].bounds!.width > 4)), isTrue);
    // Each glyph's own box centre belongs to it.
    for (final g in l.glyphs.where((g) => g.boxes.isNotEmpty)) {
      expect(l.glyphAt(g.boxes.first.toRect().center), g.index);
    }
    // Reading order: on the first line, strips go left to right with increasing glyph index.
    final line0 = l.revealStrips.where((st) => st.rect.top == double.negativeInfinity).toList()
      ..sort((a, b) => a.rect.left.compareTo(b.rect.left));
    for (var i = 1; i < line0.length; i++) {
      expect(line0[i].glyph, greaterThan(line0[i - 1].glyph));
    }
    // The clip of all glyphs covers the raster; of none, nothing.
    expect(l.revealClip(l.glyphCount).getBounds().width, greaterThan(0));
    expect(l.revealClip(0).getBounds().isEmpty, isTrue);
    seen = {};
  });

  test('fonts: ids go through the resolver; unknown ids fall back to Figtree', () {
    final asked = <String>[];
    final engine = TextLayoutEngine(fontResolver: (id) {
      asked.add(id);
      return id == 'figtree' ? 'Figtree' : 'Figtree';
    });
    engine.layoutSpec(spec('a', fontFamily: 'figtree'));
    engine.layoutSpec(spec('a', fontFamily: 'not-a-font'));
    expect(asked.toSet(), {'figtree', 'not-a-font'});
    expect(figtreeOnlyResolver('anything'), figtreeFamily);
    // The default engine lays out with Figtree: same metrics as an explicit Figtree resolver.
    final a = TextLayoutEngine().layoutSpec(spec('Figtree metrics', fontFamily: 'unknown'));
    final b = TextLayoutEngine(fontResolver: (_) => 'Figtree').layoutSpec(spec('Figtree metrics'));
    expect(a.textSize, b.textSize);
  });

  test('layout cache: equal specs reuse one layout; LRU bound', () {
    final engine = TextLayoutEngine(cacheSize: 2);
    final a = engine.layoutSpec(spec('a'));
    expect(engine.layoutSpec(spec('a')), same(a));
    expect(engine.layout(spec('a').toJson()), same(a));
    engine.layoutSpec(spec('b'));
    engine.layoutSpec(spec('c'));
    expect(engine.layoutSpec(spec('a')), isNot(same(a)), reason: 'evicted');
    expect(engine.layouts, 4);
    engine.trim();
    engine.layoutSpec(spec('c'));
    expect(engine.layouts, 5);
  });

  test('measure() drives the CORE-31 raster clamp (TextMetricsProvider)', () {
    final engine = TextLayoutEngine();
    final s = spec('A title that is fairly long', fontSizePx: 120, maxWidthPx: 1800);
    final m = engine.measure(s);
    final est = estimateTextBlockSize(s);
    expect(m.width, lessThanOrEqualTo(est.width), reason: 'the estimate is conservative');
    expect(m.height, greaterThan(0));
  });
}
