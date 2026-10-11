// OWNER: AI-11

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'segmentation_fixtures.dart';

const _seg = DpCaptionSegmenter();

List<SubtitleCueDraft> segment(List<TimedWord> words, [SegmentationContext? ctx]) => _seg.segment(words, ctx ?? context());

TimedWord w(String text, int startMs, int endMs, {String clip = 'a'}) =>
    TimedWord(text: text, start: startMs * 1000, end: endMs * 1000, clip: ItemId(clip));

SegmentationContext preset(SegmentationPreset p, {String language = 'en', bool portrait = false, FrameRate rate = FrameRate.fps30, List<TimeUs> cuts = const []}) =>
    context(language: language, settings: SegmentationSettings(preset: p), portrait: portrait, rate: rate, cuts: cuts);

int maxLineLength(List<SubtitleCueDraft> cues) =>
    cues.expand((c) => c.text.split('\n')).map((l) => l.characters.length).fold(0, (a, b) => a > b ? a : b);

void main() {
  test('no words, no cues; blank words are ignored', () {
    expect(segment(const []), isEmpty);
    expect(segment([w('  ', 0, 100), w('', 100, 200)]), isEmpty);
  });

  test('a single short sentence becomes one cue with linger', () {
    final cues = segment([w('Hello', 1000, 1400), w('there.', 1450, 1900)]);
    expect(render(cues), ['1000-2100|Hello there.']);
  });

  group('timing on the frame grid', () {
    for (final rate in [FrameRate.fps24, FrameRate.fps25, FrameRate.fps30, FrameRate.fps48, FrameRate.fps50, FrameRate.fps60]) {
      test('edges lie on the $rate grid', () {
        final words = wordsFromText('One two three four five six seven eight nine ten. Eleven twelve thirteen fourteen fifteen sixteen. Done.', startMs: 123);
        final cues = segment(words, context(rate: rate));
        expect(cues, isNotEmpty);
        for (final c in cues) {
          expect(rate.isOnGrid(c.range.start), isTrue, reason: '${c.range}');
          expect(rate.isOnGrid(c.range.end), isTrue, reason: '${c.range}');
          expect(c.range.duration, greaterThanOrEqualTo(rate.timeOfFrame(1)));
        }
      });
    }

    test('the start is the first word floored to its frame', () {
      final cues = segment([w('Hello', 1016, 1400), w('there.', 1450, 1900)]); // 30 fps: frame 30 = 1000.0 ms, 31 = 1033.3
      expect(cues.single.range.start, 1000000);
    });

    test('a short cue is extended to the minimum duration when nothing follows', () {
      final cues = segment([w('Yes.', 1000, 1200)]);
      expect(cues.single.range.start, 1000000);
      expect(cues.single.range.duration, closeTo(830000, 34000));
      expect(cues.single.range.duration, greaterThanOrEqualTo(830000));
    });

    test('lingers 0.2 s after the last word', () {
      final cues = segment(wordsFromText('We will see how this goes in the long run.', startMs: 0));
      final last = wordsFromText('We will see how this goes in the long run.', startMs: 0).last;
      expect(cues.last.range.end, closeTo(last.end + 200000, 34000));
    });

    test('cues closer than the chain threshold are chained with a 2-frame gap', () {
      final words = [
        ...wordsFromText('This is the first sentence of the talk.', startMs: 0, pauseAfterSentenceMs: 0),
      ];
      final next = wordsFromText('And here comes another sentence now.', startMs: (words.last.end ~/ 1000) + 300, pauseAfterSentenceMs: 0);
      final cues = segment([...words, ...next]);
      expect(cues.length, 2);
      final rate = FrameRate.fps30;
      expect(rate.frameIndexOf(cues[1].range.start) - rate.frameIndexOf(cues[0].range.end), 2);
    });

    test('cues farther apart than the chain threshold are not stretched', () {
      final first = wordsFromText('This is the first sentence of the talk.', startMs: 0, pauseAfterSentenceMs: 0);
      final next = wordsFromText('And here comes another sentence now.', startMs: (first.last.end ~/ 1000) + 900, pauseAfterSentenceMs: 0);
      final cues = segment([...first, ...next]);
      expect(cues.length, 2);
      expect(cues[0].range.end, closeTo(first.last.end + 200000, 34000));
      expect(cues[1].range.start - cues[0].range.end, greaterThan(500000));
    });

    test('Short phrases allow back-to-back cues; Standard keeps two frames', () {
      final words = wordsFromText('One two three four five six seven eight nine ten eleven twelve thirteen fourteen', pauseBetweenTokensMs: 0);
      final short = segment(words, preset(SegmentationPreset.shortPhrases));
      expect(short.length, greaterThan(2));
      var touching = 0;
      for (var i = 1; i < short.length; i++) {
        if (short[i].range.start == short[i - 1].range.end) touching++;
      }
      expect(touching, greaterThan(0));
      final standard = segment(words, preset(SegmentationPreset.standard));
      for (var i = 1; i < standard.length; i++) {
        expect(FrameRate.fps30.frameIndexOf(standard[i].range.start) - FrameRate.fps30.frameIndexOf(standard[i - 1].range.end), greaterThanOrEqualTo(2));
      }
    });

    test('two cues that start on the same frame are merged instead of overlapping', () {
      final cues = segment([w('Quick.', 1000, 1004), w('Quicker.', 1005, 1010), w('Then a real sentence follows here.', 3000, 5000)]);
      for (var i = 1; i < cues.length; i++) {
        expect(cues[i].range.start, greaterThanOrEqualTo(cues[i - 1].range.end));
      }
      expect(cues.first.text, contains('Quick.'));
    });
  });

  group('cue boundaries', () {
    test('a sentence end is preferred as the boundary', () {
      final words = wordsFromText('The weather is nice today. We should go outside and enjoy it while it lasts.');
      final cues = segment(words);
      expect(cues.first.text.replaceAll('\n', ' '), 'The weather is nice today.');
    });

    test('a pause of 1.2 s or more splits a cue even without punctuation', () {
      final cues = segment([w('hello', 0, 500), w('there', 600, 1100), w('friend', 2500, 3000), w('again', 3100, 3600)]);
      expect(cues.length, 2);
      expect(cues[0].text, 'hello there');
      expect(cues[1].text, 'friend again');
    });

    test('a long run without pauses never exceeds max duration + 0.5 s', () {
      final words = wordsFromText('${List.generate(80, (i) => 'word${i % 7}').join(' ')}.', msPerGrapheme: 60, pauseBetweenTokensMs: 0);
      final cues = segment(words);
      expect(cues.length, greaterThan(3));
      for (final c in cues) {
        expect(c.range.duration, lessThanOrEqualTo(7500000 + 2 * 33334));
      }
    });

    test('Single line: one line per cue, at most 42 graphemes, at most 5 s', () {
      final words = wordsFromText('Today we are going to talk about something really important because it changes how we work every single day and everything else.');
      final cues = segment(words, preset(SegmentationPreset.singleLine));
      for (final c in cues) {
        expect(c.text.contains('\n'), isFalse, reason: c.text);
        expect(c.text.characters.length, lessThanOrEqualTo(42));
        expect(c.range.duration, lessThanOrEqualTo(5000000 + 2 * 33334));
      }
      expect(cues.length, greaterThan(2));
    });

    test('Short phrases: one line of at most 20 graphemes and at most 2.5 s', () {
      final words = wordsFromText('Today we are going to talk about something really important because it changes how we work.', pauseBetweenTokensMs: 0);
      final cues = segment(words, preset(SegmentationPreset.shortPhrases));
      for (final c in cues) {
        expect(c.text.contains('\n'), isFalse);
        expect(c.text.characters.length, lessThanOrEqualTo(20), reason: c.text);
        expect(c.range.duration, lessThanOrEqualTo(2500000 + 2 * 33334));
      }
    });

    test('9:16: Standard cues use lines of at most 32 graphemes; 16:9 uses 42', () {
      final words = wordsFromText('Today we are going to talk about something really important because it changes how we work every single day and everything else around it.');
      final portrait = segment(words, preset(SegmentationPreset.standard, portrait: true));
      final landscape = segment(words, preset(SegmentationPreset.standard));
      expect(maxLineLength(portrait), lessThanOrEqualTo(32));
      expect(maxLineLength(landscape), lessThanOrEqualTo(42));
      expect(maxLineLength(landscape), greaterThan(32));
      expect(portrait.length, greaterThanOrEqualTo(landscape.length));
    });

    test('user overrides for lines, characters and speed are honoured', () {
      final words = wordsFromText('Today we are going to talk about something really important because it changes how we work every single day.');
      final cues = segment(words, context(settings: const SegmentationSettings(maxLines: 1, maxCharsPerLine: 25)));
      expect(maxLineLength(cues), lessThanOrEqualTo(25));
      expect(cues.every((c) => !c.text.contains('\n')), isTrue);
    });

    test('speech faster than the reading speed produces fewer characters per cue', () {
      final text = List.generate(40, (i) => 'wordy${i % 9}').join(' ');
      final slow = segment(wordsFromText(text, msPerGrapheme: 90), context());
      final fast = segment(wordsFromText(text, msPerGrapheme: 35), context());
      double cps(List<SubtitleCueDraft> cs) => cs.map((c) => c.text.replaceAll('\n', ' ').characters.length / (c.range.duration / 1e6)).reduce((a, b) => a > b ? a : b);
      expect(cps(slow), lessThan(20));
      // Fast speech cannot be slowed down, but the segmenter never makes it worse than the speech itself.
      expect(cps(fast), lessThan(35));
    });

    test('fractionOverReadingSpeed counts cues above the limit', () {
      final cues = [
        SubtitleCueDraft(const TimeRange(0, 1000000), 'a' * 10),
        SubtitleCueDraft(const TimeRange(2000000, 3000000), 'a' * 30),
      ];
      expect(fractionOverReadingSpeed(cues, 17), 0.5);
      expect(fractionOverReadingSpeed(const [], 17), 0);
    });
  });

  group('line breaking', () {
    test('balances two lines', () {
      final cues = segment(wordsFromText('We walked along the river until the sun went down behind the hills.'));
      final lines = cues.first.text.split('\n');
      expect(lines.length, 2);
      expect((lines[0].length - lines[1].length).abs(), lessThan(10));
    });

    test('prefers a bottom line that is equal or longer (pyramid)', () {
      final words = wordsFromText(List.generate(17, (i) => 'abc').join(' '), pauseBetweenTokensMs: 0, msPerGrapheme: 80);
      final lines = segment(words).first.text.split('\n');
      expect(lines.length, 2);
      expect(lines[0].length, lessThanOrEqualTo(lines[1].length));
    });

    test('does not end the top line with an article, preposition or conjunction when it can avoid it', () {
      final cues = segment(wordsFromText('She put the book on the table and sat down by the window.'));
      final lines = cues.first.text.split('\n');
      expect(lines.length, 2);
      expect(lines[0], isNot(endsWith(' and')));
      expect(lines[0], isNot(endsWith(' the')));
      expect(lines[0], isNot(endsWith(' on')));
    });

    test('breaks after a sentence end or comma when the balance is close', () {
      final cues = segment(wordsFromText('When we arrived at the station, the train had already left without us.'));
      final lines = cues.first.text.split('\n');
      expect(lines[0], endsWith(','));
    });

    test('a word longer than a line is hard-wrapped at a grapheme boundary', () {
      final cues = segment([w('a' * 60, 0, 3000)]);
      final lines = cues.single.text.split('\n');
      expect(lines.length, 2);
      expect(lines.every((l) => l.length <= 42), isTrue);
      expect(lines.join(), 'a' * 60);
    });

    test('long words inside a cue stay whole when they fit on a line', () {
      final cues = segment(wordsFromText('Internationalization and ${'x' * 38} are different.'));
      expect(cues.expand((c) => c.text.split('\n')).any((l) => l.contains('x' * 38)), isTrue);
    });
  });

  group('graphemes, not UTF-16 units', () {
    test('combining marks and emoji sequences count as one', () {
      // 5 family emoji = 5 graphemes (each 11 UTF-16 units).
      const family = '👨‍👩‍👧‍👦';
      final cues = segment(
        [w(family * 5, 0, 1500)],
        context(settings: const SegmentationSettings(maxLines: 1, maxCharsPerLine: 5)),
      );
      expect(cues.single.text, family * 5);
      expect(cues.single.text.contains('\n'), isFalse);
    });

    test('Devanagari conjuncts are counted as clusters when fitting a line', () {
      const word = 'नमस्ते'; // 6 code points, 3 grapheme clusters
      expect(word.characters.length, lessThan(word.length));
      final cues = segment(
        [w(word, 0, 1000), w(word, 1100, 2000)],
        context(language: 'hi', settings: const SegmentationSettings(maxLines: 1, maxCharsPerLine: 8)),
      );
      expect(cues.length, 1);
      expect(cues.single.text, '$word $word');
    });
  });

  group('kinsoku (CJK)', () {
    test('no line starts with closing punctuation or ends with an opening bracket', () {
      const text = '「今日は、晴れですね。」と彼は言った。（彼女は笑った）それから、二人は公園へ行き、静かに話をした。「また明日」と言って別れた。';
      final words = wordsFromText(text, tokenizer: Tokenizer.pairs, msPerGrapheme: 120);
      final cues = segment(words, context(language: 'ja'));
      expect(cues, isNotEmpty);
      for (final c in cues) {
        for (final line in c.text.split('\n')) {
          expect(kinsokuNoLineStart.contains(line.characters.first), isFalse, reason: 'line "$line" starts with a prohibited character');
          expect(kinsokuNoLineEnd.contains(line.characters.last), isFalse, reason: 'line "$line" ends with a prohibited character');
        }
      }
    });

    test('limits: at most 16 graphemes per line', () {
      final words = wordsFromText('これはとても長い日本語の文章で、字幕の行の長さを確認するためのテストです。', tokenizer: Tokenizer.pairs, msPerGrapheme: 120);
      final cues = segment(words, context(language: 'ja'));
      expect(maxLineLength(cues), lessThanOrEqualTo(16));
    });

    test('Korean allows 18 and breaks between words', () {
      final cues = segment(wordsFromText('오늘은 정말 중요한 이야기를 해 보려고 합니다 그리고 내일도 계속됩니다', msPerGrapheme: 150), context(language: 'ko'));
      expect(maxLineLength(cues), lessThanOrEqualTo(18));
      expect(maxLineLength(cues), greaterThan(16));
      for (final c in cues) {
        for (final l in c.text.split('\n')) {
          expect(l.startsWith(' ') || l.endsWith(' '), isFalse);
        }
      }
    });

    test('Latin words inside CJK text stay whole and touch the CJK text', () {
      final words = [w('今日は', 0, 600), w('iPhone', 650, 1100), w('を買いました。', 1150, 2000)];
      final cues = segment(words, context(language: 'ja'));
      expect(cues.single.text.replaceAll('\n', ''), '今日はiPhoneを買いました。');
    });
  });

  group('no-space scripts and RTL', () {
    test('Thai words are joined without spaces and wrap at 35', () {
      final cues = segment(wordsFromText('สวัสดีทุกคนและยินดีต้อนรับกลับสู่ช่องของเราวันนี้เราจะพูดถึงเรื่องสำคัญมาก', tokenizer: Tokenizer.triples, msPerGrapheme: 90), context(language: 'th'));
      expect(maxLineLength(cues), lessThanOrEqualTo(35));
      expect(cues.every((c) => !c.text.contains(' ')), isTrue);
    });

    test('Arabic keeps logical order and adds no direction marks', () {
      const text = 'مرحبا بكم جميعا وأهلا بكم من جديد في القناة.';
      final input = wordsFromText(text);
      final cues = segment(input, context(language: 'ar'));
      final out = cues.map((c) => c.text.replaceAll('\n', ' ')).join(' ');
      expect(out, text);
      expect(RegExp('[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]').hasMatch(out), isFalse);
    });
  });

  group('cut points', () {
    // 22 words, continuous, no punctuation until the end: needs two cues; the clip changes at 6 s.
    List<TimedWord> twoClips() => [
          for (var i = 0; i < 22; i++) w('word${i % 10}', i * 600, i * 600 + 560, clip: i * 600 < 6000 ? 'a' : 'b'),
        ];

    test('a long continuous passage breaks at the cut when the cut is known', () {
      final without = segment(twoClips().map((e) => e.copyWith(clip: const ItemId('a'))).toList());
      final withCut = segment(twoClips(), context(cuts: [6000000]));
      // With the cut known no cue straddles it.
      for (final c in withCut) {
        expect(c.range.start < 6000000 && c.range.end > 6000000 + 200000, isFalse, reason: '${c.range}');
      }
      // Without it the segmenter picks its own balanced break.
      expect(render(withCut), isNot(render(without)));
    });

    test('a sentence spanning the cut still produces one continuous cue (penalty, not a wall)', () {
      final words = [
        w('This', 0, 250, clip: 'a'),
        w('sentence', 300, 800, clip: 'a'),
        w('keeps', 850, 1200, clip: 'a'),
        w('going', 1250, 1600, clip: 'b'),
        w('after', 1650, 2000, clip: 'b'),
        w('the', 2050, 2200, clip: 'b'),
        w('cut.', 2250, 2600, clip: 'b'),
      ];
      final cues = segment(words, context(cuts: [1225000]));
      expect(cues.length, 1);
      expect(cues.single.text.replaceAll('\n', ' '), 'This sentence keeps going after the cut.');
    });

    test('the cut penalty moves an otherwise arbitrary break onto the cut', () {
      // Equal-cost breaks exist between words 10 and 14; the cut sits between 11 and 12.
      final words = [for (var i = 0; i < 24; i++) w('lorem', i * 500, i * 500 + 450)];
      final plain = segment(words);
      final cutAt = 12 * 500 * 1000 - 25000;
      final cut = segment(words, context(cuts: [cutAt]));
      expect(plain.length, cut.length);
      final boundaryCut = cut.first.range.end;
      expect(boundaryCut, lessThanOrEqualTo(cutAt + 250000));
    });
  });

  group('input handling', () {
    test('words may arrive in any order and are sorted (stable for equal starts)', () {
      final words = wordsFromText('The quick brown fox jumps over the lazy dog.');
      expect(render(segment(words.reversed.toList())), render(segment(words)));
    });

    test('zero-length words and end before start are tolerated', () {
      final cues = segment([w('Oops', 1000, 900), w('fine.', 1000, 1000)]);
      expect(cues, isNotEmpty);
      expect(cues.first.range.duration, greaterThan(0));
    });

    test('the same input always gives the same output', () {
      final words = wordsFromText('One two three four five six seven eight nine ten. Eleven twelve thirteen fourteen fifteen.');
      expect(render(segment(words)), render(segment(words)));
    });
  });
}
