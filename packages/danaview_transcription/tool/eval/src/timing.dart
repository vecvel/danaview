// OWNER: QA-06
//
// Timing metrics of the accuracy eval (ai.md §14.2, §16.5): cue boundary error against human-timed
// reference cues, reading-speed (CPS) distribution of the generated cues, and percentile helpers.

import 'package:characters/characters.dart';

/// A cue in milliseconds (reference or generated).
final class TimedCue {
  /// Creates a cue.
  const TimedCue(this.startMs, this.endMs, this.text);

  /// Reads `{"start": ms, "end": ms, "text": "..."}`.
  factory TimedCue.fromJson(Map<String, Object?> json) => TimedCue(
        (json['start']! as num).round(),
        (json['end']! as num).round(),
        (json['text'] as String?) ?? '',
      );

  /// Start, ms.
  final int startMs;

  /// End, ms.
  final int endMs;

  /// Text (lines joined by `\n`).
  final String text;

  /// Duration, ms.
  int get durationMs => endMs - startMs;

  /// Reading speed: graphemes (line breaks counted as one space) per second; infinity for an empty
  /// span. Same definition as the segmenter's `fractionOverReadingSpeed`.
  double get cps {
    if (durationMs <= 0) return double.infinity;
    return text.replaceAll('\n', ' ').characters.length / (durationMs / 1000);
  }

  /// JSON form.
  Map<String, Object?> toJson() => {'start': startMs, 'end': endMs, 'text': text};
}

/// Result of matching generated cues to reference cues.
final class BoundaryErrors {
  /// Creates a result.
  const BoundaryErrors({required this.errorsMs, required this.referenceCues, required this.matchedCues});

  /// No reference cues.
  static const BoundaryErrors none = BoundaryErrors(errorsMs: [], referenceCues: 0, matchedCues: 0);

  /// Absolute start and end errors of every matched reference cue, ms (two per match).
  final List<int> errorsMs;

  /// Reference cues considered.
  final int referenceCues;

  /// Reference cues that overlapped a generated cue.
  final int matchedCues;

  /// Median boundary error (null without matches).
  double? get medianMs => percentile(errorsMs.map((e) => e.toDouble()).toList(), 50);

  /// 90th percentile boundary error.
  double? get p90Ms => percentile(errorsMs.map((e) => e.toDouble()).toList(), 90);

  /// Fraction of reference cues with a match.
  double get matchedFraction => referenceCues == 0 ? 1 : matchedCues / referenceCues;

  /// Merges two results (corpus-level medians pool the errors).
  BoundaryErrors operator +(BoundaryErrors o) => BoundaryErrors(
        errorsMs: [...errorsMs, ...o.errorsMs],
        referenceCues: referenceCues + o.referenceCues,
        matchedCues: matchedCues + o.matchedCues,
      );
}

/// Matches each reference cue to the generated cue with the largest time overlap (ties: the
/// earlier cue) and records `|start - start'|` and `|end - end'|`. Reference cues no generated cue
/// overlaps count as unmatched (they lower [BoundaryErrors.matchedFraction]).
BoundaryErrors boundaryErrors(List<TimedCue> reference, List<TimedCue> generated) {
  final errors = <int>[];
  var matched = 0;
  for (final r in reference) {
    TimedCue? best;
    var bestOverlap = 0;
    for (final g in generated) {
      final overlap = _min(r.endMs, g.endMs) - _max(r.startMs, g.startMs);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = g;
      }
    }
    if (best == null) continue;
    matched++;
    errors
      ..add((best.startMs - r.startMs).abs())
      ..add((best.endMs - r.endMs).abs());
  }
  return BoundaryErrors(errorsMs: errors, referenceCues: reference.length, matchedCues: matched);
}

/// Reading-speed distribution of generated cues.
final class CpsDistribution {
  /// Creates a distribution from per-cue values and the limit they are judged against.
  CpsDistribution(List<double> values, this.limit) : values = List.unmodifiable(values);

  /// Per-cue CPS (finite values only).
  final List<double> values;

  /// The layout's soft reading-speed limit.
  final double limit;

  /// Median CPS.
  double? get p50 => percentile(values, 50);

  /// 90th percentile CPS.
  double? get p90 => percentile(values, 90);

  /// Highest CPS.
  double? get max => values.isEmpty ? null : values.reduce(_maxD);

  /// Fraction of cues over [limit].
  double get overLimitFraction => values.isEmpty ? 0 : values.where((v) => v > limit + 1e-9).length / values.length;

  /// Pools two distributions judged against the same limit.
  CpsDistribution operator +(CpsDistribution o) => CpsDistribution([...values, ...o.values], limit);

  /// JSON form.
  Map<String, Object?> toJson() =>
      {'cues': values.length, 'limit': limit, 'p50': p50, 'p90': p90, 'max': max, 'overLimit': overLimitFraction};
}

/// CPS distribution of [cues] against [limit] (zero-length cues are skipped).
CpsDistribution cpsDistribution(List<TimedCue> cues, double limit) =>
    CpsDistribution([for (final c in cues) if (c.cps.isFinite) c.cps], limit);

/// The [p]th percentile (nearest-rank on the sorted values, linear interpolation between ranks);
/// null for no values.
double? percentile(List<double> values, double p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  if (sorted.length == 1) return sorted.first;
  final rank = (p.clamp(0, 100) / 100) * (sorted.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;
double _maxD(double a, double b) => a > b ? a : b;
