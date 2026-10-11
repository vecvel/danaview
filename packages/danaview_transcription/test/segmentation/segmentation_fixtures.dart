// OWNER: AI-11
//
// Builders and renderers shared by the segmentation tests.

import 'package:characters/characters.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// How a language's text is cut into recognizer "words" for the fixtures.
enum Tokenizer {
  /// Whitespace.
  spaces,

  /// Two graphemes per token (CJK recognizers emit short tokens).
  pairs,

  /// Three graphemes per token (Thai).
  triples,
}

/// Timed words from [text]: each token lasts `msPerGrapheme` per grapheme (at least 120 ms);
/// [pauseAfterSentenceMs] is inserted after sentence-final tokens.
List<TimedWord> wordsFromText(
  String text, {
  Tokenizer tokenizer = Tokenizer.spaces,
  int startMs = 0,
  int msPerGrapheme = 70,
  int pauseAfterSentenceMs = 350,
  int pauseBetweenTokensMs = 20,
  int phrasePauseMs = 0,
  ItemId clip = const ItemId('clip'),
}) {
  // Phrases are separated by spaces in the text; tokens never cross a phrase.
  final phrases = text.trim().split(RegExp(r'\s+'));
  final tokens = <(String, bool)>[]; // token, last of its phrase
  for (final phrase in phrases) {
    switch (tokenizer) {
      case Tokenizer.spaces:
        tokens.add((phrase, false));
      case Tokenizer.pairs:
      case Tokenizer.triples:
        final size = tokenizer == Tokenizer.pairs ? 2 : 3;
        final g = phrase.characters.toList();
        var i = 0;
        while (i < g.length) {
          var j = i + size;
          if (j > g.length) j = g.length;
          // Attach trailing punctuation to the token before it.
          while (j < g.length && '、。，．！？…」』）,.!?'.contains(g[j])) {
            j++;
          }
          tokens.add((g.sublist(i, j).join(), j >= g.length));
          i = j;
        }
    }
  }
  final out = <TimedWord>[];
  var t = startMs;
  for (final (tok, lastOfPhrase) in tokens) {
    final dur = (tok.characters.length * msPerGrapheme).clamp(120, 100000);
    out.add(TimedWord(text: tok, start: t * 1000, end: (t + dur) * 1000, clip: clip));
    t += dur + pauseBetweenTokensMs;
    if (endsSentenceText(tok)) t += pauseAfterSentenceMs;
    if (lastOfPhrase) t += phrasePauseMs;
  }
  return out;
}

/// Renders cues as `start-end|line1/line2` rows (ms) for golden comparison.
List<String> render(List<SubtitleCueDraft> cues) => [
      for (final c in cues)
        '${(c.range.start / 1000).round()}-${(c.range.end / 1000).round()}|${c.text.replaceAll('\n', ' / ')}',
    ];

/// A context with the standard preset on a 30 fps landscape project.
SegmentationContext context({
  String language = 'en',
  SegmentationSettings settings = const SegmentationSettings(),
  FrameRate rate = FrameRate.fps30,
  List<TimeUs> cuts = const [],
  bool portrait = false,
}) {
  final lang = languageForWhisperCode(language)!;
  return SegmentationContext(
    script: lang.script,
    settings: settings,
    frameRate: rate,
    cutPoints: cuts,
    portrait: portrait,
    language: language,
  );
}
