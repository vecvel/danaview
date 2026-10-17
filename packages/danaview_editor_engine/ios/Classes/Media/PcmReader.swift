// OWNER: IOS-04
//
// AVAssetReader LPCM Float32 reader (ARCH §15, ai.md §7.2) shared by waveforms, speech audio and
// reverse audio: one audio track of a file decoded at its native rate to interleaved Float32 with
// a sample-accurate time range. AVFoundation applies MP4 edit lists and AAC priming; on top of
// that every buffer is placed by its presentation time, so frames before the range start are
// dropped, a gap at the start is zero-filled, and output stops at exactly
// round((end − start) · rate) frames (fewer only when the media ends first). Multichannel sources
// are decoded into a known MPEG layout so Downmix can weight channels by label.
//
// Blocking; call from a job queue. `MediaCancellation` is checked between buffers.

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// A thread-safe cancel flag shared by a job and its readers.
final class MediaCancellation {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw EngineError.cancelled }
    }
}

final class PcmReader {
    /// Decoded format.
    struct Format: Equatable {
        var sampleRate: Double
        var channels: Int
        /// Channel labels in buffer order (empty when unknown).
        var labels: [AudioChannelLabel]
        /// Source codec name ("aac", "pcm_s16le", ...).
        var codec: String
    }

    let format: Format
    /// Effective range (µs), clipped to the media duration.
    let startUs: Int64
    let endUs: Int64
    /// Frames the range spans at the native rate.
    let expectedFrames: Int
    private(set) var framesDelivered = 0

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let cancellation: MediaCancellation?
    private var started = false

