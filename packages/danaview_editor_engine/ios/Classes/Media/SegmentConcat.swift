// OWNER: IOS-17
//
// Passthrough concat of a segmented job (D-22, ARCH §14.2): an AVAssetReader with nil output
// settings per segment feeds ONE AVAssetWriter video input whose sourceFormatHint is the first
// segment's format description; every sample is re-timed onto the job timeline (the PTS recorded
// in the checkpoint). Segments must share SPS/PPS (VPS too for HEVC): the parameter sets are
// compared and a mismatching segment is re-encoded with the job's settings before it is appended
// (and fails with encodingFailed when it still differs). The audio file is muxed passthrough by a
// second pump running at the same time (the writer interleaves its inputs). Each segment is
// deleted right after it was appended, so peak disk ≈ output + one segment; the peak is measured
// and returned. `transform` becomes the video track's `preferredTransform` (IOS-12's rotated
// portrait layout, ARCH §14.1), so no second passthrough copy is needed to set it.

import AVFoundation
import CoreMedia
import Foundation

enum SegmentConcat {
    struct Result: Equatable {
        var frames: Int
        var durationUs: Int64
        var bytes: Int64
        /// Highest (segment directory + output) bytes seen while concatenating.
        var peakDiskBytes: Int64
        /// Segments re-encoded because their parameter sets differed from the first segment's.
        var reencodedSegments: [Int]
    }

