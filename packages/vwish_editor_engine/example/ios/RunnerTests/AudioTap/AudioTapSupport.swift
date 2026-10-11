// OWNER: IOS-18
//
// Helpers of the IOS-18 gain-tap tests: API-03 vector loading, locally generated PCM sources
// (no downloads: DC and tone WAVs are written into a temporary directory), audio-only compositions
// with one GainTap per composition track, an AVAssetReaderAudioMixOutput read under a watchdog
// (iOS 26 can block in copyNextSampleBuffer, IOS-01 V-N21) and level measurements.

import AVFoundation
import XCTest

@testable import vwish_editor_engine

enum AudioTapSupport {
    static let sampleRate = 48_000.0

    // MARK: - Vectors

    static func json(_ relativePath: String) throws -> [String: Any] {
        let url = try XCTUnwrap(TestFixtures.url(.engineApi, relativePath), "\(relativePath) missing from the test bundle")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// `[[tUs, g], …]` from a vector / plan `gain` array.
    static func keys(_ any: Any?) -> [[Double]] {
        (any as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
    }

    // MARK: - Sources

    /// A temporary directory removed by the caller's teardown.
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios18_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a Float32 48 kHz WAV of [seconds] whose channel c at sample n is `channels[c](n)`.
    static func writeWav(
        _ url: URL, seconds: Double, channels: [(Int) -> Float]
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels.count), interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int((seconds * sampleRate).rounded())
        let chunk = 48_000
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels.count {
                let data = buffer.floatChannelData![c]
                for i in 0..<n { data[i] = channels[c](written + i) }
            }
            try file.write(from: buffer)
            written += n
        }
    }

    /// `amplitude·sin(2π·freq·s + phase)` at sample n (s = n / 48 kHz), the vectors' tone definition.
    static func tone(_ freqHz: Double, _ amplitude: Double, _ phase: Double = 0) -> (Int) -> Float {
        { n in Float(amplitude * sin(2 * Double.pi * freqHz * Double(n) / sampleRate + phase)) }
    }

    // MARK: - Compositions

    /// A CMTime for [us] µs (48 kHz timescale when exact, else µs).
    static func cm(_ us: Double) -> CMTime {
        let samples = us * sampleRate / 1_000_000
        if samples == samples.rounded() { return CMTime(value: Int64(samples), timescale: 48_000) }
        return CMTime(value: Int64(us.rounded()), timescale: 1_000_000)
    }

    /// One plan audio segment: composition [t0, t1) ← source [s0, s1) (µs).
    struct Segment {
        var source: URL
        var t0: Double
        var t1: Double
        var s0: Double
        var s1: Double
    }

    /// A composition with one audio track per entry of [tracks] (each a list of segments), each with
    /// its own GainTap (`taps[i]`), and the matching audio mix.
    static func build(
        tracks: [[Segment]], taps: [GainTap], algorithm: AVAudioTimePitchAlgorithm = .timeDomain
    ) async throws -> (AVMutableComposition, AVMutableAudioMix, [AVURLAsset]) {
        let composition = AVMutableComposition()
        var assets: [URL: AVURLAsset] = [:]
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, segments) in tracks.enumerated() {
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            for s in segments {
                let asset = assets[s.source] ?? AVURLAsset(url: s.source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                assets[s.source] = asset
                let loaded = try await asset.loadTracks(withMediaType: .audio)
                let source = try XCTUnwrap(loaded.first)
                let src = CMTimeRange(start: cm(s.s0), end: cm(s.s1))
                let end = track.segments.isEmpty ? .zero : track.timeRange.end
                if CMTimeCompare(cm(s.t0), end) > 0 {
                    track.insertEmptyTimeRange(CMTimeRange(start: end, end: cm(s.t0)))
                }
                try track.insertTimeRange(src, of: source, at: cm(s.t0))
                if s.s1 - s.s0 != s.t1 - s.t0 {
                    track.scaleTimeRange(CMTimeRange(start: cm(s.t0), duration: src.duration), toDuration: CMTimeSubtract(cm(s.t1), cm(s.t0)))
                }
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = algorithm
            try taps[index].attach(to: p)
            parameters.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (composition, mix, Array(assets.values))
    }

    // MARK: - Reading

    struct MixRead {
        /// Interleaved stereo Float32 at 48 kHz.
        var interleaved: [Float]
        var status: AVAssetReader.Status
        var hung: Bool

        var frames: Int { interleaved.count / 2 }
        func left(_ i: Int) -> Float { interleaved[2 * i] }
        func right(_ i: Int) -> Float { interleaved[2 * i + 1] }
        var leftChannel: [Float] { stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] } }
    }

