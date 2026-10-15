// OWNER: IOS-12
//
// Encoder settings of one export job (ARCH §12.4 `EncodeSettings`, §14.1 'Encoder size and
// orientation', §14.2): H.264 High AutoLevel or HEVC Main AutoLevel (`hvc1`), AverageBitRate,
// ExpectedSourceFrameRate, MaxKeyFrameIntervalDuration, BT.709 colour properties, no B-frames
// (`AllowFrameReordering = false`, IOS-01), and AAC-LC 48 kHz stereo audio. The writer settings
// themselves are IOS-17's `SegmentEncodeSettings` (every segment of a job must share them, so
// they share SPS/PPS).
//
// - `EncoderSettings(msg:)` turns the glue's `EncodeSettingsMsg` into the job's settings. Audio is
//   always AAC-LC 48 kHz stereo (§14.4 conformance); the AAC bitrate is clamped to 64–320 kbps.
// - `EncoderProbe` asks VideoToolbox whether an encoder takes a codec at a size (IOS-02's one-frame
//   test encode, cached per process). Tests inject refusals.
// - `EncodeLayout.choose` implements the §14.1 rule: the requested size as is, else, for a
//   portrait size, a landscape-encoded buffer plus a `preferredTransform` rotation, else
//   `encoderSizeLimit` (or `encoderUnavailable` when the codec encodes nothing at all).
// - `EncoderErrors.map` maps writer/encoder failures to `encoderUnavailable` / `encoderSizeLimit`.
// - Location metadata is never written: no writer of the pipeline sets `metadata`.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// The engine-level encode settings of an export job.
struct EncoderSettings: Codable, Equatable {
    enum Codec: String, Codable {
        case h264, hevc
    }

    enum Container: String, Codable {
        case mp4, mov
    }

    var container: Container
    var codec: Codec
    /// Output (display) size in px.
    var width: Int
    var height: Int
    /// Export frame rate.
    var fps: Int
    /// Average video bitrate in bit/s.
    var videoBitrate: Int
    /// AAC bitrate in bit/s (clamped to `audioBitrateRange`).
    var audioBitrate: Int
    /// Maximum keyframe interval in ms (`AVVideoMaxKeyFrameIntervalDurationKey`).
    var keyframeIntervalMs: Int
    /// Location metadata is never written, whatever this says (ARCH §14.1).
    var stripLocation: Bool

    /// Output audio is always AAC-LC 48 kHz stereo (ARCH §14.2, §14.4, D-38).
    static let audioSampleRate = 48_000
    static let audioChannels = 2
    static let audioBitrateRange = 64_000...320_000

    init(
        container: Container = .mp4, codec: Codec = .h264, width: Int, height: Int, fps: Int, videoBitrate: Int,
        audioBitrate: Int = 192_000, keyframeIntervalMs: Int = 2_000, stripLocation: Bool = true
    ) {
        self.container = container
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.videoBitrate = videoBitrate
        self.audioBitrate = min(EncoderSettings.audioBitrateRange.upperBound, max(EncoderSettings.audioBitrateRange.lowerBound, audioBitrate))
        self.keyframeIntervalMs = keyframeIntervalMs
        self.stripLocation = stripLocation
    }

    /// The settings of [msg] (already range-checked by the glue's `Validate.encodeSettings`).
    init(msg: EncodeSettingsMsg) throws {
        guard msg.width >= 16, msg.height >= 16, msg.width % 2 == 0, msg.height % 2 == 0 else {
            throw EngineError.invalidArgument("settings", "size must be even and at least 16 px")
        }
        guard msg.fps > 0, msg.videoBitrate > 0, msg.audioBitrate > 0, msg.keyframeIntervalMs > 0 else {
            throw EngineError.invalidArgument("settings", "fps, bitrates and keyframe interval must be positive")
        }
        if msg.audioSampleRate != Int64(EncoderSettings.audioSampleRate) || msg.audioChannels != Int64(EncoderSettings.audioChannels) {
            Log.info(.export, "audio forced to AAC 48 kHz stereo (asked \(msg.audioSampleRate) Hz, \(msg.audioChannels) ch)")
        }
        self.init(
            container: msg.container == .mov ? .mov : .mp4, codec: msg.codec == .hevc ? .hevc : .h264,
            width: Int(msg.width), height: Int(msg.height), fps: Int(msg.fps), videoBitrate: Int(msg.videoBitrate),
            audioBitrate: Int(msg.audioBitrate), keyframeIntervalMs: Int(msg.keyframeIntervalMs),
            stripLocation: msg.stripLocation)
    }

