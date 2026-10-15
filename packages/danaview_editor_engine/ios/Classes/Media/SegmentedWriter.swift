// OWNER: IOS-17
//
// Closed-GOP segmented AVAssetWriter (D-22, ARCH §14.2, review issue 4). AVAssetWriter loses its
// encoder in the background and cannot resume, so every long reader/writer job (export IOS-12,
// proxies IOS-05) writes its video as segments of N seconds of output (default 10 s): each segment
// is its own AVAssetWriter file `v-<n>.<mp4|mov>` that starts with an IDR and uses identical
// encoder settings. After every finished segment the SegmentCheckpoint is saved atomically. An
// interruption (JobInterruption on didEnterBackground, or a writer failing with
// AVFoundationErrorDomain −11847 / −11819) discards the in-progress segment and keeps the
// checkpoint; `writeVideo` called again (same process or after a relaunch) resumes from the next
// segment, re-opening the caller's source at that segment's start (`SegmentVideoSource`).
// The optional whole-duration audio is one AAC file `a.m4a` (cheap to redo). SegmentConcat joins
// everything with a passthrough copy.
//
// Threading: `writeVideo`, `writeAudio` and `concat` block the calling queue (a job queue, never
// main); the writer pumps run on a private serial queue via requestMediaDataWhenReady.
// `interrupt()` and `cancel()` may be called from any thread.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// One uncompressed frame in output time.
struct SegmentFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
}

/// Delivers frames of an output range. The writer opens it once per segment, so a source backed
/// by an AVAssetReader re-creates its reader with that segment's `timeRange`.
protocol SegmentVideoSource: AnyObject {
    /// Prepares frames whose output PTS lie in [startUs, endUs).
    func openSegment(startUs: Int64, endUs: Int64) throws
    /// The next frame (frames before startUs are skipped, a frame at or after endUs ends the
    /// segment), or nil at the end of the input.
    func nextFrame() throws -> SegmentFrame?
    func closeSegment()
}

/// Delivers LPCM sample buffers in output time for the whole-duration audio file.
protocol SegmentAudioSource: AnyObject {
    func openAudio(startUs: Int64, endUs: Int64) throws
    func nextAudio() throws -> CMSampleBuffer?
    func closeAudio()
}

final class SegmentedWriter {
    enum Outcome: Equatable {
        case completed
        /// Stopped by an interruption; the checkpoint keeps every finished segment.
        case interrupted
    }

    static let defaultSegmentDurationUs: Int64 = 10_000_000
    static let audioFileName = "a.m4a"

    let directory: URL
    private(set) var checkpoint: SegmentCheckpoint

    /// Test hook: an error returned for (segment, frame index) fails that segment's writer as if
    /// AVFoundation had (use AVFoundationErrorDomain −11847 to simulate the background loss).
    var faultInjector: ((_ segment: Int, _ frame: Int) -> Error?)?
    /// Test hook: per-segment settings (to provoke an SPS/PPS mismatch).
    var settingsOverride: ((_ segment: Int) -> SegmentEncodeSettings?)?
    /// Output-time progress 0...1 of the video (called on the pump queue).
    var onProgress: ((Double) -> Void)?

    private let pumpQueue = DispatchQueue(label: "com.vecvel.danaview.editor.segments.pump", qos: .userInitiated)
    private let lock = NSLock()
    private var interruptRequested = false
    private var cancelled = false

