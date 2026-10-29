import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/formats.dart';

/// DV_PERF_STRICT=1 (a quiet dev Mac) asserts the absolute budget; otherwise (a loaded CI runner)
/// [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
num _limit(num budget) => _perfStrict ? budget : budget * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

Uint8List fx(String name) => File('test/fixtures/subtitles/$name').readAsBytesSync();
SubtitleParseResult parseFx(String name, {SubtitleFormat? hint}) => SubtitleCodec.parse(fx(name), hint: hint);

SubtitleCueData cue(num startS, num endS, String text) =>
    SubtitleCueData((startS * 1000000).round(), (endS * 1000000).round(), text);

void main() {
  group('decoding', () {
    final expectBasic = [cue(1, 2.5, 'Hello, world'), cue(3, 4.25, 'Second line\nwraps here')];

    test('UTF-8 without BOM, CRLF', () {
      final r = parseFx('basic.srt');
      expect(r.detectedEncoding, TextEncoding.utf8);
      expect(r.hadBom, isFalse);
      expect(r.format, SubtitleFormat.srt);
      expect(r.cues, expectBasic);
      expect(r.issues, isEmpty);
    });

    test('UTF-8 BOM', () {
      final r = parseFx('bom_utf8.srt');
      expect(r.detectedEncoding, TextEncoding.utf8);
      expect(r.hadBom, isTrue);
      expect(r.cues, expectBasic);
    });

    for (final (name, enc, bom) in [
      ('utf16le_bom.srt', TextEncoding.utf16le, true),
      ('utf16be_bom.srt', TextEncoding.utf16be, true),
      ('utf16le_nobom.srt', TextEncoding.utf16le, false),
      ('utf16be_nobom.srt', TextEncoding.utf16be, false),
    ]) {
      test(name, () {
        final r = parseFx(name);
        expect(r.detectedEncoding, enc);
        expect(r.hadBom, bom);
        expect(r.cues.first.text, 'Héllo, world');
        expect(r.cues, hasLength(2));
        expect(r.issues, isEmpty);
      });
    }

    test('Windows-1252 then Latin-1 fallback', () {
      final r = parseFx('cp1252.srt');
      expect(r.detectedEncoding, TextEncoding.windows1252);
      expect(r.cues.single.text, 'Café ‘quoted’ – €5');
      final l = parseFx('latin1_undefined.srt');
      expect(l.detectedEncoding, TextEncoding.latin1);
      expect(l.cues.single.text, 'A\u0081Bé');
    });

    test('CJK, emoji and RTL survive', () {
      final c = parseFx('cjk.srt');
      expect(c.detectedEncoding, TextEncoding.utf8);
      expect(c.cues.map((e) => e.text), ['你好，世界\nこんにちは', '안녕하세요 😀']);
      final r = parseFx('rtl.srt');
      expect(r.cues.map((e) => e.text), ['שלום עולם', 'مرحبا بالعالم']);
    });

    test('CR-only line endings', () {
      expect(parseFx('cr_only.srt').cues, expectBasic);
    });

    test('decodeText edge cases never throw', () {
      expect(decodeText(Uint8List(0)).text, '');
      expect(decodeText(Uint8List.fromList([0xFF, 0xFE, 0x41])).text, '');
      expect(decodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0xE9])).encoding, TextEncoding.utf8);
    });
  });

  group('SRT reader', () {
    test('tolerant input', () {
      final r = parseFx('tolerant.srt');
      expect(r.issues, isEmpty);
      expect(r.cues, [
        cue(1.5, 2.25, 'Top red text'),
        cue(360000, 360001, 'Hour hundred'),
        cue(5, 6, 'No separator'),
        cue(6, 7, 'after'),
        cue(62.3, 63.45, '<i>italic <b>both</b></i><b> tail</b> & <3 A "q"'),
      ]);
      expect(r.strippedTags, 3);
      expect(r.ignoredSettings, 1);
    });

    test('malformed cues become issues with line numbers; the rest import', () {
      final r = parseFx('malformed.srt');
      expect(r.cues.map((c) => c.text), ['Good one', 'Good two']);
      expect(r.issues, const [
        SubtitleIssue(6, SubtitleIssueKind.invalidTiming),
        SubtitleIssue(10, SubtitleIssueKind.endBeforeStart),
        SubtitleIssue(14, SubtitleIssueKind.emptyText),
        SubtitleIssue(17, SubtitleIssueKind.strayText),
      ]);
    });

    test('empty and garbage input', () {
      expect(SubtitleCodec.parse(Uint8List(0)).cues, isEmpty);
      final g = SubtitleCodec.parse(Uint8List.fromList(utf8.encode('hello\nworld\n')));
      expect(g.cues, isEmpty);
      expect(g.issues.single, const SubtitleIssue(1, SubtitleIssueKind.strayText));
    });
  });

  group('WebVTT reader', () {
    test('basic', () {
      final r = parseFx('basic.vtt');
      expect(r.format, SubtitleFormat.vtt);
      expect(r.cues, [cue(1, 2.5, 'Hello, world'), cue(3, 4.25, 'Second\nline')]);
    });

    test('NOTE/STYLE/REGION skipped, settings ignored, entities decoded, tags stripped', () {
      final r = parseFx('vtt_full.vtt');
      expect(r.cues, [
        cue(1, 2, 'Hi & there <you>'),
        cue(3600, 3601.5, '<i>Italic</i> timed <b>bold</b>'),
      ]);
      expect(r.ignoredSettings, 1);
      expect(r.strippedTags, 5);
      expect(r.issues, const [
        SubtitleIssue(21, SubtitleIssueKind.noTiming),
        SubtitleIssue(24, SubtitleIssueKind.endBeforeStart),
        SubtitleIssue(27, SubtitleIssueKind.emptyText),
      ]);
    });

    test('header is required, content wins over hint', () {
      final r = parseFx('vtt_no_header.vtt', hint: SubtitleFormat.vtt);
      expect(r.cues, isEmpty);
      expect(r.issues.single, const SubtitleIssue(1, SubtitleIssueKind.missingHeader));
      // Without a hint the same bytes parse as SRT (tolerant, hours optional).
      expect(parseFx('vtt_no_header.vtt').cues.single.text, 'No header');
      // A WEBVTT file is VTT even when hinted as SRT.
      expect(parseFx('basic.vtt', hint: SubtitleFormat.srt).format, SubtitleFormat.vtt);
    });

    test('BOM and CRLF', () {
      final r = parseFx('vtt_bom_crlf.vtt');
      expect(r.hadBom, isTrue);
      expect(r.cues.single, cue(1, 2, 'BOM and CRLF'));
    });
  });

  group('serialization', () {
    final cues = [cue(1, 2.5, 'Hello'), cue(3, 4.0005, '<i>Two</i>\n\n  lines  ')];

    test('SRT: numbered, CRLF, half-up ms, no BOM', () {
      final s = utf8.decode(SubtitleCodec.serialize(cues, SubtitleFormat.srt));
      expect(
          s,
          '1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n'
          '2\r\n00:00:03,000 --> 00:00:04,001\r\n<i>Two</i>\r\nlines\r\n\r\n');
      expect(SubtitleCodec.serialize(cues, SubtitleFormat.srt).take(3), isNot([0xEF, 0xBB, 0xBF]));
    });

    test('VTT: header, LF, optional BOM', () {
      final s = utf8.decode(SubtitleCodec.serialize(cues, SubtitleFormat.vtt));
      expect(
          s, 'WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n00:00:03.000 --> 00:00:04.001\n<i>Two</i>\nlines\n\n');
      final b = SubtitleCodec.serialize(cues, SubtitleFormat.vtt, bom: true);
      expect(b.take(3), [0xEF, 0xBB, 0xBF]);
      expect(SubtitleCodec.parse(b).hadBom, isTrue);
    });

    test('half-up rounding at .5 ms', () {
      final s = utf8.decode(SubtitleCodec.serialize([const SubtitleCueData(1500, 2499, 'x')], SubtitleFormat.srt));
      expect(s, contains('00:00:00,002 --> 00:00:00,002'));
    });

    test('--> in text becomes ->, markup is balanced, empty cues skipped', () {
      final s = utf8.decode(SubtitleCodec.serialize(
        [cue(0, 1, 'a --> b <i>open'), cue(1, 2, '   '), cue(2, 3, 'x</b>y')],
        SubtitleFormat.vtt,
      ));
      expect(s, contains('a -> b <i>open</i>'));
      expect(s, contains('\nxy\n'));
      expect('-->'.allMatches(s).length, 2);
      expect(SubtitleCodec.parse(Uint8List.fromList(utf8.encode(s))).cues, hasLength(2));
    });

    test('offset shifts, clamps and drops', () {
      final out = SubtitleCodec.parse(SubtitleCodec.serialize(
        [cue(0, 1, 'gone'), cue(1, 3, 'clamped'), cue(5, 6, 'kept')],
        SubtitleFormat.srt,
        offset: -2000000,
      ));
      expect(out.cues, [cue(0, 1, 'clamped'), cue(3, 4, 'kept')]);
      final pos =
          SubtitleCodec.parse(SubtitleCodec.serialize([cue(1, 2, 'a')], SubtitleFormat.vtt, offset: 3600 * 1000000));
      expect(pos.cues.single, cue(3601, 3602, 'a'));
    });

    test('hours above 99 round-trip', () {
      final c = [cue(360000, 360001.5, 'long')];
      for (final f in SubtitleFormat.values) {
        expect(SubtitleCodec.parse(SubtitleCodec.serialize(c, f)).cues, c);
      }
    });

    test('suggested file name', () {
      expect(SubtitleCodec.suggestedFileName('My Film', 'en', SubtitleFormat.srt), 'My Film.en.srt');
      expect(SubtitleCodec.suggestedFileName('a/b:c?', 'pt-BR', SubtitleFormat.vtt), 'a_b_c_.pt-BR.vtt');
      expect(SubtitleCodec.suggestedFileName('  ', 'not a tag', SubtitleFormat.vtt), 'subtitles.und.vtt');
    });
  });

  group('round trip', () {
    const alphabet = [
      'a', 'b', 'Z', ' ', '1', '42', '.', ',', ':', '-', '>', '<', '&', ';',
      '"', "'", '#', '{', '}', //
      '你', '好', 'こ', 'é', 'ñ', 'ש', 'ל', 'م', 'ر', '😀', '&amp;', '&lt;',
      '&#65;', '->', '\\',
    ];

    String randomText(math.Random r) {
      final lines = <String>[];
      final n = 1 + r.nextInt(3);
      for (var i = 0; i < n; i++) {
        final sb = StringBuffer();
        for (var j = 0, m = 1 + r.nextInt(8); j < m; j++) {
          sb.write(alphabet[r.nextInt(alphabet.length)]);
        }
        var line = sb.toString().trim();
        if (line.isEmpty) line = 'x';
        if (line.contains('-->') || line.contains('{\\')) line = 'y';
        switch (r.nextInt(6)) {
          case 0:
            line = '<i>$line</i>';
          case 1:
            line = '<b>$line</b>';
          case 2:
            line = '<i>$line<b>z</b></i>';
        }
        lines.add(line);
      }
      return lines.join('\n');
    }

    test('parse(serialize(x)) == x for random cues in both formats', () {
      final r = math.Random(20261008);
      for (var round = 0; round < 60; round++) {
        final cues = <SubtitleCueData>[];
        var t = r.nextInt(5000) * 1000;
        for (var i = 0, n = 1 + r.nextInt(25); i < n; i++) {
          final dur = r.nextInt(8000) * 1000;
          cues.add(SubtitleCueData(t, t + dur, randomText(r)));
          t += r.nextInt(4000) * 1000 + (r.nextBool() ? 0 : dur);
        }
        for (final f in SubtitleFormat.values) {
          final bytes = SubtitleCodec.serialize(cues, f, bom: r.nextBool());
          final back = SubtitleCodec.parse(bytes);
          expect(back.format, f);
          expect(back.issues, isEmpty, reason: '$f round $round');
          expect(back.cues, cues, reason: '$f round $round');
        }
      }
    });

    test('parse of serialized fixture corpus is stable', () {
      for (final name in [
        'basic.srt',
        'tolerant.srt',
        'cjk.srt',
        'rtl.srt',
        'cp1252.srt',
        'vtt_full.vtt',
        'utf16le_bom.srt'
      ]) {
        final a = parseFx(name);
        for (final f in SubtitleFormat.values) {
          final b = SubtitleCodec.parse(SubtitleCodec.serialize(a.cues, f));
          expect(b.cues, a.cues, reason: '$name via $f');
        }
      }
    });
  });

  group('performance', () {
    test('10k cues parse in <= 100 ms (SRT and VTT; 4× without DV_PERF_STRICT=1)', () {
      final cues = [
        for (var i = 0; i < 10000; i++)
          SubtitleCueData(i * 1500000, i * 1500000 + 1200000, 'Line $i of <i>text</i>\nsecond line é'),
      ];
      for (final f in SubtitleFormat.values) {
        final bytes = SubtitleCodec.serialize(cues, f);
        SubtitleCodec.parse(bytes); // warm up
        final best = [
          for (var k = 0; k < 3; k++)
            (() {
              final sw = Stopwatch()..start();
              final r = SubtitleCodec.parse(bytes);
              sw.stop();
              expect(r.cues, hasLength(10000));
              return sw.elapsedMilliseconds;
            })(),
        ].reduce(math.min);
        // ignore: avoid_print
        print('parse 10k cues ($f): best $best ms');
        expect(best, lessThanOrEqualTo(_limit(100)), reason: '$f took $best ms ($_perfMode)');
      }
    });
  });
}
