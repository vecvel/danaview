// OWNER: CORE-06
//
// The clip time map (ARCH §6.4, §11.3, §11.5; domain.md §4.5): the one function that says which
// source time a media clip shows at a timeline time, for constant speeds in [0.1, 10], speed ramps,
// and reversed clips. Preview, split, the AI transcript mapping (`timelineTimeOf`) and the plan
// compiler all derive from it, and a clip's video layer and audio segment are lowered from the
// same map (A/V sync contract, ARCH §11.5).
//
// A clip stores `(sourceIn, duration, speed)`; `sourceOut` is derived. Let `K` be the normalized
// time of the speed (`1/rate`, or the ramp total) — a source length L plays in `L·K` µs — so
// `L = duration / K` and `sourceOut = sourceIn + round(L)`.
//
// Reversed clips: the forward map `f(t)` runs from `sourceIn`, and the clip shows
// `s' = sourceIn + sourceOut − f(t)`. They play a reversed rendition whose time is
// `r = sourceOut − s' = f(t) − sourceIn` (increasing; ARCH §11.5 "r = R.end − s"), so
// [ClipTimeMap.lower] returns the *increasing* map into the playback asset's time: source time for
// forward clips, rendition time (starting at 0) for reversed clips.

import 'dart:typed_data';

import '../model/items.dart';
import '../model/speed_spec.dart';
import '../time/time.dart';
import 'speed_math.dart';

/// Maximum source-time error of [ClipTimeMap.lower], in µs, at every frame start (half the video
/// bias, domain.md §12.3).
const int defaultLowerMaxErrorUs = 250;

/// The two halves of a clip split by [ClipTimeMap.splitAt].
typedef ClipSplit = ({
  SpeedSpec leftSpeed,
  SpeedSpec rightSpeed,
  TimeUs leftSourceIn,
  TimeUs rightSourceIn,
  TimeUs leftDuration,
  TimeUs rightDuration,
});

/// Time map of one media clip. Immutable; cheap to build (a ramp is prepared once).
final class ClipTimeMap {
  /// Creates the map of a clip that starts at [start], lasts [duration] and plays the source from
  /// [sourceIn] at [speed] (reversed when [reversed]). [rate] is the project frame rate the
  /// lowered breakpoints lie on (D-35).
  ///
  /// Throws [ArgumentError] when [duration] is not positive, a constant speed is outside
  /// `[0.1, 10]`, or a ramp is invalid ([speedRampIssues]). Validate decoded projects before
  /// building maps.
  factory ClipTimeMap({
    required TimeUs start,
    required TimeUs duration,
    required TimeUs sourceIn,
    SpeedSpec speed = SpeedSpec.normal,
    bool reversed = false,
    required FrameRate rate,
  }) {
    if (duration <= 0) throw ArgumentError.value(duration, 'duration', 'must be positive');
    final double k;
    RampProfile? profile;
    switch (speed) {
      case ConstantSpeed(:final rate):
        if (!(rate >= minClipSpeed && rate <= maxClipSpeed)) {
          throw ArgumentError.value(rate, 'speed', 'must be in [$minClipSpeed, $maxClipSpeed]');
        }
        k = 1 / rate;
      case SpeedRamp():
        profile = RampProfile(speed);
        k = profile.total;
    }
    final exact = duration / k;
    return ClipTimeMap._(start, duration, sourceIn, speed, reversed, rate, profile, exact, _lengthUs(duration, exact));
  }

  /// The map of [clip] on a project of frame rate [rate].
  factory ClipTimeMap.forClip(MediaClip clip, FrameRate rate) => ClipTimeMap(
        start: clip.start,
        duration: clip.duration,
        sourceIn: clip.sourceIn,
        speed: clip.speed,
        reversed: clip.reversed,
        rate: rate,
      );

  const ClipTimeMap._(
    this.start,
    this.duration,
    this.sourceIn,
    this.speed,
    this.reversed,
    this.rate,
    this._profile,
    this._length,
    this.sourceLengthUs,
  );

  /// Timeline start of the clip.
  final TimeUs start;

  /// Timeline duration of the clip.
  final TimeUs duration;

  /// Source time at the first frame of a forward clip.
  final TimeUs sourceIn;

  /// Constant speed or ramp.
  final SpeedSpec speed;

  /// Whether the clip plays its source backwards.
  final bool reversed;

