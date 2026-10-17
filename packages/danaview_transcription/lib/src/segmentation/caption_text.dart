// OWNER: AI-11
//
// Text rules the segmenter uses (ai.md §9.2, §9.3): sentence and clause ends, kinsoku, and the
// per-language function words that make a bad place to end a line.

import '../transcript/transcript_normalizer.dart' show transcriptWordsNeedSpace;

const String _closers = '"\'”’»)」』】）〕〉》]}';
const String _sentenceEnds = '.?!…。？！؟।॥‼⁇⁈⁉｡';
const String _clauseEnds = ',;:—–、，；：،､﹐﹔';

String _stripClosers(String text) {
  var end = text.length;
  while (end > 0 && _closers.contains(text[end - 1])) {
    end--;
  }
  return text.substring(0, end);
}

/// Whether [text] ends a sentence (ignoring closing quotes and brackets).
bool endsSentenceText(String text) {
  final t = _stripClosers(text.trimRight());
  return t.isNotEmpty && _sentenceEnds.contains(t[t.length - 1]);
}

/// Whether [text] ends a clause (ignoring closing quotes and brackets).
bool endsClauseText(String text) {
  final t = _stripClosers(text.trimRight());
  return t.isNotEmpty && _clauseEnds.contains(t[t.length - 1]);
}

/// Characters a line must not start with (kinsoku): closing brackets, full stops, commas,
/// the prolonged sound mark, small kana, `！？`, and the ASCII equivalents.
const String kinsokuNoLineStart = '、。，．）」』】〕〉》］｝！？：；ゝゞヽヾー々ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ…‥〜％,.)]}!?:;%';

/// Characters a line must not end with (kinsoku): opening brackets.
const String kinsokuNoLineEnd = '（「『【〔〈《［｛([{';

/// Whether a line may not start with [grapheme].
bool isKinsokuNoStart(String grapheme) => grapheme.isNotEmpty && kinsokuNoLineStart.contains(grapheme[0]);

/// Whether a line may not end with [grapheme].
bool isKinsokuNoEnd(String grapheme) => grapheme.isNotEmpty && kinsokuNoLineEnd.contains(grapheme[0]);

/// Articles, prepositions and conjunctions of one language.
class FunctionWords {
  /// Creates the lists (all lowercase).
  const FunctionWords({required this.articles, required this.linking});

  /// Articles: a line should not end with one.
  final Set<String> articles;

  /// Prepositions and conjunctions: a cue should break before one, a line should not end with one.
  final Set<String> linking;

  /// Whether [word] (any case, with punctuation) is a preposition or conjunction.
  bool isLinking(String word) => linking.contains(normalizeFunctionWord(word));

  /// Whether [word] is an article, preposition or conjunction.
  bool isFunctionWord(String word) {
    final w = normalizeFunctionWord(word);
    return articles.contains(w) || linking.contains(w);
  }

  /// No lists.
  static const FunctionWords none = FunctionWords(articles: {}, linking: {});
}

/// Lowercases [word] and strips surrounding punctuation.
String normalizeFunctionWord(String word) {
  const strip = '.,;:!?"\'“”‘’()[]¿¡…—–-';
  final s = word.toLowerCase();
  var a = 0;
  var b = s.length;
  while (a < b && strip.contains(s[a])) {
    a++;
  }
  while (b > a && strip.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

/// Function words by whisper language code (English, Spanish, French, German, Portuguese,
/// Italian; empty for every other language, ai.md §9.3).
const Map<String, FunctionWords> functionWordsByLanguage = {
  'en': FunctionWords(
    articles: {'a', 'an', 'the'},
    linking: {
      'and', 'but', 'or', 'nor', 'so', 'yet', 'for', 'of', 'in', 'on', 'at', 'to', 'by', 'with', 'from', 'into', //
      'onto', 'over', 'under', 'about', 'as', 'if', 'because', 'that', 'which', 'who', 'while', 'when', 'where',
      'than', 'though', 'although', 'until', 'unless', 'since', 'after', 'before', 'between', 'through', 'during',
      'without', 'within', 'against', 'among',
    },
  ),
  'es': FunctionWords(
    articles: {'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas'},
    linking: {
      'y',
      'e',
      'o',
      'u',
      'pero',
      'que',
      'de',
      'del',
      'en',
      'a',
      'con',
      'por',
      'para',
      'sin',
      'sobre',
      'como',
      'si',
      'porque',
      'cuando',
      'donde',
      'entre',
      'hasta',
      'desde',
      'ni',
      'sino',
      'aunque',
      'mientras',
    },
  ),
  'fr': FunctionWords(
    articles: {'le', 'la', 'les', 'un', 'une', 'des', 'l'},
    linking: {
      'et',
      'ou',
      'mais',
      'que',
      'qui',
      'de',
      'du',
      'à',
      'en',
      'dans',
      'sur',
      'avec',
      'pour',
      'par',
      'sans',
      'comme',
      'si',
      'quand',
      'où',
      'entre',
      'donc',
      'car',
      'parce',
      'lorsque',
      'puisque',
    },
  ),
  'de': FunctionWords(
    articles: {'der', 'die', 'das', 'ein', 'eine', 'einen', 'einem', 'einer', 'den', 'dem', 'des'},
    linking: {
      'und',
      'oder',
      'aber',
      'dass',
      'daß',
      'weil',
      'wenn',
      'als',
      'ob',
      'mit',
      'von',
      'zu',
      'in',
      'auf',
      'an',
      'für',
      'bei',
      'nach',
      'über',
      'unter',
      'ohne',
      'durch',
      'gegen',
      'um',
      'aus',
      'bis',
      'seit',
      'wie',
      'sondern',
      'denn',
    },
  ),
  'pt': FunctionWords(
    articles: {'o', 'a', 'os', 'as', 'um', 'uma', 'uns', 'umas'},
    linking: {
      'e',
      'ou',
      'mas',
      'que',
      'de',
      'do',
      'da',
      'em',
      'com',
      'por',
      'para',
      'sem',
      'sobre',
      'como',
      'se',
      'porque',
      'quando',
      'onde',
      'entre',
      'até',
      'desde',
      'nem',
    },
  ),
  'it': FunctionWords(
    articles: {'il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'una', 'uno'},
    linking: {
      'e',
      'o',
      'ma',
      'che',
      'di',
      'in',
      'a',
      'da',
      'con',
      'su',
      'per',
      'tra',
      'fra',
      'senza',
      'come',
      'se',
      'perché',
      'quando',
      'dove',
      'anche',
      'però',
    },
  ),
};

/// The function words of [language] (a whisper code), or none.
FunctionWords functionWordsFor(String? language) => functionWordsByLanguage[language] ?? FunctionWords.none;

/// Whether display text puts a space between [prev] and [next] (shared with the normalizer).
bool wordsNeedSpace(String prev, String next) => transcriptWordsNeedSpace(prev, next);
