// OWNER: CORE-02
//
// Time model and frame grid (ARCH §5, D-03, D-35). Every timeline time is an integer number of
// microseconds; project and export frame rates are integers in v1.
//
// Sub-barrel of `lib/src/time/` (exported by `lib/model.dart`).

import 'package:meta/meta.dart';

export 'map_segment.dart';
export 'timecode.dart';

/// A point or span of time in microseconds (64-bit). Projects are at most 24 h long.
typedef TimeUs = int;

/// One microsecond per unit: 10^6 per second.
const int microsPerSecond = 1000000;

/// Longest supported project, 24 hours (ARCH §6.9 I1).
const TimeUs maxProjectDurationUs = 24 * 3600 * microsPerSecond;

/// Integer division rounding toward negative infinity, safe for negative operands.
int floorDiv(int a, int b) {
  assert(b > 0, 'floorDiv requires a positive divisor');
  final q = a ~/ b;
  return (a % b != 0 && a < 0) ? q - 1 : q;
}

/// Integer division rounding toward positive infinity, safe for negative operands.
int ceilDiv(int a, int b) {
  assert(b > 0, 'ceilDiv requires a positive divisor');
  final q = a ~/ b;
  return (a % b != 0 && a > 0) ? q + 1 : q;
}

/// A frame rate `num / den` frames per second.
///
/// The type stays rational for forward compatibility, but v1 projects and exports accept only
/// integer rates (`den == 1`, `num` in [supportedProjectRates]) (D-03).
///
/// **Plan grid.** Frame *k* starts at [timeOfFrame]`(k) = ceil(k·10⁶·den / num)` µs in every plan
/// and model time. Item edges, keyframes, markers and plan layer edges all lie on this grid.
///
/// **Platform-time rule (normative, ARCH §5, D-35).** Platform clocks stamp frame *k* slightly
/// differently: iOS at the rational `k/fps` (`CMTime(k, fps)`), Media3's clock band at
/// [platformTimeOfFrame]`(k) = round(k·10⁶/fps)`. For 24/30/48/60 fps these can be up to 1 µs
/// *before* the plan edge. Therefore every time that comes from a platform clock or presentation
/// timestamp is first mapped to a frame index with [frameIndexNearest], and layer activity,
/// gating, keyframe/animation/`reveal` evaluation and seek acks use `timeOfFrame(k)`, **never**
/// the raw platform µs. The shared vectors in `test/fixtures/vectors/frame_grid.json` are read by
/// the Dart, Swift and Kotlin tests.
@immutable
final class FrameRate {
  /// Creates the rate `num / den`. Both must be positive.
  const FrameRate(this.num, this.den)
      : assert(num > 0),
        assert(den > 0);

  /// Creates an integer rate of [fps] frames per second (no validation; see [FrameRate.project]).
  const FrameRate.fps(int fps) : this(fps, 1);

  /// A v1 project or export rate. Throws [ArgumentError] unless [fps] is in
  /// [supportedProjectRates] (D-03).
  factory FrameRate.project(int fps) {
    if (!supportedProjectRates.contains(fps)) {
      throw ArgumentError.value(fps, 'fps', 'v1 supports only $supportedProjectRates');
    }
    return FrameRate(fps, 1);
  }

  /// Frames per `den` seconds.
  final int num;

  /// Denominator of the rate (1 for every v1 project and export rate).
  final int den;

  /// The integer rates a v1 project or export may use (D-03).
  static const List<int> supportedProjectRates = [24, 25, 30, 48, 50, 60];

  /// 24 fps.
  static const FrameRate fps24 = FrameRate(24, 1);

  /// 25 fps.
  static const FrameRate fps25 = FrameRate(25, 1);

  /// 30 fps (the default for new empty projects).
  static const FrameRate fps30 = FrameRate(30, 1);

  /// 48 fps.
  static const FrameRate fps48 = FrameRate(48, 1);

  /// 50 fps.
  static const FrameRate fps50 = FrameRate(50, 1);

  /// 60 fps.
  static const FrameRate fps60 = FrameRate(60, 1);

  /// Whether this rate may be used by a v1 project or export (integer rate in the supported set).
  bool get isSupportedProjectRate => den == 1 && supportedProjectRates.contains(num);

  /// Frames per second as a double (display only; never use for grid math).
  double get fps => num / den;

  /// Alias of [num] (ux.md §2.1 `FrameRate.numerator`).
  int get numerator => num;

  /// Alias of [den] (ux.md §2.1 `FrameRate.denominator`).
  int get denominator => den;

  /// The duration of one frame in whole µs, rounded to nearest (`round(10⁶·den / num)`); display
  /// and UI nudges only. Grid arithmetic uses [timeOfFrame] (ux.md §2.1 `frameUs`).
  TimeUs get frameUs => floorDiv(2 * microsPerSecond * den + num, 2 * num);

