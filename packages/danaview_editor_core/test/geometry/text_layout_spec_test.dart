// OWNER: CORE-07
//
// textLayoutSpecOf / cueLayoutSpecOf (domain.md §8, §12.5): points resolved to canvas px at a
// 1,080 px short side, wrap width, box/stroke/shadow, cue markup runs, direction, canonical JSON.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

void main() {
  group('textLayoutSpecOf', () {
    const item = TextItem(
      id: ItemId('it_t'),
      start: 0,
      duration: 1000000,
      text: 'Hello\nworld',
      style: TextStyleSpec(
        fontFamily: 'playfair',
        fontSizePt: 60,
        bold: true,
        letterSpacing: 10,
        lineHeight: 1.5,
        maxWidth: 0.5,
        align: TextAlignH.left,
        background: BoxStyle(paddingPt: 12, cornerRadiusPt: 6),
        stroke: StrokeStyle(widthPt: 3),
        shadow: ShadowStyle(distancePt: 4, angleDeg: 90, blurPt: 8),
      ),
    );

    test('at 1080p points are px', () {
      final s = textLayoutSpecOf(item, const CanvasSpec());
      expect(s.text, 'Hello\nworld');
      expect(s.runs, [const TextRun('Hello\nworld')]);
      expect(s.fontFamily, 'playfair');
      expect(s.fontSizePx, 60);
      expect(s.bold, isTrue);
      expect(s.letterSpacingPx, 6);
      expect(s.lineHeight, 1.5);
      expect(s.maxWidthPx, 960);
      expect(s.align, TextAlignH.left);
      expect(s.box, const TextBoxSpec(color: 0xFF000000, opacity: 0.6, paddingPx: 12, cornerRadiusPx: 6));
      expect(s.stroke, const TextStrokeSpec(color: 0xFF000000, widthPx: 3));
      expect(s.shadow!.offset, const Offset2(0, 4));
      expect(s.shadow!.blurPx, 8);
      expect(s.scale, 1);
      expect((s.canvasWidth, s.canvasHeight), (1920, 1080));
      expect(s.maxLines, isNull);
      expect(s.direction, TextDirectionHint.auto);
    });

    test('scales with the canvas short side (portrait 720p and 4K)', () {
      final p = textLayoutSpecOf(item, const CanvasSpec(aspect: AspectRatio.portrait9x16, baseShortSide: 720));
      expect(p.scale, closeTo(2 / 3, 1e-12));
      expect(p.fontSizePx, closeTo(40, 1e-9));
      expect(p.maxWidthPx, 360);
      expect(p.box!.paddingPx, closeTo(8, 1e-9));
      final uhd = textLayoutSpecOf(item, const CanvasSpec(baseShortSide: 2160));
      expect(uhd.fontSizePx, 120);
      expect(uhd.letterSpacingPx, 12);
      expect(uhd.shadow!.offset, const Offset2(0, 8));
    });

    test('JSON is canonical and changes with the content', () {
      final a = textLayoutSpecOf(item, const CanvasSpec());
      final b = textLayoutSpecOf(item, const CanvasSpec());
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final c = textLayoutSpecOf(item.copyWith(text: 'Hello world'), const CanvasSpec());
      expect(jsonEncode(c.toJson()), isNot(jsonEncode(a.toJson())));
      expect(a.toJson().keys.first, 'runs');
    });
  });

  group('cueLayoutSpecOf', () {
    const data = SubtitleTrackData(
      style: SubtitleStyle(fontSizePt: 42, maxLines: 2, maxWidth: 0.8, outline: StrokeStyle(widthPt: 2)),
    );

    test('resolves the subtitle style with maxLines and markup runs', () {
      const cue = SubtitleCue(id: ItemId('it_c'), start: 0, duration: 1, text: 'Say <i>hello</i> <b>now</b>!');
      final s = cueLayoutSpecOf(cue, data, const CanvasSpec());
      expect(s.runs, const [
        TextRun('Say '),
        TextRun('hello', italic: true),
        TextRun(' '),
        TextRun('now', bold: true),
        TextRun('!'),
      ]);
      expect(s.text, 'Say hello now!');
      expect(s.fontSizePx, 42);
      expect(s.maxLines, 2);
      expect(s.maxWidthPx, 1536);
      expect(s.stroke!.widthPx, 2);
      expect(s.box, isNotNull);
      expect(s.lineHeight, cueLineHeight);
    });
  });

  group('parseCueMarkup', () {
    test('nesting, case, unknown tags, unmatched tags', () {
      expect(parseCueMarkup('<B>bold <I>both</i></b> plain'), const [
        TextRun('bold ', bold: true),
        TextRun('both', bold: true, italic: true),
        TextRun(' plain'),
      ]);
      expect(parseCueMarkup('a <u>b</u> c'), const [TextRun('a <u>b</u> c')]);
      expect(parseCueMarkup('</i>x'), const [TextRun('x')]);
      expect(parseCueMarkup('<i>open'), const [TextRun('open', italic: true)]);
      expect(parseCueMarkup('a<i></i>b'), const [TextRun('ab')]);
      expect(parseCueMarkup(''), isEmpty);
      expect(parseCueMarkup('1 < 2 > 0'), const [TextRun('1 < 2 > 0')]);
      expect(parseCueMarkup('😀<b>🇯🇵</b>'), const [TextRun('😀'), TextRun('🇯🇵', bold: true)]);
    });
  });

  group('direction', () {
    test('first strong character decides', () {
      expect(resolveTextDirection('Hello'), TextDirectionHint.ltr);
      expect(resolveTextDirection('مرحبا Hello'), TextDirectionHint.rtl);
      expect(resolveTextDirection('123 שלום'), TextDirectionHint.rtl);
      expect(resolveTextDirection('42 Hello مرحبا'), TextDirectionHint.ltr);
      expect(resolveTextDirection('東京'), TextDirectionHint.ltr);
      expect(resolveTextDirection('123 !?'), TextDirectionHint.ltr);
      expect(resolveTextDirection(''), TextDirectionHint.ltr);
    });
  });
}
