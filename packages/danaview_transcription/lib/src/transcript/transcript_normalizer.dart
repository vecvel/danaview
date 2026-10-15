// OWNER: AI-10
//
// Normalization and filtering of raw segments before caching (ai.md §8.3). Every rule is a pure
// function of its input and can be toggled with [NormalizerOptions]:
//
// 1. trim and collapse whitespace, strip a leading `"- "` dialogue dash;
// 2. non-speech annotations (`[..]`, `(..)`, `♪..♪`, `*..*`) removed, segments that were only
//    annotations dropped (skipped when sound descriptions are wanted);
// 3. silence hallucinations: `nsp > 0.5 && lp < -0.8`, and the per-language phrase list gated by
//    `nsp > 0.3` or a short segment ending the unit;
// 4. repetition loops: 3+ identical consecutive segments collapse to the first, 4+ identical
//    consecutive words inside a segment collapse to one;
// 5. timing sanity: words monotonic and inside their segment, zero-duration words get 60 ms
//    borrowed from the neighbouring gaps, segments under 100 ms with at most one character drop.

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../catalog/tuning.dart';
import '../languages/languages.dart';
import 'hallucination_phrases.dart';
import 'transcript_models.dart';

/// Which normalization rules run, and their thresholds (defaults are the ai.md §8.3 values).
@immutable
final class NormalizerOptions {
  /// Creates options; everything is on by default.
  const NormalizerOptions({
    this.collapseWhitespace = true,
    this.stripLeadingDash = true,
    this.removeAnnotations = true,
    this.dropPunctuationOnly = true,
    this.gateSilenceHallucinations = true,
    this.gatePhrases = true,
    this.collapseRepeatedWords = true,
    this.collapseRepeatedSegments = true,
    this.fixTiming = true,
    this.noSpeechDropThreshold = SpeechTuning.hallucinationNoSpeech,
    this.logprobDropThreshold = SpeechTuning.hallucinationLogprob,
    this.phraseNoSpeechThreshold = SpeechTuning.hallucinationPhraseNoSpeech,
    this.shortEndSegment = const Duration(milliseconds: 1200),
    this.segmentRepeatRun = 3,
    this.wordRepeatRun = 4,
    this.minWordDuration = const Duration(milliseconds: 60),
    this.minSegmentDuration = const Duration(milliseconds: 100),
  });

  /// Trim and collapse whitespace.
  final bool collapseWhitespace;

  /// Strip a leading `"- "`.
  final bool stripLeadingDash;

  /// Remove `[..]`, `(..)`, `♪..♪`, `*..*` spans (turn off when sound descriptions are wanted).
  final bool removeAnnotations;

  /// Drop segments that contain no letter or digit after cleaning.
  final bool dropPunctuationOnly;

  /// Drop segments with `nsp > noSpeechDropThreshold && lp < logprobDropThreshold`.
  final bool gateSilenceHallucinations;

  /// Drop gated hallucination phrases.
  final bool gatePhrases;

  /// Collapse words repeated [wordRepeatRun] or more times.
  final bool collapseRepeatedWords;

  /// Collapse [segmentRepeatRun] or more identical consecutive segments.
  final bool collapseRepeatedSegments;

  /// Force monotonic word timing, give zero-length words time, drop tiny segments.
  final bool fixTiming;

  /// `nsp` above which a low-confidence segment is a silence hallucination.
  final double noSpeechDropThreshold;

  /// `lp` below which a high-`nsp` segment is a silence hallucination.
  final double logprobDropThreshold;

  /// `nsp` above which a phrase-list match is dropped.
  final double phraseNoSpeechThreshold;

  /// A phrase match that ends the unit and is shorter than this is dropped regardless of `nsp`.
  final Duration shortEndSegment;

  /// Consecutive identical segments (including the first) that form a loop.
  final int segmentRepeatRun;

  /// Consecutive identical words that form a loop.
  final int wordRepeatRun;

  /// Duration given to zero-duration words.
  final Duration minWordDuration;

  /// Segments shorter than this with at most one character are dropped.
  final Duration minSegmentDuration;

