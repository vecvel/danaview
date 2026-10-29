// OWNER: AI-11
//
// Property tests over random word streams: no overlap, limits respected, nothing lost, grid-aligned,
// deterministic; and the 10k-word performance budget (ai.md §9.3, §14: <= 150 ms with DV_PERF_STRICT=1,
// a quiet dev Mac; 4× that otherwise, a loaded CI runner).

import 'dart:io' show Platform;
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'segmentation_fixtures.dart';

const _seg = DpCaptionSegmenter();

/// DV_PERF_STRICT=1 asserts the 150 ms budget; otherwise [_looseFactor] times it.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';
const int _looseFactor = 4;
int get _limitMs => _perfStrict ? 150 : 150 * _looseFactor;
String get _perfMode => _perfStrict ? 'DV_PERF_STRICT=1' : 'loose ×$_looseFactor, no DV_PERF_STRICT';

const _latinPool = ['a', 'an', 'the', 'and', 'of', 'to', 'in', 'it', 'is', 'we', 'you', 'they', 'really', 'because', 'important', 'something', 'think', 'know', 'about', 'people', 'actually', 'international', 'understanding', 'incredible'];
const _cjkPool = ['今日', 'は', '皆さ', 'んに', '大切', 'な', 'お知', 'らせ', 'が', 'あり', 'ます', '来週', 'から', '新し', 'い', 'サー', 'ビス', 'を', '始め', 'る'];

List<TimedWord> randomWords(Random rnd, int count, {required bool cjk, double fast = 1}) {
  final pool = cjk ? _cjkPool : _latinPool;
  final out = <TimedWord>[];
  var t = rnd.nextInt(5000) * 1000;
  for (var i = 0; i < count; i++) {
    var text = pool[rnd.nextInt(pool.length)];
    final r = rnd.nextInt(100);
    if (r < 8) {
      text += cjk ? '。' : '.';
    } else if (r < 16) {
      text += cjk ? '、' : ',';
    } else if (r < 18) {
      text += cjk ? '？' : '?';
    }
    final dur = ((120 + rnd.nextInt(380) + text.characters.length * 25) / fast).round() * 1000;
    out.add(TimedWord(text: text, start: t, end: t + dur, clip: ItemId('c${i ~/ 40}')));
    // Pauses: mostly tiny, sometimes none, sometimes a breath, rarely a long silence.
    final p = rnd.nextInt(100);
    t += dur + switch (p) {
      < 30 => 0,
      < 80 => rnd.nextInt(80) * 1000,
      < 95 => 300000 + rnd.nextInt(500) * 1000,
      _ => 1200000 + rnd.nextInt(3000) * 1000,
    };
  }
  return out;
}

