import AVFoundation
import XCTest

@testable import DVSpikeHost

/// ARCH §14.2: AVAssetReader(composition) → AVAssetWriter with the preview compositor, and the
/// IOS-17 segmented writer: interrupted mid-segment (the simulated background encoder loss), it
/// resumes from the checkpoint and the passthrough concat is frame-exact.
final class ExportTests: XCTestCase {
  func testSegmentedExportResumesAfterInterruption() async throws {
    let g = try await GridCase.load()
    let built = try await g.build(renderScale: 0.5)
    let dir = MediaFactory.directory.appendingPathComponent("segments-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let seg = SegmentedExporter(built: built, directory: dir, segmentFrames: 30)
    XCTAssertEqual(seg.segmentCount, 3)

    // Attempt 1: interrupted 10 frames into segment 1.
    let first = try await seg.run(interrupt: { s, n in s == 1 && n >= 10 })
    XCTAssertFalse(first)
    XCTAssertEqual(seg.loadCheckpoint().completed, [0])
    XCTAssertFalse(FileManager.default.fileExists(atPath: seg.segmentURL(1).path), "partial segment kept")

    // Attempt 2 (after "return to foreground"): resumes at segment 1.
    built.state.log.reset()
    let second = try await seg.run()
    XCTAssertTrue(second)
    XCTAssertEqual(seg.loadCheckpoint().completed, [0, 1, 2])
    let rendered = Set(built.state.log.all.map(\.k))
    XCTAssertFalse(rendered.contains(5), "segment 0 was re-rendered")
    XCTAssertTrue(rendered.isSuperset(of: Set(30..<90)))

    // Each segment starts with a sync sample (closed GOP).
    for i in 0..<seg.segmentCount {
      let asset = AVURLAsset(url: seg.segmentURL(i))
      let track = try await asset.loadTracks(withMediaType: .video).first!
      let reader = try AVAssetReader(asset: asset)
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(out)
      reader.startReading()
      let s = try XCTUnwrap(out.copyNextSampleBuffer())
      let attachments = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
      let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
      XCTAssertFalse(notSync, "segment \(i) does not start with a sync sample")
    }

    let out = MediaFactory.url("segmented_concat.mp4")
    let n = try await seg.concat(to: out)
    XCTAssertEqual(n, 90)
    XCTAssertFalse(seg.log.contains { $0.contains("differs") }, "segments do not share SPS/PPS: \(seg.log)")

    // Every frame of the concatenated file is on the grid and shows the expected content.
    let asset = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let reader = try AVAssetReader(asset: asset)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var ks: [Int64] = []
    var bad: [String] = []
    while let s = output.copyNextSampleBuffer() {
      guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
      let k = Grid.frameIndexNearest(CMSampleBufferGetPresentationTimeStamp(s), fps: 30)
      ks.append(k)
      bad += g.check(pb, k: k)
    }
    XCTAssertEqual(ks, Array(0..<90))
    XCTAssertEqual(bad, [])
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 3, accuracy: 0.001)
    Metrics.record(
      "export.segmentedResume",
      ["segments": seg.segmentCount, "concatFrames": n, "contentErrors": bad.count, "log": seg.log])
  }
}