    /// Opens audio stream [audioStream] (index among the audio tracks) of [url] for
    /// [startUs, endUs) (whole file when nil). Fails with unsupportedMedia for containers or tracks
    /// AVFoundation cannot decode.
    init(url: URL, audioStream: Int = 0, startUs: Int64? = nil, endUs: Int64? = nil,
         cancellation: MediaCancellation? = nil) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError(.mediaOffline, "media file missing")
        }
        if SniffedContainer.sniff(url).unsupportedOnIOS {
            throw EngineError(.unsupportedMedia, "container not supported on iOS")
        }
        self.cancellation = cancellation
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let loaded = try MediaBlocking.await { () -> (CMTime, [AVAssetTrack]) in
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return (duration, tracks)
        }
        let tracks = loaded.1
        guard audioStream >= 0, audioStream < tracks.count else {
            throw EngineError(.unsupportedMedia, tracks.isEmpty ? "no audio track" : "audio stream out of range")
        }
        let track = tracks[audioStream]
        let descriptions = try MediaBlocking.await { try await track.load(.formatDescriptions) }
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw EngineError(.unsupportedMedia, "audio format unknown")
        }
        let channels = Int(asbd.mChannelsPerFrame)
        let rate = asbd.mSampleRate
        let durationUs = Probe.microseconds(loaded.0)
        let start = max(0, startUs ?? 0)
        let end = min(endUs ?? durationUs, durationUs > 0 ? durationUs : (endUs ?? 0))
        guard end > start else { throw EngineError.invalidArgument("range", "empty or past the media end") }
        self.startUs = start
        self.endUs = end
        expectedFrames = Int((Double(end - start) * rate / 1_000_000).rounded())

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        let layout = PcmReader.layout(channels: channels)
        if let tag = layout.tag {
            var channelLayout = AudioChannelLayout()
            channelLayout.mChannelLayoutTag = tag
            settings[AVChannelLayoutKey] = Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        format = Format(sampleRate: rate, channels: channels, labels: layout.labels,
                        codec: Probe.audioCodecName(description))

        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(value: start, timescale: 1_000_000), end: CMTime(value: end, timescale: 1_000_000))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.unsupportedMedia, "audio output refused") }
        reader.add(output)
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }

    /// The decode layout for [channels]: mono/stereo as is; more channels in an MPEG layout.
    static func layout(channels: Int) -> (tag: AudioChannelLayoutTag?, labels: [AudioChannelLabel]) {
        let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center
        let LFE = kAudioChannelLabel_LFEScreen, Ls = kAudioChannelLabel_LeftSurround
        let Rs = kAudioChannelLabel_RightSurround, Cs = kAudioChannelLabel_CenterSurround
        let Rls = kAudioChannelLabel_RearSurroundLeft, Rrs = kAudioChannelLabel_RearSurroundRight
        switch channels {
        case 1: return (nil, [C])
        case 2: return (nil, [L, R])
        case 3: return (kAudioChannelLayoutTag_MPEG_3_0_A, [L, R, C])
        case 4: return (kAudioChannelLayoutTag_Quadraphonic, [L, R, Ls, Rs])
        case 5: return (kAudioChannelLayoutTag_MPEG_5_0_A, [L, R, C, Ls, Rs])
        case 6: return (kAudioChannelLayoutTag_MPEG_5_1_A, [L, R, C, LFE, Ls, Rs])
        case 7: return (kAudioChannelLayoutTag_MPEG_6_1_A, [L, R, C, LFE, Ls, Rs, Cs])
        case 8: return (kAudioChannelLayoutTag_MPEG_7_1_C, [L, R, C, LFE, Ls, Rs, Rls, Rrs])
        default: return (nil, [])
        }
    }

    /// Fraction of the range delivered.
    var progress: Double { expectedFrames > 0 ? min(1, Double(framesDelivered) / Double(expectedFrames)) : 1 }

    /// The next chunk of interleaved Float32 frames, or nil at the end of the range.
    func read() throws -> [Float]? {
        if !started {
            started = true
            guard reader.startReading() else {
                throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "audio reader did not start")
            }
        }
        let channels = format.channels
        while framesDelivered < expectedFrames {
            try cancellation?.check()
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio decode failed")
                }
                return nil
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var samples = [Float](repeating: 0, count: frames * channels)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(raw.count, CMBlockBufferGetDataLength(block)),
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw EngineError(.decodeFailed, "audio copy failed \(status)") }

            // Place the buffer by its PTS (sample-accurate range).
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            var position = framesDelivered
            if pts.isValid {
                position = Int(((pts.seconds - Double(startUs) / 1_000_000) * format.sampleRate).rounded())
                // After the first buffer, rounding jitter of a frame or two is not a gap.
                if framesDelivered > 0 && abs(position - framesDelivered) <= 2 { position = framesDelivered }
            }
            var chunk = samples[...]
            var gap = 0
            if position < framesDelivered {
                let drop = min(frames, framesDelivered - position)
                chunk = chunk.dropFirst(drop * channels)
            } else if position > framesDelivered {
                gap = position - framesDelivered
            }
            var out: [Float] = []
            if gap > 0 {
                out.append(contentsOf: [Float](repeating: 0, count: min(gap, expectedFrames - framesDelivered) * channels))
            }
            let remaining = expectedFrames - framesDelivered - out.count / channels
            if remaining > 0 { out.append(contentsOf: chunk.prefix(remaining * channels)) }
            guard !out.isEmpty else { continue }
            framesDelivered += out.count / channels
            if framesDelivered >= expectedFrames, reader.status == .reading { reader.cancelReading() }
            return out
        }
        return nil
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }
}

/// The fixed downmix of ARCH §15 / ai.md §7.2: mono copy; stereo 0.5/0.5; 5.1 and wider
/// 0.5·C + 0.25·(L+R) + 0.125·(each surround), LFE dropped. Shared by waveforms and speech audio.
enum Downmix {
    static func coefficients(channels: Int, labels: [AudioChannelLabel]) -> [Float] {
        if channels == 1 { return [1] }
        if channels == 2 { return [0.5, 0.5] }
        guard labels.count == channels else {
            return [Float](repeating: 1 / Float(channels), count: channels)
        }
        return labels.map { label -> Float in
            switch label {
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: return 0.5
            case kAudioChannelLabel_Left, kAudioChannelLabel_Right: return 0.25
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return 0
            default: return 0.125  // surrounds
            }
        }
    }

    /// Interleaved [samples] of [channels] to mono with [coefficients].
    static func mono(_ samples: [Float], channels: Int, coefficients: [Float]) -> [Float] {
        if channels == 1 { return samples }
        let frames = samples.count / channels
        var result = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { out in
                for channel in 0..<channels where coefficients[channel] != 0 {
                    var weight = coefficients[channel]
                    // out += weight * input[channel::channels]
                    vDSP_vsma(input.baseAddress! + channel, vDSP_Stride(channels), &weight,
                              out.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(frames))
                }
            }
        }
        return result
    }
}
