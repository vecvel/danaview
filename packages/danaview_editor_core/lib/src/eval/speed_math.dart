// OWNER: CORE-06
//
// Speed math (ARCH §6.4, domain.md §4.5): closed forms for speed ramps and small numeric helpers.
//
// A ramp is a piecewise-linear speed `v(x)` over the **normalized source position** `x ∈ [0, 1]`
// of a clip's source range of length `L` µs (2–16 points, strictly increasing x with x₀ = 0 and
// xₙ = 1, speeds in [0.1, 10]). On one segment `[x₀, x₁]` with slope `b = (v₁ − v₀)/(x₁ − x₀)`:
//
//   time spent        τ_seg = (L/b)·ln(v₁/v₀)          (L·Δx/v₀ when b = 0)
//   inverse           x(τ)  = x₀ + v₀·(e^{bτ/L} − 1)/b  (x₀ + v₀·τ/L when b = 0)
//
// Everything below works with the *normalized time* `u = τ / L`, so a ramp is described once for
// any L: `RampProfile.total` is `K = T / L`, hence a clip of timeline duration T plays source
// length `L = T / K`.

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/speed_spec.dart';

/// `ln(1 + x)`, accurate for tiny `x` (Kahan). dart:math has no `log1p`.
double log1p(double x) {
  if (x <= -1) return x == -1 ? double.negativeInfinity : double.nan;
  final u = 1 + x;
  if (u == 1) return x;
  return math.log(u) * x / (u - 1);
}

/// `eˣ − 1`, accurate for tiny `x` (Kahan). dart:math has no `expm1`.
double expm1(double x) {
  final u = math.exp(x);
  if (u == 1) return x;
  final um1 = u - 1;
  if (um1 == -1) return -1;
  if (u.isInfinite) return u;
  return um1 * x / math.log(u);
}

/// `ln(1 + r) / r`, with the limit 1 at `r = 0` and a series for tiny `|r|`.
double log1pOverR(double r) {
  if (r.abs() < 1e-9) return 1 - r / 2 + r * r / 3;
  return log1p(r) / r;
}

/// `(eᶻ − 1) / z`, with the limit 1 at `z = 0` and a series for tiny `|z|`.
double expm1OverZ(double z) {
  if (z.abs() < 1e-9) return 1 + z / 2 + z * z / 6;
  return expm1(z) / z;
}

/// Normalized time `∫ dx / v` over a stretch of length [dx] (in x) where the speed goes linearly
/// from [v0] to [v1]: `(1/b)·ln(v1/v0)` with `b = (v1 − v0)/dx`, or `dx / v0` when `v0 == v1`.
double rampTime(double dx, double v0, double v1) {
  if (dx <= 0) return 0;
  return dx / v0 * log1pOverR((v1 - v0) / v0);
}

/// Inverse of [rampTime] on a segment of length [segDx] whose speed goes from [v0] to [v1]: the
/// position offset reached after normalized time [u] (`v₀·(e^{b·u} − 1)/b`).
double rampOffsetAtTime(double u, double segDx, double v0, double v1) {
  if (u <= 0) return 0;
  final b = (v1 - v0) / segDx;
  return v0 * u * expm1OverZ(b * u);
}

/// Problems with [ramp] as a speed ramp (empty when it is valid): point count 2–16, x₀ = 0,
/// xₙ = 1, strictly increasing x, speeds in [[minClipSpeed], [maxClipSpeed]] and all finite.
List<String> speedRampIssues(SpeedRamp ramp) {
  final p = ramp.points;
  final issues = <String>[];
  if (p.length < 2 || p.length > 16) issues.add('a ramp needs 2 to 16 points, has ${p.length}');
  if (p.isEmpty) return issues;
  if (p.first.x != 0) issues.add('the first point must be at x = 0');
  if (p.last.x != 1) issues.add('the last point must be at x = 1');
  for (var i = 0; i < p.length; i++) {
    final pt = p[i];
    if (!pt.x.isFinite || !pt.y.isFinite) {
      issues.add('point $i is not finite');
      continue;
    }
    if (pt.y < minClipSpeed || pt.y > maxClipSpeed) issues.add('point $i speed ${pt.y} is outside [$minClipSpeed, $maxClipSpeed]');
    if (i > 0 && !(pt.x > p[i - 1].x)) issues.add('point $i is not to the right of point ${i - 1}');
  }
  return issues;
}

/// A [SpeedRamp] prepared for evaluation: segment boundaries and the cumulative normalized time at
/// each point. Immutable; build once per clip.
final class RampProfile {
  RampProfile._(this.xs, this.vs, this.cumulative);