  /// Start time of frame [k] on the plan grid: `ceil(k·10⁶·den / num)`.
  TimeUs timeOfFrame(int k) => ceilDiv(k * microsPerSecond * den, num);

  /// Index of the frame whose plan-grid interval contains [t]: `floor(t·num / (10⁶·den))`.
  ///
  /// Use only for plan and model times. Times reported by a platform clock go through
  /// [frameIndexNearest] (D-35).
  int frameIndexOf(TimeUs t) => floorDiv(t * num, microsPerSecond * den);

  /// Index of the frame nearest to a **platform** time [tau] (µs): `round(τ·fps / 10⁶)`, computed
  /// exactly as `floorDiv(τ·num + 500000·den, 1000000·den)` (D-35).
  ///
  /// This is the normative mapping for iOS `compositionTime`/item time/output-buffer PTS and for
  /// Media3 effect, compositor and `onVideoFrameAboutToBeRendered` pts and `currentPosition`. It is
  /// exact because the plan, rational and rounded platform times of one frame differ by < 1 µs
  /// while frames are ≥ 16,666 µs apart.
  int frameIndexNearest(TimeUs tau) => floorDiv(tau * num + 500000 * den, microsPerSecond * den);

  /// The frame index nearest to a rational platform time `value / timescale` seconds (for example
  /// a `CMTime`), rounded half up, without converting to µs first.
  int frameIndexOfRational(int value, int timescale) {
    assert(timescale > 0);
    // round(value·num / (timescale·den)) = floor((2·value·num + timescale·den) / (2·timescale·den))
    return floorDiv(2 * value * num + timescale * den, 2 * timescale * den);
  }

  /// The platform frame time `P(k) = round(k·10⁶·den / num)` (half up): the time Media3's clock
  /// band stamps frame [k] with, and where Android anchors every sequence item and gap boundary
  /// (ARCH §5 rule 3, §13.3). Android exact seeks target `P(k)` rounded to ms in the direction
  /// recorded as `androidSeekMsRounding` in `frame_grid.json` (measured by AND-01).
  TimeUs platformTimeOfFrame(int k) => floorDiv(2 * k * microsPerSecond * den + num, 2 * num);

  /// Floors [t] to the start of its frame.
  TimeUs quantize(TimeUs t) => timeOfFrame(frameIndexOf(t));

  /// Rounds [t] to the nearest frame start (ties go to the later frame).
  TimeUs quantizeNearest(TimeUs t) {
    final k = frameIndexOf(t);
    final a = timeOfFrame(k);
    final b = timeOfFrame(k + 1);
    return (t - a) < (b - t) ? a : b;
  }

  /// Whether [t] lies exactly on a frame start of this grid.
  bool isOnGrid(TimeUs t) => quantize(t) == t;

  /// Duration of frame [k] in whole µs (varies by ±1 µs on grids whose frame length is not an
  /// integer number of µs).
  TimeUs frameDurationAt(int k) => timeOfFrame(k + 1) - timeOfFrame(k);

  @override
  bool operator ==(Object other) => other is FrameRate && other.num * den == num * other.den;

  @override
  int get hashCode {
    final g = _gcd(num, den);
    return Object.hash(num ~/ g, den ~/ g);
  }

  @override
  String toString() => den == 1 ? '$num fps' : '$num/$den fps';

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
}

/// A half-open time range `[start, end)` in microseconds.
@immutable
final class TimeRange {
  /// Creates `[start, end)`; [end] must not be before [start].
  const TimeRange(this.start, this.end) : assert(end >= start);

  /// Creates `[start, start + duration)`.
  const TimeRange.withDuration(TimeUs start, TimeUs duration) : this(start, start + duration);

  /// Inclusive start.
  final TimeUs start;

  /// Exclusive end.
  final TimeUs end;

  /// `end - start`.
  TimeUs get duration => end - start;

  /// Whether the range is empty.
  bool get isEmpty => end == start;

  /// Whether [t] lies in `[start, end)`.
  bool contains(TimeUs t) => t >= start && t < end;

  /// Whether this range shares at least one microsecond with [other].
  bool overlaps(TimeRange other) => start < other.end && other.start < end;

  /// The intersection with [other], or `null` when they do not overlap.
  TimeRange? intersect(TimeRange other) {
    final s = start > other.start ? start : other.start;
    final e = end < other.end ? end : other.end;
    return e > s ? TimeRange(s, e) : null;
  }

  /// This range moved by [delta].
  TimeRange shift(TimeUs delta) => TimeRange(start + delta, end + delta);

  @override
  bool operator ==(Object other) => other is TimeRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimeRange($start, $end)';
}