  /// The project frame rate the lowered breakpoints lie on.
  final FrameRate rate;

  final RampProfile? _profile;

  /// The exact source length `L` in µs (`duration / K`).
  final double _length;

  /// The source length in whole µs: `round(L)`, limited so the average rate stays in [0.1, 10].
  final TimeUs sourceLengthUs;

  /// Timeline end (exclusive).
  TimeUs get end => start + duration;

  /// Source time where the clip's source range ends (exclusive): `sourceIn + sourceLengthUs`.
  TimeUs get sourceOut => sourceIn + sourceLengthUs;

  /// The source range `[sourceIn, sourceOut)` the clip plays (also when reversed).
  TimeRange get sourceRange => TimeRange(sourceIn, sourceOut);

  /// The source length in whole µs of a clip of timeline [duration] and [speed] (rate-free).
  static TimeUs sourceLengthOf(TimeUs duration, SpeedSpec speed) {
    final k = speedTimeFactor(speed);
    return _lengthUs(duration, duration / k);
  }

  /// The timeline duration that plays [sourceRange] at [speed], on the grid of [rate]:
  /// `max(1 frame, quantizeNearest(T))` with `T = L·K` (ARCH §6.3 duration authority). A speed
  /// change keeps the source range and recomputes the duration with this.
  static TimeUs durationFor(TimeRange sourceRange, SpeedSpec speed, FrameRate rate) {
    final t = (sourceRange.duration * speedTimeFactor(speed)).round();
    final snapped = rate.quantizeNearest(t);
    final oneFrame = rate.timeOfFrame(1);
    return snapped < oneFrame ? oneFrame : snapped;
  }

  static TimeUs _lengthUs(TimeUs duration, double exact) {
    final lo = (0.1 * duration).ceil();
    final hi = (10 * duration).floor();
    final r = exact.round();
    return r < lo ? lo : (r > hi ? hi : r);
  }

  // -------------------------------------------------------------------------------------------
  // Evaluation.
  // -------------------------------------------------------------------------------------------

  double _tau(TimeUs t) => (t - start).clamp(0, duration).toDouble();

  /// Forward position `pos ∈ [0, L]` (µs of source advanced) after clip-local time τ.
  double _positionAt(double tau) {
    final p = _profile;
    if (p == null) return tau * (speed as ConstantSpeed).rate;
    return _length * p.positionAtTime(tau / _length);
  }

  /// Clip-local time τ at which the forward position is [pos] (inverse of [_positionAt]).
  double _timeOfPosition(double pos) {
    final p = _profile;
    if (p == null) return pos / (speed as ConstantSpeed).rate;
    return _length * p.timeAtPosition(pos / _length);
  }

  /// The exact source time (µs, fractional) shown at timeline time [t] (clamped to the clip).
  /// Reversed clips return `sourceOut − pos`.
  double sourceAt(TimeUs t) {
    final pos = _positionAt(_tau(t));
    return reversed ? sourceOut - pos : sourceIn + pos;
  }

  /// The source time in whole µs shown at timeline time [t], limited to
  /// `[sourceIn, sourceOut − 1]`.
  TimeUs toSource(TimeUs t) {
    final s = sourceAt(t).round();
    final hi = sourceOut - 1;
    return s < sourceIn ? sourceIn : (s > hi ? hi : s);
  }

  /// The exact timeline time (µs, fractional) at which source time [s] is shown, or null when [s]
  /// is trimmed away: outside `[sourceIn, sourceOut)` (`(sourceIn, sourceOut]` for reversed
  /// clips, whose first frame shows `sourceOut`). The exact inverse of [sourceAt].
  double? timelineAt(double s) {
    final pos = reversed ? sourceOut - s : s - sourceIn;
    if (pos < 0 || pos >= sourceLengthUs) return null;
    return start + _timeOfPosition(pos);
  }

  /// The timeline time (whole µs, rounded) at which source time [s] is shown, or null when it is
  /// trimmed away (AI transcript mapping, ai.md §10.1). `timelineTimeOf(toSource(t))` returns `t`
  /// to within ±1 µs when the speed is at least 1×; for slower clips the source quantum (1 µs of
  /// source = `1/speed` µs of timeline) bounds the difference.
  TimeUs? timelineTimeOf(TimeUs s) {
    final t = timelineAt(s.toDouble());
    return t?.round();
  }

