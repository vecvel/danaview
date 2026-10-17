// OWNER: CORE-02
//
// One piece of a piecewise-linear timeline → source time map (ARCH §6.4, §11.2). Shared by the
// clip time map (`ClipTimeMap.lower`, CORE-06) and the RenderPlan (`map` of media layers and audio
// segments, CORE-29), so both use one type.

import 'package:meta/meta.dart';

import 'time.dart';

/// Maps timeline `[t0, t1)` linearly onto source `[s0, s1]` (all µs).
///
/// In a RenderPlan, `t0`/`t1` lie on the plan's `canvas.gridFps` grid (D-35) and the rate
/// `(s1 − s0) / (t1 − t0)` is within [0.1, 10]. Source times are exact (unbiased, D-04).
@immutable
final class MapSegment {
  /// Creates a segment. Requires `t1 > t0` and `s1 >= s0`.
  const MapSegment(this.t0, this.t1, this.s0, this.s1)
      : assert(t1 > t0),
        assert(s1 >= s0);

  /// Timeline start (inclusive).
  final TimeUs t0;

  /// Timeline end (exclusive).
  final TimeUs t1;

  /// Source time at [t0].
  final TimeUs s0;

  /// Source time at [t1].
  final TimeUs s1;

  /// Playback rate of this segment (source µs per timeline µs).
  double get rate => (s1 - s0) / (t1 - t0);

  /// Source time at timeline time [t] (linear; not clamped).
  double sourceAt(TimeUs t) => s0 + (t - t0) * (s1 - s0) / (t1 - t0);

  /// Whether timeline time [t] lies in `[t0, t1)`.
  bool contains(TimeUs t) => t >= t0 && t < t1;

  @override
  bool operator ==(Object other) =>
      other is MapSegment && other.t0 == t0 && other.t1 == t1 && other.s0 == s0 && other.s1 == s1;

  @override
  int get hashCode => Object.hash(t0, t1, s0, s1);

  @override
  String toString() => 'MapSegment($t0, $t1, $s0, $s1)';
}
