// OWNER: QA-06
//
// Text scoring for the accuracy eval (ai.md §16.5): a scoring normalizer (case, punctuation and
// whitespace folded, like whisper's basic normalizer), tokenization by script (words for
// space-delimited scripts, graphemes for CJK and no-space scripts) and Levenshtein alignment with
// substitution/deletion/insertion counts, giving WER and CER.

import 'package:characters/characters.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

final RegExp _notWordChar = RegExp(r"[^\p{L}\p{N}\p{M}\s]", unicode: true);
final RegExp _apostrophes = RegExp("['’ʼ]");
final RegExp _spaces = RegExp(r'\s+');

/// Folds [text] for scoring: lower case, apostrophes removed (so "don't" == "dont"), every other
/// punctuation or symbol becomes a space, whitespace collapsed and trimmed.
String scoringNormalize(String text) =>
    text.toLowerCase().replaceAll(_apostrophes, '').replaceAll(_notWordChar, ' ').replaceAll(_spaces, ' ').trim();

/// Whether WER is meaningful for the whisper language [language] (space-delimited scripts and
/// Korean); CJK and no-space scripts are scored by CER only.
bool usesWordErrorRate(String language) {
  final script = languageForWhisperCode(language)?.script ?? ScriptProfile.spaceDelimited;
  return script == ScriptProfile.spaceDelimited || script == ScriptProfile.korean;
}

/// Scoring tokens of [text]: words when [usesWordErrorRate] holds for [language], otherwise
/// graphemes (spaces dropped).
List<String> scoringTokens(String text, String language) {
  final folded = scoringNormalize(text);
  if (folded.isEmpty) return const [];
  if (usesWordErrorRate(language)) return folded.split(' ');
  return graphemesOf(folded);
}

/// Graphemes of the folded [text] without spaces (CER units).
List<String> graphemesOf(String text) => [
      for (final g in scoringNormalize(text).characters)
        if (g != ' ') g,
    ];

/// Edit operations between a reference and a hypothesis.
final class EditCounts {
  /// Creates counts.
  const EditCounts({
    required this.substitutions,
    required this.deletions,
    required this.insertions,
    required this.referenceLength,
  });

  /// No tokens on either side.
  static const EditCounts zero = EditCounts(substitutions: 0, deletions: 0, insertions: 0, referenceLength: 0);

  /// Substituted tokens.
  final int substitutions;

  /// Reference tokens missing from the hypothesis.
  final int deletions;

  /// Hypothesis tokens not in the reference.
  final int insertions;

  /// Reference tokens.
  final int referenceLength;

  /// Total edits.
  int get errors => substitutions + deletions + insertions;

  /// Error rate (edits / reference tokens); an empty reference scores 0 when the hypothesis is
  /// empty too and 1 otherwise.
  double get rate => referenceLength == 0 ? (insertions == 0 ? 0 : 1) : errors / referenceLength;

  /// Sum of two counts (corpus-level rates add counts, never rates).
  EditCounts operator +(EditCounts o) => EditCounts(
        substitutions: substitutions + o.substitutions,
        deletions: deletions + o.deletions,
        insertions: insertions + o.insertions,
        referenceLength: referenceLength + o.referenceLength,
      );

  /// JSON form.
  Map<String, Object?> toJson() =>
      {'s': substitutions, 'd': deletions, 'i': insertions, 'n': referenceLength, 'rate': rate};

  @override
  bool operator ==(Object other) =>
      other is EditCounts &&
      other.substitutions == substitutions &&
      other.deletions == deletions &&
      other.insertions == insertions &&
      other.referenceLength == referenceLength;

  @override
  int get hashCode => Object.hash(substitutions, deletions, insertions, referenceLength);

  @override
  String toString() => 'EditCounts(S$substitutions D$deletions I$insertions / $referenceLength)';
}

/// Minimum-edit alignment of [hypothesis] against [reference] (unit costs; ties prefer
/// substitution, then deletion, so the counts are deterministic).
EditCounts alignTokens(List<String> reference, List<String> hypothesis) {
  final n = reference.length;
  final m = hypothesis.length;
  if (n == 0) return EditCounts(substitutions: 0, deletions: 0, insertions: m, referenceLength: 0);
  if (m == 0) return EditCounts(substitutions: 0, deletions: n, insertions: 0, referenceLength: n);
  // cost[j], and per cell the (s, d, i) that reached it.
  var cost = List<int>.generate(m + 1, (j) => j);
  var subs = List<int>.filled(m + 1, 0);
  var dels = List<int>.filled(m + 1, 0);
  var ins = List<int>.generate(m + 1, (j) => j);
  for (var i = 1; i <= n; i++) {
    final nc = List<int>.filled(m + 1, 0);
    final ns = List<int>.filled(m + 1, 0);
    final nd = List<int>.filled(m + 1, 0);
    final ni = List<int>.filled(m + 1, 0);
    nc[0] = i;
    nd[0] = i;
    for (var j = 1; j <= m; j++) {
      final same = reference[i - 1] == hypothesis[j - 1];
      final diag = cost[j - 1] + (same ? 0 : 1);
      final up = cost[j] + 1; // deletion
      final left = nc[j - 1] + 1; // insertion
      if (diag <= up && diag <= left) {
        nc[j] = diag;
        ns[j] = subs[j - 1] + (same ? 0 : 1);
        nd[j] = dels[j - 1];
        ni[j] = ins[j - 1];
      } else if (up <= left) {
        nc[j] = up;
        ns[j] = subs[j];
        nd[j] = dels[j] + 1;
        ni[j] = ins[j];
      } else {
        nc[j] = left;
        ns[j] = ns[j - 1];
        nd[j] = nd[j - 1];
        ni[j] = ni[j - 1] + 1;
      }
    }
    cost = nc;
    subs = ns;
    dels = nd;
    ins = ni;
  }
  return EditCounts(substitutions: subs[m], deletions: dels[m], insertions: ins[m], referenceLength: n);
}

/// Word (or, for CJK and no-space scripts, character) edit counts of [hypothesis] vs [reference].
EditCounts wordEdits(String reference, String hypothesis, String language) =>
    alignTokens(scoringTokens(reference, language), scoringTokens(hypothesis, language));

/// Character edit counts (graphemes, spaces dropped).
EditCounts characterEdits(String reference, String hypothesis) =>
    alignTokens(graphemesOf(reference), graphemesOf(hypothesis));