    /// The settings as the glue message (records, `activeJobs`).
    var msg: EncodeSettingsMsg {
        EncodeSettingsMsg(
            container: container == .mov ? .mov : .mp4, codec: codec == .hevc ? .hevc : .h264, width: Int64(width),
            height: Int64(height), fps: Int64(fps), videoBitrate: Int64(videoBitrate), audioBitrate: Int64(audioBitrate),
            audioSampleRate: Int64(EncoderSettings.audioSampleRate), audioChannels: Int64(EncoderSettings.audioChannels),
            keyframeIntervalMs: Int64(keyframeIntervalMs), stripLocation: stripLocation)
    }

    var isPortrait: Bool { height > width }
    var shortSide: Int { min(width, height) }
    var fileType: AVFileType { container == .mov ? .mov : .mp4 }
    var fileExtension: String { container.rawValue }

    /// Keyframe interval in seconds, at most one segment (every segment starts with an IDR anyway).
    var keyframeIntervalSeconds: Double {
        min(Double(SegmentedWriter.defaultSegmentDurationUs) / 1_000_000, max(0.1, Double(keyframeIntervalMs) / 1000))
    }

    /// The same settings with another codec (HEVC → H.264 fallback).
    func with(codec: Codec) -> EncoderSettings {
        var copy = self
        copy.codec = codec
        return copy
    }

    /// Human-readable encoder name for `ExportResult.videoEncoderName` (no device data).
    var encoderName: String { codec == .hevc ? "VideoToolbox HEVC" : "VideoToolbox H.264" }

    /// The writer settings of every segment: [layout] `.rotated` swaps width and height (the
    /// landscape-encoded buffer of §14.1).
    func segmentSettings(layout: EncodeLayout) -> SegmentEncodeSettings {
        let rotated = layout == .rotated
        return SegmentEncodeSettings(
            codec: codec == .hevc ? .hevc : .h264,
            width: rotated ? height : width,
            height: rotated ? width : height,
            fps: fps,
            averageBitRate: videoBitrate,
            maxKeyFrameIntervalFrames: nil,
            maxKeyFrameIntervalSeconds: keyframeIntervalSeconds,
            allowFrameReordering: false,
            container: container == .mov ? .mov : .mp4,
            profileLevel: nil,
            audio: SegmentEncodeSettings.Audio(
                sampleRate: EncoderSettings.audioSampleRate, channels: EncoderSettings.audioChannels, bitRate: audioBitrate))
    }

    /// Bytes the export needs on disk (ARCH §14.1 estimate `(video + audio bps)·sec/8·1.02`) plus one
    /// 10 s segment (ARCH §14.2: peak disk ≈ estimate + one segment).
    func requiredBytes(durationUs: Int64) -> Int64 {
        let bps = Double(videoBitrate + audioBitrate)
        let seconds = Double(max(0, durationUs)) / 1_000_000
        let estimate = bps * seconds / 8 * 1.02
        let segment = Double(videoBitrate) * Double(SegmentedWriter.defaultSegmentDurationUs) / 1_000_000 / 8
        return Int64(estimate + segment)
    }
}

/// How the video is encoded (ARCH §14.1).
enum EncodeLayout: String, Codable, Equatable {
    /// The output size as requested.
    case native
    /// A portrait output encoded as a landscape buffer (frames rotated 90° counter-clockwise) with
    /// a 90° clockwise `preferredTransform` on the video track, so players show it upright.
    case rotated

