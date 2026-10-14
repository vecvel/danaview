// OWNER: CORE-35
//
// Measurement helpers of the core benchmarks: warm-up, per-sample timing with `Stopwatch`,
// percentiles, and the JSON shape of a result row (`run.dart` writes and compares these).

/// One measured metric.
final class MetricResult {
  /// Creates a result from raw samples (µs, any order).
  MetricResult(this.id, List<int> samplesUs, {required this.budgetUs, required this.label, this.budgetGated = true})
      : samples = List.unmodifiable(List<int>.of(samplesUs)..sort());

  /// Stable id (the key in `baseline.json`).
  final String id;

  /// Human-readable description.
  final String label;

  /// The ARCH §18.2 budget (p90, µs).
  final int budgetUs;

  /// Whether `--check` fails on a budget miss. False for rows whose ARCH §18.2 budget another
  /// ticket owns (they are still measured, reported and regression-gated).
  final bool budgetGated;

  /// Sorted samples (µs).
  final List<int> samples;

  /// The [q] quantile (nearest rank), µs.
  int quantile(double q) {
    if (samples.isEmpty) return 0;
    final rank = (q * samples.length).ceil().clamp(1, samples.length);
    return samples[rank - 1];
  }

  /// Median, µs.
  int get p50 => quantile(0.5);

  /// 90th percentile (the budget statistic), µs.
  int get p90 => quantile(0.9);

  /// Slowest sample, µs.
  int get max => samples.isEmpty ? 0 : samples.last;

  /// Whether [p90] meets [budgetUs].
  bool get withinBudget => p90 <= budgetUs;

  /// JSON row.
  Map<String, Object?> toJson() => {
        'label': label,
        'p50Us': p50,
        'p90Us': p90,
        'maxUs': max,
        'n': samples.length,
        'budgetUs': budgetUs,
        if (!budgetGated) 'budgetGated': false,
      };

  /// One aligned text line for the console.
  String describe() {
    String ms(int us) => (us / 1000).toStringAsFixed(us < 10000 ? 3 : 1).padLeft(8);
    return '${id.padRight(30)} p50 ${ms(p50)} ms  p90 ${ms(p90)} ms  max ${ms(max)} ms  '
        'budget ${ms(budgetUs)} ms  ${withinBudget ? 'ok' : budgetGated ? 'OVER BUDGET' : 'over budget (not gated here)'}';
  }
}

/// Runs [setup] + timed [body] [warmup] times untimed, then [samples] times timed, and returns
/// the timings of [body] only (µs). [setup] prepares the next input (an edit, a fresh codec …)
/// and is never timed.
List<int> measure({
  required int warmup,
  required int samples,
  void Function(int i)? setup,
  required void Function(int i) body,
}) {
  final sw = Stopwatch();
  final out = <int>[];
  for (var i = 0; i < warmup + samples; i++) {
    setup?.call(i);
    sw
      ..reset()
      ..start();
    body(i);
    sw.stop();
    if (i >= warmup) out.add(sw.elapsedMicroseconds);
  }
  return out;
}

/// Keeps a value alive so the compiler cannot drop the work that produced it.
Object? blackhole;
