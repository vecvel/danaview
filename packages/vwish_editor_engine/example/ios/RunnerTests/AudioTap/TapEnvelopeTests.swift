// OWNER: IOS-18
//
// TapEnvelope and the GainTap render kernel without AVFoundation (BUILD_PLAN IOS-18):
// - every API-03 gain vector (gain.json) is reproduced by the envelope and by the rendered PCM of the
//   tap kernel, sample-exactly (±0.01 dB; exact zero where g = 0);
// - envelope swaps are glitch-free: no sample discontinuity above −60 dBFS;
// - ramp-seam crossfades are 5 ms equal-power windows centred on the seam;
// - the kernel continues from the last known time on an invalid range and handles Int16.

import AVFoundation
import XCTest

@testable import vwish_editor_engine

final class TapEnvelopeTests: XCTestCase {
    private static let minus60dB: Float = 0.001

    private func envelopes() throws -> [(name: String, keys: [[Double]], samples: [[String: Any]])] {
        let root = try AudioTapSupport.json("vectors/gain.json")
        XCTAssertEqual(root["sampleRate"] as? Int, 48_000)
        let list = try XCTUnwrap(root["envelopes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(list.count, 7)
        return list.map {
            ($0["name"] as? String ?? "?", AudioTapSupport.keys($0["keys"]), $0["samples"] as? [[String: Any]] ?? [])
        }
    }

    /// Checks one rendered multiplier against a vector sample (±0.01 dB, exact 0 for g = 0).
    private func check(_ got: Double, _ sample: [String: Any], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let g = (sample["g"] as? NSNumber)?.doubleValue ?? .nan
        if g == 0 {
            XCTAssertLessThanOrEqual(abs(got), 1e-7, label, file: file, line: line)
        } else {
            XCTAssertEqual(AudioTapSupport.db(got), AudioTapSupport.db(g), accuracy: 0.01, label, file: file, line: line)
        }
    }

    func testEnvelopeReproducesApi03GainVectors() throws {
        for env in try envelopes() {
            let e = TapEnvelope(planGain: env.keys)
            for s in env.samples {
                let tUs = try XCTUnwrap((s["tUs"] as? NSNumber)?.doubleValue)
                let i = try XCTUnwrap(s["i"] as? Int)
                XCTAssertEqual(tUs, Double(i) * 1_000_000 / 48_000, accuracy: 1e-6)
                check(e.gain(atUs: Double(i) * 1_000_000 / 48_000), s, "\(env.name) i=\(i)")
                // `fill` (the render path) agrees with the scalar evaluation.
                var out: Float = .nan
                e.fill(&out, count: 1, startUs: Double(i) * 1_000_000 / 48_000, sampleRate: 48_000)
                check(Double(out), s, "\(env.name) fill i=\(i)")
            }
        }
    }

    func testDbTableMatchesConversions() throws {
        let root = try AudioTapSupport.json("vectors/gain.json")
        for row in try XCTUnwrap(root["db"] as? [[String: Any]]) {
            let g = try XCTUnwrap((row["g"] as? NSNumber)?.doubleValue)
            let db = try XCTUnwrap((row["db"] as? NSNumber)?.doubleValue)
            XCTAssertEqual(AudioTapSupport.db(g), db, accuracy: 1e-6)
        }
    }

    /// The tap kernel's rendered PCM (DC 0.5 through GainTapRenderState in 1024-frame calls that
    /// continue from the last known time, as AVPlayer does after an invalid first range).
    func testRenderedPcmReproducesApi03GainVectorsSampleExactly() throws {
        for env in try envelopes() {
            let maxI = env.samples.compactMap { $0["i"] as? Int }.max() ?? 0
            let tap = GainTap(envelope: TapEnvelope(planGain: env.keys))
            let out = AudioTapSupport.renderDirect(tap: tap, input: { _ in 0.5 }, frames: maxI + 1)
            for s in env.samples {
                let i = try XCTUnwrap(s["i"] as? Int)
                check(Double(out[2 * i]) / 0.5, s, "\(env.name) L i=\(i)")
                check(Double(out[2 * i + 1]) / 0.5, s, "\(env.name) R i=\(i)")
            }
        }
    }

    /// Calls handed explicit composition starts (as in AVAssetReaderAudioMixOutput) give the same
    /// samples as continuation, and a call that starts mid-envelope evaluates from range.start.
    func testExplicitStartsMatchContinuation() throws {
        let keys: [[Double]] = [[0, 1], [1_000_000, 2], [2_000_000, 2], [3_000_000, 0]]
        let a = AudioTapSupport.renderDirect(tap: GainTap(envelope: TapEnvelope(planGain: keys)), input: { _ in 0.25 }, frames: 150_000, chunk: 937)
        let b = AudioTapSupport.renderDirect(
            tap: GainTap(envelope: TapEnvelope(planGain: keys)), input: { _ in 0.25 }, frames: 150_000, chunk: 937, explicitStarts: true)
        XCTAssertEqual(a.count, b.count)
        var maxDiff: Float = 0
        for i in 0..<a.count { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
        XCTAssertLessThan(maxDiff, 1e-6)
        let late = AudioTapSupport.renderDirect(
            tap: GainTap(envelope: TapEnvelope(planGain: keys)), input: { _ in 0.25 }, frames: 10, startUs: 500_000)
        XCTAssertEqual(Double(late[0]), 0.25 * 1.5, accuracy: 1e-6)
    }

    /// A gain-only patch swaps the envelope while rendering: the output never steps by more than
    /// −60 dBFS between samples (DC at 0.5, the worst case for a step), the blend ends at the new
    /// envelope exactly, and the swap needs no new tap.
    func testEnvelopeSwapIsGlitchFree() throws {
        let cases: [(from: Double, to: Double)] = [(1, 2), (2, 0), (0, 2), (1, 0.5), (0.4, 1.6)]
        for c in cases {
            let tap = GainTap(envelope: TapEnvelope(planGain: [[0, c.from]]))
            let frames = 48_000
            let out = AudioTapSupport.renderDirect(
                tap: tap, input: { _ in 0.5 }, frames: frames, chunk: 512,
                swap: (call: 40, envelope: TapEnvelope(planGain: [[0, c.to]])))
            var maxStep: Float = 0
            for i in 1..<frames { maxStep = max(maxStep, abs(out[2 * i] - out[2 * (i - 1)])) }
            XCTAssertLessThanOrEqual(maxStep, Self.minus60dB, "swap \(c.from) → \(c.to): step \(AudioTapSupport.db(Double(maxStep))) dBFS")
            XCTAssertEqual(Double(out[0]), 0.5 * c.from, accuracy: 1e-6)
            let blendEnd = 40 * 512 + Int(GainTap.swapBlendSeconds * 48_000)
            XCTAssertEqual(Double(out[2 * blendEnd]), 0.5 * c.to, accuracy: 1e-6)
            XCTAssertEqual(Double(out[2 * (frames - 1)]), 0.5 * c.to, accuracy: 1e-6)
            XCTAssertTrue(tap.envelope.gains == [c.to])
        }
    }

    /// The same swap on a full-scale 1 kHz tone: the pure-tone residual (clicks) stays below −60 dBFS.
    func testEnvelopeSwapOnToneHasNoClick() throws {
        let tap = GainTap(envelope: TapEnvelope(planGain: [[0, 1]]))
        let tone = AudioTapSupport.tone(1_000, 0.5)
        let out = AudioTapSupport.renderDirect(
            tap: tap, input: tone, frames: 24_000, chunk: 512, swap: (call: 10, envelope: TapEnvelope(planGain: [[0, 2]])))
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        let residual = AudioTapSupport.toneResidual(left, freqHz: 1_000)
        XCTAssertLessThanOrEqual(AudioTapSupport.maxAbs(residual, 2, residual.count), Self.minus60dB)
        // A hard swap (no blend) would leave a step of the tone's amplitude in the residual.
        var hard = left
        for i in (10 * 512)..<hard.count { hard[i] = tone(i) * 2 }
        XCTAssertGreaterThan(AudioTapSupport.maxAbs(AudioTapSupport.toneResidual(hard, freqHz: 1_000), 2, hard.count), 0.01)
    }

    /// A swap that arrives during a blend is applied after it, still without a step.
    func testSwapDuringBlendIsDeferredWithoutStep() throws {
        let tap = GainTap(envelope: TapEnvelope(planGain: [[0, 1]]))
        let state = GainTapRenderState(controller: tap)
        state.prepare(
            maxFrames: 256,
            format: AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0))
        var out: [Float] = []
        for call in 0..<60 {
            if call == 2 { tap.swapEnvelope(TapEnvelope(planGain: [[0, 2]])) }
            if call == 4 { tap.swapEnvelope(TapEnvelope(planGain: [[0, 0]])) }
            var buf = [Float](repeating: 0.5, count: 256)
            buf.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                state.process(&list, frames: 256, startUs: nil)
            }
            out += buf
        }
        var maxStep: Float = 0
        for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        XCTAssertLessThanOrEqual(maxStep, Self.minus60dB)
        XCTAssertEqual(out.last ?? -1, 0, accuracy: 1e-7)
    }

    // MARK: - Seams

    func testSeamCrossfadesAreEqualPowerWindowsCentredOnTheSeam() {
        let seam: Int64 = 1_000_000
        let out = TapEnvelope.unity.withSeamCrossfades([.init(timeUs: seam, edge: .outgoing)])
        let inc = TapEnvelope(planGain: [[0, 1]]).withSeamCrossfades([.init(timeUs: seam, edge: .incoming)])
        XCTAssertEqual(out.gain(atUs: 997_499), 1, accuracy: 1e-12)
        XCTAssertEqual(inc.gain(atUs: 997_499), 1, accuracy: 1e-12)  // outside the window the factor is 1
        XCTAssertEqual(out.gain(atUs: 997_500), 1, accuracy: 1e-12)
        XCTAssertEqual(inc.gain(atUs: 997_500), 0, accuracy: 1e-12)
        XCTAssertEqual(out.gain(atUs: Double(seam)), sqrt(0.5), accuracy: 1e-9)
        XCTAssertEqual(inc.gain(atUs: Double(seam)), sqrt(0.5), accuracy: 1e-9)
        var t = 997_500.0
        while t < 1_002_500 {
            let a = out.gain(atUs: t)
            let b = inc.gain(atUs: t)
            XCTAssertEqual(a * a + b * b, 1, accuracy: 1e-9, "t=\(t)")
            t += 1_000_000 / 48_000
        }
        // The render path agrees with the scalar path across the window.
        let n = 480
        var buf = [Float](repeating: 0, count: n)
        out.fill(&buf, count: n, startUs: 995_000, sampleRate: 48_000)
        for i in 0..<n {
            XCTAssertEqual(Double(buf[i]), out.gain(atUs: 995_000 + Double(i) * 1_000_000 / 48_000), accuracy: 1e-6)
        }
        // Seams multiply the plan envelope.
        let boosted = TapEnvelope(planGain: [[0, 2]]).withSeamCrossfades([.init(timeUs: seam, edge: .outgoing)])
        XCTAssertEqual(boosted.gain(atUs: Double(seam)), 2 * sqrt(0.5), accuracy: 1e-9)
        XCTAssertEqual(boosted.envelopeGain(atUs: Double(seam)), 2, accuracy: 1e-12)
    }

    func testAlternatingSeamsAssignOutgoingAndIncomingPerTrack() {
        let b: [Int64] = [300_000, 600_000, 900_000]
        XCTAssertEqual(
            TapEnvelope.alternatingSeams(boundariesUs: b, track: 0),
            [.init(timeUs: 300_000, edge: .outgoing), .init(timeUs: 600_000, edge: .incoming), .init(timeUs: 900_000, edge: .outgoing)])
        XCTAssertEqual(
            TapEnvelope.alternatingSeams(boundariesUs: b, track: 1),
            [.init(timeUs: 300_000, edge: .incoming), .init(timeUs: 600_000, edge: .outgoing), .init(timeUs: 900_000, edge: .incoming)])
    }

    // MARK: - Kernel details

    func testEmptyAndUnsortedKeysAndNonFiniteGains() {
        XCTAssertEqual(TapEnvelope.unity.gain(atUs: 123), 1)
        let e = TapEnvelope(keys: [(2_000_000, 0), (0, 1), (1_000_000, .nan)])
        XCTAssertEqual(e.timesUs, [0, 1_000_000, 2_000_000])
        XCTAssertEqual(e.gains, [1, 0, 0])
        XCTAssertEqual(e.gain(atUs: 500_000), 0.5, accuracy: 1e-12)
        XCTAssertEqual(e.gain(atUs: -5), 1)
        XCTAssertEqual(e.gain(atUs: 9e9), 0)
    }

    func testInt16BuffersAreScaledAndClamped() {
        let tap = GainTap(envelope: TapEnvelope(planGain: [[0, 2]]))
        let state = GainTapRenderState(controller: tap)
        state.prepare(
            maxFrames: 4,
            format: AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0))
        var buf: [Int16] = [1_000, -1_000, 20_000, -20_000]
        buf.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            state.process(&list, frames: 4, startUs: 0)
        }
        XCTAssertEqual(buf, [2_000, -2_000, 32_767, -32_768])
    }

    func testZeroFillClearsEveryBuffer() {
        var a: [Float] = [1, 2, 3]
        var b: [Float] = [.nan, 5, 6]
        a.withUnsafeMutableBytes { ra in
            b.withUnsafeMutableBytes { rb in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(ra.count), mData: ra.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rb.count), mData: rb.baseAddress)
                GainTapRenderState.zeroFill(list.unsafeMutablePointer)
            }
        }
        XCTAssertEqual(a, [0, 0, 0])
        XCTAssertEqual(b, [0, 0, 0])
    }

    func testNonInterleavedBuffersGetTheSameGainPerFrame() {
        let tap = GainTap(envelope: TapEnvelope(planGain: [[0, 0], [1_000_000, 1]]))
        let state = GainTapRenderState(controller: tap)
        state.prepare(
            maxFrames: 4_800,
            format: AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        var l = [Float](repeating: 1, count: 4_800)
        var r = [Float](repeating: -1, count: 4_800)
        l.withUnsafeMutableBytes { rl in
            r.withUnsafeMutableBytes { rr in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rl.count), mData: rl.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rr.count), mData: rr.baseAddress)
                state.process(list.unsafeMutablePointer, frames: 4_800, startUs: 500_000)
            }
        }
        XCTAssertEqual(Double(l[0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(r[0]), -0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(l[4_799]), 0.5 + 4_799.0 / 48_000, accuracy: 1e-6)
        XCTAssertEqual(state.nextUs ?? 0, 600_000, accuracy: 1e-6)
    }
}
