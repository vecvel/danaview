import CoreMedia
import Foundation

/// ARCH §5 / D-35 frame grid, mirrored from `danaview_editor_core` (CORE-02) for the spike.
///
/// Plan/model times use `timeOfFrame(k) = ceil(k·10⁶/fps)`; platform times (iOS `compositionTime`,
/// item time, output PTS) are mapped back with `frameIndexNearest` and evaluated at
/// `timeOfFrame(k)`. Grid times handed to AVFoundation are the exact rationals `CMTime(k, fps)`.
enum Grid {
  static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
  }

  static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }

  /// Plan time of frame k (µs): ceil(k·10⁶/fps).
  static func timeOfFrame(_ k: Int64, fps: Int64) -> Int64 { ceilDiv(k * 1_000_000, fps) }

  /// floor(t·fps/10⁶): the frame containing plan time t.
  static func frameIndexOf(_ t: Int64, fps: Int64) -> Int64 { floorDiv(t * fps, 1_000_000) }

  /// round(τ·fps/10⁶) for a platform time in µs.
  static func frameIndexNearest(_ tauUs: Int64, fps: Int64) -> Int64 {
    floorDiv(tauUs * fps + 500_000, 1_000_000)
  }

  /// round(time × fps), computed exactly on the rational CMTime (no Double rounding).
  static func frameIndexNearest(_ time: CMTime, fps: Int64) -> Int64 {
    precondition(time.isNumeric, "non-numeric CMTime")
    let v = time.value
    let ts = Int64(time.timescale)
    return floorDiv(2 * v * fps + ts, 2 * ts)
  }

  /// Media3-style platform time P(k) = round(k·10⁶/fps) (kept for the shared vectors).
  static func platformTimeOfFrame(_ k: Int64, fps: Int64) -> Int64 {
    floorDiv(2 * k * 1_000_000 + fps, 2 * fps)
  }

  /// Exact grid time for AVFoundation (D-35 rule 2).
  static func cm(frame k: Int64, fps: Int64) -> CMTime { CMTime(value: k, timescale: Int32(fps)) }

  /// Source (non-grid) times stay microsecond CMTimes.
  static func cm(us: Int64) -> CMTime { CMTime(value: us, timescale: 1_000_000) }

  /// Microseconds of a CMTime, rounded to nearest (diagnostics only).
  static func us(_ time: CMTime) -> Int64 {
    floorDiv(2 * time.value * 1_000_000 + Int64(time.timescale), 2 * Int64(time.timescale))
  }
}
