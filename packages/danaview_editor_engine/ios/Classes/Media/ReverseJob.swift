// OWNER: IOS-07
//
// Reversed rendition of a source range (ARCH §15 'Reverse', review issue 14), written to the
// Dart-supplied `derived/<specHash>.mp4`. Bounded memory and disk:
//
// 1. Timeline: one cheap passthrough read of the compressed video samples gives every frame's
//    PTS (no decode). A source frame i covering [p_i, e_i) (e_i = next PTS, capped at the range
//    end E) is shown in the output at the MIRRORED time E − e_i, so the last source frame comes
//    first and every frame keeps its own duration (VFR preserved).
// 2. Chunks from the end: the output is written by the IOS-17 SegmentedWriter in segments of
//    ≈ 2 s; output segment k holds the source frames whose end lies in (E − (k+1)·2 s, E − k·2 s],
//    i.e. the chunks are taken from the END of the source range. For each chunk the source is
//    decoded once (the reader starts at the sync sample before the chunk's first frame, so a chunk
//    decodes at most one partial GOP extra) into an ALL-INTRA H.264 intermediate in
//    `work/reverse-<specHash>/chunk.mov`, which is then read back with an
//    AVAssetReaderTrackOutput (`supportsRandomAccess = true`, one `reset(forReadingTimeRanges:)`
//    per frame, last frame first, 420v buffers). Only one intermediate exists at a time (deleted
//    when its segment closes) and it is never copied: peak work disk = finished segments (≈ the
//    output) + one chunk intermediate; peak memory = a few decoded 420v frames + codec working
//    sets.
// 3. Audio: the range is decoded to 48 kHz stereo Float32 in 64k-frame blocks taken from the end,
//    each block reversed in memory and appended in output order -> AAC 128k (SegmentedWriter
//    `writeAudio`, the whole-duration `a.m4a`).
// 4. The segments and the audio are concatenated (passthrough) into `<output>.part`, the source's
//    preferred transform restored (passthrough remux) and renamed to the output path.
//
// Preflight: ranges > 10 min are refused (`reverseRange` limit, message token "reverseRange";
// the Dart side maps it to `LimitExceeded('reverseRange')`), and free space must be at least
// 2 × estimated output + one chunk intermediate + 64 MB (`diskFull`).
// Interruptions (background via the JobRegistry/IOS-17 JobInterruption, or a pre-emption) keep
// every finished chunk: the checkpoint in `work/reverse-<specHash>/` resumes from the next chunk.
// Cancel deletes the work directory and the partial output.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class ReverseJob: MediaJobBody {
    /// Longest reversible range (ARCH §15 preflight).
    static let maxRangeUs: Int64 = 600_000_000
    /// Output (= source) duration of one chunk.
    static let defaultChunkUs: Int64 = 2_000_000
    /// Audio is reversed in blocks of this many 48 kHz frames.
    static let audioBlockFrames = 65_536
    static let audioSampleRate = 48_000
    static let audioBitRate = 128_000
    static let jobKind = "reverse"
    static let settingsVersion = "rev1"
    /// Free-space slack of the preflight.
    static let slackBytes: Int64 = 64 * 1_048_576
    /// Message token of the range refusal (Dart: `LimitExceeded('reverseRange')`).
    static let rangeLimitToken = "reverseRange"

    let kind = JobKindMsg.reverse
    let mediaURL: URL
    let fingerprint: String
    let startUs: Int64
    let endUs: Int64
    let audioStream: Int?
    let output: URL
    private let paths: Paths
    let chunkDurationUs: Int64

    // Test hooks.
    /// Called with the writer before every run (fault injection).
    var configureWriter: ((SegmentedWriter) -> Void)?
    /// Called after each chunk intermediate is written (bytes of the intermediate file).
    var onIntermediateWritten: ((_ intermediate: URL, _ bytes: Int64) -> Void)?
    /// Overrides the free-space query of the preflight.
    var freeBytesOverride: (() -> Int64)?

    init(mediaURL: URL, fingerprint: String, startUs: Int64, endUs: Int64, audioStream: Int?, output: URL,
         paths: Paths, chunkDurationUs: Int64 = ReverseJob.defaultChunkUs) {
        self.mediaURL = mediaURL
        self.fingerprint = fingerprint
        self.startUs = startUs
        self.endUs = endUs
        self.audioStream = audioStream
        self.output = output
        self.paths = paths
        self.chunkDurationUs = max(100_000, chunkDurationUs)
    }

    /// The spec hash of the rendition (output file name without extension).
    var specKey: String { CacheStore.fileName(output.deletingPathExtension().lastPathComponent) }
    var exclusiveKey: String? { "reverse-\(specKey)" }
    var workDirectory: URL { paths.work.appendingPathComponent("reverse-\(specKey)", isDirectory: true) }
    var partialURL: URL { output.appendingPathExtension("part") }

    // MARK: Sizing

    /// Output video bit rate: ≈ 0.1 bit per pixel per frame, 2...40 Mbit/s.
    static func outputBitRate(width: Int, height: Int, fps: Double) -> Int {
        let value = Double(width * height) * max(1, fps) * 0.1
        return Int(min(40_000_000, max(2_000_000, value)))
    }

    /// All-intra intermediate bit rate: ≈ 0.3 bit per pixel per frame, 8...150 Mbit/s.
    static func intermediateBitRate(width: Int, height: Int, fps: Double) -> Int {
        let value = Double(width * height) * max(1, fps) * 0.3
        return Int(min(150_000_000, max(8_000_000, value)))
    }

    /// Bytes of [bitRate] over [durationUs].
    static func bytes(bitRate: Int, durationUs: Int64) -> Int64 {
        Int64(Double(bitRate) / 8 * Double(durationUs) / 1_000_000)
    }

    /// The ARCH §15 preflight: range cap, then free space.
    static func preflight(rangeUs: Int64, estimatedOutputBytes: Int64, chunkBytes: Int64, freeBytes: Int64) throws {
        guard rangeUs > 0 else { throw EngineError.invalidArgument("range", "empty reverse range") }
        if rangeUs > maxRangeUs {
            throw EngineError(.unsupportedMedia, "limitExceeded \(rangeLimitToken) \(maxRangeUs)")
        }
        let needed = 2 * estimatedOutputBytes + chunkBytes + slackBytes
        if freeBytes < needed { throw EngineError(.diskFull, "not enough space for the reversed clip") }
    }

    /// Whether [error] is the range refusal of `preflight`.
    static func isRangeLimit(_ error: Error) -> Bool {
        let engine = EngineError.from(error)
        return engine.code == .unsupportedMedia && engine.message.contains(rangeLimitToken)
    }

    // MARK: Run

    func run(_ control: JobControl) throws -> JobResultMsg {
        if endUs - startUs > ReverseJob.maxRangeUs {
            throw EngineError(.unsupportedMedia, "limitExceeded \(ReverseJob.rangeLimitToken) \(ReverseJob.maxRangeUs)")
        }
        let info = try VideoTrackInfo.load(mediaURL)
        let rangeStart = max(0, startUs)
        let rangeEnd = min(endUs, info.endUs)
        guard rangeEnd > rangeStart else { throw EngineError.invalidArgument("range", "empty or past the media end") }
        let durationUs = rangeEnd - rangeStart

        func even(_ v: Int) -> Int { max(2, v - v % 2) }
        let width = even(info.width), height = even(info.height)
        let outputRate = ReverseJob.outputBitRate(width: width, height: height, fps: info.nominalFps)
        let intermediateRate = ReverseJob.intermediateBitRate(width: width, height: height, fps: info.nominalFps)
        let hasAudio = info.hasAudio
        let estimate = ReverseJob.bytes(bitRate: outputRate + (hasAudio ? ReverseJob.audioBitRate : 0), durationUs: durationUs)
        let chunkBytes = ReverseJob.bytes(bitRate: intermediateRate, durationUs: chunkDurationUs + 1_000_000)
        let free = try freeBytesOverride?() ?? Paths.freeBytes(at: paths.cacheRoot.path)
        try ReverseJob.preflight(rangeUs: durationUs, estimatedOutputBytes: estimate, chunkBytes: chunkBytes, freeBytes: free)

        try paths.ensureDirectory(paths.work)
        let directory = workDirectory
        DiskCache.markActive(directory)
        defer { DiskCache.unmarkActive(directory) }

        let timeline = try ReverseTimeline.load(info: info, startUs: rangeStart, endUs: rangeEnd, control: control)
        guard !timeline.frames.isEmpty else { throw EngineError(.decodeFailed, "no video frames in the range") }
        try control.check()
        control.progress(0.02)

        let settings = SegmentEncodeSettings(
            codec: .h264, width: width, height: height, fps: max(1, Int(info.nominalFps.rounded())),
            averageBitRate: outputRate, maxKeyFrameIntervalFrames: nil, maxKeyFrameIntervalSeconds: 1,
            allowFrameReordering: false, container: .mp4,
            audio: hasAudio ? SegmentEncodeSettings.Audio(sampleRate: ReverseJob.audioSampleRate, channels: 2,
                                                          bitRate: ReverseJob.audioBitRate) : nil)
        let writer = try SegmentedWriter(
            directory: directory, jobKind: ReverseJob.jobKind,
            inputHash: "\(fingerprint)-\(rangeStart)-\(rangeEnd)-\(ReverseJob.settingsVersion)",
            settings: settings, startUs: 0, endUs: durationUs, segmentDurationUs: chunkDurationUs)
        configureWriter?(writer)
        control.onStop { reason in
            if reason == .cancel { writer.cancel() } else { writer.interrupt() }
        }
        writer.onProgress = { control.progress(0.02 + $0 * 0.83) }

        let intermediateSettings = SegmentEncodeSettings(
            codec: .h264, width: width, height: height, fps: max(1, Int(info.nominalFps.rounded())),
            averageBitRate: intermediateRate, maxKeyFrameIntervalFrames: 1, maxKeyFrameIntervalSeconds: nil,
            allowFrameReordering: false, container: .mov)
        let source = ReverseFrameSource(
            info: info, timeline: timeline, intermediate: directory.appendingPathComponent("chunk.mov"),
            settings: intermediateSettings, control: control)
        source.onIntermediateWritten = onIntermediateWritten
        if try writer.writeVideo(source: source) == .interrupted {
            try control.check()
            throw EngineError(.interrupted, "reverse interrupted", retryable: true)
        }
        try control.check()
        if hasAudio {
            let audio = ReverseAudioSource(url: mediaURL, audioStream: audioStream ?? 0, sourceStartUs: rangeStart,
                                           sourceEndUs: rangeEnd, control: control)
            if try writer.writeAudio(source: audio) == .interrupted {
                try control.check()
                throw EngineError(.interrupted, "reverse audio interrupted", retryable: true)
            }
        }
        control.progress(0.9)
        try control.check()

        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
        let partial = partialURL
        try? FileManager.default.removeItem(at: partial)
        if info.transform.isIdentity {
            _ = try writer.concat(to: partial)
        } else {
            let joined = directory.appendingPathComponent("joined.mp4")
            _ = try writer.concat(to: joined)
            try PassthroughRemux.remux(from: joined, to: partial, fileType: .mp4, transform: info.transform)
            try? FileManager.default.removeItem(at: joined)
        }
        try control.check()
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            throw EngineError.from(error)
        }
        try? FileManager.default.removeItem(at: directory)
        control.progress(1)
        return JobResultMsg(kind: .reverse, asset: GeneratedAssetMsg(
            path: output.path, sizeBytes: SegmentedWriter.fileSize(output), durationUs: durationUs))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