  /// The playback rate (source µs per timeline µs) at timeline time [t] (clamped to the clip). A
  /// reversed clip reports the same positive magnitude.
  double speedAt(TimeUs t) {
    final p = _profile;
    if (p == null) return (speed as ConstantSpeed).rate;
    return p.speedAtPosition(_positionAt(_tau(t)) / _length);
  }

  // -------------------------------------------------------------------------------------------
  // Splitting.
  // -------------------------------------------------------------------------------------------

  /// What a split at timeline time [at] (`start < at < end`) leaves in the two halves, defined
  /// through the time map so it is correct for ramps and reversed clips (domain.md §4.10
  /// `SplitItems`): each half keeps its source range and its content's speeds, so the halves'
  /// maps equal this map at every frame (± the 1 µs rounding of the right half's `sourceIn`).
  ///
  /// * constant speed: both halves keep the speed;
  /// * ramp: the left half gets `crop(0, x)` and the right half `crop(x, 1)` where `x` is the
  ///   normalized source position of the cut ([SpeedRamps.crop]);
  /// * forward clip: the right half starts at `sourceIn + round(pos)`;
  /// * reversed clip: the left half (which plays the end of the source range first) starts at
  ///   `sourceOut − round(pos)`, the right half keeps `sourceIn`.
  ///
  /// Throws [RangeError] when [at] is not inside the clip.
  ClipSplit splitAt(TimeUs at) {
    if (at <= start || at >= end) {
      throw RangeError.range(at, start + 1, end - 1, 'at', 'split time must lie strictly inside the clip');
    }
    final pos = _positionAt((at - start).toDouble());
    final cut = pos.round();
    final SpeedSpec leftSpeed;
    final SpeedSpec rightSpeed;
    if (speed is SpeedRamp) {
      final x = pos / _length;
      leftSpeed = SpeedRamps.crop(speed as SpeedRamp, 0, x);
      rightSpeed = SpeedRamps.crop(speed as SpeedRamp, x, 1);
    } else {
      leftSpeed = speed;
      rightSpeed = speed;
    }
    return (
      leftSpeed: leftSpeed,
      rightSpeed: rightSpeed,
      leftSourceIn: reversed ? sourceOut - cut : sourceIn,
      rightSourceIn: reversed ? sourceIn : sourceIn + cut,
      leftDuration: at - start,
      rightDuration: end - at,
    );
  }

  // -------------------------------------------------------------------------------------------
  // Lowering.
  // -------------------------------------------------------------------------------------------

