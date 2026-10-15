// OWNER: FIX-48FPS-TIMESCALE
//
// 48 fps media at an exact timescale (QA-03 finding 4). AVAssetWriter's default video timescale is
// 600, which cannot hold 48 fps (frame k at round(12.5·k) ticks, up to 833 µs off k/48). The
// segmented export writer (IOS-17, used by IOS-12) and the ENG-05 fixture tool now write a
// timescale that is a multiple of every project rate:
// - `SegmentEncodeSettings.videoTimescale` divides by 24/25/30/48/50/60 (and by 600);
// - the regenerated frame_counter_720p48.mp4 stores frame k exactly at k/48 s;
// - a segmented 48 fps export plus passthrough concat (and the segment files) stores every frame
//   exactly at CMTime(k, 48), with barcodes 0..383 in order.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class VideoTimescaleTests: XCTestCase {
    private static let fixture = "frame_counter_720p48.mp4"
    private static let fps = 48
    private static let frameCount = 384

    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        super.tearDown()
    }

    /// Track timescale and sample PTS of the video track of [url] (no decode).
    private func trackTiming(_ url: URL) throws -> (timescale: CMTimeScale, pts: [CMTime]) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let timescale = try MediaBlocking.await { try await track.load(.naturalTimeScale) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var pts: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        return (timescale, pts.sorted { CMTimeCompare($0, $1) < 0 })
    }

    private func assertExactGrid(_ pts: [CMTime], fps: Int, count: Int, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pts.count, count, "\(what): frame count", file: file, line: line)
        // Passthrough sample times are media times: a B-frame track (the fixture) starts after a
        // composition offset that its edit list removes, so compare relative to the first frame.
        let first = pts.first ?? .zero
        XCTAssertEqual(Int64(first.value) * Int64(fps) % Int64(first.timescale), 0,
                       "\(what): first frame \(first.value)/\(first.timescale) on the grid", file: file, line: line)
        var off: [String] = []
        for (k, t) in pts.enumerated()
        where CMTimeCompare(CMTimeSubtract(t, first), CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))) != 0 {
            if off.count < 5 { off.append("k=\(k) at \(t.value)/\(t.timescale)") }
        }
        XCTAssertTrue(off.isEmpty, "\(what): frames off k/\(fps): \(off)", file: file, line: line)
    }

    func testVideoTimescaleHoldsEveryProjectRate() {
        for fps in [24, 25, 30, 48, 50, 60] {
            let settings = SegmentEncodeSettings(
                codec: .h264, width: 1280, height: 720, fps: fps, averageBitRate: 4_000_000,
                maxKeyFrameIntervalFrames: nil, maxKeyFrameIntervalSeconds: 1, allowFrameReordering: false,
                container: .mp4, audio: nil)
            let ts = Int(settings.videoTimescale)
            XCTAssertEqual(ts % fps, 0, "timescale \(ts) holds \(fps) fps")
            XCTAssertEqual(ts % 600, 0, "timescale \(ts) holds 600-tick source PTS")
        }
        XCTAssertEqual(SegmentEncodeSettings.videoTimescale(fps: 48), 48_000)
        // A rate that does not divide the base gets the LCM (never a v1 project rate, D-03).
        XCTAssertEqual(Int(SegmentEncodeSettings.videoTimescale(fps: 7)) % 7, 0)
        XCTAssertEqual(Int(SegmentEncodeSettings.videoTimescale(fps: 7)) % 48_000, 0)
        // The timescale is derived, not persisted: checkpoint JSON is unchanged.
        let json = String(data: try! JSONEncoder().encode(SegmentTestSupport.settings()), encoding: .utf8)!
        XCTAssertFalse(json.contains("imescale"), json)
    }

    func testFixtureStoresEveryFrameAtKOver48() throws {
        let (timescale, pts) = try trackTiming(try ProbeFixtures.url(VideoTimescaleTests.fixture))
        XCTAssertEqual(Int(timescale) % 48, 0, "fixture track timescale \(timescale)")
        assertExactGrid(pts, fps: 48, count: VideoTimescaleTests.frameCount, "fixture")
    }

    func testSegmented48FpsExportIsOnTheExactGrid() throws {
        let dir = SegmentTestSupport.tempDirectory("ts48")
        directories.append(dir)
        let settings = SegmentEncodeSettings(
            codec: .h264, width: 1280, height: 720, fps: VideoTimescaleTests.fps, averageBitRate: 4_000_000,
            maxKeyFrameIntervalFrames: nil, maxKeyFrameIntervalSeconds: 1, allowFrameReordering: false,
            container: .mp4, audio: nil)
        let writer = try SegmentedWriter(
            directory: dir, jobKind: "export", inputHash: "frame_counter_720p48", settings: settings,
            startUs: 0, endUs: 8_000_000, segmentDurationUs: 3_000_000)
        let source = AssetTrackFrameSource(url: try ProbeFixtures.url(VideoTimescaleTests.fixture))
        XCTAssertEqual(try SegmentTestSupport.runToCompletion(writer, source: source), 0)

        // Each segment file (before concat deletes it).
        var segmentFrames = 0
        for index in 0..<writer.segmentCount {
            let (timescale, pts) = try trackTiming(writer.segmentURL(index))
            XCTAssertEqual(timescale, settings.videoTimescale, "segment \(index) timescale")
            for t in pts {
                XCTAssertEqual(Int64(t.value) * 48 % Int64(t.timescale), 0, "segment \(index): \(t.value)/\(t.timescale) on the 48 fps grid")
            }
            segmentFrames += pts.count
        }
        XCTAssertEqual(segmentFrames, VideoTimescaleTests.frameCount)

        let out = dir.appendingPathComponent("out.mp4")
        let result = try writer.concat(to: out)
        XCTAssertEqual(result.frames, VideoTimescaleTests.frameCount)
        let (timescale, pts) = try trackTiming(out)
        XCTAssertEqual(timescale, settings.videoTimescale, "concat output timescale")
        assertExactGrid(pts, fps: 48, count: VideoTimescaleTests.frameCount, "concat output")

        let asset = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try MediaBlocking.await { try await asset.load(.duration) }
        XCTAssertEqual(CMTimeCompare(duration, CMTime(value: 8, timescale: 1)), 0, "duration \(duration.value)/\(duration.timescale)")
        XCTAssertEqual(try SegmentTestSupport.readBack(out).map { $0.index },
                       (0..<VideoTimescaleTests.frameCount).map { Optional($0) })
    }
}