// MARK: - Timeline

/// The source frames of a range and their mirrored output times.
struct ReverseTimeline {
    struct Frame {
        /// Source PTS (track timescale).
        let pts: CMTime
        /// End of the frame in the source (next PTS, capped at the range end).
        let end: CMTime
        /// Output PTS: rangeEnd − end.
        let outputPts: CMTime
    }

    /// Frames overlapping the range in source order.
    let frames: [Frame]
    let rangeStart: CMTime
    let rangeEnd: CMTime

    /// Builds the timeline from the source PTS list ([pts] in any order, [trackEnd] = end of the
    /// last frame).
    init(pts: [CMTime], trackEnd: CMTime, startUs: Int64, endUs: Int64) {
        let start = CMTime(value: startUs, timescale: 1_000_000)
        let end = CMTime(value: endUs, timescale: 1_000_000)
        rangeStart = start
        rangeEnd = end
        var sorted = pts.sorted { CMTimeCompare($0, $1) < 0 }
        sorted = sorted.enumerated().filter { $0.offset == 0 || CMTimeCompare($0.element, sorted[$0.offset - 1]) != 0 }.map { $0.element }
        var frames: [Frame] = []
        for (i, p) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : CMTimeMaximum(trackEnd, CMTimeAdd(p, CMTime(value: 1, timescale: 1_000_000)))
            let frameEnd = CMTimeMinimum(next, end)
            guard CMTimeCompare(p, end) < 0, CMTimeCompare(frameEnd, start) > 0 else { continue }
            frames.append(Frame(pts: p, end: frameEnd, outputPts: CMTimeSubtract(end, frameEnd)))
        }
        self.frames = frames
    }

    /// Reads the PTS of every compressed video sample around the range (no decoding).
    static func load(info: VideoTrackInfo, startUs: Int64, endUs: Int64, control: JobControl?) throws -> ReverseTimeline {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: info.asset)
        } catch {
            throw EngineError.from(error)
        }
        // A margin before the start finds the frame straddling it; after the end, the next PTS.
        let margin: Int64 = 2_000_000
        reader.timeRange = CMTimeRange(
            start: CMTime(value: max(0, startUs - margin), timescale: 1_000_000),
            end: CMTime(value: min(info.endUs, endUs + margin), timescale: 1_000_000))
        let output = AVAssetReaderTrackOutput(track: info.track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "timeline reader did not start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var pts: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if control?.isStopped == true { try control?.check() }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid { pts.append(time) }
        }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "timeline read failed")
        }
        let trackEnd = CMTime(value: info.endUs, timescale: 1_000_000)
        return ReverseTimeline(pts: pts, trackEnd: trackEnd, startUs: startUs, endUs: endUs)
    }

    /// Frames shown in output [outputStartUs, outputEndUs), in source order.
    func frames(outputStartUs: Int64, outputEndUs: Int64) -> ArraySlice<Frame> {
        let lo = CMTime(value: outputStartUs, timescale: 1_000_000)
        let hi = CMTime(value: outputEndUs, timescale: 1_000_000)
        // outputPts decreases with the index.
        guard let last = frames.lastIndex(where: { CMTimeCompare($0.outputPts, lo) >= 0 }) else { return [] }
        guard let first = frames.firstIndex(where: { CMTimeCompare($0.outputPts, hi) < 0 }), first <= last else { return [] }
        return frames[first...last]
    }
}

