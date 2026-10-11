// OWNER: IOS-18
//
// Ramp-seam click test (BUILD_PLAN IOS-18, review issue 21, ARCH §13.2 'Audio'): a 7-point speed
// ramp (7 segments of 300 ms at 1, 1.25, 1.6, 2, 1.6, 1.25, 1×) over tone_1khz with keep-pitch
// (`.timeDomain`) read through AVAssetReaderAudioMixOutput with GainTaps.
//
// Click metric: the pure-tone predictor residual e[i] = x[i] − 2cos(ω)·x[i−1] + x[i−2] (0 for a steady
// 1 kHz sine, ≈ the jump size at a discontinuity). A seam passes when the largest residual within
// ±40 ms of it (grain placement moves seams by up to 29.5 ms, ARCH §14.2) exceeds the largest
// residual inside the segments (the time-stretcher's own floor) by no more than −40 dBFS (0.01).
//
// Two layouts are measured: (a) one composition track, plain per-segment scaleTimeRange (the default
// of IOS-08), and (b) the ramp-seam option: segments alternate across two tracks, each extended 2.5 ms
// over the seam, with 5 ms equal-power tap crossfades (`TapEnvelope.withSeamCrossfades`). The AC is
// met when (a) passes, or (b) passes and the option is enabled; (b) must pass in any case, so the
// fallback is always available to IOS-08.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class RampSeamTests: XCTestCase {
    private static let speeds: [Double] = [1, 1.25, 1.6, 2, 1.6, 1.25, 1]
    private static let segmentUs = 300_000.0
    private static let halfUs = Double(TapEnvelope.seamCrossfadeUs) / 2

    private func toneFixture() throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"), "ENG-05 tone_1khz.wav missing")
    }

    /// Composition [t0, t1) and source [s0, s1) of ramp segment k (source starts at 0.5 s).
    private func segment(_ k: Int) -> (t0: Double, t1: Double, s0: Double, s1: Double, rate: Double) {
        let s0 = 500_000 + Self.speeds[..<k].reduce(0) { $0 + $1 * Self.segmentUs }
        let rate = Self.speeds[k]
        return (Double(k) * Self.segmentUs, Double(k + 1) * Self.segmentUs, s0, s0 + rate * Self.segmentUs, rate)
    }

    private var expectFrames: Int { Int(Double(Self.speeds.count) * Self.segmentUs * 48_000 / 1_000_000) - 480 }

    private var boundariesUs: [Int64] { (1..<Self.speeds.count).map { Int64(Double($0) * Self.segmentUs) } }

    struct SeamReport {
        var floor: Float
        var seams: [Float]
        var worstExcessDb: Double {
            let excess = (seams.max() ?? 0) - floor
            return excess > 0 ? 20 * log10(Double(excess)) : -.infinity
        }
        var passes: Bool { (seams.max() ?? 0) - floor <= 0.01 }
    }

    private func measure(_ read: AudioTapSupport.MixRead) -> SeamReport {
        let left = read.leftChannel
        let e = AudioTapSupport.toneResidual(left, freqHz: 1_000)
        let n = Self.speeds.count
        let total = Int(Double(n) * Self.segmentUs * 48_000 / 1_000_000)
        XCTAssertGreaterThanOrEqual(left.count, total - 480, "short read")
        func frame(_ us: Double) -> Int { Int(us * 48_000 / 1_000_000) }
        var floor: Float = 0
        for k in 0..<n {
            let s = segment(k)
            // Inside the segment, away from both seams and from the read's first/last 50 ms.
            floor = max(floor, AudioTapSupport.maxAbs(e, frame(s.t0 + 50_000), frame(s.t1 - 50_000)))
        }
        let seams = boundariesUs.map { b in AudioTapSupport.maxAbs(e, frame(Double(b) - 40_000), frame(Double(b) + 40_000)) }
        return SeamReport(floor: floor, seams: seams)
    }

    /// (a) One track, per-segment scaleTimeRange. Nil when no good read came back: on the iOS 26.5
    /// simulator this layout often reads with silent windows or hangs (IOS-18 run 2026-10-11: 3 of 4
    /// reads bad), which is itself a reason for the crossfade option.
    private func singleTrackRead() async throws -> AudioTapSupport.MixRead? {
        let tone = try toneFixture()
        let segs = (0..<Self.speeds.count).map { k -> AudioTapSupport.Segment in
            let s = segment(k)
            return .init(source: tone, t0: s.t0, t1: s.t1, s0: s.s0, s1: s.s1)
        }
        let (read, reads) = try await AudioTapSupport.readValidated(expectFrames: expectFrames, audible: [0..<expectFrames]) {
            try await AudioTapSupport.buildWithTaps(tracks: [segs], taps: [GainTap()])
        }
        let bad = AudioTapSupport.badReason(read, expectFrames: expectFrames, audible: [0..<expectFrames])
        print("IOS-18 ramp single-track: \(reads) read(s), bad=\(bad ?? "no")")
        return bad == nil ? read : nil
    }

    /// (b) The ramp-seam option: alternate tracks, ±2.5 ms overlap, 5 ms equal-power crossfades.
    private func crossfadeRead() async throws -> AudioTapSupport.MixRead {
        let tone = try toneFixture()
        let n = Self.speeds.count
        var tracks: [[AudioTapSupport.Segment]] = [[], []]
        for k in 0..<n {
            let s = segment(k)
            let pre = k > 0 ? Self.halfUs : 0
            let post = k < n - 1 ? Self.halfUs : 0
            tracks[k % 2].append(
                .init(source: tone, t0: s.t0 - pre, t1: s.t1 + post, s0: s.s0 - pre * s.rate, s1: s.s1 + post * s.rate))
        }
        let envelopes = (0..<2).map { track in
            TapEnvelope.unity.withSeamCrossfades(TapEnvelope.alternatingSeams(boundariesUs: boundariesUs, track: track))
        }
        let (read, reads) = try await AudioTapSupport.readValidated(expectFrames: expectFrames, audible: [0..<expectFrames]) {
            try await AudioTapSupport.buildWithTaps(tracks: tracks, taps: envelopes.map { GainTap(envelope: $0) })
        }
        print("IOS-18 ramp crossfade: \(reads) read(s)")
        XCTAssertFalse(read.hung)
        return read
    }

    func testRampSeamClickTestWithKeepPitch() async throws {
        let single = try await singleTrackRead().map(measure)
        let crossfadeRead = try await crossfadeRead()
        XCTAssertNil(
            AudioTapSupport.badReason(crossfadeRead, expectFrames: expectFrames, audible: [0..<expectFrames]),
            "crossfade layout: no good read")
        let crossfade = measure(crossfadeRead)
        let singleText = single.map { "floor \($0.floor) seams \($0.seams) worst excess \($0.worstExcessDb) dBFS" } ?? "no good read"
        print(
            "IOS-18 ramp seams: single-track \(singleText); "
                + "crossfade floor \(crossfade.floor) seams \(crossfade.seams) worst excess \(crossfade.worstExcessDb) dBFS")
        // The fallback must always pass, so IOS-08 can use it.
        XCTAssertTrue(
            crossfade.passes,
            "crossfade option: seam transient \(crossfade.worstExcessDb) dBFS above the tone "
                + "(floor \(crossfade.floor), seams \(crossfade.seams))")
        // AC: the single-track layout passes, or the crossfade option is enabled (and passing).
        XCTAssertTrue(
            TapEnvelope.rampSeamCrossfadesEnabled || single?.passes == true,
            "single-track ramp seams fail (\(singleText)) and the crossfade option is disabled")
    }

    /// The detector itself: a hard 1 kHz phase jump of 90° at 0.5 s is far above −40 dBFS, a steady
    /// tone gives nothing.
    func testClickDetectorSeesPhaseJumps() {
        let a = 0.251188643
        var x = (0..<48_000).map { AudioTapSupport.tone(1_000, a)($0) }
        let e0 = AudioTapSupport.toneResidual(x, freqHz: 1_000)
        XCTAssertLessThan(AudioTapSupport.maxAbs(e0, 2, x.count), 1e-5)
        for i in 24_000..<48_000 { x[i] = AudioTapSupport.tone(1_000, a, Double.pi / 2)(i) }
        let e1 = AudioTapSupport.toneResidual(x, freqHz: 1_000)
        XCTAssertGreaterThan(AudioTapSupport.maxAbs(e1, 23_990, 24_010), 0.1)
    }
}
