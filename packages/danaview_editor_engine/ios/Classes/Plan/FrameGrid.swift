// OWNER: IOS-08
//
// The frame grid of ARCH §5 (CORE-02 `FrameRate`) and the platform-time rule D-35, mirrored for
// the iOS engine. Shared vectors: packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json
// (RunnerTests/Composition/FrameGridVectorTests.swift).
//
// - Plan and model times are integer µs; frame k of an integer rate starts at
//   `timeOfFrame(k) = ceil(k·10⁶/fps)`.
// - A platform time τ (composition time, item time, buffer PTS) becomes a frame with
//   `frameIndexNearest(τ) = round(τ·fps/10⁶)`; every evaluation then uses `timeOfFrame(k)`.
// - AVFoundation receives grid times as exact rationals `CMTime(k, fps)` (never µs CMTimes);
//   source times stay `CMTime(µs, 1_000_000)`.

import CoreMedia
import Foundation

/// An integer frame rate (v1: 24, 25, 30, 48, 50 or 60) and its grid arithmetic (ARCH §5).
struct FrameGrid: Equatable, Hashable {
    /// Frames per second.
    let fps: Int64

    init(_ fps: Int) {
        self.fps = Int64(fps)
    }

    init(fps: Int64) {
        self.fps = fps
    }

    /// The v1 rates.
    static let v1Rates: Set<Int> = [24, 25, 30, 48, 50, 60]

    /// floor(a / b) for b > 0.
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    /// ceil(a / b) for b > 0.
    static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }

    /// Plan time of frame k (µs): ceil(k·10⁶/fps).
    func timeOfFrame(_ k: Int64) -> Int64 { Self.ceilDiv(k * 1_000_000, fps) }

    /// The frame containing plan time t: floor(t·fps/10⁶).
    func frameIndexOf(_ t: Int64) -> Int64 { Self.floorDiv(t * fps, 1_000_000) }

    /// Plan time floored to its frame start.
    func quantize(_ t: Int64) -> Int64 { timeOfFrame(frameIndexOf(t)) }

    /// Whether t is a frame start of this grid.
    func isOnGrid(_ t: Int64) -> Bool { quantize(t) == t }

    /// round(τ·fps/10⁶) for a platform time τ in µs (D-35).
    func frameIndexNearest(_ tauUs: Int64) -> Int64 {
        Self.floorDiv(tauUs * fps + 500_000, 1_000_000)
    }

    /// round(time × fps), exact on the rational CMTime (no Double rounding).
    func frameIndexNearest(_ time: CMTime) -> Int64 {
        precondition(time.isNumeric, "non-numeric CMTime")
        let v = time.value
        let ts = Int64(time.timescale)
        // round(v·fps/ts) = floor((2·v·fps + ts) / (2·ts)). Large values fall back to 128-bit maths.
        let (product, overflow) = v.multipliedReportingOverflow(by: 2 * fps)
        if !overflow {
            let (sum, overflow2) = product.addingReportingOverflow(ts)
            if !overflow2 { return Self.floorDiv(sum, 2 * ts) }
        }
        let rounded = (Double(v) * Double(fps) / Double(ts)).rounded(.toNearestOrAwayFromZero)
        return Int64(rounded)
    }

    /// Media3-style platform time P(k) = round(k·10⁶/fps) (shared vectors only on iOS).
    func platformTimeOfFrame(_ k: Int64) -> Int64 {
        Self.floorDiv(2 * k * 1_000_000 + fps, 2 * fps)
    }

    /// Exact grid time of frame k for AVFoundation (D-35 rule 2).
    func cmTime(frame k: Int64) -> CMTime { CMTime(value: k, timescale: CMTimeScale(fps)) }

    /// The grid time of a plan time that lies on this grid (`CMTime(frameIndexOf(t), fps)`).
    func cmTime(gridUs t: Int64) -> CMTime { cmTime(frame: frameIndexOf(t)) }

    /// One frame (`frameDuration` of a video composition).
    var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(fps)) }

    /// A source (non-grid) time in µs.
    static func cmTime(us: Int64) -> CMTime { CMTime(value: us, timescale: 1_000_000) }

    /// µs of a CMTime rounded to nearest (diagnostics; never used for grid decisions).
    static func us(_ time: CMTime) -> Int64 {
        let ts = Int64(time.timescale)
        let (product, overflow) = time.value.multipliedReportingOverflow(by: 2_000_000)
        if !overflow { return floorDiv(product + ts, 2 * ts) }
        return Int64((Double(time.value) * 1_000_000 / Double(ts)).rounded())
    }
}