// MARK: - Video source

/// Frames of one output segment, last source frame first, through a per-chunk all-intra
/// intermediate.
final class ReverseFrameSource: SegmentVideoSource {
    private let info: VideoTrackInfo
    private let timeline: ReverseTimeline
    private let intermediateURL: URL
    private let settings: SegmentEncodeSettings
    private let control: JobControl?
    private let renderer: FrameRenderer
    var onIntermediateWritten: ((URL, Int64) -> Void)?

    private var chunk: [ReverseTimeline.Frame] = []
    /// PTS of the intermediate's samples (source order).
    private var intermediatePts: [CMTime] = []
    private var cursor = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init(info: VideoTrackInfo, timeline: ReverseTimeline, intermediate: URL, settings: SegmentEncodeSettings,
         control: JobControl?) {
        self.info = info
        self.timeline = timeline
        intermediateURL = intermediate
        self.settings = settings
        self.control = control
        renderer = FrameRenderer(width: settings.width, height: settings.height, toneMap: info.isHDR)
    }

    func openSegment(startUs: Int64, endUs: Int64) throws {
        closeSegment()
        chunk = Array(timeline.frames(outputStartUs: startUs, outputEndUs: endUs))
        cursor = 0
        guard !chunk.isEmpty else { return }
        try writeIntermediate()
        try openIntermediate()
    }