  /// A copy with the given fields replaced.
  NormalizerOptions copyWith({bool? removeAnnotations}) => NormalizerOptions(
        collapseWhitespace: collapseWhitespace,
        stripLeadingDash: stripLeadingDash,
        removeAnnotations: removeAnnotations ?? this.removeAnnotations,
        dropPunctuationOnly: dropPunctuationOnly,
        gateSilenceHallucinations: gateSilenceHallucinations,
        gatePhrases: gatePhrases,
        collapseRepeatedWords: collapseRepeatedWords,
        collapseRepeatedSegments: collapseRepeatedSegments,
        fixTiming: fixTiming,
        noSpeechDropThreshold: noSpeechDropThreshold,
        logprobDropThreshold: logprobDropThreshold,
        phraseNoSpeechThreshold: phraseNoSpeechThreshold,
        shortEndSegment: shortEndSegment,
        segmentRepeatRun: segmentRepeatRun,
        wordRepeatRun: wordRepeatRun,
        minWordDuration: minWordDuration,
        minSegmentDuration: minSegmentDuration,
      );
}

/// What a normalization pass removed or changed (counts only, never text).
@immutable
final class NormalizationReport {
  /// Creates a report.
  const NormalizationReport({
    this.annotationSegmentsDropped = 0,
    this.annotationSpansRemoved = 0,
    this.silenceHallucinationsDropped = 0,
    this.phraseHallucinationsDropped = 0,
    this.repeatedSegmentsCollapsed = 0,
    this.repeatedWordsCollapsed = 0,
    this.timingAdjustments = 0,
    this.tinySegmentsDropped = 0,
    this.emptySegmentsDropped = 0,
  });

  /// Segments that were only annotations.
  final int annotationSegmentsDropped;

  /// Annotation spans removed from kept segments.
  final int annotationSpansRemoved;

  /// Segments dropped by the `nsp`/`lp` gate.
  final int silenceHallucinationsDropped;

  /// Segments dropped by the phrase list.
  final int phraseHallucinationsDropped;

  /// Segments removed from repetition loops.
  final int repeatedSegmentsCollapsed;

  /// Words removed from in-segment repetition loops.
  final int repeatedWordsCollapsed;

  /// Words whose timing was corrected.
  final int timingAdjustments;

  /// Segments dropped for being tiny.
  final int tinySegmentsDropped;

  /// Segments dropped for having no text (also punctuation-only).
  final int emptySegmentsDropped;

  /// Total segments removed.
  int get segmentsDropped =>
      annotationSegmentsDropped +
      silenceHallucinationsDropped +
      phraseHallucinationsDropped +
      repeatedSegmentsCollapsed +
      tinySegmentsDropped +
      emptySegmentsDropped;
}

/// The normalized segments and what changed.
@immutable
final class NormalizedTranscript {
  /// Creates the result.
  const NormalizedTranscript(this.segments, this.report);

  /// Cleaned segments in source order.
  final List<TranscriptSegment> segments;

  /// Counts of what the rules did.
  final NormalizationReport report;
}

/// Normalizes raw whisper segments (ai.md §8.3). Stateless and deterministic.
final class TranscriptNormalizer {
  /// Creates a normalizer.
  const TranscriptNormalizer([this.options = const NormalizerOptions()]);

  /// Rule switches and thresholds.
  final NormalizerOptions options;

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _hasLetterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  // Closed annotation spans, longest alternatives first. A lone music note opens a span that runs
  // to the end of the segment (singing / music with no closing mark).
  static final RegExp _annotation = RegExp(
    r'\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】|\*[^*\n]+\*|[♪♫][^♪♫]*[♪♫]|[♪♫].*$|\u{1F3B5}[^\u{1F3B5}]*\u{1F3B5}|\u{1F3B5}.*$',
    unicode: true,
    dotAll: true,
  );

