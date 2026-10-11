// OWNER: IOS-07
//
// Reverse rendition job (BUILD_PLAN IOS-07):
// - barcodes strictly decreasing over the whole output; duration = range ± 1 frame;
// - clicks of clap_flash_av mirrored within ±20 ms;
// - peak work-dir size <= one chunk intermediate + output;
// - peak memory delta <= 40 MB at 1080p and <= 90 MB at 4K (simulator measurement of the
//   process footprint; device numbers are recorded by QA-04);
// - preflight refusals (range > 10 min, free space) tested;
// - cancel removes the work files; a background interruption resumes from the last complete chunk
//   and keeps the barcode sequence continuous;
// - VFR sources keep every frame's duration mirrored.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class ReverseJobTests: XCTestCase {
    private var roots: TempRoots!
    private var paths: Paths!

    override func setUpWithError() throws {
        roots = try TempRoots()
        paths = try MediaJobTestSupport.paths(roots)
    }

    override func tearDown() {
        roots?.remove()
        super.tearDown()
    }

    private func output(_ name: String) -> URL {
        paths.derived.appendingPathComponent("\(name).mp4")
    }

    private func job(_ fixture: String, startUs: Int64, endUs: Int64, name: String, chunkUs: Int64 = ReverseJob.defaultChunkUs) throws -> ReverseJob {
        ReverseJob(mediaURL: try ProbeFixtures.url(fixture), fingerprint: "fp-\(fixture)", startUs: startUs, endUs: endUs,
                   audioStream: nil, output: output(name), paths: paths, chunkDurationUs: chunkUs)
    }

    // MARK: Timeline

    func testTimelineMirrorsFrameEnds() {
        // 4 frames of 0.25 s, range [0.1 s, 0.9 s).
        let pts = [0, 250_000, 500_000, 750_000].map { CMTime(value: $0, timescale: 1_000_000) }
        let timeline = ReverseTimeline(pts: pts, trackEnd: CMTime(value: 1_000_000, timescale: 1_000_000),
                                       startUs: 100_000, endUs: 900_000)
        XCTAssertEqual(timeline.frames.count, 4)
        let outputs = timeline.frames.map { Int64(($0.outputPts.seconds * 1_000_000).rounded()) }
        // Frame 3 [0.75, 0.9) -> 0; frame 2 ends at 0.75 -> 0.15; frame 1 -> 0.4; frame 0 -> 0.65.
        XCTAssertEqual(outputs, [650_000, 400_000, 150_000, 0])
        XCTAssertEqual(timeline.frames(outputStartUs: 0, outputEndUs: 400_000).map { Int64($0.pts.seconds * 1_000_000) },
                       [500_000, 750_000])
        XCTAssertEqual(timeline.frames(outputStartUs: 400_000, outputEndUs: 800_000).count, 2)
    }

    func testAudioBlockReversal() {
        var samples: [Float] = [1, -1, 2, -2, 3, -3]
        ReverseAudioSource.reverseFrames(&samples, channels: 2)
        XCTAssertEqual(samples, [3, -3, 2, -2, 1, -1])
    }

    // MARK: Preflight

    func testPreflightRefusesLongRangesAndLowDisk() {
        XCTAssertThrowsError(try ReverseJob.preflight(
            rangeUs: ReverseJob.maxRangeUs + 1, estimatedOutputBytes: 1, chunkBytes: 1, freeBytes: .max)) { error in
            XCTAssertTrue(ReverseJob.isRangeLimit(error))
        }
        XCTAssertNoThrow(try ReverseJob.preflight(
            rangeUs: ReverseJob.maxRangeUs, estimatedOutputBytes: 100, chunkBytes: 10, freeBytes: 210 + ReverseJob.slackBytes))
        XCTAssertThrowsError(try ReverseJob.preflight(
            rangeUs: 1_000_000, estimatedOutputBytes: 100, chunkBytes: 10, freeBytes: 209 + ReverseJob.slackBytes)) { error in
            XCTAssertEqual(EngineError.from(error).code, .diskFull)
        }
    }

    func testRunRefusesBeforeTouchingDisk() throws {
        let tooLong = try job("frame_counter_720p25.mp4", startUs: 0, endUs: ReverseJob.maxRangeUs + 1_000_000, name: "long")
        XCTAssertThrowsError(try tooLong.run(JobControl(jobId: "l"))) { XCTAssertTrue(ReverseJob.isRangeLimit($0)) }
        let full = try job("frame_counter_720p25.mp4", startUs: 0, endUs: 8_000_000, name: "full")
        full.freeBytesOverride = { 10_000_000 }
        XCTAssertThrowsError(try full.run(JobControl(jobId: "d"))) { XCTAssertEqual(EngineError.from($0).code, .diskFull) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.workDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.output.path))
    }

    // MARK: Output

    func testBarcodesStrictlyDecreasingAndDurationWithinOneFrame() throws {
        // 1.3 s .. 6.7 s of the 25 fps counter: frames 32...167 (frame 32 starts at 1.28 s).
        let reverse = try job("frame_counter_720p25.mp4", startUs: 1_300_000, endUs: 6_700_000, name: "r25")
        var peakWork: Int64 = 0
        var peakIntermediate: Int64 = 0
        reverse.onIntermediateWritten = { url, bytes in
            peakIntermediate = max(peakIntermediate, bytes)
            peakWork = max(peakWork, SegmentedWriter.directorySize(url.deletingLastPathComponent()))
        }
        let result = try reverse.run(JobControl(jobId: "r"))
        let asset = try XCTUnwrap(result.asset)
        XCTAssertEqual(asset.path, reverse.output.path)
        XCTAssertEqual(asset.durationUs, 5_400_000)
        let frames = try SegmentTestSupport.readBack(reverse.output)
        let indices = frames.compactMap(\.index)
        XCTAssertEqual(indices.count, frames.count, "every frame readable")
        XCTAssertEqual(indices.first, 167)
        XCTAssertEqual(indices.last, 32)
        XCTAssertEqual(indices, Array((32...167).reversed()), "strictly decreasing, no frame lost")
        let facts = try MediaJobTestSupport.videoFacts(reverse.output)
        XCTAssertEqual(Double(facts.durationUs), 5_400_000, accuracy: 40_000)
        XCTAssertEqual(facts.ptsUs.first, 0)
        XCTAssertEqual(facts.codec, kCMVideoCodecType_H264)
        // Work disk: finished segments (part of the output) + one intermediate.
        let outputBytes = SegmentedWriter.fileSize(reverse.output)
        XCTAssertGreaterThan(peakIntermediate, 0)
        XCTAssertLessThanOrEqual(peakWork, peakIntermediate + outputBytes + 64 * 1024,
                                 "peak work \(peakWork) intermediate \(peakIntermediate) output \(outputBytes)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.workDirectory.path), "work removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.partialURL.path))
    }

    func testVfrFramesKeepTheirMirroredDurations() throws {
        let reverse = try job("vfr_720p.mp4", startUs: 0, endUs: 6_000_000, name: "vfr")
        _ = try reverse.run(JobControl(jobId: "v"))
        let source = try MediaJobTestSupport.videoFacts(try ProbeFixtures.url("vfr_720p.mp4"))
        let output = try MediaJobTestSupport.videoFacts(reverse.output)
        XCTAssertEqual(output.ptsUs.count, source.ptsUs.count)
        // Source frame i [p_i, p_{i+1}) -> output starts at 6 s − p_{i+1}.
        let ends = Array(source.ptsUs.dropFirst()) + [6_000_000]
        let expected = ends.map { 6_000_000 - $0 }.reversed()
        for (a, b) in zip(output.ptsUs, expected) { XCTAssertLessThanOrEqual(abs(a - b), 2_000, "\(a) vs \(b)") }
        let indices = try SegmentTestSupport.readBack(reverse.output).compactMap(\.index)
        XCTAssertEqual(indices, indices.sorted(by: >))
    }

    func testClicksAreMirrored() throws {
        let reverse = try job("clap_flash_av.mp4", startUs: 0, endUs: 6_000_000, name: "clap")
        _ = try reverse.run(JobControl(jobId: "c"))
        let reader = try PcmReader(url: reverse.output)
        var mono: [Float] = []
        let channels = reader.format.channels
        while let chunk = try reader.read() {
            for f in 0..<(chunk.count / channels) { mono.append(chunk[f * channels]) }
        }
        let rate = reader.format.sampleRate
        XCTAssertEqual(Double(mono.count) / rate, 6, accuracy: 0.05)
        // Onsets: first sample above -30 dBFS after 50 ms of quiet.
        var onsets: [Double] = []
        var quiet = 0
        for (i, value) in mono.enumerated() {
            if abs(value) > 0.03 {
                if quiet > Int(0.05 * rate) { onsets.append(Double(i) / rate) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        // A click [t, t + 20 ms] lands at [6 − t − 20 ms, 6 − t]; its onset is 6 − t − 0.02.
        let expected = [1.0, 2.5, 4.0].map { 6 - $0 - 0.02 }.sorted()
        XCTAssertEqual(onsets.count, 3, "onsets \(onsets)")
        for (a, b) in zip(onsets, expected) { XCTAssertEqual(a, b, accuracy: 0.02) }
        // Flash frames mirrored too: frames 120, 75, 30 at 6 − (k + 1)/30.
        let frames = try SegmentTestSupport.readBack(reverse.output)
        for flash in [30, 75, 120] {
            let pts = try XCTUnwrap(frames.first { $0.index == flash }?.ptsUs)
            XCTAssertEqual(Double(pts) / 1_000_000, 6 - Double(flash + 1) / 30, accuracy: 0.002)
        }
    }

    func testCancelRemovesWorkFiles() throws {
        let reverse = try job("frame_counter_720p25.mp4", startUs: 0, endUs: 8_000_000, name: "cancel")
        let control = JobControl(jobId: "x")
        reverse.configureWriter = { writer in
            writer.faultInjector = { segment, frame in
                if segment == 2 && frame == 4 { control.stop(.cancel) }
                return nil
            }
        }
        XCTAssertThrowsError(try reverse.run(control)) { XCTAssertEqual(EngineError.from($0).code, .cancelled) }
        reverse.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.workDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.partialURL.path))
    }

    func testBackgroundInterruptionResumesFromTheLastChunk() throws {
        let recorder = JobEventRecorder()
        let context = try MediaJobTestSupport.context(roots, events: recorder.hub)
        let interruption = JobInterruption(center: NotificationCenter())
        let registry = JobRegistry(context: context, concurrency: 1, interruption: interruption, startInterruption: false)
        interruption.start()
        let reverse = try job("frame_counter_720p25.mp4", startUs: 0, endUs: 8_000_000, name: "bg")
        let lock = NSLock()
        var fired = false
        var runs: [[Int]] = []
        reverse.configureWriter = { writer in
            lock.lock()
            runs.append([])
            lock.unlock()
            writer.faultInjector = { segment, frame in
                lock.lock()
                if !runs[runs.count - 1].contains(segment) { runs[runs.count - 1].append(segment) }
                let fire = !fired && segment == 2 && frame == 7
                if fire { fired = true }
                lock.unlock()
                if fire { interruption.didEnterBackground() }
                return nil
            }
        }
        let id = registry.enqueue(reverse, priority: .interactive)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { registry.state(of: id) == .waitingForForeground })
        let checkpoint = try XCTUnwrap(SegmentCheckpoint.load(from: reverse.workDirectory))
        XCTAssertEqual(checkpoint.completed.map(\.index), [0, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reverse.workDirectory.appendingPathComponent("chunk.mov").path),
                       "no intermediate left while paused")
        interruption.willEnterForeground()
        recorder.waitForEnd(id, test: self)
        XCTAssertNotNil(recorder.done(id), "\(String(describing: recorder.failure(id)))")
        lock.lock()
        let seen = runs
        lock.unlock()
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.last?.first, 2, "resumed at the interrupted chunk")
        let indices = try SegmentTestSupport.readBack(reverse.output).compactMap(\.index)
        XCTAssertEqual(indices, Array((0..<200).reversed()), "continuous across the resume")
    }

    // MARK: Memory

    func testPeakMemoryAt1080p() throws {
        let reverse = try job("frame_counter_1080p30.mp4", startUs: 0, endUs: 8_000_000, name: "mem1080")
        // Warm the codecs and caches once so the measurement sees the steady state.
        _ = try self.job("frame_counter_1080p30.mp4", startUs: 0, endUs: 500_000, name: "warm1080").run(JobControl(jobId: "w"))
        let delta = try MediaJobTestSupport.peakFootprintDelta { _ = try reverse.run(JobControl(jobId: "m")) }
        print("reverse 1080p peak footprint delta: \(delta / 1_048_576) MB")
        XCTAssertLessThanOrEqual(delta, 40 * 1_048_576)
        let indices = try SegmentTestSupport.readBack(reverse.output).compactMap(\.index)
        XCTAssertEqual(indices, Array((0..<240).reversed()))
    }

    func testPeakMemoryAt4K() throws {
        let source = roots.base.appendingPathComponent("uhd.mp4")
        try MediaJobTestSupport.makeBarcodeClip(source, width: 3840, height: 2160, fps: 30, frames: 90)
        let warm = ReverseJob(mediaURL: source, fingerprint: "uhd", startUs: 0, endUs: 300_000, audioStream: nil,
                              output: output("warm4k"), paths: paths)
        _ = try warm.run(JobControl(jobId: "w"))
        let reverse = ReverseJob(mediaURL: source, fingerprint: "uhd", startUs: 0, endUs: 3_000_000, audioStream: nil,
                                 output: output("mem4k"), paths: paths)
        let delta = try MediaJobTestSupport.peakFootprintDelta { _ = try reverse.run(JobControl(jobId: "m")) }
        print("reverse 4K peak footprint delta: \(delta / 1_048_576) MB")
        XCTAssertLessThanOrEqual(delta, 90 * 1_048_576)
        let indices = try SegmentTestSupport.readBack(reverse.output).compactMap(\.index)
        XCTAssertEqual(indices, Array((0..<90).reversed()))
    }
}