    /// The layout the encoder accepts for [settings]: `.native`, else `.rotated` for a portrait
    /// size whose landscape twin encodes; otherwise `encoderSizeLimit` (`encoderUnavailable` when
    /// the codec does not encode even a small reference size).
    static func choose(_ settings: EncoderSettings, probe: EncoderProbe) throws -> EncodeLayout {
        if probe.canEncode(settings.codec, settings.width, settings.height) { return .native }
        if settings.isPortrait, probe.canEncode(settings.codec, settings.height, settings.width) {
            Log.info(.export, "portrait \(settings.width)x\(settings.height) refused: encoding landscape with rotation")
            return .rotated
        }
        throw EncoderErrors.refused(settings, probe: probe)
    }

    /// The display transform of a `.rotated` video track whose encoded buffer is
    /// [encodedWidth]×[encodedHeight] (landscape): 90° clockwise, so the display is
    /// encodedHeight×encodedWidth.
    static func rotatedTransform(encodedHeight: Int) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(encodedHeight), ty: 0)
    }
}

/// Whether an encoder takes a codec at a size.
struct EncoderProbe {
    /// (codec, width, height) → encodes.
    var canEncode: (EncoderSettings.Codec, Int, Int) -> Bool

    /// Small reference size: a codec that refuses it is unavailable, not size-limited.
    static let referenceSize = (width: 640, height: 360)

    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    /// VideoToolbox: a session plus a one-frame test encode at the size (IOS-02's probe; the same
    /// test also covers the pre-17.4 HEVC path), cached per process.
    static let system = EncoderProbe { codec, width, height in
        let key = "\(codec.rawValue)-\(width)x\(height)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let ok = Capabilities.testEncode(
            codec: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, width: width, height: height)
        lock.lock()
        cache[key] = ok
        lock.unlock()
        return ok
    }

    /// A probe that refuses exactly the sizes [refused] answers true for (tests).
    static func refusing(_ refused: @escaping (EncoderSettings.Codec, Int, Int) -> Bool, base: EncoderProbe = .system) -> EncoderProbe {
        EncoderProbe { codec, w, h in refused(codec, w, h) ? false : base.canEncode(codec, w, h) }
    }
}

/// Encoder failure mapping (ARCH §14.1, §19).
enum EncoderErrors {
    /// The failure for a size [probe] refuses: `encoderUnavailable` when the codec refuses the small
    /// reference size too, otherwise `encoderSizeLimit` (UX-39 then offers "Lower resolution").
    static func refused(_ settings: EncoderSettings, probe: EncoderProbe) -> EngineError {
        let ref = EncoderProbe.referenceSize
        if !probe.canEncode(settings.codec, ref.width, ref.height) {
            return EngineError(.encoderUnavailable, "no \(settings.codec.rawValue) encoder")
        }
        return EngineError(.encoderSizeLimit, "\(settings.codec.rawValue) encoder refused \(settings.width)x\(settings.height)")
    }

    /// Whether [error] (from a segment writer) means the encoder would not take the configuration.
    static func isEncoderRefusal(_ error: Error) -> Bool {
        let e = EngineError.from(error)
        switch e.code {
        case .encoderUnavailable, .encoderSizeLimit: return true
        default: break
        }
        let ns = error as NSError
        // AVErrorInvalidOutputSettings-like configuration failures and VideoToolbox parameter errors.
        if ns.domain == EngineError.avFoundationDomain, [-11861, -11841, -11834, -11840].contains(ns.code) { return true }
        if ns.domain == NSOSStatusErrorDomain, [-12902, -12908, -12915, -12903].contains(ns.code) { return true }
        return false
    }

    /// Maps a writer failure of the video encoder to the export error: refusals become
    /// `encoderSizeLimit`/`encoderUnavailable`, other errors keep their mapping.
    static func map(_ error: Error, settings: EncoderSettings, probe: EncoderProbe) -> EngineError {
        guard isEncoderRefusal(error) else { return EngineError.from(error) }
        return refused(settings, probe: probe)
    }
}