  /// Normalizes [segments] of one unit. [language] is the whisper code of the transcript (picks
  /// the phrase list and the word-joining rule); [unitEndUs] is the end of the unit's source
  /// range, used to recognise a short segment that ends it (defaults to the last segment's end).
  NormalizedTranscript normalize(
    Iterable<TranscriptSegment> segments, {
    required String language,
    TimeUs? unitEndUs,
  }) {
    final spaced =
        (languageForWhisperCode(language)?.script ?? ScriptProfile.spaceDelimited) == ScriptProfile.spaceDelimited;
    var annotationSegments = 0;
    var annotationSpans = 0;
    var silence = 0;
    var phrase = 0;
    var repeatedWords = 0;
    var repeatedSegments = 0;
    var timing = 0;
    var tiny = 0;
    var empty = 0;

    final sorted = segments.toList()
      ..sort((a, b) => a.startUs != b.startUs ? a.startUs.compareTo(b.startUs) : a.endUs.compareTo(b.endUs));
    final endOfUnit = unitEndUs ?? (sorted.isEmpty ? 0 : sorted.map((s) => s.endUs).reduce((a, b) => a > b ? a : b));

    // Rules 1-2 and 5 (part): per-segment cleaning.
    var cleaned = <TranscriptSegment>[];
    for (final original in sorted) {
      var seg = original;
      if (options.removeAnnotations) {
        final r = _removeAnnotations(seg);
        if (r != null) {
          annotationSpans += r.spans;
          seg = r.segment;
          if (!_hasLetterOrDigit.hasMatch(seg.text)) {
            annotationSegments++;
            continue;
          }
        }
      }
      var text = seg.text;
      if (options.collapseWhitespace) text = text.replaceAll(_spaces, ' ').trim();
      if (options.stripLeadingDash) text = text.replaceFirst(RegExp(r'^(?:-\s+)+'), '');
      if (text != seg.text) seg = seg.copyWith(text: text);
      if (text.isEmpty) {
        empty++;
        continue;
      }
      if (options.dropPunctuationOnly && !_hasLetterOrDigit.hasMatch(text)) {
        empty++;
        continue;
      }
      cleaned.add(seg);
    }

    // Rule 3: silence hallucinations.
    final gated = <TranscriptSegment>[];
    for (var i = 0; i < cleaned.length; i++) {
      final seg = cleaned[i];
      if (options.gateSilenceHallucinations &&
          seg.noSpeechProb > options.noSpeechDropThreshold &&
          seg.avgLogProb < options.logprobDropThreshold) {
        silence++;
        continue;
      }
      if (options.gatePhrases && _matchesPhrase(seg.text, language)) {
        final shortAtEnd = seg.durationUs < options.shortEndSegment.inMicroseconds &&
            (i == cleaned.length - 1 || seg.endUs >= endOfUnit - 500000);
        if (seg.noSpeechProb > options.phraseNoSpeechThreshold || shortAtEnd) {
          phrase++;
          continue;
        }
      }
      gated.add(seg);
    }
    cleaned = gated;

    // Rule 4a: repeated words inside a segment.
    if (options.collapseRepeatedWords) {
      for (var i = 0; i < cleaned.length; i++) {
        final r = _collapseWords(cleaned[i], spaced);
        if (r != null) {
          repeatedWords += r.removed;
          cleaned[i] = r.segment;
        }
      }
    }

    // Rule 4b: loops of identical segments.
    if (options.collapseRepeatedSegments) {
      final out = <TranscriptSegment>[];
      var i = 0;
      while (i < cleaned.length) {
        final key = _compareKey(cleaned[i].text);
        var j = i + 1;
        while (key.isNotEmpty && j < cleaned.length && _compareKey(cleaned[j].text) == key) {
          j++;
        }
        out.add(cleaned[i]);
        if (j - i >= options.segmentRepeatRun) {
          repeatedSegments += j - i - 1;
          i = j;
        } else {
          // Not a loop: keep the repeats (a speaker may repeat himself once or twice).
          for (var k = i + 1; k < j; k++) {
            out.add(cleaned[k]);
          }
          i = j;
        }
      }
      cleaned = out;
    }

    // Rule 5: timing sanity.
    if (options.fixTiming) {
      final out = <TranscriptSegment>[];
      for (final seg in cleaned) {
        final fixed = _fixTiming(seg);
        timing += fixed.adjusted;
        final s = fixed.segment;
        if (s.durationUs < options.minSegmentDuration.inMicroseconds && s.text.characters.length <= 1) {
          tiny++;
          continue;
        }
        out.add(s);
      }
      cleaned = out;
    }

    return NormalizedTranscript(
      List.unmodifiable(cleaned),
      NormalizationReport(
        annotationSegmentsDropped: annotationSegments,
        annotationSpansRemoved: annotationSpans,
        silenceHallucinationsDropped: silence,
        phraseHallucinationsDropped: phrase,
        repeatedSegmentsCollapsed: repeatedSegments,
        repeatedWordsCollapsed: repeatedWords,
        timingAdjustments: timing,
        tinySegmentsDropped: tiny,
        emptySegmentsDropped: empty,
      ),
    );
  }