  /// Builds a profile. Throws [ArgumentError] when [speedRampIssues] reports problems.
  factory RampProfile(SpeedRamp ramp) {
    final issues = speedRampIssues(ramp);
    if (issues.isNotEmpty) throw ArgumentError.value(ramp, 'ramp', issues.join('; '));
    final n = ramp.points.length;
    final xs = Float64List(n);
    final vs = Float64List(n);
    final cum = Float64List(n);
    for (var i = 0; i < n; i++) {
      xs[i] = ramp.points[i].x;
      vs[i] = ramp.points[i].y;
      if (i > 0) cum[i] = cum[i - 1] + rampTime(xs[i] - xs[i - 1], vs[i - 1], vs[i]);
    }
    return RampProfile._(xs, vs, cum);
  }

  /// Point positions (normalized source position, 0 → 1).
  final Float64List xs;

  /// Point speeds.
  final Float64List vs;

  /// Normalized time at each point: `cumulative[i] = ∫₀^{xᵢ} dx / v`.
  final Float64List cumulative;

  /// `K`: the normalized time of the whole ramp. A clip of source length L takes `L·K` µs.
  double get total => cumulative.last;

  /// Number of points.
  int get length => xs.length;

  /// Index `i` of the segment `[xᵢ, xᵢ₊₁]` containing [x] (clamped to the ramp).
  int _segmentOfPosition(double x) {
    var lo = 0;
    var hi = xs.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (xs[mid] <= x) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Index `i` of the segment whose normalized-time span contains [u] (clamped).
  int _segmentOfTime(double u) {
    var lo = 0;
    var hi = xs.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cumulative[mid] <= u) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The speed at normalized source position [x] (linear between points; clamped to [0, 1]).
  double speedAtPosition(double x) {
    final xc = x.clamp(0.0, 1.0).toDouble();
    final i = _segmentOfPosition(xc);
    final dx = xs[i + 1] - xs[i];
    return vs[i] + (vs[i + 1] - vs[i]) * ((xc - xs[i]) / dx);
  }

  /// Normalized time `u(x)` at which the clip reaches position [x] (clamped to [0, 1]).
  double timeAtPosition(double x) {
    final xc = x.clamp(0.0, 1.0).toDouble();
    final i = _segmentOfPosition(xc);
    final dx = xs[i + 1] - xs[i];
    final off = xc - xs[i];
    final v = vs[i] + (vs[i + 1] - vs[i]) * (off / dx);
    return cumulative[i] + rampTime(off, vs[i], v);
  }

  /// Position `x(u)` reached after normalized time [u] (clamped to [0, [total]]).
  double positionAtTime(double u) {
    if (u <= 0) return 0;
    if (u >= total) return 1;
    final i = _segmentOfTime(u);
    final off = rampOffsetAtTime(u - cumulative[i], xs[i + 1] - xs[i], vs[i], vs[i + 1]);
    final x = xs[i] + off;
    return x > xs[i + 1] ? xs[i + 1] : x;
  }

  /// Normalized position where each point sits in normalized time (the segment seams).
  Float64List get seamTimes => cumulative;
}

/// Points closer than this (normalized) to a crop boundary are merged into it.
const double _cropEpsilon = 1e-9;

/// Operations on [SpeedRamp] values.
abstract final class SpeedRamps {
  /// Crops [ramp] to the normalized source window `[a, b]` (`0 ≤ a < b ≤ 1`) and renormalizes it
  /// to `[0, 1]`: content keeps the speeds it had (trimming a clip crops its ramp, domain.md §4.5).
  /// Points inside the window are kept, boundary points carry the interpolated speeds, and the
  /// preset id is dropped (a cropped curve is custom).
  static SpeedRamp crop(SpeedRamp ramp, double a, double b) {
    if (!(a >= 0 && b <= 1 && a < b)) throw RangeError('crop window must satisfy 0 <= a < b <= 1, got [$a, $b]');
    final profile = RampProfile(ramp);
    final points = <SpeedPoint>[SpeedPoint(0, profile.speedAtPosition(a))];
    for (var i = 0; i < profile.length; i++) {
      final x = profile.xs[i];
      final nx = (x - a) / (b - a);
      if (nx > _cropEpsilon && nx < 1 - _cropEpsilon) points.add(SpeedPoint(nx, profile.vs[i]));
    }
    points.add(SpeedPoint(1, profile.speedAtPosition(b)));
    return SpeedRamp(points);
  }

  /// The speed of [ramp] at normalized source position [x].
  static double speedAt(SpeedRamp ramp, double x) => RampProfile(ramp).speedAtPosition(x);

  /// Normalized time `K` of [ramp]: a source range of length L plays in `L·K` µs.
  static double timeFactor(SpeedRamp ramp) => RampProfile(ramp).total;

  /// Whether every speed of [ramp] is the same (it behaves like a constant speed).
  static bool isFlat(SpeedRamp ramp) => ramp.points.every((p) => p.y == ramp.points.first.y);
}

/// The time factor `K` for any [SpeedSpec]: `1 / rate` for a constant speed, the ramp's total for a
/// ramp. A source length L plays in `L·K` µs.
double speedTimeFactor(SpeedSpec speed) => switch (speed) {
      ConstantSpeed(:final rate) => 1 / rate,
      SpeedRamp() => RampProfile(speed).total,
    };
