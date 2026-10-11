// OWNER: IOS-18 (temporary diagnostic, removed before hand-off)
import AVFoundation
import XCTest
@testable import vwish_editor_engine

final class ZZDiagTests: XCTestCase {
    func testDiag1x() async throws {
        let tone = try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"))
        for (label, t0, withMeter, env) in [("empty+1x unity", 297_500.0, false, TapEnvelope.unity), ("empty+1x unity meter", 297_500.0, true, TapEnvelope.unity),
                                       ("empty+1x seam", 297_500.0, false, TapEnvelope.unity.withSeamCrossfades([.init(timeUs: 300_000, edge: .incoming)])),
                                       ("noempty 1x seam meter", 0.0, true, TapEnvelope.unity.withSeamCrossfades([.init(timeUs: 2_500, edge: .incoming)])),
                                       ("empty+1x unity meter again", 297_500.0, true, TapEnvelope.unity)] {
            let meter = withMeter ? GainTapMeter() : nil
            let (comp, mix, assets) = try await AudioTapSupport.build(
                tracks: [[.init(source: tone, t0: t0, t1: 600_000, s0: 1_000_000, s1: 1_000_000 + 600_000 - t0)]], taps: [GainTap(envelope: env, meter: meter)])
            let read = try AudioTapSupport.readMix(comp, mix: mix)
            withExtendedLifetime(assets) {}
            let left = read.leftChannel
            var firstNonZero = -1
            for i in 0..<left.count where abs(left[i]) > 1e-4 { firstNonZero = i; break }
            print("DIAG1 \(label): frames=\(left.count) firstNonZero=\(firstNonZero) calls=\(meter?.calls.prefix(3).map { $0.startUs ?? -1 } ?? [])")
        }
    }

    func testDiag() async throws {
        let tone = try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"))
        let speeds: [Double] = [1, 1.25, 1.6, 2, 1.6, 1.25, 1]
        let seg = 300_000.0, half = 2_500.0
        let n = speeds.count
        var tracks: [[AudioTapSupport.Segment]] = [[], []]
        for k in 0..<n {
            let s0 = 500_000 + speeds[..<k].reduce(0) { $0 + $1 * seg }
            let r = speeds[k]
            let pre = k > 0 ? half : 0, post = k < n - 1 ? half : 0
            tracks[k % 2].append(.init(source: tone, t0: Double(k) * seg - pre, t1: Double(k + 1) * seg + post, s0: s0 - pre * r, s1: s0 + r * seg + post * r))
        }
        let b: [Int64] = (1..<n).map { Int64(Double($0) * seg) }
        for solo in [0, 1, -1] {
            let meters = [GainTapMeter(), GainTapMeter()]
            let taps = (0..<2).map { t in
                GainTap(envelope: solo >= 0 && solo != t ? TapEnvelope(planGain: [[0, 0]]) :
                    TapEnvelope.unity.withSeamCrossfades(TapEnvelope.alternatingSeams(boundariesUs: b, track: t)), meter: meters[t])
            }
            let (comp, mix, assets) = try await AudioTapSupport.build(tracks: tracks, taps: taps)
            let read = try AudioTapSupport.readMix(comp, mix: mix)
            withExtendedLifetime(assets) {}
            let left = read.leftChannel
            let e = AudioTapSupport.toneResidual(left, freqHz: 1_000)
            print("DIAG solo=\(solo) frames=\(left.count) calls0=\(meters[0].calls.prefix(3).map { $0.startUs ?? -1 }) calls1=\(meters[1].calls.prefix(3).map { $0.startUs ?? -1 })")
            let c = 14_400
            var mi = 0; var mv: Float = 0
            for i in (c - 1_920)..<(c + 1_920) where abs(e[i]) > mv { mv = abs(e[i]); mi = i }
            let lv = stride(from: 14_160, to: 14_640, by: 24).map { String(format: "%d:%.2f", $0, AudioTapSupport.rmsDb(left, $0, $0 + 24)) }
            print("DIAG solo=\(solo) seam1 maxResidual \(mv) at \(mi) levels \(lv)")
            let around = ((mi - 6)...(mi + 6)).map { String(format: "%.4f", left[$0]) }
            print("DIAG samples \(around)")
        }
    }
}