  // -------------------------------------------------------------------------------------------
  // Annotations.
  // -------------------------------------------------------------------------------------------

  ({TranscriptSegment segment, int spans})? _removeAnnotations(TranscriptSegment seg) {
    final raw = seg.text;
    final matches = _annotation.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    final buffer = StringBuffer();
    var last = 0;
    for (final m in matches) {
      buffer.write(raw.substring(last, m.start));
      buffer.write(' ');
      last = m.end;
    }
    buffer.write(raw.substring(last));
    final text = buffer.toString().replaceAll(_spaces, ' ').trim();

    var words = seg.words;
    if (words.isNotEmpty) {
      final kept = <TranscriptWord>[];
      var cursor = 0;
      for (final w in words) {
        final t = w.text.trim();
        if (t.isEmpty) continue;
        final idx = raw.indexOf(t, cursor);
        if (idx < 0) {
          kept.add(w);
          continue;
        }
        final end = idx + t.length;
        cursor = end;
        final inside = matches.any((m) => idx < m.end && end > m.start);
        if (!inside) kept.add(w);
      }
      words = kept;
    }
    return (segment: seg.copyWith(text: text, words: words), spans: matches.length);
  }

  // -------------------------------------------------------------------------------------------
  // Hallucination phrases.
  // -------------------------------------------------------------------------------------------

  static String _compareKey(String s) => s.toLowerCase().replaceAll(_notLetterOrDigit, '');

