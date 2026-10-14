// OWNER: QA-06
//
// Scoring normalizer, tokenization and WER/CER counts (tool/eval/src/scoring.dart).

import 'package:flutter_test/flutter_test.dart';

import '../src/scoring.dart';

void main() {
  group('scoringNormalize', () {
    test('folds case, punctuation, apostrophes and whitespace', () {
      expect(scoringNormalize("  And so, my fellow   Americans: don't ASK!  "), 'and so my fellow americans dont ask');
      expect(scoringNormalize('“Quoted” — text…'), 'quoted text');
      expect(scoringNormalize('...'), '');
    });

    test('keeps letters of every script and combining marks', () {
      expect(scoringNormalize('こんにちは、世界。'), 'こんにちは 世界');
      expect(scoringNormalize('नमस्ते दुनिया!'), 'नमस्ते दुनिया');
      expect(scoringNormalize('مرحبا، بالعالم'), 'مرحبا بالعالم');
    });
  });

  group('tokens', () {
    test('words for space-delimited scripts and Korean, graphemes for CJK and no-space scripts', () {
      expect(usesWordErrorRate('en'), isTrue);
      expect(usesWordErrorRate('ko'), isTrue);
      expect(usesWordErrorRate('ja'), isFalse);
      expect(usesWordErrorRate('zh'), isFalse);
      expect(usesWordErrorRate('th'), isFalse);
      expect(scoringTokens('Hello, world.', 'en'), ['hello', 'world']);
      expect(scoringTokens('你好，世界。', 'zh'), ['你', '好', '世', '界']);
      expect(scoringTokens('', 'en'), isEmpty);
    });
  });

  group('alignTokens', () {
    test('identical sequences have no errors', () {
      final e = alignTokens(['a', 'b', 'c'], ['a', 'b', 'c']);
      expect(e.errors, 0);
      expect(e.rate, 0);
    });

    test('counts substitutions, deletions and insertions', () {
      expect(alignTokens(['a', 'b', 'c'], ['a', 'x', 'c']),
          const EditCounts(substitutions: 1, deletions: 0, insertions: 0, referenceLength: 3));
      expect(alignTokens(['a', 'b', 'c'], ['a', 'c']),
          const EditCounts(substitutions: 0, deletions: 1, insertions: 0, referenceLength: 3));
      expect(alignTokens(['a', 'b'], ['a', 'b', 'c', 'd']),
          const EditCounts(substitutions: 0, deletions: 0, insertions: 2, referenceLength: 2));
      expect(alignTokens(['the', 'cat', 'sat', 'on', 'the', 'mat'], ['the', 'cat', 'sit', 'on', 'mat', 'now']).errors, 3);
    });

    test('empty sides', () {
      expect(alignTokens(const [], const []).rate, 0);
      expect(alignTokens(const [], ['x']).rate, 1);
      expect(alignTokens(['x', 'y'], const []).rate, 1);
    });

    test('the error total equals the Levenshtein distance on random sequences', () {
      int lev(List<String> a, List<String> b) {
        var prev = List<int>.generate(b.length + 1, (j) => j);
        for (var i = 1; i <= a.length; i++) {
          final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
          for (var j = 1; j <= b.length; j++) {
            final c = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
            final d = prev[j] + 1;
            final ins = cur[j - 1] + 1;
            cur[j] = c < d ? (c < ins ? c : ins) : (d < ins ? d : ins);
          }
          prev = cur;
        }
        return prev[b.length];
      }

      var seed = 12345;
      int next(int n) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % n;
      }

      for (var k = 0; k < 200; k++) {
        final a = [for (var i = 0; i < next(12); i++) 'abcd'[next(4)]];
        final b = [for (var i = 0; i < next(12); i++) 'abcd'[next(4)]];
        final e = alignTokens(a, b);
        expect(e.errors, lev(a, b), reason: '$a vs $b');
        expect(e.referenceLength - e.deletions - e.substitutions, b.length - e.insertions - e.substitutions,
            reason: 'matched tokens agree on both sides');
      }
    });
  });

  test('WER and CER of the jfk reference against a typical whisper output', () {
    const ref = 'And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.';
    const hyp = 'And so my fellow Americans ask not what your country can do for you ask what you can do for your country';
    expect(wordEdits(ref, hyp, 'en').rate, 0);
    expect(wordEdits(ref, '$hyp thank you', 'en').insertions, 2);
    expect(characterEdits(ref, hyp).rate, 0);
  });

  test('corpus counts add', () {
    const a = EditCounts(substitutions: 1, deletions: 2, insertions: 3, referenceLength: 10);
    const b = EditCounts(substitutions: 0, deletions: 0, insertions: 1, referenceLength: 10);
    expect((a + b).rate, closeTo(7 / 20, 1e-12));
  });
}
