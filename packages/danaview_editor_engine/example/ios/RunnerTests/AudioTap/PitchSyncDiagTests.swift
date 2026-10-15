// OWNER: FIX-IOS-PITCH-SYNC (temporary diagnostic, removed before hand-off)

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PitchSyncDiagTests: XCTestCase {
    static let clickEveryUs = 600_000.0
    static let clickFirstUs = 300_000.0

    static func clickSource(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("clicks.wav")
        let len = Int(0.020 * AudioTapSupport.sampleRate)
        try AudioTapSupport.writeWav(url, seconds: 14, channels: [{ n in
            let t = Double(n) / AudioTapSupport.sampleRate * 1_000_000 - clickFirstUs
            guard t >= 0 else { return 0 }
            let k = (t / clickEveryUs).rounded(.down)
            let i = n - Int(((clickFirstUs + k * clickEveryUs) * AudioTapSupport.sampleRate / 1_000_000).rounded())
            guard i >= 0, i < len else { return 0 }
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(len))
            return Float(0.5 * w * sin(2 * Double.pi * 2_000 * Double(i) / AudioTapSupport.sampleRate))
        }])
        return url
    }

    /// (onset µs, centroid µs) of the click nearest [tUs] (±120 ms).
    static func click(_ x: [Float], near tUs: Double) -> (Double, Double)? {
        let sr = AudioTapSupport.sampleRate
        let a = max(0, Int((tUs - 120_000) * sr / 1e6))
        let b = min(x.count, Int((tUs + 120_000) * sr / 1e6))
        guard a < b else { return nil }
        var peak: Float = 0
        for i in a..<b { peak = max(peak, abs(x[i])) }
        guard peak > 0.02 else { return nil }
        var onset = a
        while abs(x[onset]) < 0.1 * peak { onset += 1 }
        var e = 0.0, et = 0.0
        for i in a..<b {
            let v = Double(x[i]) * Double(x[i])
            e += v
            et += v * Double(i)
        }
        return (Double(onset) * 1e6 / sr, et / e * 1e6 / sr)
    }

    func measure(_ name: String, tracks: [[AudioTapSupport.Segment]], durUs: Double, src: URL) async throws {
        let frames = Int(durUs * AudioTapSupport.sampleRate / 1e6)
        let (read, _) = try await AudioTapSupport.readValidated(expectFrames: frames - 4_800) {
            let taps = tracks.map { _ in GainTap() }
            return try await AudioTapSupport.buildWithTaps(tracks: tracks, taps: taps)
        }
        let x = read.leftChannel
        var line = "PSDIAG \(name):"
        for seg in tracks.flatMap({ $0 }) {
            let r = (seg.s1 - seg.s0) / (seg.t1 - seg.t0)
            var s = Self.clickFirstUs
            while s < seg.s1 {
                if s >= seg.s0 {
                    let t = seg.t0 + (s - seg.s0) / r
                    if t > seg.t0 + 150_000, t < seg.t1 - 150_000, let c = Self.click(x, near: t) {
                        // centroid of the ideal click = 10 ms after its start (1x)
                        line += String(format: " [r%.2f t%.2fs on%+.1f ce%+.1f]", r, t / 1e6, (c.0 - t) / 1000, (c.1 - t - 10_000) / 1000)
                    }
                }
                s += Self.clickEveryUs
            }
        }
        print(line)
    }

    func testDiagnose() async throws {
        let dir = try AudioTapSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try Self.clickSource(dir)
        typealias S = AudioTapSupport.Segment
        for r in [0.5, 0.75, 1.0, 1.5, 2.0] {
            try await measure("single r=\(r)", tracks: [[S(source: src, t0: 0, t1: 6_000_000, s0: 0, s1: 6_000_000 * r)]], durUs: 6_000_000, src: src)
        }
        for r in [0.5, 2.0] {
            try await measure("1x|r|1x r=\(r)", tracks: [[
                S(source: src, t0: 0, t1: 1_000_000, s0: 0, s1: 1_000_000),
                S(source: src, t0: 1_000_000, t1: 4_000_000, s0: 1_000_000, s1: 1_000_000 + 3_000_000 * r),
                S(source: src, t0: 4_000_000, t1: 6_000_000, s0: 1_000_000 + 3_000_000 * r, s1: 3_000_000 + 3_000_000 * r),
            ]], durUs: 6_000_000, src: src)
            try await measure("r|gap|1x r=\(r)", tracks: [[
                S(source: src, t0: 0, t1: 2_000_000, s0: 0, s1: 2_000_000 * r),
                S(source: src, t0: 3_000_000, t1: 6_000_000, s0: 5_000_000, s1: 8_000_000),
            ]], durUs: 6_000_000, src: src)
        }
        try await measure("1x two edits", tracks: [[
            S(source: src, t0: 0, t1: 3_000_000, s0: 0, s1: 3_000_000),
            S(source: src, t0: 3_000_000, t1: 6_000_000, s0: 5_000_000, s1: 8_000_000),
        ]], durUs: 6_000_000, src: src)
        // Start offset dependence: the same 0.5x segment starting at different source/comp times.
        for off in [0.0, 100_000.0, 250_000.0] {
            try await measure("0.5 off=\(off)", tracks: [[S(source: src, t0: 0, t1: 6_000_000, s0: off, s1: off + 3_000_000)]], durUs: 6_000_000, src: src)
            try await measure("0.5 at=\(off)", tracks: [[S(source: src, t0: off, t1: 6_000_000, s0: 0, s1: (6_000_000 - off) / 2)]], durUs: 6_000_000, src: src)
        }
    }
}