  /// Lowers the map to contiguous piecewise-linear [MapSegment]s covering `[start, end)` for the
  /// RenderPlan (ARCH §11.3):
  ///
  /// * every segment has a rate in [0.1, 10];
  /// * every interior breakpoint `t` is a frame start of the project grid ([rate], D-35), the
  ///   first and last are the clip's own start and end;
  /// * the segment map is within [maxErrorUs] of source time at every frame start;
  /// * the map is increasing and in the playback asset's time: source time for forward clips,
  ///   reversed-rendition time (0 at the clip start) for reversed clips (`r = sourceOut − s`).
  ///
  /// A constant speed lowers to one segment; a ramp splits adaptively (typically 10–40 segments).
  List<MapSegment> lower({int maxErrorUs = defaultLowerMaxErrorUs}) {
    final base = reversed ? 0 : sourceIn;
    final profile = _profile;
    if (profile == null) {
      return [MapSegment(start, end, base, base + sourceLengthUs)];
    }

    // Frame starts strictly inside (start, end).
    var kLo = rate.frameIndexOf(start);
    while (rate.timeOfFrame(kLo) <= start) {
      kLo++;
    }
    var kHi = rate.frameIndexOf(end);
    while (rate.timeOfFrame(kHi) >= end) {
      kHi--;
    }
    final interior = kHi >= kLo ? kHi - kLo + 1 : 0;
    final m = interior + 1; // last index; index 0 is `start`, index m is `end`
    final times = Int64List(m + 1);
    final pos = Float64List(m + 1);
    times[0] = start;
    pos[0] = 0;
    for (var j = 1; j <= interior; j++) {
      final t = rate.timeOfFrame(kLo + j - 1);
      times[j] = t;
      pos[j] = _positionAt((t - start).toDouble());
    }
    times[m] = end;
    pos[m] = _length;

    final tol = maxErrorUs > 4 ? maxErrorUs - 2.0 : maxErrorUs / 2;

    // Seed with the ramp's own corners (snapped to the nearest frame), then refine adaptively.
    final seeds = <int>{0, m};
    for (var i = 1; i < profile.length - 1; i++) {
      final target = start + (_length * profile.cumulative[i]).round();
      final idx = _nearestIndex(times, target);
      if (idx > 0 && idx < m) seeds.add(idx);
    }
    final sorted = seeds.toList()..sort();
    final breaks = <int>[0];

    // Whether the chord from index [a] to index [b] stays within [tol] of the exact position at
    // every frame start strictly between them.
    bool feasible(int a, int b) {
      final ta = times[a].toDouble();
      final span = (times[b] - times[a]).toDouble();
      final pa = pos[a];
      final dp = pos[b] - pa;
      for (var j = a + 1; j < b; j++) {
        if ((pos[j] - (pa + dp * ((times[j] - ta) / span))).abs() > tol) return false;
      }
      return true;
    }

    // Greedy: from [a], take the farthest end [b] (≤ [limit]) whose chord is feasible, found by
    // galloping then bisection on the length. Every accepted chord is verified in full.
    void refine(int a, int limit) {
      var from = a;
      while (from < limit) {
        var best = from + 1; // adjacent frames have no interior frame: always feasible
        var step = 1;
        var failed = limit + 1;
        while (true) {
          final probe = from + 2 * step;
          if (probe > limit) {
            if (feasible(from, limit)) {
              best = limit;
            } else {
              failed = limit;
            }
            break;
          }
          if (feasible(from, probe)) {
            best = probe;
            step *= 2;
          } else {
            failed = probe;
            break;
          }
        }
        while (failed - best > 1) {
          final mid = (best + failed) >> 1;
          if (feasible(from, mid)) {
            best = mid;
          } else {
            failed = mid;
          }
        }
        breaks.add(best);
        from = best;
      }
    }

    for (var i = 1; i < sorted.length; i++) {
      refine(sorted[i - 1], sorted[i]);
    }

    // Integer source times at the breakpoints, keeping every segment's rate inside [0.1, 10] and
    // the end exactly at sourceOut.
    final n = breaks.length;
    final t = [for (final i in breaks) times[i]];
    final s = List<int>.filled(n, 0);
    s[0] = base;
    final sEnd = base + sourceLengthUs;
    s[n - 1] = sEnd;
    final tEnd = t[n - 1];
    for (var i = 1; i < n - 1; i++) {
      final dt = t[i] - t[i - 1];
      final rem = tEnd - t[i];
      var lo = s[i - 1] + (0.1 * dt).ceil();
      var hi = s[i - 1] + (10 * dt).floor();
      final loEnd = sEnd - (10 * rem).floor();
      final hiEnd = sEnd - (0.1 * rem).ceil();
      if (loEnd <= hi && hiEnd >= lo) {
        if (loEnd > lo) lo = loEnd;
        if (hiEnd < hi) hi = hiEnd;
      }
      final wanted = base + pos[breaks[i]].round();
      s[i] = wanted < lo ? lo : (wanted > hi ? hi : wanted);
    }

    return [for (var i = 0; i + 1 < n; i++) MapSegment(t[i], t[i + 1], s[i], s[i + 1])];
  }

  /// Index in the sorted [times] closest to [target].
  static int _nearestIndex(Int64List times, TimeUs target) {
    var lo = 0;
    var hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (target - times[lo - 1]) <= (times[lo] - target)) return lo - 1;
    return lo;
  }
}

/// Time-map accessors on a [MediaClip] (ux.md §2.1 `source`, domain.md §4.4 derived values).
extension MediaClipTimeMap on MediaClip {
  /// The time map of this clip on a project of frame rate [rate].
  ClipTimeMap timeMap(FrameRate rate) => ClipTimeMap.forClip(this, rate);

  /// The exclusive end of the source range, derived from `(sourceIn, duration, speed)`.
  TimeUs get sourceOut => sourceIn + ClipTimeMap.sourceLengthOf(duration, speed);

  /// The source range `[sourceIn, sourceOut)` the clip plays.
  TimeRange get sourceRange => TimeRange(sourceIn, sourceOut);
}