    private final class Accumulator {
        let lock = NSLock()
        var samples: [Float] = []
        func append(_ xs: [Float]) {
            lock.lock()
            samples += xs
            lock.unlock()
        }
        var snapshot: [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }

    /// Reads [composition] through AVAssetReaderAudioMixOutput (LPCM Float32 48 kHz stereo, the
    /// IOS-12 export format) with [mix]; the read runs on a worker under a watchdog.
    static func readMix(
        _ composition: AVComposition, mix: AVAudioMix, algorithm: AVAudioTimePitchAlgorithm = .timeDomain,
        timeout: TimeInterval = 30
    ) throws -> MixRead {
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: composition.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        output.audioMix = mix
        output.audioTimePitchAlgorithm = algorithm
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        let acc = Accumulator()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                floats.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                acc.append(floats)
            }
            withExtendedLifetime(reader) { done.signal() }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            reader.cancelReading()
            _ = done.wait(timeout: .now() + 5)
            return MixRead(interleaved: acc.snapshot, status: reader.status, hung: true)
        }
        return MixRead(interleaved: acc.snapshot, status: reader.status, hung: false)
    }

    // MARK: - Levels

    static func db(_ g: Double) -> Double { 20 * log10(g) }

    /// RMS level (dB) of channel [channel] over frames [a, b).
    static func rmsDb(_ read: MixRead, channel: Int, _ a: Int, _ b: Int) -> Double {
        guard a >= 0, b <= read.frames, a < b else { return .nan }
        var s = 0.0
        for i in a..<b {
            let v = Double(read.interleaved[2 * i + channel])
            s += v * v
        }
        return 10 * log10(s / Double(b - a))
    }

    static func rmsDb(_ x: [Float], _ a: Int, _ b: Int) -> Double {
        guard a >= 0, b <= x.count, a < b else { return .nan }
        var s = 0.0
        for i in a..<b { s += Double(x[i]) * Double(x[i]) }
        return 10 * log10(s / Double(b - a))
    }

    /// Residual of a pure-tone predictor: e[i] = x[i] − 2cos(ω)·x[i−1] + x[i−2] is exactly 0 for any
    /// sinusoid of frequency [freqHz] with constant amplitude and phase, and about the jump size at a
    /// discontinuity, so it isolates clicks from the tone (ramp-seam click test).
    static func toneResidual(_ x: [Float], freqHz: Double) -> [Float] {
        let c = Float(2 * cos(2 * Double.pi * freqHz / sampleRate))
        guard x.count > 2 else { return [] }
        var e = [Float](repeating: 0, count: x.count)
        for i in 2..<x.count { e[i] = x[i] - c * x[i - 1] + x[i - 2] }
        return e
    }

    static func maxAbs(_ x: [Float], _ a: Int, _ b: Int) -> Float {
        let lo = max(a, 0)
        let hi = min(b, x.count)
        guard lo < hi else { return 0 }
        var m: Float = 0
        for i in lo..<hi { m = max(m, abs(x[i])) }
        return m
    }

    // MARK: - Direct rendering (no AVFoundation)

    /// Runs [frames] interleaved stereo frames of [input] through a tap render state in calls of
    /// [chunk] frames, the first call at [startUs] and the rest continuing (nil range), optionally
    /// swapping the envelope before call [swapAtCall]. Returns the interleaved output.
    static func renderDirect(
        tap: GainTap, input: (Int) -> Float, frames: Int, startUs: Double = 0, chunk: Int = 1_024,
        swap: (call: Int, envelope: TapEnvelope)? = nil, explicitStarts: Bool = false
    ) -> [Float] {
        let state = GainTapRenderState(controller: tap)
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        state.prepare(maxFrames: chunk, format: asbd)
        var out = [Float](repeating: 0, count: frames * 2)
        var done = 0
        var call = 0
        while done < frames {
            let n = min(chunk, frames - done)
            if let swap, swap.call == call { tap.swapEnvelope(swap.envelope) }
            var samples = [Float](repeating: 0, count: n * 2)
            for f in 0..<n {
                let v = input(done + f)
                samples[2 * f] = v
                samples[2 * f + 1] = v
            }
            samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                let start: Double? = (call == 0 || explicitStarts) ? startUs + Double(done) * 1_000_000 / sampleRate : nil
                state.process(&list, frames: n, startUs: start)
            }
            out.replaceSubrange(2 * done..<2 * (done + n), with: samples)
            done += n
            call += 1
        }
        return out
    }
}
