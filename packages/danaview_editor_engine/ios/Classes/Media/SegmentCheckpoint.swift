// OWNER: IOS-17
//
// Atomic checkpoint of a segment-resumable reader/writer job (D-22, ARCH §14.2): job kind, input
// hash (plan or source fingerprint), encode settings, segment length, total range, the completed
// segments with their durations and first PTS, and whether the whole-duration audio file is
// complete. Written as JSON with write-to-temp + rename after every finished segment, so it
// survives a process kill at any point; a checkpoint whose kind, input hash or settings differ
// from the job's is discarded (the job restarts).
// FIX-48FPS-TIMESCALE: `videoTimescale` (the writers' media/movie timescale).

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// A CMTime that survives JSON (value/timescale; no epoch or flags beyond valid).
struct CodableTime: Codable, Equatable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    var time: CMTime { CMTime(value: value, timescale: timescale) }
}

/// Encoder settings shared by every segment of a job (identical settings -> identical SPS/PPS).
struct SegmentEncodeSettings: Codable, Equatable {
    enum Codec: String, Codable {
        case h264, hevc
    }

    enum Container: String, Codable {
        case mp4, mov
    }

    var codec: Codec = .h264
    var width: Int
    var height: Int
    /// Expected frame rate (`AVVideoExpectedSourceFrameRateKey`).
    var fps: Int
    var averageBitRate: Int
    /// Hard cap of the video data rate as a multiple of `averageBitRate`, enforced over a 1 s
    /// window (`kVTCompressionPropertyKey_DataRateLimits` next to AverageBitRate; QA-11 measured
    /// 1.2–1.6× overshoot of AverageBitRate alone on high-detail content). nil = no cap (proxy,
    /// reverse and precompose intermediates); exports set `defaultDataRateLimitFactor` (IOS-12).
    /// Optional so that a checkpoint written before the cap decodes (and then mismatches, so the
    /// job restarts with the capped settings).
    var dataRateLimitFactor: Double? = nil
    /// Keyframe interval in frames (`AVVideoMaxKeyFrameIntervalKey`), nil for none.
    var maxKeyFrameIntervalFrames: Int?
    /// Keyframe interval in seconds (`AVVideoMaxKeyFrameIntervalDurationKey`), nil for none.
    var maxKeyFrameIntervalSeconds: Double? = 1
    /// B-frames off by default: decode order equals presentation order, so concat never has to
    /// reconcile DTS across segment boundaries.
    var allowFrameReordering: Bool = false
    var container: Container = .mp4
    /// `AVVideoProfileLevelKey` override; nil = H.264 High / HEVC Main AutoLevel.
    var profileLevel: String?
    /// AAC settings of the whole-duration audio file, nil without audio.
    var audio: Audio?

    struct Audio: Codable, Equatable {
        var sampleRate: Int = 48_000
        var channels: Int = 2
        var bitRate: Int = 128_000
    }

    var fileType: AVFileType { container == .mov ? .mov : .mp4 }

    /// Base media and movie timescale of every video file a segmented job writes (segments,
    /// concat output, re-encoded segments). AVAssetWriter otherwise picks 600, which cannot hold
    /// 48 fps (frame k at round(12.5·k) ticks, up to 833 µs off k/48; QA-03 finding 4,
    /// FIX-48FPS-TIMESCALE). 48000 is a multiple of every project rate (24/25/30/48/50/60, LCM
    /// 1200) and of 600, so grid times CMTime(k, fps) and 600-tick source PTS land on exact ticks.
    static let baseVideoTimescale: Int32 = 48_000

    /// Video media/movie timescale for this job: `baseVideoTimescale`, or its least common
    /// multiple with `fps` for a rate that does not divide it (never in v1, D-03).
    var videoTimescale: CMTimeScale {
        SegmentEncodeSettings.videoTimescale(fps: fps)
    }

    static func videoTimescale(fps: Int) -> CMTimeScale {
        let base = Int(baseVideoTimescale)
        guard fps > 0, base % fps != 0 else { return baseVideoTimescale }
        var a = base, b = fps
        while b != 0 { (a, b) = (b, a % b) }
        let lcm = base / a * fps
        return lcm <= Int(Int32.max) ? CMTimeScale(lcm) : baseVideoTimescale
    }

    /// Peak factor of the export data-rate cap: 1.5× the average bitrate per second.
    static let defaultDataRateLimitFactor: Double = 1.5

