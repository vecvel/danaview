// OWNER: IOS-18 (temporary diagnostic, removed before hand-off)

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class RampSeamDiagTests: XCTestCase {
    func testDiagnoseSeamClicks() async throws {
        let speeds: [Double] = [1, 1.25, 1.6, 2, 1.6, 1.25, 1]
        let seg = 300_000.0
        let half = 2_500.0
        let tone = try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"))
        let n = speeds.count
        let bounds = (1..<n).map { Int64(Double($0) * seg) }
        for iteration in 0..<12 {
            var tracks: [[AudioTapSupport.Segment]] = [[], []]
            for k in 0..<n {
                let s0 = 500_000 + speeds[..<k].reduce(0) { $0 + $1 * seg }
                let r = speeds[k]
                let pre = k > 0 ? half : 0
                let post = k < n - 1 ? half : 0
                let t0 = Double(k) * seg
                let t1 = t0 + seg
                tracks[k % 2].append(.init(source: tone, t0: t0 - pre, t1: t1 + post, s0: s0 - pre * r, s1: s0 + r * seg + post * r))
            }
            let meters = [GainTapMeter(), GainTapMeter()]
            let taps = (0..<2).map { t in
                GainTap(envelope: TapEnvelope.unity.withSeamCrossfades(TapEnvelope.alternatingSeams(boundariesUs: bounds, track: t)), meter: meters[t])
            }
            let (comp, mix, assets) = try await AudioTapSupport.build(tracks: tracks, taps: taps)
            let read = try AudioTapSupport.readMix(comp, mix: mix)
            withExtendedLifetime(assets) {}
            let x = read.leftChannel
            let e = AudioTapSupport.toneResidual(x, freqHz: 1_000)
            for (j, b) in bounds.enumerated() {
                let c = Int(Double(b) * 48_000 / 1_000_000)
                let a = c - 1_920
                let z = min(c + 1_920, e.count)
                guard a >= 0, z > a else { continue }
                var worst = a
                for i in a..<z where abs(e[i]) > abs(e[worst]) { worst = i }
                if abs(e[worst]) > 0.01 {
                    print("DIAG it\(iteration) seam\(j) b=\(b) click at \(worst - c) frames (\(Double(worst - c) / 48.0) ms) e=\(e[worst]) frames=\(read.frames)")
                    var prof: [String] = []
                    for blk in stride(from: c - 480, to: min(c + 480, x.count), by: 24) {
                        var m: Float = 0
                        for i in blk..<min(blk + 24, x.count) { m = max(m, abs(x[i])) }
                        prof.append(String(format: "%.3f", m))
                    }
                    print("DIAG profile (0.5 ms peaks, seam-10ms..+10ms): \(prof.joined(separator: " "))")
                    for t in 0..<2 {
                        let calls = meters[t].calls.filter { c in
                            guard let s = c.startUs else { return true }
                            return s > Double(b) - 60_000 && s < Double(b) + 60_000
                        }
                        print("DIAG track\(t) calls near seam: \(calls.map { "\($0.startUs.map { String(format: "%.1f", $0) } ?? "nil")+\($0.frames)" })")
                    }
                    for t in 0..<2 {
                        let all = meters[t].calls
                        var gaps: [String] = []
                        for i in 1..<all.count {
                            if let p = all[i - 1].startUs, let s = all[i].startUs {
                                let exp = p + Double(all[i - 1].frames) * 1_000_000 / 48_000
                                if abs(s - exp) > 1 { gaps.append(String(format: "%.1f->%.1f", exp, s)) }
                            }
                        }
                        print("DIAG track\(t) \(all.count) calls, first \(all.first.map { "\($0.startUs ?? -1)" } ?? "-"), range gaps >1us: \(gaps)")
                    }
                }
            }
            print("DIAG it\(iteration) done frames=\(read.frames)")
        }
    }
}
