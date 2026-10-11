// OWNER: IOS-18
//
// GainTap in AVAssetReaderAudioMixOutput (the IOS-12 export read; BUILD_PLAN IOS-18, D-37, V-N21):
// - API-03 gain vectors reproduced on the rendered PCM, sample-exactly (±0.01 dB);
// - 200% vs 100% on tone_1khz (ENG-05 fixture) measures +6.02 ± 0.1 dB, at 1×, 2× and 0.5×;
// - fades, an equal-power dissolve and volume keyframes (audio_mix.json `three_lane_reference`)
//   match the Dart reference mixer within ±0.5 dB per 20 ms window.
// All reads use `.timeDomain` (ARCH §13.2: never `.spectral`). Sources other than tone_1khz are
// generated locally (DC and the vectors' tone definitions).

import AVFoundation
import XCTest

@testable import vwish_editor_engine

final class GainTapReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try AudioTapSupport.tempDir()
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func toneFixture() throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"), "ENG-05 tone_1khz.wav missing")
    }

    // MARK: - Vectors on rendered PCM

    func testReaderReproducesApi03GainVectorsSampleExactly() async throws {
        let dc = dir.appendingPathComponent("dc.wav")
        try AudioTapSupport.writeWav(dc, seconds: 10.5, channels: [{ _ in 0.5 }, { _ in 0.5 }])
        let root = try AudioTapSupport.json("vectors/gain.json")
        for env in try XCTUnwrap(root["envelopes"] as? [[String: Any]]) {
            let name = env["name"] as? String ?? "?"
            let samples = env["samples"] as? [[String: Any]] ?? []
            let maxI = samples.compactMap { $0["i"] as? Int }.max() ?? 0
            let endUs = (Double(maxI) + 4_800) * 1_000_000 / 48_000
            var meter = GainTapMeter()
            let (read, reads) = try await AudioTapSupport.readValidated(expectFrames: maxI + 1) {
                meter = GainTapMeter()
                let tap = GainTap(envelope: TapEnvelope(planGain: AudioTapSupport.keys(env["keys"])), meter: meter)
                return try await AudioTapSupport.build(
                    tracks: [[.init(source: dc, t0: 0, t1: endUs, s0: 0, s1: endUs)]], taps: [tap])
            }
            print("IOS-18 vectors \(name): \(reads) read(s)")
            XCTAssertFalse(read.hung, name)
            XCTAssertEqual(read.status, .completed, name)
            XCTAssertGreaterThan(read.frames, maxI, name)
            XCTAssertTrue(meter.failures.isEmpty, "\(name): GetSourceAudio failed \(meter.failures)")
            for s in samples {
                let i = try XCTUnwrap(s["i"] as? Int)
                guard i < read.frames else { continue }
                let g = try XCTUnwrap((s["g"] as? NSNumber)?.doubleValue)
                for (ch, v) in [("L", read.left(i)), ("R", read.right(i))] {
                    if g == 0 {
                        XCTAssertLessThanOrEqual(abs(v), 1e-6, "\(name) \(ch) i=\(i)")
                    } else {
                        XCTAssertEqual(
                            AudioTapSupport.db(Double(v) / 0.5), AudioTapSupport.db(g), accuracy: 0.01, "\(name) \(ch) i=\(i)")
                    }
                }
            }
            // The tap saw composition-time ranges from 0 (V-N21).
            let starts = meter.calls.compactMap(\.startUs)
            XCTAssertEqual(starts.first ?? -1, 0, accuracy: 1, name)
        }
    }

    // MARK: - +6.02 dB on tone_1khz

    /// 200% vs 100% through the reader: +6.02 ± 0.1 dB over a 1×, 2× and 0.5× composition (the
    /// IOS-01 three-segment layout: [0,1) ← [0,1) at 1×, [1,2) ← [3,5) at 2×, [2,4) ← [6,7) at 0.5×).
    func testBoost200PctMeasuresPlus6dBInReader() async throws {
        let tone = try toneFixture()
        let segments: [AudioTapSupport.Segment] = [
            .init(source: tone, t0: 0, t1: 1_000_000, s0: 0, s1: 1_000_000),
            .init(source: tone, t0: 1_000_000, t1: 2_000_000, s0: 3_000_000, s1: 5_000_000),
            .init(source: tone, t0: 2_000_000, t1: 4_000_000, s0: 6_000_000, s1: 7_000_000),
        ]
        var reads: [Double: AudioTapSupport.MixRead] = [:]
        for gain in [1.0, 2.0] {
            let (read, count) = try await AudioTapSupport.readValidated(
                expectFrames: 4 * 48_000 - 2_400, audible: [0..<(4 * 48_000 - 4_800)]
            ) {
                try await AudioTapSupport.build(tracks: [segments], taps: [GainTap(envelope: TapEnvelope(planGain: [[0, gain]]))])
            }
            print("IOS-18 boost \(gain): \(count) read(s)")
            XCTAssertFalse(read.hung)
            XCTAssertGreaterThanOrEqual(read.frames, 4 * 48_000 - 2_400)
            reads[gain] = read
        }
        let unity = try XCTUnwrap(reads[1])
        let boost = try XCTUnwrap(reads[2])
        // Unity reads at the fixture level (−12 dBFS peak sine = −15.01 dBFS RMS).
        XCTAssertEqual(AudioTapSupport.rmsDb(unity, channel: 0, 4_800, 43_200), -15.01, accuracy: 0.3)
        for (label, a, b) in [("1x", 0.1, 0.9), ("2x", 1.1, 1.9), ("0.5x", 2.1, 3.9)] {
            let i = Int(a * 48_000)
            let j = Int(b * 48_000)
            for ch in 0..<2 {
                let d = AudioTapSupport.rmsDb(boost, channel: ch, i, j) - AudioTapSupport.rmsDb(unity, channel: ch, i, j)
                XCTAssertEqual(d, 6.0206, accuracy: 0.1, "\(label) ch\(ch)")
            }
        }
    }

    // MARK: - Reference mixer

    /// audio_mix.json `three_lane_reference`: main A → B with a 400 ms equal-power dissolve, music
    /// at 40% with 1 s fades, voice keyframes 100 → 200 → 50 → 100%. Each plan audio segment is a
    /// composition track with its GainTap; per 20 ms window L/R RMS within ±0.5 dB of the reference
    /// (windows the reference puts below −50 dBFS must stay below −44 dBFS).
    func testFadesAndKeyframesMatchReferenceMixer() async throws {
        let root = try AudioTapSupport.json("vectors/audio_mix.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let c = try XCTUnwrap(cases.first { $0["name"] as? String == "three_lane_reference" })
        let sources = try XCTUnwrap(c["sources"] as? [String: [String: Any]])
        var files: [String: URL] = [:]
        for (asset, def) in sources {
            let channels = try XCTUnwrap(def["channels"] as? [Any])
            let gens: [(Int) -> Float] = channels.map { ch in
                guard let ch = ch as? [String: Any] else { return { _ in 0 } }
                return AudioTapSupport.tone(
                    (ch["freqHz"] as? NSNumber)?.doubleValue ?? 0, (ch["amplitude"] as? NSNumber)?.doubleValue ?? 0,
                    (ch["phase"] as? NSNumber)?.doubleValue ?? 0)
            }
            let url = dir.appendingPathComponent("\(asset).wav")
            try AudioTapSupport.writeWav(url, seconds: 10, channels: gens)
            files[asset] = url
        }
        let plan = try XCTUnwrap(c["plan"] as? [String: Any])
        let audio = try XCTUnwrap(plan["audio"] as? [[String: Any]])
        var tracks: [[AudioTapSupport.Segment]] = []
        var gains: [[[Double]]] = []
        for seg in audio {
            let url = try XCTUnwrap(files[try XCTUnwrap(seg["asset"] as? String)])
            let map = AudioTapSupport.keys(seg["map"])
            tracks.append(map.map { .init(source: url, t0: $0[0], t1: $0[1], s0: $0[2], s1: $0[3]) })
            gains.append(AudioTapSupport.keys(seg["gain"]))
        }
        let frames = try XCTUnwrap(c["frames"] as? Int)
        let (read, reads) = try await AudioTapSupport.readValidated(expectFrames: frames, audible: [0..<frames]) {
            try await AudioTapSupport.build(tracks: tracks, taps: gains.map { GainTap(envelope: TapEnvelope(planGain: $0)) })
        }
        XCTAssertFalse(read.hung)
        let windowSamples = try XCTUnwrap(c["windowSamples"] as? Int)
        let windows = try XCTUnwrap(c["windows"] as? [[NSNumber]])
        let startUs = (c["startUs"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertEqual(startUs, 0)
        var compared = 0
        var worst = 0.0
        for (w, row) in windows.enumerated() {
            let a = w * windowSamples
            let b = a + windowSamples
            guard b <= read.frames else {
                XCTFail("read ended at \(read.frames) frames, before window \(w)")
                break
            }
            for ch in 0..<2 {
                let ref = row[ch].doubleValue
                let got = AudioTapSupport.rmsDb(read, channel: ch, a, b)
                if ref < -50 {
                    XCTAssertLessThan(got, -44, "window \(w) ch\(ch): reference \(ref) dB")
                } else {
                    compared += 1
                    worst = max(worst, abs(got - ref))
                    XCTAssertEqual(got, ref, accuracy: 0.5, "window \(w) ch\(ch)")
                }
            }
        }
        XCTAssertGreaterThan(compared, 300)
        print("IOS-18 three_lane_reference: \(compared) windows, worst |Δ| = \(worst) dB, \(reads) read(s)")
    }

    // MARK: - pitch: false

    /// ARCH §13.2: `.varispeed` (pitch off) failed in the reader over scaled ranges on the iOS 26.5
    /// simulator in IOS-01, so IOS-18 checks it before IOS-12 relies on it: audio_mix.json
    /// `varispeed_2x` (500 Hz read at 2× → 1 kHz) must match the reference windows within ±0.5 dB
    /// with the tap on. A hang or silent read fails the test (the finding goes to IOS-12/QA-11).
    func testVarispeedReadOverScaledRangeMatchesReference() async throws {
        let root = try AudioTapSupport.json("vectors/audio_mix.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let c = try XCTUnwrap(cases.first { $0["name"] as? String == "varispeed_2x" })
        let url = dir.appendingPathComponent("tone500.wav")
        try AudioTapSupport.writeWav(url, seconds: 2, channels: [AudioTapSupport.tone(500, 0.5)])
        let seg = try XCTUnwrap((c["plan"] as? [String: Any])?["audio"] as? [[String: Any]]).first!
        XCTAssertEqual(seg["pitch"] as? Bool, false)
        let map = AudioTapSupport.keys(seg["map"])
        // Pad with 1× audio after the case so the reader's tail does not fall inside the windows.
        var segments: [AudioTapSupport.Segment] = map.map { .init(source: url, t0: $0[0], t1: $0[1], s0: $0[2], s1: $0[3]) }
        segments.append(.init(source: url, t0: 200_000, t1: 400_000, s0: 400_000, s1: 600_000))
        let gain = AudioTapSupport.keys(seg["gain"])
        let (read, reads) = try await AudioTapSupport.readValidated(
            expectFrames: 9_600, audible: [0..<9_600], algorithm: .varispeed, timeout: 15
        ) {
            try await AudioTapSupport.build(
                tracks: [segments], taps: [GainTap(envelope: TapEnvelope(planGain: gain))], algorithm: .varispeed)
        }
        print("IOS-18 varispeed_2x: \(reads) read(s)")
        XCTAssertFalse(read.hung, "varispeed read hung over a scaled range")
        let windowSamples = try XCTUnwrap(c["windowSamples"] as? Int)
        let windows = try XCTUnwrap(c["windows"] as? [[NSNumber]])
        // Skip the first window: the resampler's start-up transient.
        for (w, row) in windows.enumerated() where w > 0 {
            let a = w * windowSamples
            guard a + windowSamples <= read.frames else { return XCTFail("short read: \(read.frames) frames") }
            for ch in 0..<2 {
                XCTAssertEqual(
                    AudioTapSupport.rmsDb(read, channel: ch, a, a + windowSamples), row[ch].doubleValue, accuracy: 0.5,
                    "window \(w) ch\(ch)")
            }
        }
    }
}