    /// Opens (or resumes) the job in [directory]. A checkpoint of a different job is discarded
    /// together with its segment files; partial segment files left by a kill are deleted.
    init(
        directory: URL, jobKind: String, inputHash: String, settings: SegmentEncodeSettings,
        startUs: Int64, endUs: Int64, segmentDurationUs: Int64 = SegmentedWriter.defaultSegmentDurationUs
    ) throws {
        guard endUs > startUs, segmentDurationUs > 0 else {
            throw EngineError.invalidArgument("range", "empty segmented job")
        }
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
        let fresh = SegmentCheckpoint(
            jobKind: jobKind, inputHash: inputHash, settings: settings, startUs: startUs, endUs: endUs,
            segmentDurationUs: segmentDurationUs)
        if var existing = SegmentCheckpoint.load(from: directory),
           existing.matches(jobKind: jobKind, inputHash: inputHash, settings: settings, startUs: startUs,
                            endUs: endUs, segmentDurationUs: segmentDurationUs) {
            // Keep only segments whose files still exist (a crash between rename and save is fine,
            // a deleted file is redone).
            let ext = settings.container.rawValue
            existing.completed = existing.completed.filter {
                $0.frames == 0 || FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("v-\($0.index).\(ext)").path)
            }
            if existing.audioComplete
                && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(SegmentedWriter.audioFileName).path) {
                existing.audioComplete = false
            }
            checkpoint = existing
        } else {
            checkpoint = fresh
            SegmentedWriter.removeSegmentFiles(in: directory)
            try fresh.save(to: directory)
        }
        removePartials()
    }

    var segmentCount: Int { checkpoint.segmentCount }

    func segmentURL(_ index: Int) -> URL {
        directory.appendingPathComponent("v-\(index).\(checkpoint.settings.container.rawValue)")
    }

    func partialSegmentURL(_ index: Int) -> URL {
        directory.appendingPathComponent("v-\(index).partial.\(checkpoint.settings.container.rawValue)")
    }

    var audioURL: URL { directory.appendingPathComponent(SegmentedWriter.audioFileName) }
    private var partialAudioURL: URL { directory.appendingPathComponent("a.partial.m4a") }

    // MARK: Control

    /// Stops the running segment at the next frame; the segment is discarded, the checkpoint kept.
    func interrupt() {
        lock.lock()
        interruptRequested = true
        lock.unlock()
    }

    /// Stops and deletes every file of the job (the directory included).
    func cancel() {
        lock.lock()
        interruptRequested = true
        cancelled = true
        lock.unlock()
        pumpQueue.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptRequested
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func clearInterrupt() {
        lock.lock()
        interruptRequested = false
        lock.unlock()
    }

    /// Whether [error] is the background encoder loss / media services reset (resumable).
    static func isInterruption(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == EngineError.avFoundationDomain && (ns.code == -11847 || ns.code == -11819) { return true }
        if let engine = error as? EngineError { return engine.code == .interrupted }
        return false
    }

    // MARK: Video

    /// Writes every remaining segment. Returns `.interrupted` when stopped (checkpoint kept).
    func writeVideo(source: SegmentVideoSource) throws -> Outcome {
        clearInterrupt()
        removePartials()
        while !checkpoint.isVideoComplete {
            if isCancelled { throw EngineError.cancelled }
            let index = checkpoint.nextSegment
            if try writeSegment(index, source: source) == .interrupted {
                if isCancelled { throw EngineError.cancelled }
                Log.info(.jobs, "segmented \(checkpoint.jobKind): segment \(index) interrupted, \(checkpoint.completed.count) kept")
                return .interrupted
            }
        }
        return .completed
    }

    private func writeSegment(_ index: Int, source: SegmentVideoSource) throws -> Outcome {
        let range = checkpoint.range(of: index)
        let settings = settingsOverride?(index) ?? checkpoint.settings
        let partial = partialSegmentURL(index)
        try? FileManager.default.removeItem(at: partial)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partial, fileType: settings.fileType)
        } catch {
            throw EngineError.from(error)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError(.encoderUnavailable, "segment input refused") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        try source.openSegment(startUs: range.startUs, endUs: range.endUs)
        defer { source.closeSegment() }
        guard writer.startWriting() else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encoderUnavailable, "segment writer did not start")
        }
        let start = CMTime(value: range.startUs, timescale: 1_000_000)
        let end = CMTime(value: range.endUs, timescale: 1_000_000)
        writer.startSession(atSourceTime: start)

        var frames = 0
        var firstPts: CMTime?
        var failure: Error?
        var stopped = false
        var finished = false
        let done = DispatchSemaphore(value: 0)
        let total = Double(max(1, checkpoint.endUs - checkpoint.startUs))
        let jobStart = checkpoint.startUs
        input.requestMediaDataWhenReady(on: pumpQueue) { [self] in
            guard !finished else { return }
            func finish() {
                finished = true
                done.signal()
            }
            while input.isReadyForMoreMediaData {
                if shouldStop {
                    stopped = true
                    return finish()
                }
                if let fault = faultInjector?(index, frames) {
                    failure = fault
                    return finish()
                }
                let frame: SegmentFrame?
                do {
                    frame = try source.nextFrame()
                } catch {
                    failure = error
                    return finish()
                }
                guard let frame = frame else {
                    input.markAsFinished()
                    return finish()
                }
                if CMTimeCompare(frame.pts, start) < 0 { continue }
                if CMTimeCompare(frame.pts, end) >= 0 {
                    input.markAsFinished()
                    return finish()
                }
                guard adaptor.append(frame.pixelBuffer, withPresentationTime: frame.pts) else {
                    failure = writer.error ?? EngineError(.encodingFailed, "segment append failed")
                    return finish()
                }
                if firstPts == nil { firstPts = frame.pts }
                frames += 1
                if frames % 15 == 0, let progress = onProgress {
                    let us = Double(frame.pts.value) * 1_000_000 / Double(frame.pts.timescale)
                    progress(min(1, max(0, (us - Double(jobStart)) / total)))
                }
            }
        }
        done.wait()

        if stopped || failure != nil {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            if stopped { return .interrupted }
            if let failure = failure, SegmentedWriter.isInterruption(failure) { return .interrupted }
            throw EngineError.from(failure!)
        }
        guard let first = firstPts else {
            // Nothing fell into this range (input shorter than the range): an empty segment.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            try record(SegmentCheckpoint.Segment(
                index: index, startUs: range.startUs, endUs: range.endUs, frames: 0, bytes: 0,
                firstPts: CodableTime(start)))
            return .completed
        }
        writer.endSession(atSourceTime: end)
        let finishedWriting = DispatchSemaphore(value: 0)
        writer.finishWriting { finishedWriting.signal() }
        finishedWriting.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            let error: Error = writer.error ?? EngineError(.encodingFailed, "segment writer did not complete")
            if SegmentedWriter.isInterruption(error) { return .interrupted }
            throw EngineError.from(error)
        }
        let final = segmentURL(index)
        do {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            throw EngineError.from(error)
        }
        try record(SegmentCheckpoint.Segment(
            index: index, startUs: range.startUs, endUs: range.endUs, frames: frames,
            bytes: SegmentedWriter.fileSize(final), firstPts: CodableTime(first)))
        onProgress?(Double(range.endUs - checkpoint.startUs) / total)
        return .completed
    }

    private func record(_ segment: SegmentCheckpoint.Segment) throws {
        checkpoint.completed.removeAll { $0.index == segment.index }
        checkpoint.completed.append(segment)
        checkpoint.completed.sort { $0.index < $1.index }
        try checkpoint.save(to: directory)
    }

    // MARK: Audio

    /// Writes the whole-duration AAC file (skipped when already complete).
    func writeAudio(source: SegmentAudioSource) throws -> Outcome {
        guard let settings = checkpoint.settings.audioOutputSettings else { return .completed }
        if checkpoint.audioComplete { return .completed }
        clearInterrupt()
        try? FileManager.default.removeItem(at: partialAudioURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partialAudioURL, fileType: .m4a)
        } catch {
            throw EngineError.from(error)
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError(.encoderUnavailable, "audio input refused") }
        writer.add(input)
        try source.openAudio(startUs: checkpoint.startUs, endUs: checkpoint.endUs)
        defer { source.closeAudio() }
        guard writer.startWriting() else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encoderUnavailable, "audio writer did not start")
        }
        let start = CMTime(value: checkpoint.startUs, timescale: 1_000_000)
        let end = CMTime(value: checkpoint.endUs, timescale: 1_000_000)
        writer.startSession(atSourceTime: start)
        var failure: Error?
        var stopped = false
        var finished = false
        var appended = 0
        let done = DispatchSemaphore(value: 0)
        input.requestMediaDataWhenReady(on: pumpQueue) { [self] in
            guard !finished else { return }
            func finish() {
                finished = true
                done.signal()
            }
            while input.isReadyForMoreMediaData {
                if shouldStop {
                    stopped = true
                    return finish()
                }
                let sample: CMSampleBuffer?
                do {
                    sample = try source.nextAudio()
                } catch {
                    failure = error
                    return finish()
                }
                guard let buffer = sample else {
                    input.markAsFinished()
                    return finish()
                }
                guard input.append(buffer) else {
                    failure = writer.error ?? EngineError(.encodingFailed, "audio append failed")
                    return finish()
                }
                appended += 1
            }
        }
        done.wait()
        if stopped || failure != nil || appended == 0 {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partialAudioURL)
            if stopped { return .interrupted }
            if let failure = failure {
                if SegmentedWriter.isInterruption(failure) { return .interrupted }
                throw EngineError.from(failure)
            }
            throw EngineError(.decodeFailed, "no audio samples")
        }
        // Trim to the output duration (the reader may run past it, ARCH §14.2).
        writer.endSession(atSourceTime: end)
        let finishedWriting = DispatchSemaphore(value: 0)
        writer.finishWriting { finishedWriting.signal() }
        finishedWriting.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partialAudioURL)
            let error: Error = writer.error ?? EngineError(.encodingFailed, "audio writer did not complete")
            if SegmentedWriter.isInterruption(error) { return .interrupted }
            throw EngineError.from(error)
        }
        do {
            try? FileManager.default.removeItem(at: audioURL)
            try FileManager.default.moveItem(at: partialAudioURL, to: audioURL)
        } catch {
            throw EngineError.from(error)
        }
        checkpoint.audioComplete = true
        try checkpoint.save(to: directory)
        return .completed
    }

    // MARK: Concat

    /// Joins the finished segments (and the audio file) into [output] with a passthrough copy;
    /// each segment is deleted after it was appended. The checkpoint is deleted on success.
    /// [transform] is the output video track's `preferredTransform` (identity by default).
    func concat(to output: URL, transform: CGAffineTransform = .identity) throws -> SegmentConcat.Result {
        guard checkpoint.isVideoComplete else {
            throw EngineError(.internal, "concat before every segment is written")
        }
        let result = try SegmentConcat.concat(
            checkpoint: checkpoint, directory: directory, segmentURL: segmentURL,
            audioURL: checkpoint.audioComplete ? audioURL : nil, to: output, transform: transform,
            isCancelled: { [weak self] in self?.isCancelled ?? true })
        SegmentCheckpoint.delete(in: directory)
        try? FileManager.default.removeItem(at: audioURL)
        return result
    }

    // MARK: Files

    private func removePartials() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.contains(".partial.") || name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func removeSegmentFiles(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("v-") || name.hasPrefix("a.") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Bytes of every regular file below [directory] ([excluding] one file, e.g. an output that
    /// lives inside it).
    static func directorySize(_ directory: URL, excluding: URL? = nil) -> Int64 {
        let skip = excluding?.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, url.standardizedFileURL.resolvingSymlinksInPath().path != skip {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Reader-backed source

/// Frames of one video track of a file, mapped to output time: output = source − sourceStart +
/// outputStart (identical PTS when both starts are equal, as proxies need). Re-creates its
/// AVAssetReader with each segment's time range. Output pixel format 420v by default.
final class AssetTrackFrameSource: SegmentVideoSource {
    private let asset: AVURLAsset
    private let sourceStartUs: Int64
    private let outputStartUs: Int64
    private let pixelFormat: OSType
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var track: AVAssetTrack?

    init(url: URL, sourceStartUs: Int64 = 0, outputStartUs: Int64 = 0,
         pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.sourceStartUs = sourceStartUs
        self.outputStartUs = outputStartUs
        self.pixelFormat = pixelFormat
    }

    private var offset: CMTime { CMTime(value: outputStartUs - sourceStartUs, timescale: 1_000_000) }

    func openSegment(startUs: Int64, endUs: Int64) throws {
        closeSegment()
        if track == nil {
            track = try MediaBlocking.await { [asset] in try await asset.loadTracks(withMediaType: .video).first }
        }
        guard let track = track else { throw EngineError(.unsupportedMedia, "no video track") }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        let start = CMTime(value: startUs - outputStartUs + sourceStartUs, timescale: 1_000_000)
        let end = CMTime(value: endUs - outputStartUs + sourceStartUs, timescale: 1_000_000)
        reader.timeRange = CMTimeRange(start: start, end: end)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    func nextFrame() throws -> SegmentFrame? {
        guard let output = output, let reader = reader else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), offset)
            return SegmentFrame(pixelBuffer: image, pts: pts)
        }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "reader failed")
        }
        return nil
    }

    func closeSegment() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
    }
}

// MARK: - Blocking bridge

/// Runs async AVFoundation loads from the engine's job queues (never from Swift concurrency's
/// cooperative pool, never from main).
enum MediaBlocking {
    static func await<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached(priority: .userInitiated) {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
