// OWNER: CORE-34
//
// The model fuzzer's minimizer: it shrinks a failing run into a small regression fixture that
// still fails with the same signature (check, known defect and violation codes or exception
// type).
//
// The fuzz input is a list of choice streams, one per step (fuzz_choices.dart), plus the start
// project. The minimizer repeats these passes until none of them makes progress or the budget
// runs out:
//
// 1. **steps**: delete chunks of steps, from half the run down to single steps (ddmin);
// 2. **project**: drop the markers, whole lanes (the main lane stays), chunks of items and unused
//    pool assets. `repair()` cleans up dangling transitions and links, so the start project
//    stays valid;
// 3. **draws**: replace a step's whole stream with zeros, then set single draws to 0 or halve
//    them. Small draws mean simple choices: the first weight bucket, the first target, no
//    optional field.
//
// Each step replays its own stream, so a change to one step never shifts the draws of another.
// A candidate is kept when its replay fails with the target signature. The replay's recorded
// draws then become the new case, so the case is cut at the failing step and every draw is
// reduced to the value actually used.

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'fuzz_runner.dart';

/// Decides whether a replay reproduced the failure being minimized.
typedef FailureMatch = bool Function(FuzzFailure failure);

/// The result of a minimization.
final class MinimizeResult {
  MinimizeResult._(this.fuzzCase, this.failure, this.runs, this.before, this.after, this.budgetExhausted);

  /// The minimized case (replays recorded choices).
  final FuzzCase fuzzCase;

  /// The minimized case's failure.
  final FuzzFailure failure;

  /// Replays run.
  final int runs;

  /// Size of the input case.
  final CaseSize before;

  /// Size of the minimized case.
  final CaseSize after;

  /// Whether the run or time budget stopped the minimizer before it reached a fixed point.
  final bool budgetExhausted;

  @override
  String toString() => 'minimized $before -> $after in $runs replays${budgetExhausted ? ' (budget exhausted)' : ''}';
}

/// The size measures the minimizer lowers.
final class CaseSize implements Comparable<CaseSize> {
  /// Measures [c] (which must replay recorded choices).
  factory CaseSize.of(FuzzCase c) {
    var draws = 0, sum = 0;
    for (final s in c.recorded!) {
      draws += s.length;
      for (final d in s) {
        sum += d;
      }
    }
    var items = 0;
    for (final t in c.project.tracks) {
      items += t.items.length;
    }
    return CaseSize._(c.steps, draws, sum, c.project.tracks.length, items, c.project.markers.length, c.project.pool.length);
  }

  CaseSize._(this.steps, this.draws, this.drawSum, this.tracks, this.items, this.markers, this.assets);

  /// Steps.
  final int steps;

  /// Draws over all steps.
  final int draws;

  /// Sum of all draws.
  final int drawSum;

  /// Lanes of the start project.
  final int tracks;

  /// Items of the start project.
  final int items;

  /// Markers of the start project.
  final int markers;

  /// Pool assets of the start project.
  final int assets;

