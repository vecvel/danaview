// OWNER: IOS-17
//
// Segmented writer, checkpoint, passthrough concat and job interruption (BUILD_PLAN IOS-17):
// - an H.264 segmented export of frame_counter_720p25 interrupted at random points (the writer
//   failed with AVFoundationErrorDomain −11847) resumes and concatenates to a file whose barcodes,
//   frame count and PTS equal an uninterrupted export;
// - the concat output passes the §14.4 container checks (avc1, size, fps, frame count =
//   duration × fps ± 1, every segment starting with a sync sample, AAC 48 kHz stereo when audio
//   is muxed); peak disk is measured;
// - the checkpoint survives a process kill (new writer instance, stray partial segment);
// - an SPS/PPS mismatch is re-encoded;
// - JobInterruption interrupts on didEnterBackground and re-queues on willEnterForeground.
//
// Real-device background behaviour (encoder loss after > 30 s in the background on iOS 18/26) is
// deferred: no device available (D-43); the simulator never takes the encoder away (IOS-01).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// Helpers of the IOS-17 tests.
enum SegmentTestSupport {
    static let fixture = "frame_counter_720p25.mp4"
    static let frameCount = 200
    static let fps = 25

    static func settings(audio: Bool = false) -> SegmentEncodeSettings {
        SegmentEncodeSettings(
            codec: .h264, width: 1280, height: 720, fps: fps, averageBitRate: 4_000_000,
            maxKeyFrameIntervalFrames: nil, maxKeyFrameIntervalSeconds: 1, allowFrameReordering: false,
            container: .mp4, audio: audio ? SegmentEncodeSettings.Audio() : nil)
    }

    static func tempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("danaview-seg-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writer(_ directory: URL, inputHash: String = "frame_counter_720p25", audio: Bool = false) throws -> SegmentedWriter {
        try SegmentedWriter(
            directory: directory, jobKind: "export", inputHash: inputHash, settings: settings(audio: audio),
            startUs: 0, endUs: 8_000_000, segmentDurationUs: 2_000_000)
    }

    /// PTS (µs) and barcode index of every frame of [url].
    static func readBack(_ url: URL) throws -> [(ptsUs: Int64, index: Int?)] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [(Int64, Int?)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            frames.append((Int64((pts.seconds * 1_000_000).rounded()), FrameBarcode.read(pixelBuffer: image).index))
        }
        return frames
    }

    /// Whether the first sample of [url]'s video track is a sync sample.
    static func startsWithSyncSample(_ url: URL) throws -> Bool {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer() else { return false }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    /// Runs `writeVideo` until complete; returns the number of interruptions.
    static func runToCompletion(_ writer: SegmentedWriter, source: SegmentVideoSource, maxRuns: Int = 20) throws -> Int {
        var interruptions = 0
        for _ in 0..<maxRuns {
            if try writer.writeVideo(source: source) == .completed { return interruptions }
            interruptions += 1
        }
        XCTFail("did not complete in \(maxRuns) runs")
        return interruptions
    }

    static func interruptionError() -> NSError {
        NSError(domain: AVFoundationErrorDomain, code: -11847)
    }
}

/// A sine LPCM source (Float32 interleaved stereo, 48 kHz) for the audio file.
final class SineAudioSource: SegmentAudioSource {
    private var frame = 0
    private var endFrame = 0
    private var startUs: Int64 = 0
    private let chunk = 4800

    func openAudio(startUs: Int64, endUs: Int64) throws {
        self.startUs = startUs
        frame = 0
        endFrame = Int((endUs - startUs) * 48_000 / 1_000_000)
    }

    func nextAudio() throws -> CMSampleBuffer? {
        guard frame < endFrame else { return nil }
        let count = min(chunk, endFrame - frame)
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let value = Float(0.25 * sin(2 * Double.pi * 1000 * Double(frame + i) / 48_000))
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let pts = CMTime(value: Int64(frame) + startUs * 48_000 / 1_000_000, timescale: 48_000)
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        frame += count
        return sample
    }

    func closeAudio() {}
}