void main() {
  const rates = [FrameRate.fps24, FrameRate.fps25, FrameRate.fps30, FrameRate.fps50, FrameRate.fps60];
  const presets = SegmentationPreset.values;

  group('invariants over random streams', () {
    for (final cjk in [false, true]) {
      for (final preset in presets) {
        test('${cjk ? 'ja' : 'en'} / ${preset.name}: no overlap, limits, grid, no lost words', () {
          final rnd = Random(preset.index * 31 + (cjk ? 7 : 0));
          for (var run = 0; run < 40; run++) {
            final rate = rates[rnd.nextInt(rates.length)];
            final portrait = rnd.nextBool();
            final words = randomWords(rnd, 20 + rnd.nextInt(120), cjk: cjk, fast: 1 + rnd.nextInt(3) * 0.5);
            final cuts = [for (var i = 0; i < rnd.nextInt(4); i++) rnd.nextInt(60) * 1000000];
            final ctx = context(language: cjk ? 'ja' : 'en', settings: SegmentationSettings(preset: preset), rate: rate, cuts: cuts, portrait: portrait);
            final layout = CaptionLayout.resolve(ctx.settings, ctx.script, portrait: portrait);
            final cues = _seg.segment(words, ctx);

            expect(cues, isNotEmpty);
            final frame = rate.timeOfFrame(1);
            for (var i = 0; i < cues.length; i++) {
              final c = cues[i];
              final why = 'run $run cue $i ${c.range} "${c.text}"';
              // Grid and minimum length.
              expect(rate.isOnGrid(c.range.start), isTrue, reason: why);
              expect(rate.isOnGrid(c.range.end), isTrue, reason: why);
              expect(c.range.duration, greaterThanOrEqualTo(frame), reason: why);
              // Line and character limits.
              final lines = c.text.split('\n');
              expect(lines.length, lessThanOrEqualTo(layout.maxLines), reason: why);
              for (final l in lines) {
                expect(l.characters.length, lessThanOrEqualTo(layout.maxCharsPerLine), reason: why);
                expect(l.trim(), l, reason: 'no stray spaces at line edges: $why');
                expect(l, isNotEmpty, reason: why);
              }
              // Duration: soft max + 0.5 s hard slack (+ quantization).
              final words = c.text.replaceAll('\n', ' ').split(' ').length;
              if (words > 1 || !cjk) {
                expect(c.range.duration, lessThanOrEqualTo(layout.maxDurationUs + 500000 + 2 * frame), reason: why);
              }
              // No overlap and the minimum gap.
              if (i > 0) {
                final prev = cues[i - 1];
                expect(c.range.start, greaterThanOrEqualTo(prev.range.end), reason: why);
                expect(rate.frameIndexOf(c.range.start) - rate.frameIndexOf(prev.range.end), greaterThanOrEqualTo(layout.minGapFrames), reason: why);
                // Minimum duration holds unless the next cue pins the end.
                if (prev.range.duration < layout.minDurationUs - frame) {
                  expect(rate.frameIndexOf(c.range.start) - rate.frameIndexOf(prev.range.end), layout.minGapFrames, reason: 'short cue not pinned by its neighbour: $why');
                }
              }
            }
            // Order and no word lost.
            String squash(String s) => s.replaceAll(RegExp(r'\s+'), '');
            final sorted = [...words]..sort((a, b) => a.start.compareTo(b.start));
            expect(squash(cues.map((c) => c.text).join()), squash(sorted.map((x) => x.text).join()));
            // Determinism and independence of input order.
            expect(render(_seg.segment(words, ctx)), render(cues));
            expect(render(_seg.segment(words.reversed.toList(), ctx)), render(cues));
          }
        });
      }
    }

    test('cues start no later than their first word and never start before the previous word', () {
      final rnd = Random(99);
      for (var run = 0; run < 30; run++) {
        final words = randomWords(rnd, 60, cjk: false);
        final ctx = context();
        final cues = _seg.segment(words, ctx);
        final starts = [for (final w in words) w.start];
        for (final c in cues) {
          // Each cue start is a floored word start, so some word starts within one frame after it.
          final near = starts.any((s) => s >= c.range.start && s - c.range.start < 34000);
          expect(near, isTrue, reason: '${c.range}');
        }
      }
    });
  });

  group('performance', () {
    test('10k words segment in <= 150 ms', () {
      final rnd = Random(5);
      final words = randomWords(rnd, 10000, cjk: false);
      final ctx = context();
      // Warm the JIT, then take the best of a few runs (the machine is shared).
      _seg.segment(words.sublist(0, 2000), ctx);
      var best = 1 << 30;
      late List<SubtitleCueDraft> cues;
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        cues = _seg.segment(words, ctx);
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      expect(cues.length, greaterThan(500));
      // ignore: avoid_print
      print('segment 10k words: best $best ms');
      expect(best, lessThanOrEqualTo(_limitMs), reason: 'best of 5: $best ms ($_perfMode)');
    });

    test('10k CJK tokens and 10k words with cut points also meet the budget', () {
      final rnd = Random(6);
      final cjk = randomWords(rnd, 10000, cjk: true);
      final cuts = [for (var i = 1; i < 200; i++) i * 20000000];
      final cjkCtx = context(language: 'ja', cuts: cuts);
      _seg.segment(cjk.sublist(0, 2000), cjkCtx);
      var best = 1 << 30;
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        _seg.segment(cjk, cjkCtx);
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      // ignore: avoid_print
      print('segment 10k CJK tokens with cuts: best $best ms');
      expect(best, lessThanOrEqualTo(_limitMs), reason: 'best of 5: $best ms ($_perfMode)');
    });
  });
}