  /// Steps first, then the start project, then the draws.
  @override
  int compareTo(CaseSize o) {
    for (final (a, b) in [(steps, o.steps), (items, o.items), (tracks, o.tracks), (markers, o.markers), (assets, o.assets), (draws, o.draws), (drawSum, o.drawSum)]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  @override
  String toString() =>
      '{steps $steps, draws $draws (sum $drawSum), tracks $tracks, items $items, markers $markers, assets $assets}';
}

/// Thrown when the failure to minimize does not reproduce on replay (the run is not
/// deterministic, which is itself a bug).
final class NotReproducible implements Exception {
  /// Creates the exception.
  NotReproducible(this.message);

  /// Details.
  final String message;

  @override
  String toString() => 'NotReproducible: $message';
}

/// Shrinks failing fuzz runs.
final class FuzzMinimizer {
  /// Creates a minimizer. [maxRuns] and [timeBudget] bound the work; [tolerateKnownDefects] must
  /// match the run being minimized; [probe] is the injected check of that run (tests).
  FuzzMinimizer({
    this.maxRuns = 4000,
    this.timeBudget = const Duration(minutes: 3),
    this.tolerateKnownDefects = false,
    this.shrinkProject = true,
    this.probe,
  });

  /// Maximum number of replays.
  final int maxRuns;

  /// Maximum wall time.
  final Duration timeBudget;

  /// Whether replays tolerate open known defects.
  final bool tolerateKnownDefects;

  /// Whether the start project is shrunk too.
  final bool shrinkProject;

  /// The injected check of the run, if any.
  final FuzzProbe? probe;

  int _runs = 0;
  final Stopwatch _clock = Stopwatch();
  late FuzzCase _best;
  late FuzzFailure _failure;
  late FailureMatch _match;

  bool get _exhausted => _runs >= maxRuns || _clock.elapsed >= timeBudget;

  /// Minimizes [fuzzCase], whose run fails. [match] decides whether a replay reproduces it; by
  /// default the failure signature must stay the same.
  MinimizeResult minimize(FuzzCase fuzzCase, {FailureMatch? match}) {
    _runs = 0;
    _clock
      ..reset()
      ..start();
    final first = _run(fuzzCase);
    final failure = first.failure;
    if (failure == null) throw ArgumentError.value(fuzzCase.seed, 'fuzzCase', 'the run does not fail');
    _match = match ?? (f) => f.signature == failure.signature;
    if (!_match(failure)) throw ArgumentError.value(failure.signature, 'match', 'rejects the original failure');
    // The recorded draws up to the failing step replay the same failure.
    final replay = fuzzCase.replaying(first.choices);
    if (!_try(replay)) {
      throw NotReproducible('seed ${fuzzCase.seed}: replaying the recorded choices did not fail with ${failure.signature}');
    }
    final before = CaseSize.of(replay);
    var progress = true;
    while (progress && !_exhausted) {
      final start = CaseSize.of(_best);
      _deleteSteps();
      if (shrinkProject) _shrinkProject();
      _simplifyDraws();
      progress = CaseSize.of(_best).compareTo(start) < 0;
    }
    return MinimizeResult._(_best, _failure, _runs, before, CaseSize.of(_best), _exhausted);
  }

  FuzzResult _run(FuzzCase c) {
    _runs++;
    return FuzzRunner.run(c, probe: probe, tolerateKnownDefects: tolerateKnownDefects);
  }

  /// Replays [c]; when it reproduces the failure, it becomes the best case (with the recorded
  /// draws of the replay).
  bool _try(FuzzCase c) {
    if (c.steps == 0) return false;
    final r = _run(c);
    final f = r.failure;
    if (f == null || !_match(f)) return false;
    _best = c.replaying(r.choices);
    _failure = f;
    return true;
  }

  List<List<int>> get _steps => _best.recorded!;

  void _deleteSteps() {
    for (var n = _steps.length ~/ 2; n >= 1 && !_exhausted; n ~/= 2) {
      var i = 0;
      while (i + n <= _steps.length && !_exhausted) {
        final s = _steps;
        final cand = [...s.sublist(0, i), ...s.sublist(i + n)];
        if (!_try(_best.replaying(cand))) i += n;
      }
    }
  }

  void _simplifyDraws() {
    for (var i = _steps.length - 1; i >= 0 && !_exhausted; i--) {
      if (i >= _steps.length) continue;
      if (_steps[i].every((d) => d == 0)) continue;
      if (_tryDraws(i, const [])) continue;
      for (var j = 0; j < _steps[i].length && !_exhausted; j++) {
        if (i >= _steps.length || j >= _steps[i].length) break;
        final v = _steps[i][j];
        if (v == 0) continue;
        if (_tryDraws(i, [..._steps[i]]..[j] = 0)) continue;
        if (v > 1) _tryDraws(i, [..._steps[i]]..[j] = v ~/ 2);
      }
    }
  }

  bool _tryDraws(int step, List<int> draws) {
    final s = [..._steps];
    s[step] = draws;
    return _try(_best.replaying(s));
  }

  // -------------------------------------------------------------------------------------------
  // Start project.
  // -------------------------------------------------------------------------------------------

  void _shrinkProject() {
    if (_best.project.markers.isNotEmpty) {
      _tryProject((p) => p.copyWith(timeline: p.timeline.copyWith(markers: const [])));
    }
    // Whole lanes, top first.
    for (var i = 0; i < _best.project.tracks.length && !_exhausted;) {
      final t = _best.project.tracks[i];
      if (t.isMain || !_tryProject((p) => _withTracks(p, [for (final x in p.tracks) if (x.id != t.id) x]))) i++;
    }
    // Chunks of items on each lane.
    for (var li = 0; li < _best.project.tracks.length && !_exhausted; li++) {
      final id = _best.project.tracks[li].id;
      Track? lane() => _best.project.tracks.where((t) => t.id == id).firstOrNull;
      for (var n = (lane()?.items.length ?? 0); n >= 1 && !_exhausted; n ~/= 2) {
        var i = 0;
        while (!_exhausted) {
          final t = lane();
          if (t == null || i + n > t.items.length) break;
          final keep = [...t.items.sublist(0, i), ...t.items.sublist(i + n)];
          if (!_tryProject((p) => _withTracks(p, [for (final x in p.tracks) x.id == id ? x.copyWith(items: keep) : x]))) i += n;
        }
      }
    }
    // Pool assets nothing uses.
    final used = _usedMedia(_best.project);
    if (_best.project.pool.assets.keys.any((id) => !used.contains(id))) {
      _tryProject((p) => p.copyWith(pool: MediaPool({for (final e in p.pool.assets.entries) if (used.contains(e.key)) e.key: e.value})));
    }
  }

  bool _tryProject(EditProject Function(EditProject p) edit) {
    final edited = edit(_best.project);
    final (repaired, _) = repair(edited);
    if (validate(repaired).isNotEmpty) return false;
    return _try(_best.replaying(_steps, project: repaired));
  }

  static EditProject _withTracks(EditProject p, List<Track> tracks) => p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));

  /// Media the timeline uses, with the sources of derived assets.
  static Set<MediaId> _usedMedia(EditProject p) {
    final used = mediaReferencedBy(p.timeline);
    var grew = true;
    while (grew) {
      grew = false;
      for (final id in [...used]) {
        final source = switch (p.pool[id]?.derived) {
          ReversedSpec(:final media) => media,
          StillSpec(:final media) => media,
          _ => null,
        };
        if (source != null && used.add(source)) grew = true;
      }
    }
    return used;
  }
}
