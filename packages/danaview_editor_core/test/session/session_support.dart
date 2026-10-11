// OWNER: CORE-19
//
// Shared helpers of the session tests: a fake clock and session construction over the command
// fixtures of test/ops/framework/ops_support.dart.

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../ops/framework/ops_support.dart';

/// A manual UTC clock.
final class FakeClock {
  /// Starts at [start] (default: the fixtures' `when`).
  FakeClock([DateTime? start]) : now = start ?? when;

  /// Current time.
  DateTime now;

  /// The clock function handed to the session.
  DateTime call() => now;

  /// Moves the clock forward.
  void advance(Duration d) => now = now.add(d);
}

/// A session on [p] (default: the standard fixture) with seeded ids and a fake clock.
EditSession sessionOn(
  EditProject? p, {
  FakeClock? clock,
  HistoryPolicy policy = const HistoryPolicy(),
  EditPolicy editPolicy = const EditPolicy(),
  int seed = 900001,
}) =>
    EditSession(
      p ?? standard(),
      ids: SeededIdGenerator(seed),
      policy: policy,
      editPolicy: editPolicy,
      clock: (clock ?? FakeClock()).call,
    );

/// Whether [a] and [b] hold the identical lane, marker and settings objects (snapshot identity;
/// the root revision may differ).
bool sameSnapshot(Timeline a, Timeline b) {
  if (!identical(a.settings, b.settings)) return false;
  if (a.tracks.length != b.tracks.length || a.markers.length != b.markers.length) return false;
  for (var i = 0; i < a.tracks.length; i++) {
    if (!identical(a.tracks[i], b.tracks[i])) return false;
  }
  for (var i = 0; i < a.markers.length; i++) {
    if (!identical(a.markers[i], b.markers[i])) return false;
  }
  return true;
}