  bool _matchesPhrase(String text, String language) {
    final key = _compareKey(text);
    if (key.isEmpty) return false;
    for (final p in hallucinationPhrasesFor(language)) {
      final pk = _compareKey(p);
      if (pk.isEmpty) continue;
      if (key == pk) return true;
      if (pk.length >= 6 && key.contains(pk) && key.length <= pk.length + 12) return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------------------------
  // Repetition.
  // -------------------------------------------------------------------------------------------

  ({TranscriptSegment segment, int removed})? _collapseWords(TranscriptSegment seg, bool spaced) {
    var removed = 0;
    var words = seg.words;
    var text = seg.text;

    if (words.isNotEmpty) {
      final out = <TranscriptWord>[];
      var i = 0;
      while (i < words.length) {
        final key = _compareKey(words[i].text);
        var j = i + 1;
        while (key.isNotEmpty && j < words.length && _compareKey(words[j].text) == key) {
          j++;
        }
        if (j - i >= options.wordRepeatRun) {
          // Keep the first occurrence, stretched over the whole run so the timing stays covered.
          out.add(words[i].copyWith(endUs: words[j - 1].endUs));
          removed += j - i - 1;
        } else {
          out.addAll(words.sublist(i, j));
        }
        i = j;
      }
      words = out;
    }

    if (spaced) {
      final tokens = text.split(' ');
      final out = <String>[];
      var i = 0;
      var textRemoved = 0;
      while (i < tokens.length) {
        final key = _compareKey(tokens[i]);
        var j = i + 1;
        while (key.isNotEmpty && j < tokens.length && _compareKey(tokens[j]) == key) {
          j++;
        }
        if (j - i >= options.wordRepeatRun) {
          out.add(tokens[i]);
          textRemoved += j - i - 1;
        } else {
          out.addAll(tokens.sublist(i, j));
        }
        i = j;
      }
      if (textRemoved > 0) {
        text = out.join(' ');
        if (removed == 0) removed = textRemoved;
      }
    } else if (removed > 0 && words.isNotEmpty) {
      text = joinTranscriptWords([for (final w in words) w.text]);
    }

    if (removed == 0) return null;
    return (segment: seg.copyWith(text: text, words: words), removed: removed);
  }

  // -------------------------------------------------------------------------------------------
  // Timing.
  // -------------------------------------------------------------------------------------------

  ({TranscriptSegment segment, int adjusted}) _fixTiming(TranscriptSegment seg) {
    var adjusted = 0;
    final start = seg.startUs;
    var end = seg.endUs;
    if (end < start) {
      end = start;
      adjusted++;
    }
    if (seg.words.isEmpty) {
      return (segment: end == seg.endUs ? seg : seg.copyWith(endUs: end), adjusted: adjusted);
    }

    final minWord = options.minWordDuration.inMicroseconds;
    final ws = [for (final w in seg.words) w.copyWith()];
    // Inside the segment, then monotonic (start >= previous end).
    var cursor = start;
    for (var i = 0; i < ws.length; i++) {
      var s = ws[i].startUs;
      var e = ws[i].endUs;
      final s0 = s;
      final e0 = e;
      if (s < cursor) s = cursor;
      if (s > end) s = end;
      if (e < s) e = s;
      if (e > end) e = end;
      if (s != s0 || e != e0) adjusted++;
      ws[i] = ws[i].copyWith(startUs: s, endUs: e);
      cursor = e;
    }
    // Zero-duration words borrow minWord from the gaps next to them.
    for (var i = 0; i < ws.length; i++) {
      final w = ws[i];
      if (w.durationUs > 0) continue;
      var need = minWord;
      final nextStart = i + 1 < ws.length ? ws[i + 1].startUs : end;
      final after = nextStart - w.endUs;
      final takeAfter = after > 0 ? (after < need ? after : need) : 0;
      var s = w.startUs;
      final e = w.endUs + takeAfter;
      need -= takeAfter;
      if (need > 0) {
        final prevEnd = i > 0 ? ws[i - 1].endUs : start;
        final before = s - prevEnd;
        final takeBefore = before > 0 ? (before < need ? before : need) : 0;
        s -= takeBefore;
      }
      if (s != w.startUs || e != w.endUs) adjusted++;
      ws[i] = w.copyWith(startUs: s, endUs: e);
    }
    return (segment: seg.copyWith(startUs: start, endUs: end, words: ws), adjusted: adjusted);
  }
}

/// Joins word texts into display text: a space between words except where either neighbouring
/// character belongs to a no-space script (kana, han, Thai, ...), where words touch. Latin or digit
/// runs inside such text keep their spaces.
String joinTranscriptWords(Iterable<String> words) {
  final out = StringBuffer();
  String? prev;
  for (final raw in words) {
    final w = raw.trim();
    if (w.isEmpty) continue;
    if (prev != null && transcriptWordsNeedSpace(prev, w)) out.write(' ');
    out.write(w);
    prev = w;
  }
  return out.toString();
}

/// Whether display text puts a space between the words [prev] and [next]: not when either side
/// touches a no-space script (kana, han, Thai, ...).
bool transcriptWordsNeedSpace(String prev, String next) => !_isNoSpaceScript(prev.runes.last) && !_isNoSpaceScript(next.runes.first);

/// Scripts written without spaces between words (Hangul is space-delimited, so it is not listed).
bool _isNoSpaceScript(int r) =>
    (r >= 0x3040 && r <= 0x30FF) || // hiragana, katakana
    (r >= 0x3400 && r <= 0x9FFF) || // CJK ideographs
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0xFF00 && r <= 0xFFEF) || // full-width forms
    (r >= 0x3000 && r <= 0x303F) || // CJK punctuation
    (r >= 0x0E00 && r <= 0x0EFF) || // Thai, Lao
    (r >= 0x1000 && r <= 0x109F) || // Myanmar
    (r >= 0x1780 && r <= 0x17FF) || // Khmer
    (r >= 0x0F00 && r <= 0x0FFF) || // Tibetan
    (r >= 0x20000 && r <= 0x2FA1F);
