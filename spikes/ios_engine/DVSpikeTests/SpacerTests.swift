import AVFoundation
import XCTest

@testable import DVSpikeHost

/// ARCH §13.2 runtime spacer: which codecs can write (and AVFoundation can read back) a 16×16
/// one-frame video on this OS, so IOS-08 picks one that works everywhere.
final class SpacerTests: XCTestCase {
  func testSpacerCodecs() async throws {
    var results: [String: String] = [:]
    for (name, codec, type) in [
      ("h264.mp4", AVVideoCodecType.h264, AVFileType.mp4), ("h264.mov", .h264, .mov),
      ("hevc.mov", .hevc, .mov), ("jpeg.mov", .jpeg, .mov),
    ] {
      // Default encoder settings only (no compression properties): see MediaFactory.spacer.
      let url = MediaFactory.url("spacer_probe_\(name)")
      do {
        try await MediaFactory.writeSolid(to: url, codec: codec, fileType: type, size: 16)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let range = try await track?.load(.timeRange)
        results[name] = "ok duration=\(range.map { "\($0.duration.value)/\($0.duration.timescale)" } ?? "?")"
      } catch {
        results[name] = "failed: \(error)"
      }
    }
    Metrics.record("spacer.codecs16x16", results)
    XCTAssertTrue(results["h264.mov"]?.hasPrefix("ok") ?? false, "\(results)")
    // The spacer the builder uses decodes into the composition.
    let spacer = try await MediaFactory.spacer()
    XCTAssertEqual(spacer.pathExtension, "mov")
  }
}