    /// `DataRateLimits` value: [bytes, seconds] pairs (one pair: `factor × averageBitRate / 8`
    /// bytes per 1 s), nil without a cap.
    var dataRateLimits: [NSNumber]? {
        guard let factor = dataRateLimitFactor, factor > 0, averageBitRate > 0 else { return nil }
        let bytesPerSecond = (Double(averageBitRate) * factor / 8).rounded(.up)
        return [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)]
    }

    /// Writer output settings: H.264 High AutoLevel or HEVC Main AutoLevel (hvc1), BT.709.
    var videoOutputSettings: [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: allowFrameReordering,
        ]
        if let limits = dataRateLimits { compression[kVTCompressionPropertyKey_DataRateLimits as String] = limits }
        if let frames = maxKeyFrameIntervalFrames { compression[AVVideoMaxKeyFrameIntervalKey] = frames }
        if let seconds = maxKeyFrameIntervalSeconds { compression[AVVideoMaxKeyFrameIntervalDurationKey] = seconds }
        switch codec {
        case .h264: compression[AVVideoProfileLevelKey] = profileLevel ?? AVVideoProfileLevelH264HighAutoLevel
        case .hevc: compression[AVVideoProfileLevelKey] = profileLevel ?? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
        }
        return [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// AAC-LC output settings of the audio file.
    var audioOutputSettings: [String: Any]? {
        guard let audio = audio else { return nil }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = audio.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: audio.channels,
            AVEncoderBitRateKey: audio.bitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }
}

/// The persisted state of a segmented job.
struct SegmentCheckpoint: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var index: Int
        /// Output range of the segment (µs, end exclusive).
        var startUs: Int64
        var endUs: Int64
        var frames: Int
        var bytes: Int64
        /// PTS of the first frame written (concat re-times against it).
        var firstPts: CodableTime
    }

    static let fileName = "checkpoint.json"
    static let currentVersion = 1

    var version: Int = SegmentCheckpoint.currentVersion
    /// "export", "proxy", ... (IOS-12, IOS-05).
    var jobKind: String
    /// Plan hash or source fingerprint; a different input invalidates the checkpoint.
    var inputHash: String
    var settings: SegmentEncodeSettings
    /// Output range of the whole job (µs).
    var startUs: Int64
    var endUs: Int64
    var segmentDurationUs: Int64
    var completed: [Segment] = []
    var audioComplete: Bool = false
    var updatedAt: Date = Date()

    /// Number of segments the job is split into.
    var segmentCount: Int {
        let span = max(0, endUs - startUs)
        return Int((span + segmentDurationUs - 1) / segmentDurationUs)
    }

    /// Output range of segment [index].
    func range(of index: Int) -> (startUs: Int64, endUs: Int64) {
        let start = startUs + Int64(index) * segmentDurationUs
        return (start, min(endUs, start + segmentDurationUs))
    }

    /// The first segment not completed yet (== segmentCount when all are done).
    var nextSegment: Int {
        var next = 0
        let done = Set(completed.map { $0.index })
        while done.contains(next) { next += 1 }
        return next
    }

    /// Output time the job resumes from (callers re-create their reader with this `timeRange` start).
    var resumeTimeUs: Int64 { range(of: nextSegment).startUs }

    var isVideoComplete: Bool { nextSegment >= segmentCount }

    /// Fraction of the output already written.
    var doneFraction: Double {
        let total = Double(max(1, endUs - startUs))
        let done = completed.reduce(Int64(0)) { $0 + ($1.endUs - $1.startUs) }
        return min(1, Double(done) / total)
    }

    /// Whether this checkpoint belongs to the same job (kind, input and settings).
    func matches(jobKind: String, inputHash: String, settings: SegmentEncodeSettings, startUs: Int64, endUs: Int64,
                 segmentDurationUs: Int64) -> Bool {
        version == SegmentCheckpoint.currentVersion && self.jobKind == jobKind && self.inputHash == inputHash
            && self.settings == settings && self.startUs == startUs && self.endUs == endUs
            && self.segmentDurationUs == segmentDurationUs
    }

    // MARK: Persistence

    static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The checkpoint in [directory], or nil when missing or unreadable.
    static func load(from directory: URL) -> SegmentCheckpoint? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SegmentCheckpoint.self, from: data)
    }

    /// Writes atomically (temp file + rename).
    func save(to directory: URL) throws {
        var copy = self
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(copy)
            try data.write(to: SegmentCheckpoint.url(in: directory), options: .atomic)
        } catch {
            throw EngineError.from(error)
        }
    }

    static func delete(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}