final class SegmentedWriterTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        super.tearDown()
    }

    private func directory(_ name: String) -> URL {
        let url = SegmentTestSupport.tempDirectory(name)
        directories.append(url)
        return url
    }

    private func fixtureSource() throws -> AssetTrackFrameSource {
        AssetTrackFrameSource(url: try ProbeFixtures.url(SegmentTestSupport.fixture))
    }

    /// The uninterrupted reference export (cached across tests of one run).
    private static var reference: [(ptsUs: Int64, index: Int?)]?

    private func referenceFrames() throws -> [(ptsUs: Int64, index: Int?)] {
        if let cached = SegmentedWriterTests.reference { return cached }
        let dir = directory("reference")
        let writer = try SegmentTestSupport.writer(dir)
        XCTAssertEqual(try SegmentTestSupport.runToCompletion(writer, source: try fixtureSource()), 0)
        let out = dir.appendingPathComponent("out.mp4")
        _ = try writer.concat(to: out)
        let frames = try SegmentTestSupport.readBack(out)
        SegmentedWriterTests.reference = frames
        return frames
    }

    func testUninterruptedExportPassesContainerChecks() throws {
        let dir = directory("plain")
        let writer = try SegmentTestSupport.writer(dir)
        XCTAssertEqual(writer.segmentCount, 4)
        XCTAssertEqual(try SegmentTestSupport.runToCompletion(writer, source: try fixtureSource()), 0)
        var segmentBytes: Int64 = 0
        for index in 0..<writer.segmentCount {
            XCTAssertTrue(try SegmentTestSupport.startsWithSyncSample(writer.segmentURL(index)), "segment \(index) starts with an IDR")
            segmentBytes = max(segmentBytes, SegmentedWriter.fileSize(writer.segmentURL(index)))
        }
        let out = dir.appendingPathComponent("out.mp4")
        let result = try writer.concat(to: out)
        XCTAssertEqual(result.frames, SegmentTestSupport.frameCount)
        XCTAssertEqual(result.reencodedSegments, [])
        for index in 0..<4 {
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.segmentURL(index).path), "segment \(index) deleted")
        }
        XCTAssertNil(SegmentCheckpoint.load(from: dir), "checkpoint removed after concat")

        // §14.4 container checks.
        let asset = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tracks) = try MediaBlocking.await { () -> (CMTime, [AVAssetTrack]) in
            (try await asset.load(.duration), try await asset.loadTracks(withMediaType: .video))
        }
        let track = try XCTUnwrap(tracks.first)
        let (size, rate, descriptions) = try MediaBlocking.await {
            try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        }
        XCTAssertEqual(Probe.fourCC(CMFormatDescriptionGetMediaSubType(descriptions[0])), "avc1")
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(Double(rate), 25, accuracy: 0.1)
        XCTAssertEqual(duration.seconds, 8, accuracy: 0.001)
        let frames = try SegmentTestSupport.readBack(out)
        XCTAssertEqual(Double(frames.count), duration.seconds * 25, accuracy: 1)
        XCTAssertEqual(frames.map { $0.index }, (0..<200).map { Optional($0) })

        // Peak disk: the segments are deleted as they are appended (output + about one segment),
        // but shouldOptimizeForNetworkUse rewrites the finished file once to move moov to the front,
        // so a second copy of the output exists briefly (measured on the simulator: 2.0× output).
        XCTAssertGreaterThan(result.peakDiskBytes, 0)
        XCTAssertLessThanOrEqual(result.peakDiskBytes, 2 * result.bytes + segmentBytes + 64 * 1024)
        print("IOS-17 concat: output \(result.bytes) B, largest segment \(segmentBytes) B, peak disk \(result.peakDiskBytes) B")
    }

    func testRandomInterruptionsResumeToTheSameFile() throws {
        let reference = try referenceFrames()
        XCTAssertEqual(reference.count, SegmentTestSupport.frameCount)
        var rng = SeededRandom(seed: 17)
        for round in 0..<2 {
            let dir = directory("interrupted-\(round)")
            let writer = try SegmentTestSupport.writer(dir)
            // Three random failures (segment, frame), each firing once.
            var faults: Set<String> = []
            while faults.count < 3 {
                faults.insert("\(rng.next(below: 4))-\(rng.next(below: 50))")
            }
            var fired: Set<String> = []
            writer.faultInjector = { segment, frame in
                let key = "\(segment)-\(frame)"
                guard faults.contains(key), !fired.contains(key) else { return nil }
                fired.insert(key)
                return SegmentTestSupport.interruptionError()
            }
            let interruptions = try SegmentTestSupport.runToCompletion(writer, source: try fixtureSource())
            XCTAssertEqual(interruptions, 3)
            let out = dir.appendingPathComponent("out.mp4")
            let result = try writer.concat(to: out)
            let frames = try SegmentTestSupport.readBack(out)
            XCTAssertEqual(result.frames, reference.count)
            XCTAssertEqual(frames.count, reference.count)
            XCTAssertEqual(frames.map { $0.ptsUs }, reference.map { $0.ptsUs }, "PTS equal the uninterrupted export")
            XCTAssertEqual(frames.map { $0.index }, reference.map { $0.index }, "barcodes equal the uninterrupted export")
        }
    }

    func testCheckpointSurvivesProcessKill() throws {
        let dir = directory("kill")
        do {
            let writer = try SegmentTestSupport.writer(dir)
            writer.faultInjector = { segment, frame in
                segment == 2 && frame == 10 ? SegmentTestSupport.interruptionError() : nil
            }
            XCTAssertEqual(try writer.writeVideo(source: try fixtureSource()), .interrupted)
            XCTAssertEqual(writer.checkpoint.completed.map { $0.index }, [0, 1])
        }
        // The "killed" process left a partial segment behind.
        let stray = dir.appendingPathComponent("v-2.partial.mp4")
        try Data(repeating: 7, count: 4096).write(to: stray)
        let onDisk = try XCTUnwrap(SegmentCheckpoint.load(from: dir))
        XCTAssertEqual(onDisk.completed.count, 2)
        XCTAssertEqual(onDisk.resumeTimeUs, 4_000_000)
        XCTAssertEqual(onDisk.doneFraction, 0.5, accuracy: 1e-9)

        // A new process: same job -> resumes after segment 1.
        let resumed = try SegmentTestSupport.writer(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "partial segment removed on resume")
        XCTAssertEqual(resumed.checkpoint.nextSegment, 2)
        let found = JobInterruption.resumableJobs(under: dir.deletingLastPathComponent())
        XCTAssertTrue(found.contains { $0.directory.standardizedFileURL == dir.standardizedFileURL && $0.jobKind == "export" })
        XCTAssertEqual(try resumed.writeVideo(source: try fixtureSource()), .completed)
        let out = dir.appendingPathComponent("out.mp4")
        _ = try resumed.concat(to: out)
        let frames = try SegmentTestSupport.readBack(out)
        XCTAssertEqual(frames.map { $0.index }, (0..<200).map { Optional($0) })

        // A different input invalidates a checkpoint.
        let other = directory("other")
        do {
            let writer = try SegmentTestSupport.writer(other)
            writer.faultInjector = { segment, _ in segment == 1 ? SegmentTestSupport.interruptionError() : nil }
            XCTAssertEqual(try writer.writeVideo(source: try fixtureSource()), .interrupted)
        }
        let fresh = try SegmentTestSupport.writer(other, inputHash: "changed-plan")
        XCTAssertEqual(fresh.checkpoint.completed.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.segmentURL(0).path))
    }

    func testParameterSetMismatchIsReencoded() throws {
        let dir = directory("sps")
        let writer = try SegmentTestSupport.writer(dir)
        writer.settingsOverride = { segment in
            guard segment == 1 else { return nil }
            var odd = SegmentTestSupport.settings()
            odd.profileLevel = AVVideoProfileLevelH264BaselineAutoLevel
            return odd
        }
        XCTAssertEqual(try writer.writeVideo(source: try fixtureSource()), .completed)
        let first = try SegmentConcat.formatDescription(of: writer.segmentURL(0), mediaType: .video)
        let second = try SegmentConcat.formatDescription(of: writer.segmentURL(1), mediaType: .video)
        XCTAssertNotEqual(SegmentConcat.parameterSets(first), SegmentConcat.parameterSets(second))
        XCTAssertFalse(SegmentConcat.parameterSets(first).isEmpty)
        let out = dir.appendingPathComponent("out.mp4")
        let result = try writer.concat(to: out)
        XCTAssertEqual(result.reencodedSegments, [1])
        let frames = try SegmentTestSupport.readBack(out)
        XCTAssertEqual(frames.count, 200)
        XCTAssertEqual(frames.map { $0.index }, (0..<200).map { Optional($0) })
    }

    func testAudioIsMuxedPassthrough() throws {
        let dir = directory("audio")
        let writer = try SegmentTestSupport.writer(dir, audio: true)
        XCTAssertEqual(try writer.writeAudio(source: SineAudioSource()), .completed)
        XCTAssertTrue(writer.checkpoint.audioComplete)
        XCTAssertEqual(try writer.writeVideo(source: try fixtureSource()), .completed)
        let out = dir.appendingPathComponent("out.mp4")
        _ = try writer.concat(to: out)
        let asset = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .audio).first })
        let (range, descriptions) = try MediaBlocking.await { try await audio.load(.timeRange, .formatDescriptions) }
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(range.duration.seconds, 8, accuracy: 0.05)
        XCTAssertEqual(try SegmentTestSupport.readBack(out).count, 200)
    }

    func testCancelDeletesTheJobDirectory() throws {
        let dir = directory("cancel")
        let writer = try SegmentTestSupport.writer(dir)
        writer.faultInjector = { [weak writer] segment, frame in
            if segment == 1 && frame == 5 { writer?.cancel() }
            return nil
        }
        XCTAssertThrowsError(try writer.writeVideo(source: try fixtureSource())) { error in
            XCTAssertEqual(EngineError.from(error).code, .cancelled)
        }
        let gone = expectation(description: "directory removed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}

final class JobInterruptionTests: XCTestCase {
    final class FakeJob: InterruptibleJob {
        let interruptionJobId: String
        var interrupts = 0

        init(_ id: String) {
            interruptionJobId = id
        }

        func interruptForBackground() {
            interrupts += 1
        }
    }

    func testBackgroundInterruptsAndForegroundRequeues() {
        let center = NotificationCenter()
        let interruption = JobInterruption(center: center)
        interruption.start()
        var reported: [String] = []
        var requeued: [String] = []
        interruption.onInterrupted = { reported += $0 }
        interruption.requeue = { requeued.append($0) }
        let a = FakeJob("a"), b = FakeJob("b")
        XCTAssertTrue(interruption.register(a))
        XCTAssertTrue(interruption.register(b))
        interruption.unregister(jobId: "b")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(a.interrupts, 1)
        XCTAssertEqual(b.interrupts, 0)
        XCTAssertEqual(reported, ["a"])
        XCTAssertTrue(interruption.isBackgrounded)

        // A job started in the background is interrupted at once and waits for the foreground.
        let c = FakeJob("c")
        XCTAssertFalse(interruption.register(c))
        let drained = expectation(description: "main")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(c.interrupts, 1)
        XCTAssertEqual(Set(interruption.interruptedJobIds), ["a", "c"])

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(requeued, ["a", "c"])
        XCTAssertFalse(interruption.isBackgrounded)
        XCTAssertTrue(interruption.interruptedJobIds.isEmpty)
        interruption.stop()
    }

    func testBackgroundingStopsASegmentedJobWhichResumesOnForeground() throws {
        let dir = SegmentTestSupport.tempDirectory("lifecycle").appendingPathComponent("export-job42")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let writer = try SegmentTestSupport.writer(dir)
        let center = NotificationCenter()
        let interruption = JobInterruption(center: center)
        interruption.start()
        interruption.register(SegmentedJobHandle(jobId: "job42", writer: writer))
        let source = AssetTrackFrameSource(url: try ProbeFixtures.url(SegmentTestSupport.fixture))
        writer.faultInjector = { segment, frame in
            if segment == 1 && frame == 20 {
                DispatchQueue.main.sync { center.post(name: UIApplication.didEnterBackgroundNotification, object: nil) }
            }
            return nil
        }
        let queue = DispatchQueue(label: "test.segments")
        var first: SegmentedWriter.Outcome?
        let stopped = expectation(description: "interrupted")
        queue.async {
            first = try? writer.writeVideo(source: source)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 60)
        XCTAssertEqual(first, .interrupted)
        XCTAssertEqual(writer.checkpoint.completed.map { $0.index }, [0])
        let resumable = JobInterruption.resumableJobs(under: dir.deletingLastPathComponent())
        XCTAssertEqual(resumable.first?.jobId, "job42")

        writer.faultInjector = nil
        let finished = expectation(description: "resumed")
        var second: SegmentedWriter.Outcome?
        interruption.requeue = { id in
            XCTAssertEqual(id, "job42")
            interruption.register(SegmentedJobHandle(jobId: id, writer: writer))
            queue.async {
                second = try? writer.writeVideo(source: source)
                finished.fulfill()
            }
        }
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        wait(for: [finished], timeout: 120)
        XCTAssertEqual(second, .completed)
        let out = dir.appendingPathComponent("out.mp4")
        _ = try writer.concat(to: out)
        XCTAssertEqual(try SegmentTestSupport.readBack(out).map { $0.index }, (0..<200).map { Optional($0) })
    }
}

/// Deterministic xorshift for reproducible "random" interruption points.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next(below bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