    // Stage 1: decode the chunk's source frames once into an all-intra intermediate.
    private func writeIntermediate() throws {
        try? FileManager.default.removeItem(at: intermediateURL)
        let first = chunk.first!.pts, last = chunk.last!.pts
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: info.asset)
            writer = try AVAssetWriter(outputURL: intermediateURL, fileType: .mov)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = CMTimeRange(start: first, end: chunk.last!.end)
        let source = AVAssetReaderTrackOutput(
            track: info.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: info.decodePixelFormat])
        source.alwaysCopiesSampleData = false
        reader.add(source)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = info.sampleTimescale
        guard writer.canAdd(input) else { throw EngineError(.encoderUnavailable, "intermediate input refused") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "chunk reader did not start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard writer.startWriting() else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encoderUnavailable, "intermediate writer did not start")
        }
        writer.startSession(atSourceTime: first)
        var written: [CMTime] = []
        var failure: Error?
        while let sample = source.copyNextSampleBuffer() {
            if let control = control, control.isStopped {
                failure = EngineError(.interrupted, "stopped", retryable: true)
                break
            }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, first) < 0 || CMTimeCompare(pts, last) > 0 { continue }
            if let previous = written.last, CMTimeCompare(pts, previous) <= 0 { continue }
            let frame: CVPixelBuffer
            do {
                frame = try renderer.render(image)
            } catch {
                failure = error
                break
            }
            while !input.isReadyForMoreMediaData {
                if control?.isStopped == true { break }
                usleep(1_000)
            }
            if control?.isStopped == true {
                failure = EngineError(.interrupted, "stopped", retryable: true)
                break
            }
            guard adaptor.append(frame, withPresentationTime: pts) else {
                failure = writer.error ?? EngineError(.encodingFailed, "intermediate append failed")
                break
            }
            written.append(pts)
        }
        if failure == nil, reader.status == .failed {
            failure = reader.error ?? EngineError(.decodeFailed, "chunk decode failed")
        }
        if failure == nil, written.isEmpty { failure = EngineError(.decodeFailed, "no frames decoded for the chunk") }
        if let failure = failure {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: intermediateURL)
            throw failure
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: chunk.last!.end)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: intermediateURL)
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "intermediate did not complete")
        }
        onIntermediateWritten?(intermediateURL, SegmentedWriter.fileSize(intermediateURL))
    }

    // Stage 2: random-access reader on the intermediate.
    private func openIntermediate() throws {
        let asset = AVURLAsset(url: intermediateURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try MediaBlocking.await({ try await asset.loadTracks(withMediaType: .video).first }) else {
            throw EngineError(.decodeFailed, "intermediate has no video")
        }
        // The intermediate's own sample times (a cheap passthrough pass over one chunk).
        intermediatePts = try ReverseFrameSource.samplePts(asset: asset, track: track)
        guard !intermediatePts.isEmpty else { throw EngineError(.decodeFailed, "empty intermediate") }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = true
        reader.add(output)
        reader.timeRange = range(ofIntermediate: intermediatePts.count - 1)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "intermediate reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    static func samplePts(asset: AVAsset, track: AVAssetTrack) throws -> [CMTime] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "intermediate scan failed")
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// The time range that holds only intermediate frame [index].
    private func range(ofIntermediate index: Int) -> CMTimeRange {
        let start = intermediatePts[index]
        let end = index + 1 < intermediatePts.count
            ? intermediatePts[index + 1] : CMTimeAdd(start, CMTime(value: 1, timescale: 1_000))
        return CMTimeRange(start: start, end: end)
    }

    /// The chunk frame an intermediate sample stands for (same index when the counts agree,
    /// otherwise the nearest source PTS).
    private func chunkFrame(forIntermediate index: Int) -> ReverseTimeline.Frame {
        if intermediatePts.count == chunk.count { return chunk[index] }
        let t = intermediatePts[index]
        return chunk.min { abs(CMTimeSubtract($0.pts, t).seconds) < abs(CMTimeSubtract($1.pts, t).seconds) }!
    }

    // Stage 3: frames in reverse order.
    func nextFrame() throws -> SegmentFrame? {
        guard let output = output, let reader = reader, cursor < intermediatePts.count else { return nil }
        if let control = control, control.isStopped { throw EngineError(.interrupted, "stopped", retryable: true) }
        let index = intermediatePts.count - 1 - cursor
        if cursor > 0 {
            // Finish the previous range, then jump back one frame.
            while output.copyNextSampleBuffer() != nil {}
            if reader.status == .failed {
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "intermediate read failed")
            }
            output.reset(forReadingTimeRanges: [NSValue(timeRange: range(ofIntermediate: index))])
        }
        cursor += 1
        let wanted = intermediatePts[index]
        var picked: CVPixelBuffer?
        while picked == nil, let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if abs(CMTimeSubtract(pts, wanted).seconds) < 0.0005 || CMTimeCompare(pts, wanted) >= 0 { picked = image }
        }
        guard let image = picked else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "intermediate frame missing")
        }
        let frame = chunkFrame(forIntermediate: index)
        return SegmentFrame(pixelBuffer: image, pts: frame.outputPts)
    }

    func closeSegment() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
        intermediatePts = []
        chunk = []
        try? FileManager.default.removeItem(at: intermediateURL)
    }
}

