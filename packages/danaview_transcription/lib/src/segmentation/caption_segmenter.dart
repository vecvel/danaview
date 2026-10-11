// OWNER: AI-11
//
// The deterministic caption segmenter (ai.md §9.3): timed words in, subtitle cue drafts out.
//
// 1. Cue boundaries by dynamic programming over the words (a cue spans at most 48 words); the cost
//    of a cue is the sum of: a fit limit (lines x characters, hard), a hard limit on internal
//    gaps (>= 1.2 s) and on the span (max duration + 0.5 s), a penalty for a too short or too
//    fast cue measured on its displayed duration, the quality of the break after it, a penalty
//    for crossing a cut point, and a constant per cue (fewer, fuller cues).
// 2. Line breaking inside a cue: balanced lines with a pyramid preference, punctuation bonus,
//    function words and kinsoku penalised, over-long words hard-wrapped at a grapheme boundary.
// 3. Timing on the project frame grid: start = floor to the frame, end = last word + linger,
//    extended to the minimum duration, chained to the next cue when the gap is small, never
//    closer to the next cue than the minimum gap; a cue that cannot keep one frame is merged with
//    its neighbour.
//
// Pure and deterministic: no hash-map iteration, stable tie-breaks (the shorter cue wins a tie).

import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:danaview_editor_core/model.dart';

import '../languages/languages.dart';
import 'caption_layout.dart';
import 'caption_text.dart';
import 'timed_word.dart';

/// Turns timed words into cues.
abstract interface class CaptionSegmenter {
  /// Segments [words] (timeline time, any order) into cues. Pure and deterministic.
  List<SubtitleCueDraft> segment(List<TimedWord> words, SegmentationContext context);
}

/// The dynamic-programming segmenter.
final class DpCaptionSegmenter implements CaptionSegmenter {
  /// Creates the segmenter.
  const DpCaptionSegmenter();

  /// Most words in one cue.
  static const int maxCueWords = 48;

  /// A pause this long inside a cue forces a break.
  static const TimeUs maxInternalGapUs = 1200000;

  /// A cue's words may span at most `maxDuration` plus this slack.
  static const TimeUs durationSlackUs = 500000;

  /// A gap this long counts as a natural break.
  static const TimeUs naturalBreakGapUs = 500000;

  /// Cost of a sentence end inside a cue (prefers one cue per sentence when the limits allow).
  static const double internalSentencePenalty = 1.5;

  /// Cost of a cue that crosses a cut point.
  static const double cutCrossingPenalty = 3;