    static func concat(
        checkpoint: SegmentCheckpoint, directory: URL, segmentURL: @escaping (Int) -> URL, audioURL: URL?,
        to output: URL, transform: CGAffineTransform = .identity, isCancelled: @escaping () -> Bool
    ) throws -> Result {
        let segments = checkpoint.completed.filter { $0.frames > 0 }.sorted { $0.index < $1.index }
        guard let firstSegment = segments.first else { throw EngineError(.encodingFailed, "no video segments") }
        let hint = try formatDescription(of: segmentURL(firstSegment.index), mediaType: .video)
        let hintSets = parameterSets(hint)

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: checkpoint.settings.fileType)
        } catch {
            throw EngineError.from(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw EngineError(.encodingFailed, "concat video input refused") }
        writer.add(videoInput)

        var audioFeed: AudioFeed?
        var audioInput: AVAssetWriterInput?
        if let audioURL = audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            let audioHint = try formatDescription(of: audioURL, mediaType: .audio)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioFeed = try AudioFeed(url: audioURL, startUs: checkpoint.startUs)
            }
        }

        let feed = VideoFeed(
            segments: segments, settings: checkpoint.settings, directory: directory, segmentURL: segmentURL,
            hintSets: hintSets, output: output)
        guard writer.startWriting() else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "concat writer did not start")
        }
        writer.startSession(atSourceTime: CMTime(value: checkpoint.startUs, timescale: 1_000_000))

        let group = DispatchGroup()
        var videoFailure: Error?
        var audioFailure: Error?
        pump(videoInput, label: "video", group: group, isCancelled: isCancelled, next: { try feed.next() }) {
            videoFailure = $0
        }
        if let input = audioInput, let audio = audioFeed {
            pump(input, label: "audio", group: group, isCancelled: isCancelled, next: { try audio.next() }) {
                audioFailure = $0
            }
        }
        group.wait()
        if let failure = videoFailure ?? audioFailure {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw EngineError.from(failure)
        }
        writer.endSession(atSourceTime: CMTime(value: checkpoint.endUs, timescale: 1_000_000))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "concat did not complete")
        }
        let bytes = SegmentedWriter.fileSize(output)
        return Result(
            frames: feed.frames, durationUs: checkpoint.endUs - checkpoint.startUs, bytes: bytes,
            peakDiskBytes: max(feed.peakDiskBytes, bytes + SegmentedWriter.directorySize(directory, excluding: output)),
            reencodedSegments: feed.reencoded)
    }

    /// Feeds [input] from [next] on its own queue until nil, a failure or cancellation.
    private static func pump(
        _ input: AVAssetWriterInput, label: String, group: DispatchGroup, isCancelled: @escaping () -> Bool,
        next: @escaping () throws -> CMSampleBuffer?, fail: @escaping (Error) -> Void
    ) {
        group.enter()
        var done = false
        let queue = DispatchQueue(label: "com.vecvel.danaview.editor.concat.\(label)", qos: .userInitiated)
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                if isCancelled() {
                    done = true
                    fail(EngineError.cancelled)
                    input.markAsFinished()
                    return group.leave()
                }
                do {
                    guard let sample = try next() else {
                        done = true
                        input.markAsFinished()
                        return group.leave()
                    }
                    guard input.append(sample) else {
                        done = true
                        fail(EngineError(.encodingFailed, "concat \(label) append failed"))
                        return group.leave()
                    }
                } catch {
                    done = true
                    fail(error)
                    input.markAsFinished()
                    return group.leave()
                }
            }
        }
    }

    // MARK: Video feed

    /// Compressed video samples of every segment in order, re-timed; re-encodes mismatching
    /// segments and deletes each segment once it is exhausted.
    private final class VideoFeed {
        let segments: [SegmentCheckpoint.Segment]
        let settings: SegmentEncodeSettings
        let directory: URL
        let segmentURL: (Int) -> URL
        let hintSets: [Data]
        let output: URL
        private var position = -1
        private var reader: AVAssetReader?
        private var trackOutput: AVAssetReaderTrackOutput?
        private var offset: CMTime = .zero
        private var offsetKnown = false
        private var current: SegmentCheckpoint.Segment?
        private var currentFiles: [URL] = []
        private(set) var frames = 0
        private(set) var peakDiskBytes: Int64 = 0
        private(set) var reencoded: [Int] = []

        init(segments: [SegmentCheckpoint.Segment], settings: SegmentEncodeSettings, directory: URL,
             segmentURL: @escaping (Int) -> URL, hintSets: [Data], output: URL) {
            self.segments = segments
            self.settings = settings
            self.directory = directory
            self.segmentURL = segmentURL
            self.hintSets = hintSets
            self.output = output
        }

        func next() throws -> CMSampleBuffer? {
            while true {
                if let trackOutput = trackOutput, let sample = trackOutput.copyNextSampleBuffer() {
                    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                    if !offsetKnown, let segment = current {
                        offset = CMTimeSubtract(segment.firstPts.time, CMSampleBufferGetPresentationTimeStamp(sample))
                        offsetKnown = true
                    }
                    frames += 1
                    if frames % 30 == 0 { measure() }
                    return try SegmentConcat.retime(sample, by: offset)
                }
                if let reader = reader, reader.status == .failed {
                    throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "segment read failed")
                }
                try advance()
                if position >= segments.count { return nil }
            }
        }

        private func advance() throws {
            measure()
            reader?.cancelReading()
            reader = nil
            trackOutput = nil
            for file in currentFiles {
                try? FileManager.default.removeItem(at: file)
            }
            currentFiles = []
            position += 1
            guard position < segments.count else { return }
            let segment = segments[position]
            current = segment
            offsetKnown = false
            var url = segmentURL(segment.index)
            currentFiles = [url]
            let description = try SegmentConcat.formatDescription(of: url, mediaType: .video)
            if SegmentConcat.parameterSets(description) != hintSets {
                Log.info(.jobs, "segment \(segment.index) parameter sets differ; re-encoding it")
                let redo = directory.appendingPathComponent("v-\(segment.index).reencoded.\(settings.container.rawValue)")
                try SegmentConcat.reencode(url, to: redo, settings: settings, segment: segment)
                let again = try SegmentConcat.formatDescription(of: redo, mediaType: .video)
                guard SegmentConcat.parameterSets(again) == hintSets else {
                    throw EngineError(.encodingFailed, "segment \(segment.index) parameter sets differ after re-encode")
                }
                reencoded.append(segment.index)
                url = redo
                currentFiles.append(redo)
                measure()
            }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try MediaBlocking.await({ try await asset.loadTracks(withMediaType: .video).first }) else {
                throw EngineError(.decodeFailed, "segment without video")
            }
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
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "segment reader did not start")
            }
            self.reader = reader
            trackOutput = output
        }

        private func measure() {
            let bytes = SegmentedWriter.directorySize(directory, excluding: output) + SegmentedWriter.fileSize(output)
            peakDiskBytes = max(peakDiskBytes, bytes)
        }
    }

    // MARK: Audio feed

    private final class AudioFeed {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let startUs: Int64
        var offset: CMTime?

        init(url: URL, startUs: Int64) throws {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try MediaBlocking.await({ try await asset.loadTracks(withMediaType: .audio).first }) else {
                throw EngineError(.decodeFailed, "audio file without a track")
            }
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw EngineError.from(error)
            }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            self.startUs = startUs
            guard reader.startReading() else {
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio reader did not start")
            }
        }

        func next() throws -> CMSampleBuffer? {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio read failed")
                }
                return nil
            }
            if offset == nil {
                offset = CMTimeSubtract(
                    CMTime(value: startUs, timescale: 1_000_000), CMSampleBufferGetPresentationTimeStamp(sample))
            }
            guard let offset = offset, CMTimeCompare(offset, .zero) != 0 else { return sample }
            return try SegmentConcat.retime(sample, by: offset)
        }
    }

    // MARK: Helpers

    /// [sample] with every timing entry shifted by [offset].
    static func retime(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        if CMTimeCompare(offset, .zero) == 0 { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<Int(count) {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        guard status == noErr, let result = copy else { throw EngineError(.encodingFailed, "retime failed \(status)") }
        return result
    }

    /// The first format description of [url]'s first track of [mediaType].
    static func formatDescription(of url: URL, mediaType: AVMediaType) throws -> CMFormatDescription {
        let asset = AVURLAsset(url: url)
        let description = try MediaBlocking.await { () -> CMFormatDescription? in
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return nil }
            return try await track.load(.formatDescriptions).first
        }
        guard let result = description else { throw EngineError(.decodeFailed, "no \(mediaType.rawValue) format") }
        return result
    }

    /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) of a format description; empty for other codecs.
    static func parameterSets(_ description: CMFormatDescription) -> [Data] {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        var sets: [Data] = []
        var count = 0
        if subtype == kCMVideoCodecType_H264 {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = pointer {
                    sets.append(Data(bytes: p, count: size))
                }
            }
        } else if subtype == kCMVideoCodecType_HEVC {
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = pointer {
                    sets.append(Data(bytes: p, count: size))
                }
            }
        }
        return sets
    }

    /// Decodes [source] and encodes it again with [settings] at the same PTS.
    static func reencode(_ source: URL, to destination: URL, settings: SegmentEncodeSettings,
                         segment: SegmentCheckpoint.Segment) throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try MediaBlocking.await({ try await asset.loadTracks(withMediaType: .video).first }) else {
            throw EngineError(.decodeFailed, "segment without video")
        }
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: settings.fileType)
        } catch {
            throw EngineError.from(error)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw (reader.error ?? writer.error).map(EngineError.from) ?? EngineError(.encodingFailed, "re-encode did not start")
        }
        var started = false
        var pending: CMSampleBuffer?
        while true {
            guard let sample = pending ?? output.copyNextSampleBuffer() else { break }
            pending = nil
            if !started {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                started = true
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                usleep(1000)
            }
            guard input.append(sample) else {
                reader.cancelReading()
                writer.cancelWriting()
                throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "re-encode append failed")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "re-encode did not complete")
        }
        _ = segment
    }
}