// MARK: - Audio source

/// The range's audio at 48 kHz stereo Float32, reversed: blocks of 64k frames are taken from the
/// end of the range, reversed in memory and delivered in output order.
final class ReverseAudioSource: SegmentAudioSource {
    private let url: URL
    private let audioStream: Int
    private let sourceStartUs: Int64
    private let sourceEndUs: Int64
    private let control: JobControl?
    private let rate = ReverseJob.audioSampleRate
    private let channels = 2
    private var track: AVAssetTrack?
    private var asset: AVURLAsset?
    private var totalFrames = 0
    private var nextOutputFrame = 0
    private var outputEndFrame = 0
    private var outputStartFrame = 0

    init(url: URL, audioStream: Int, sourceStartUs: Int64, sourceEndUs: Int64, control: JobControl?) {
        self.url = url
        self.audioStream = audioStream
        self.sourceStartUs = sourceStartUs
        self.sourceEndUs = sourceEndUs
        self.control = control
    }

    func openAudio(startUs: Int64, endUs: Int64) throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try MediaBlocking.await { try await asset.loadTracks(withMediaType: .audio) }
        guard !tracks.isEmpty else { throw EngineError(.unsupportedMedia, "no audio track") }
        self.asset = asset
        track = tracks[min(max(0, audioStream), tracks.count - 1)]
        totalFrames = Int((Double(sourceEndUs - sourceStartUs) * Double(rate) / 1_000_000).rounded())
        outputStartFrame = Int((Double(max(0, startUs)) * Double(rate) / 1_000_000).rounded())
        outputEndFrame = min(totalFrames, Int((Double(endUs) * Double(rate) / 1_000_000).rounded()))
        nextOutputFrame = outputStartFrame
    }

    func nextAudio() throws -> CMSampleBuffer? {
        guard nextOutputFrame < outputEndFrame else { return nil }
        try control?.check()
        let count = min(ReverseJob.audioBlockFrames, outputEndFrame - nextOutputFrame)
        // Output frames [o, o + count) are source-relative frames (N − o − count, N − o].
        let sourceFirst = totalFrames - nextOutputFrame - count
        var block = try readSource(firstFrame: sourceFirst, frames: count)
        ReverseAudioSource.reverseFrames(&block, channels: channels)
        let sample = try ReverseAudioSource.makeSampleBuffer(
            block, frames: count, channels: channels, rate: rate, startFrame: nextOutputFrame)
        nextOutputFrame += count
        return sample
    }

    func closeAudio() {
        asset = nil
        track = nil
    }

    /// Reverses the frame order of interleaved samples in place.
    static func reverseFrames(_ samples: inout [Float], channels: Int) {
        let frames = samples.count / channels
        var i = 0, j = frames - 1
        while i < j {
            for c in 0..<channels { samples.swapAt(i * channels + c, j * channels + c) }
            i += 1
            j -= 1
        }
    }

    /// Source-relative frames [firstFrame, firstFrame + frames) at 48 kHz stereo, silence where the
    /// source has none. Buffers are placed by their PTS (sample-accurate).
    private func readSource(firstFrame: Int, frames: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: frames * channels)
        guard let asset = asset, let track = track else { return result }
        let blockStart = Double(sourceStartUs) / 1_000_000 + Double(firstFrame) / Double(rate)
        let blockEnd = blockStart + Double(frames) / Double(rate)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        let pad = 0.05
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, blockStart - pad), preferredTimescale: CMTimeScale(rate)),
                                       end: CMTime(seconds: blockEnd + pad, preferredTimescale: CMTimeScale(rate)))
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "audio reader did not start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var expected: Int?
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            var position = expected ?? 0
            if pts.isValid {
                let measured = Int(((pts.seconds - blockStart) * Double(rate)).rounded())
                // Rounding jitter of a frame or two between contiguous buffers is not a gap.
                if expected == nil || abs(measured - position) > 2 { position = measured }
            }
            expected = position + count
            if position >= frames { break }
            if position + count <= 0 { continue }
            var buffer = [Float](repeating: 0, count: count * channels)
            let status = buffer.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: min(raw.count, CMBlockBufferGetDataLength(data)),
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw EngineError(.decodeFailed, "audio copy failed \(status)") }
            let from = max(0, -position), to = min(count, frames - position)
            if from < to {
                for f in from..<to {
                    let d = (position + f) * channels, s = f * channels
                    for c in 0..<channels { result[d + c] = buffer[s + c] }
                }
            }
        }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio decode failed")
        }
        return result
    }

    /// An interleaved Float32 LPCM sample buffer at output frame [startFrame].
    static func makeSampleBuffer(_ samples: [Float], frames: Int, channels: Int, rate: Int, startFrame: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format = format else { throw EngineError(.internal, "audio format \(status)") }
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block = block else { throw EngineError(.internal, "audio block \(status)") }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == kCMBlockBufferNoErr else { throw EngineError(.internal, "audio copy \(status)") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: Int64(startFrame), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample = sample else { throw EngineError(.internal, "audio sample \(status)") }
        return sample
    }
}
