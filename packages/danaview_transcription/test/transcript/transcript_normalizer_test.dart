// OWNER: AI-10

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart' show RawSegment, RawWord;

import 'transcript_fixtures.dart';

NormalizedTranscript run(List<TranscriptSegment> segs, {String language = 'en', NormalizerOptions options = const NormalizerOptions(), int? unitEndMs}) =>
    TranscriptNormalizer(options).normalize(segs, language: language, unitEndUs: unitEndMs == null ? null : unitEndMs * 1000);

void main() {
  group('whitespace and dialogue dashes', () {
    test('trims and collapses whitespace', () {
      final r = run([seg(0, 2000, '  Hello   there \n  friend  ', words: false)]);
      expect(texts(r.segments), ['Hello there friend']);
    });

    test('strips a leading "- " that whisper emits for dialogue', () {
      final r = run([seg(0, 2000, '- Where are you going?', words: false), seg(2500, 4000, '- - To the shop.', words: false)]);
      expect(texts(r.segments), ['Where are you going?', 'To the shop.']);
    });

    test('keeps hyphenated words', () {
      final r = run([seg(0, 2000, 'well-known fact', words: false)]);
      expect(texts(r.segments), ['well-known fact']);
    });

    test('switches off individually', () {
      final r = run([seg(0, 2000, '- Hi', words: false)], options: const NormalizerOptions(stripLeadingDash: false));
      expect(texts(r.segments), ['- Hi']);
    });
  });

  group('non-speech annotations', () {
    test('drops segments that are only annotations', () {
      final r = run([
        seg(0, 1000, '[MUSIC]', words: false),
        seg(1000, 2000, '(applause)', words: false),
        seg(2000, 3000, '♪ la la la ♪', words: false),
        seg(3000, 4000, '*laughs*', words: false),
        seg(4000, 6000, 'Real speech here.'),
      ]);
      expect(texts(r.segments), ['Real speech here.']);
      expect(r.report.annotationSegmentsDropped, 4);
    });

    test('removes spans inside text and the matching words', () {
      final r = run([seg(0, 4000, 'Well [BLANK_AUDIO] hello (laughs) there')]);
      expect(texts(r.segments), ['Well hello there']);
      expect([for (final w in r.segments.single.words) w.text], ['Well', 'hello', 'there']);
      expect(r.report.annotationSpansRemoved, 2);
    });

    test('words split across tokens of one annotation are all removed', () {
      final s = TranscriptSegment(
        startUs: 0,
        endUs: 4000000,
        text: 'Yes [ loud noise ] indeed',
        words: const [
          TranscriptWord(text: 'Yes', startUs: 0, endUs: 500000),
          TranscriptWord(text: '[', startUs: 500000, endUs: 1000000),
          TranscriptWord(text: 'loud', startUs: 1000000, endUs: 1500000),
          TranscriptWord(text: 'noise', startUs: 1500000, endUs: 2000000),
          TranscriptWord(text: ']', startUs: 2000000, endUs: 2500000),
          TranscriptWord(text: 'indeed', startUs: 2500000, endUs: 3000000),
        ],
      );
      final r = run([s]);
      expect(r.segments.single.text, 'Yes indeed');
      expect([for (final w in r.segments.single.words) w.text], ['Yes', 'indeed']);
    });

    test('an unclosed music note swallows the rest of the segment', () {
      final r = run([seg(0, 3000, 'Okay ♪ happy birthday to you', words: false)]);
      expect(texts(r.segments), ['Okay']);
    });

    test('keeps annotations when sound descriptions are requested', () {
      final r = run(
        [seg(0, 1000, '[MUSIC]', words: false), seg(1000, 3000, 'Hello (laughs) there', words: false)],
        options: const NormalizerOptions(removeAnnotations: false),
      );
      expect(texts(r.segments), ['[MUSIC]', 'Hello (laughs) there']);
    });

    test('drops segments with no letters or digits left', () {
      final r = run([seg(0, 1000, '...', words: false), seg(1000, 2000, '1984', words: false)]);
      expect(texts(r.segments), ['1984']);
    });
  });

  group('silence hallucinations', () {
    test('drops nsp > 0.5 with lp < -0.8, keeps either one alone', () {
      final r = run([
        seg(0, 2000, 'dropped one', nsp: 0.7, lp: -1.2),
        seg(3000, 5000, 'kept high nsp', nsp: 0.7, lp: -0.3),
        seg(6000, 8000, 'kept low lp', nsp: 0.2, lp: -1.5),
        seg(9000, 11000, 'edge case', nsp: 0.5, lp: -0.8),
      ]);
      expect(texts(r.segments), ['kept high nsp', 'kept low lp', 'edge case']);
      expect(r.report.silenceHallucinationsDropped, 1);
    });

    test('phrase list needs nsp > 0.3', () {
      final r = run([
        seg(0, 3000, 'Thanks for watching!', nsp: 0.1),
        seg(4000, 7000, 'Thanks for watching!', nsp: 0.4),
        seg(8000, 12000, 'And then he said hello'),
      ]);
      expect(texts(r.segments), ['Thanks for watching!', 'And then he said hello']);
      expect(r.report.phraseHallucinationsDropped, 1);
    });

    test('a short phrase that ends the unit is dropped even with low nsp', () {
      final r = run([seg(0, 4000, 'We are done with this part.'), seg(5000, 5800, 'Thank you.')], unitEndMs: 5900);
      expect(texts(r.segments), ['We are done with this part.']);
    });

    test('a long phrase-like segment at the end survives', () {
      final r = run([seg(0, 4000, 'We are done.'), seg(5000, 8000, 'Thank you.')], unitEndMs: 8000);
      expect(texts(r.segments), ['We are done.', 'Thank you.']);
    });

    test('a phrase in the middle of speech with low nsp survives', () {
      final r = run([seg(0, 800, 'Thank you.'), seg(1000, 4000, 'Next topic then.')], unitEndMs: 4000);
      expect(texts(r.segments), ['Thank you.', 'Next topic then.']);
    });

    test('per-language phrases: ja, es, de and universal credits', () {
      expect(texts(run([seg(0, 3000, 'ご視聴ありがとうございました', nsp: 0.5, words: false)], language: 'ja').segments), isEmpty);
      expect(texts(run([seg(0, 3000, 'Gracias por ver el video.', nsp: 0.5, words: false)], language: 'es').segments), isEmpty);
      expect(texts(run([seg(0, 3000, 'Untertitel der Amara.org-Community', nsp: 0.5, words: false)], language: 'de').segments), isEmpty);
      expect(texts(run([seg(0, 3000, 'Subtitles by the Amara.org community', nsp: 0.5, words: false)], language: 'fi').segments), isEmpty);
      // An English phrase in a Japanese transcript is not on the Japanese list.
      expect(texts(run([seg(0, 3000, 'Thank you for watching', nsp: 0.5, words: false)], language: 'ja').segments), ['Thank you for watching']);
    });
  });

  group('repetition loops', () {
    test('collapses three or more identical segments to the first', () {
      final r = run([
        seg(0, 2000, 'I do not know.'),
        seg(2000, 4000, 'I do not know.'),
        seg(4000, 6000, 'i do not know'),
        seg(6000, 8000, 'I do not know!'),
        seg(8000, 10000, 'Something else.'),
      ]);
      expect(texts(r.segments), ['I do not know.', 'Something else.']);
      expect(r.report.repeatedSegmentsCollapsed, 3);
    });

    test('keeps two identical segments', () {
      final r = run([seg(0, 2000, 'Go go.'), seg(2000, 4000, 'Go go.'), seg(4000, 6000, 'Now.')]);
      expect(texts(r.segments), ['Go go.', 'Go go.', 'Now.']);
    });

    test('collapses a word repeated four or more times inside a segment', () {
      final r = run([seg(0, 5000, 'and the the the the the end')]);
      expect(r.segments.single.text, 'and the end');
      expect([for (final w in r.segments.single.words) w.text], ['and', 'the', 'end']);
      // The kept occurrence covers the whole run so the timing stays contiguous.
      final the = r.segments.single.words[1];
      expect(the.endUs - the.startUs, greaterThan(2000000));
    });

    test('keeps a word repeated three times', () {
      final r = run([seg(0, 5000, 'no no no way')]);
      expect(r.segments.single.text, 'no no no way');
    });

    test('collapses repeated words in languages without spaces from the word list', () {
      final words = [
        for (var i = 0; i < 6; i++) TranscriptWord(text: 'はい', startUs: i * 300000, endUs: (i + 1) * 300000),
        const TranscriptWord(text: '終わり', startUs: 1800000, endUs: 2400000),
      ];
      final s = TranscriptSegment(startUs: 0, endUs: 2400000, text: 'はいはいはいはいはいはい終わり', words: words);
      final r = run([s], language: 'ja');
      expect(r.segments.single.text, 'はい終わり');
      expect(r.segments.single.words.length, 2);
    });

    test('can be switched off', () {
      final r = run(
        [seg(0, 2000, 'a'), seg(2000, 4000, 'a'), seg(4000, 6000, 'a'), seg(6000, 8000, 'a')],
        options: const NormalizerOptions(collapseRepeatedSegments: false, fixTiming: false),
      );
      expect(r.segments.length, 4);
    });
  });

  group('timing sanity', () {
    test('forces words monotonic and inside the segment', () {
      final s = TranscriptSegment(
        startUs: 1000000,
        endUs: 3000000,
        text: 'a b c d',
        words: const [
          TranscriptWord(text: 'a', startUs: 500000, endUs: 1500000), // starts before the segment
          TranscriptWord(text: 'b', startUs: 1200000, endUs: 1800000), // overlaps a
          TranscriptWord(text: 'c', startUs: 2000000, endUs: 1900000), // end before start
          TranscriptWord(text: 'd', startUs: 2500000, endUs: 4000000), // ends after the segment
        ],
      );
      final w = run([s]).segments.single.words;
      for (var i = 0; i < w.length; i++) {
        expect(w[i].startUs, greaterThanOrEqualTo(1000000));
        expect(w[i].endUs, lessThanOrEqualTo(3000000));
        expect(w[i].endUs, greaterThanOrEqualTo(w[i].startUs));
        if (i > 0) expect(w[i].startUs, greaterThanOrEqualTo(w[i - 1].endUs));
      }
    });

    test('gives zero-duration words 60 ms, borrowed from the following gap first', () {
      final s = TranscriptSegment(
        startUs: 0,
        endUs: 2000000,
        text: 'x y',
        words: const [
          TranscriptWord(text: 'x', startUs: 500000, endUs: 500000),
          TranscriptWord(text: 'y', startUs: 1000000, endUs: 1500000),
        ],
      );
      final w = run([s]).segments.single.words;
      expect(w[0].startUs, 500000);
      expect(w[0].endUs - w[0].startUs, 60000);
    });

    test('borrows from the preceding gap when there is none after', () {
      final s = TranscriptSegment(
        startUs: 0,
        endUs: 1000000,
        text: 'x y',
        words: const [
          TranscriptWord(text: 'x', startUs: 0, endUs: 400000),
          TranscriptWord(text: 'y', startUs: 1000000, endUs: 1000000),
        ],
      );
      final w = run([s]).segments.single.words;
      expect(w[1].endUs, 1000000);
      expect(w[1].endUs - w[1].startUs, 60000);
      expect(w[1].startUs, greaterThanOrEqualTo(w[0].endUs));
    });

    test('drops segments under 100 ms with one character or less', () {
      final r = run([seg(0, 50000 ~/ 1000, 'a', words: false), seg(1000, 3000, 'ok')]);
      expect(texts(r.segments), ['ok']);
      expect(r.report.tinySegmentsDropped, 1);
    });

    test('keeps a short segment with real text', () {
      final r = run([seg(0, 60, 'no', words: false)]);
      expect(texts(r.segments), ['no']);
    });

    test('output is sorted by start time', () {
      final r = run([seg(5000, 6000, 'later'), seg(1000, 2000, 'earlier')]);
      expect(texts(r.segments), ['earlier', 'later']);
    });
  });

  test('normalizing twice changes nothing (idempotent)', () {
    final input = [
      seg(0, 3000, '- Hello (laughs) there'),
      seg(3000, 5000, 'we we we we we go'),
      seg(5000, 6000, '[MUSIC]'),
      seg(6000, 9000, 'Thank you.', nsp: 0.6),
    ];
    final once = run(input);
    final twice = run(once.segments);
    expect(twice.segments, once.segments);
  });

  test('fromRaw converts WAV-relative time to absolute source time', () {
    final t = TranscriptSegment.fromRaw(
      const RawSegment(
        index: 0,
        chunk: 0,
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        text: ' Hi ',
        noSpeechProb: 0.1,
        avgLogProb: -0.3,
        words: [RawWord(text: ' Hi', start: Duration(seconds: 1), end: Duration(seconds: 2), probability: 0.9)],
      ),
      offsetUs: 5000000,
    );
    expect(t.startUs, 5000000 + 1000000);
    expect(t.words.single.text, 'Hi');
    expect(t.words.single.startUs, 5000000 + 1000000);
  });
}
