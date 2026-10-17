// OWNER: CORE-34
//
// The minimizer shrinks failing fuzz runs (BUILD_PLAN CORE-34: "at least one minimizer test
// proves shrinking works"). The failures here are injected with a probe, so the tests do not
// depend on any open defect.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'fuzz_fixture.dart';
import 'fuzz_generator.dart';
import 'fuzz_minimizer.dart';
import 'fuzz_runner.dart';

/// Fails once the session has added two markers (their ids come from the fuzz id generator).
String? _twoNewMarkers(EditProject p) =>
    p.markers.where((m) => m.id.value.startsWith('mk_Fz')).length >= 2 ? 'two new markers' : null;

/// Fails once a lane holds three or more items whose ids come from the fuzz id generator.
String? _threeNewItemsOnALane(EditProject p) =>
    p.tracks.any((t) => t.items.where((i) => i.id.value.startsWith('it_Fz')).length >= 3) ? 'three new items on a lane' : null;

/// The first seed from [from] whose run fails with [probe] within [steps] steps.
(FuzzCase, FuzzResult) _failingSeed(FuzzProbe probe, {int from = 0, int steps = 300}) {
  for (var seed = from; seed < from + 60; seed++) {
    final c = FuzzCase.forSeed(seed, steps: steps);
    final r = FuzzRunner.run(c, probe: probe);
    if (r.failure != null && r.failure!.check == FuzzCheck.injected) return (c, r);
  }
  throw StateError('no seed triggers the probe');
}

/// The actions [c] runs, in order.
List<FuzzAction> _actionsOf(FuzzCase c, FuzzProbe probe) {
  final actions = <FuzzAction>[];
  FuzzRunner.run(c, probe: probe, trace: (step, a, s) => actions.add(a));
  return actions;
}

void main() {
  test('shrinks an injected failure to the steps it needs and an empty start project', () {
    final (original, run) = _failingSeed(_twoNewMarkers);
    final m = FuzzMinimizer(probe: _twoNewMarkers).minimize(original);
    printOnFailure('seed ${original.seed}: $m');

    expect(m.failure.check, FuzzCheck.injected);
    expect(m.failure.signature, run.failure!.signature);
    expect(m.budgetExhausted, isFalse);
    // Steps: two AddMarker applies, or one composite holding both.
    expect(m.after.steps, lessThanOrEqualTo(2));
    expect(m.after.steps, lessThan(m.before.steps));
    final actions = _actionsOf(m.fuzzCase, _twoNewMarkers);
    expect(actions, hasLength(m.after.steps));
    for (final a in actions) {
      expect(a, isA<ApplyAction>());
      final cmd = (a as ApplyAction).command;
      expect(cmd is AddMarker || (cmd is CompositeCommand && cmd.commands.whereType<AddMarker>().length >= 2), isTrue,
          reason: a.describe());
    }
    // The start project shrank to its main lane: nothing else was needed.
    expect(m.after.tracks, 1);
    expect(m.after.items, 0);
    expect(m.after.markers, 0);
    expect(m.after.assets, 0);
    expect(m.fuzzCase.project.tracks.single.isMain, isTrue);
    // Draws were lowered toward zero.
    expect(m.after.draws, lessThan(m.before.draws));
    expect(m.after.drawSum, lessThan(m.before.drawSum));

    // The minimized case replays the same failure, also from its fixture text.
    final replay = FuzzRunner.run(m.fuzzCase, probe: _twoNewMarkers);
    expect(replay.failure?.signature, m.failure.signature);
    final fixture = FuzzFixture.decode(FuzzFixture.ofCase('probe', m.fuzzCase, failure: m.failure).encode());
    final fromFile = FuzzRunner.run(fixture.toCase(), probe: _twoNewMarkers);
    expect(fromFile.failure?.signature, m.failure.signature);
    expect(fromFile.failure?.step, m.after.steps - 1);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('shrinks a failure built up over several steps', () {
    final (original, run) = _failingSeed(_threeNewItemsOnALane, from: 3);
    final m = FuzzMinimizer(probe: _threeNewItemsOnALane).minimize(original);
    printOnFailure('seed ${original.seed}: $m');
    expect(m.failure.signature, run.failure!.signature);
    expect(m.after.compareTo(m.before), lessThan(0));
    expect(m.after.steps, lessThanOrEqualTo(3), reason: '$m');
    expect(FuzzRunner.run(m.fuzzCase, probe: _threeNewItemsOnALane).failure?.check, FuzzCheck.injected);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the budget stops the minimizer with a reproducing case', () {
    final (original, run) = _failingSeed(_twoNewMarkers, from: 10);
    final m = FuzzMinimizer(probe: _twoNewMarkers, maxRuns: 3).minimize(original);
    expect(m.budgetExhausted, isTrue);
    expect(m.runs, lessThanOrEqualTo(4));
    expect(m.failure.signature, run.failure!.signature);
    expect(FuzzRunner.run(m.fuzzCase, probe: _twoNewMarkers).failure?.signature, run.failure!.signature);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('refuses a passing run and a matcher that rejects the failure', () {
    final passing = FuzzCase.forSeed(5, steps: 3);
    expect(FuzzRunner.run(passing).failure, isNull);
    expect(() => FuzzMinimizer().minimize(passing), throwsArgumentError);
    final (original, _) = _failingSeed(_twoNewMarkers);
    expect(() => FuzzMinimizer(probe: _twoNewMarkers).minimize(original, match: (f) => false), throwsArgumentError);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