  @override
  List<SubtitleCueDraft> segment(List<TimedWord> words, SegmentationContext context) {
    final prepared = <TimedWord>[
      for (final w in words)
        if (w.text.trim().isNotEmpty) w.copyWith(text: w.text.trim(), end: w.end < w.start ? w.start : w.end),
    ];
    if (prepared.isEmpty) return const [];
    // Stable sort: equal starts keep their input order.
    final indexed = [for (var i = 0; i < prepared.length; i++) (i, prepared[i])]..sort((a, b) {
        final c = a.$2.start.compareTo(b.$2.start);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return _Run([for (final e in indexed) e.$2], context).run();
  }
}

/// Fraction of [drafts] whose reading speed exceeds [maxCps] (graphemes without line breaks per
/// second). More than 20% triggers "Captions may be hard to read on sped-up clips" (ai.md §10.1).
double fractionOverReadingSpeed(List<SubtitleCueDraft> drafts, double maxCps) {
  if (drafts.isEmpty) return 0;
  var over = 0;
  for (final d in drafts) {
    final seconds = d.range.duration / microsPerSecond;
    final chars = d.text.replaceAll('\n', ' ').characters.length;
    if (seconds <= 0 || chars / seconds > maxCps + 1e-9) over++;
  }
  return over / drafts.length;
}

bool _isLatinChar(String g) {
  final r = g.runes.first;
  return (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
}

class _Run {
  _Run(this.words, this.ctx)
      : layout = CaptionLayout.resolve(ctx.settings, ctx.script, portrait: ctx.portrait),
        n = words.length,
        rate = ctx.frameRate,
        atoms = ctx.script == ScriptProfile.spaceDelimited || ctx.script == ScriptProfile.korean,
        func = functionWordsFor(ctx.language) {
    glen = Int32List(n);
    sp = Uint8List(n);
    lenPrefix = Int32List(n + 1);
    spPrefix = Int32List(n + 1);
    start = Int64List(n);
    end = Int64List(n);
    sentencePrefix = Int32List(n + 1);
    clipChangePrefix = Int32List(n + 1);
    nextNoStart = Uint8List(n);
    endsOpener = Uint8List(n);
    endsClause = Uint8List(n);
    endsSentence = Uint8List(n);
    linking = Uint8List(n);
    nextCut = Int64List(n);

    final cuts = ctx.cutPoints;
    var cutIdx = 0;
    for (var k = 0; k < n; k++) {
      final w = words[k];
      final chars = w.text.characters;
      glen[k] = chars.length;
      sp[k] = k > 0 && wordsNeedSpace(words[k - 1].text, w.text) ? 1 : 0;
      lenPrefix[k + 1] = lenPrefix[k] + glen[k];
      spPrefix[k + 1] = spPrefix[k] + sp[k];
      start[k] = w.start;
      end[k] = w.end;
      endsSentence[k] = w.endsSentence ? 1 : 0;
      endsClause[k] = w.endsClause ? 1 : 0;
      sentencePrefix[k + 1] = sentencePrefix[k] + endsSentence[k];
      clipChangePrefix[k + 1] = clipChangePrefix[k] + (k > 0 && words[k - 1].clip != w.clip ? 1 : 0);
      nextNoStart[k] = isKinsokuNoStart(chars.first) ? 1 : 0;
      endsOpener[k] = isKinsokuNoEnd(chars.last) ? 1 : 0;
      linking[k] = func.isLinking(w.text) ? 1 : 0;
      while (cutIdx < cuts.length && cuts[cutIdx] <= w.start) {
        cutIdx++;
      }
      nextCut[k] = cutIdx < cuts.length ? cuts[cutIdx] : 0x7fffffffffffffff;
    }
    gapUs = layout.minGapFrames * rate.frameUs;
  }

  final List<TimedWord> words;
  final SegmentationContext ctx;
  final CaptionLayout layout;
  final int n;
  final FrameRate rate;
  final bool atoms;
  final FunctionWords func;

  late final Int32List glen;
  late final Uint8List sp;
  late final Int32List lenPrefix;
  late final Int32List spPrefix;
  late final Int64List start;
  late final Int64List end;
  late final Int32List sentencePrefix;
  late final Int32List clipChangePrefix;
  late final Uint8List nextNoStart;
  late final Uint8List endsOpener;
  late final Uint8List endsClause;
  late final Uint8List endsSentence;
  late final Uint8List linking;
  late final Int64List nextCut;
  late final int gapUs;

  int get _c => layout.maxCharsPerLine;
  int get _l => layout.maxLines;

  List<SubtitleCueDraft> run() {
    final groups = _boundaries();
    return _timeAndText(groups);
  }

  // -------------------------------------------------------------------------------------------
  // Step 1: cue boundaries.
  // -------------------------------------------------------------------------------------------

  /// Characters of the cue `i..j` with the spaces between its words.
  int _total(int i, int j) => (lenPrefix[j + 1] - lenPrefix[i]) + (spPrefix[j + 1] - spPrefix[i + 1]);

  bool _fits(int i, int j, int total) {
    if (i == j) return true;
    if (!atoms) return total <= _l * _c;
    if (total <= _c) return true;
    if (_l <= 1) return false;
    var lines = 1;
    var cur = 0;
    for (var k = i; k <= j; k++) {
      if (glen[k] > _c) return false;
      if (k == i) {
        cur = glen[k];
      } else if (cur + sp[k] + glen[k] <= _c) {
        cur += sp[k] + glen[k];
      } else {
        lines++;
        if (lines > _l) return false;
        cur = glen[k];
      }
    }
    return true;
  }

  double _cueCost(int i, int j, int total) {
    var cost = 1.0;
    final first = start[i];
    final lastEnd = end[j];
    var shown = lastEnd + layout.lingerUs;
    final minEnd = first + layout.minDurationUs;
    if (minEnd > shown) shown = minEnd;
    if (j + 1 < n) {
      final limit = start[j + 1] - gapUs;
      final floor = lastEnd;
      final cap = limit > floor ? limit : floor;
      if (shown > cap) shown = cap;
    }
    var shownDur = shown - first;
    if (shownDur < 1000) shownDur = 1000;
    if (shownDur < layout.minDurationUs) cost += 8 * (layout.minDurationUs - shownDur) / microsPerSecond;
    final cps = total / (shownDur / microsPerSecond);
    if (cps > layout.maxCps) cost += 4 * (cps - layout.maxCps);

    if (j == n - 1) {
      // The last cue ends at a natural break.
    } else {
      final gap = start[j + 1] - end[j];
      var q = 5;
      if (endsSentence[j] == 1 || gap >= DpCaptionSegmenter.naturalBreakGapUs) {
        q = 0;
      } else if (endsClause[j] == 1) {
        q = 1;
      } else if (linking[j + 1] == 1) {
        q = 2;
      }
      if (nextNoStart[j + 1] == 1) q += 6;
      if (endsOpener[j] == 1) q += 6;
      cost += q;
    }

    cost += DpCaptionSegmenter.internalSentencePenalty * (sentencePrefix[j] - sentencePrefix[i]);
    if (nextCut[i] < end[j] || clipChangePrefix[j + 1] - clipChangePrefix[i + 1] > 0) {
      cost += DpCaptionSegmenter.cutCrossingPenalty;
    }
    return cost;
  }

  List<(int, int)> _boundaries() {
    final best = List<double>.filled(n + 1, double.infinity);
    final from = List<int>.filled(n + 1, 0);
    best[0] = 0;
    final capacity = _l * _c;
    final maxSpan = layout.maxDurationUs + DpCaptionSegmenter.durationSlackUs;
    for (var j = 0; j < n; j++) {
      final lo = j - (DpCaptionSegmenter.maxCueWords - 1) < 0 ? 0 : j - (DpCaptionSegmenter.maxCueWords - 1);
      for (var i = j; i >= lo; i--) {
        if (i < j) {
          if (start[i + 1] - end[i] >= DpCaptionSegmenter.maxInternalGapUs) break;
          if (end[j] - start[i] > maxSpan) break;
        }
        final total = _total(i, j);
        if (i < j) {
          if (total > capacity) break;
          if (!_fits(i, j, total)) break;
        }
        final c = best[i] + _cueCost(i, j, total);
        if (c < best[j + 1] - 1e-9) {
          best[j + 1] = c;
          from[j + 1] = i;
        }
      }
    }
    final out = <(int, int)>[];
    var j = n;
    while (j > 0) {
      final i = from[j];
      out.add((i, j - 1));
      j = i;
    }
    return out.reversed.toList();
  }

  // -------------------------------------------------------------------------------------------
  // Step 3: timing (and merging cues that cannot keep a frame).
  // -------------------------------------------------------------------------------------------

  int _nearestFrame(TimeUs t) => rate.frameIndexOf(rate.quantizeNearest(t));

  int _ceilFrame(TimeUs t) {
    final k = rate.frameIndexOf(t);
    return rate.timeOfFrame(k) < t ? k + 1 : k;
  }

  List<SubtitleCueDraft> _timeAndText(List<(int, int)> groups) {
    final out = <SubtitleCueDraft>[];
    final minFrames = _ceilFrame(layout.minDurationUs);
    final chainFrames = _ceilFrame(layout.chainGapUs);
    final maxFrames = rate.frameIndexOf(layout.maxDurationUs + DpCaptionSegmenter.durationSlackUs);
    final g = List<(int, int)>.of(groups);
    var gi = 0;
    while (gi < g.length) {
      final (a, b) = g[gi];
      final sF = rate.frameIndexOf(start[a]);
      final wordEndF = _ceilFrame(end[b]);
      var eF = _nearestFrame(end[b] + layout.lingerUs);
      if (eF < sF + minFrames) eF = sF + minFrames;
      final capF = sF + maxFrames > wordEndF ? sF + maxFrames : wordEndF;
      if (eF > capF) eF = capF;
      if (gi + 1 < g.length) {
        final nextF = rate.frameIndexOf(start[g[gi + 1].$1]);
        final limitF = nextF - layout.minGapFrames;
        if (nextF - eF < chainFrames && limitF > eF && limitF <= capF) eF = limitF;
        if (eF > limitF) eF = limitF;
        if (eF < sF + 1) {
          // Too close to the next cue to keep a frame: merge with it.
          g[gi] = (a, g[gi + 1].$2);
          g.removeAt(gi + 1);
          continue;
        }
      } else if (eF < sF + 1) {
        eF = sF + 1;
      }
      out.add(SubtitleCueDraft(TimeRange(rate.timeOfFrame(sF), rate.timeOfFrame(eF)), _text(a, b)));
      gi++;
    }
    return out;
  }

  // -------------------------------------------------------------------------------------------
  // Step 2: line breaking.
  // -------------------------------------------------------------------------------------------

  String _text(int a, int b) {
    // Items: words (space-delimited scripts) or graphemes (CJK, no-space); a word wider than a
    // line is split into graphemes as well so it can be hard-wrapped.
    final text = <String>[];
    final ilen = <int>[];
    final isp = <int>[];
    final pen = <double>[]; // penalty of a break AFTER the item
    final wordBoundary = <bool>[]; // the item ends a word
    for (var k = a; k <= b; k++) {
      final w = words[k].text;
      final chars = w.characters.toList();
      final split = !atoms || chars.length > _c;
      if (!split) {
        text.add(w);
        ilen.add(chars.length);
        isp.add(k > a ? sp[k] : 0);
        wordBoundary.add(true);
        var p = 0.0;
        if (endsSentence[k] == 1) {
          p -= 6;
        } else if (endsClause[k] == 1) {
          p -= 3;
        }
        if (func.isFunctionWord(w)) p += 4;
        if (k < b && nextNoStart[k + 1] == 1) p += 50;
        if (endsOpener[k] == 1) p += 50;
        pen.add(p);
      } else {
        for (var c = 0; c < chars.length; c++) {
          final g = chars[c];
          final last = c == chars.length - 1;
          text.add(g);
          ilen.add(1);
          isp.add(c == 0 && k > a ? sp[k] : 0);
          wordBoundary.add(last);
          var p = last ? 0.0 : (atoms ? 3.0 : 8.0);
          if (last) {
            if (endsSentence[k] == 1) {
              p -= 6;
            } else if (endsClause[k] == 1) {
              p -= 3;
            }
          } else if (isKinsokuNoStart(chars[c + 1])) {
            p += 50;
          } else if (_isLatinChar(g) && _isLatinChar(chars[c + 1])) {
            p += 20; // keep Latin words inside CJK text whole
          }
          if (isKinsokuNoEnd(g)) p += 50;
          if (last && k < b && nextNoStart[k + 1] == 1) p += 50;
          pen.add(p);
        }
      }
    }

    final lines = _layoutLines(ilen, isp, pen);
    final buffer = StringBuffer();
    for (var li = 0; li < lines.length; li++) {
      if (li > 0) buffer.write('\n');
      final (from, to) = lines[li];
      for (var k = from; k < to; k++) {
        if (k > from && isp[k] == 1) buffer.write(' ');
        buffer.write(text[k]);
      }
    }
    return buffer.toString();
  }

  /// Splits the items into the fewest lines that fit and balances them.
  List<(int, int)> _layoutLines(List<int> ilen, List<int> isp, List<double> pen) {
    final m = ilen.length;
    final c = _c;
    int lineLen(int from, int to) {
      var len = 0;
      for (var k = from; k < to; k++) {
        len += ilen[k] + (k > from ? isp[k] : 0);
      }
      return len;
    }

    if (lineLen(0, m) <= c || _l <= 1) {
      // One line fits, or a one-line layout: wrap greedily only if a line overflows.
      if (lineLen(0, m) <= c) return [(0, m)];
      return _greedy(ilen, isp);
    }

    // Fewest lines by greedy filling.
    final greedy = _greedy(ilen, isp);
    final lines = greedy.length;
    if (lines <= 1) return greedy;
    final total = lineLen(0, m);
    final target = total / lines;

    // dp[l][k]: best cost of covering items [0, k) with l lines.
    const inf = double.infinity;
    final dp = List.generate(lines + 1, (_) => List<double>.filled(m + 1, inf));
    final back = List.generate(lines + 1, (_) => List<int>.filled(m + 1, 0));
    dp[0][0] = 0;
    for (var l = 1; l <= lines; l++) {
      for (var k = l; k <= m; k++) {
        for (var s = k - 1; s >= l - 1; s--) {
          final len = lineLen(s, k);
          if (len > c) break;
          if (dp[l - 1][s] == inf) continue;
          var cost = dp[l - 1][s] + (len - target).abs();
          if (s > 0) cost += pen[s - 1];
          if (cost < dp[l][k] - 1e-9) {
            dp[l][k] = cost;
            back[l][k] = s;
          }
        }
      }
    }
    if (dp[lines][m] == inf) return greedy;
    final out = <(int, int)>[];
    var k = m;
    for (var l = lines; l >= 1; l--) {
      final s = back[l][k];
      out.add((s, k));
      k = s;
    }
    final result = out.reversed.toList();
    if (lines == 2) {
      // Pyramid shape: prefer the bottom line equal or longer. Re-pick with the bias.
      var bestCost = inf;
      var bestBreak = result[0].$2;
      for (var s = 1; s < m; s++) {
        final l1 = lineLen(0, s);
        final l2 = lineLen(s, m);
        if (l1 > c || l2 > c) continue;
        final cost = (l1 - l2).abs() + (l1 > l2 ? 2 : 0) + pen[s - 1];
        if (cost < bestCost - 1e-9) {
          bestCost = cost;
          bestBreak = s;
        }
      }
      return [(0, bestBreak), (bestBreak, m)];
    }
    return result;
  }

  List<(int, int)> _greedy(List<int> ilen, List<int> isp) {
    final out = <(int, int)>[];
    var from = 0;
    var cur = 0;
    for (var k = 0; k < ilen.length; k++) {
      if (k == from) {
        cur = ilen[k];
      } else if (cur + isp[k] + ilen[k] <= _c) {
        cur += isp[k] + ilen[k];
      } else {
        out.add((from, k));
        from = k;
        cur = ilen[k];
      }
    }
    out.add((from, ilen.length));
    return out;
  }
}
