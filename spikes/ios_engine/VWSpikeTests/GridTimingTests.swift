import AVFoundation
import XCTest

@testable import VWSpikeHost

/// D-35 grid timing on iOS: edits at `CMTime(k, 30)`, cuts at k ≡ 1 and 2 (mod 3), compositor
/// `k = round(compositionTime × fps)` evaluated at `timeOfFrame(k)`. Every output frame must carry
/// the expected barcode(s) in export, exact seek and playback.
final class GridTimingTests: XCTestCase {
  func testGridTimesAreExactRationals() async throws {
    let g = try await GridCase.load()
    let built = try await g.build()
    // Cut frames of the fixture: 31, 61 (≡ 1 mod 3) and 32, 62 (≡ 2 mod 3).
    let cuts = Set(g.plan.layers.flatMap { [$0.t0, $0.t1] }.map { Grid.frameIndexOf($0, fps: 30) })
    XCTAssertTrue(cuts.isSuperset(of: [31, 32, 61, 62]), "\(cuts.sorted())")
    var boundaries: [Int64] = []
    for case let ins as SpikeInstruction in built.videoComposition.instructions {
      XCTAssertEqual(ins.timeRange.start.timescale, 30)
      XCTAssertEqual(ins.timeRange.duration.timescale, 30)
      boundaries.append(ins.timeRange.start.value)
    }
    XCTAssertEqual(boundaries, [0, 31, 32, 61, 62])
    for track in built.composition.tracks(withMediaType: .video) {
      for seg in track.segments where !seg.isEmpty {
        // Composition-side (target) ranges are on the 1/30 grid.
        let target = seg.timeMapping.target
        let k = Grid.frameIndexNearest(target.start, fps: 30)
        XCTAssertEqual(
          CMTimeCompare(target.start, Grid.cm(frame: k, fps: 30)), 0,
          "target start \(target.start) not on the grid")
      }
    }
    let valid = built.videoComposition.isValid(
      for: built.composition, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
      validationDelegate: nil)
    XCTAssertTrue(valid)
    Metrics.record(
      "D-35.instructions",
      ["boundaries": boundaries, "buildMs": Stats.round2(built.buildMs), "valid": valid])
  }

  /// AVAssetReader(composition) + AVAssetWriter with the same compositor: every one of the 90
  /// frames is stamped k = 0…89 in order, the compositor's active set matches CORE-29's
  /// expected-active table and the composited and encoded frames show the expected barcodes.
  func testGridCutsExportBarcode100Percent() async throws {
    let g = try await GridCase.load()
    let built = try await g.build()
    var composited: [(Int64, [String])] = []
    let out = MediaFactory.url("grid_export.mp4")
    let result = try await ExportPipeline.export(built: built, to: out) { pb, _ in
      let k = SpikeCompositor.frameStamp(pb) ?? -1
      composited.append((k, g.check(pb, k: k)))
    }
    XCTAssertEqual(result.stamps.compactMap { $0 }, Array(0..<90))

    // Activity per frame vs the expected-active table.
    var activityMismatches: [String] = []
    for r in built.state.log.all {
      if let want = g.expectedActive(r.k), Set(want) != Set(r.active) {
        activityMismatches.append("k=\(r.k) want \(want) got \(r.active)")
      }
      if !r.missing.isEmpty { activityMismatches.append("k=\(r.k) missing source \(r.missing)") }
    }
    XCTAssertEqual(activityMismatches, [])

    let compositedBad = composited.filter { !$0.1.isEmpty }
    XCTAssertEqual(compositedBad.flatMap(\.1), [])

    // Read the encoded file back and check every frame again (PTS → k with frameIndexNearest).
    let back = try ExportPipeline.readBack(out)
    var encodedBad: [String] = []
    let asset = AVURLAsset(url: out)
    let reader = try AVAssetReader(asset: asset)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var ks: [Int64] = []
    var encodedBadFrames = Set<Int64>()
    while let s = output.copyNextSampleBuffer() {
      guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
      let k = Grid.frameIndexNearest(CMSampleBufferGetPresentationTimeStamp(s), fps: 30)
      ks.append(k)
      let problems = g.check(pb, k: k)
      if !problems.isEmpty { encodedBadFrames.insert(k) }
      encodedBad += problems
    }
    XCTAssertEqual(ks, Array(0..<90))
    XCTAssertEqual(encodedBad, [])
    Metrics.record(
      "D-35.gridCuts.export",
      [
        "frames": result.frames, "compositedCorrect": composited.count - compositedBad.count,
        "encodedCorrect": ks.count - encodedBadFrames.count,
        "readBackFrames": back.count, "exportMs": Stats.round2(result.ms),
      ])
  }

  /// Exact seek to every frame of the grid case: ack by `vwish.frame` and correct content.
  /// Run twice: asking the video output for the seek target `CMTime(k, 30)` (production rule,
  /// asserted 90/90) and, as a diagnostic, for `item.currentTime()` after the seek.
  func testGridCutsExactSeekEveryFrame() async throws {
    let g = try await GridCase.load()
    var results: [String: Any] = [:]
    for query in [PlayerHarness.Query.seekTarget, .itemTime] {
      let built = try await g.build()
      let harness = PlayerHarness(built: built)
      harness.query = query
      try await harness.waitReady()
      var bad: [String] = []
      var notAcked: [String] = []
      var acked = 0
      var onTime = 0
      var itemTimeOff: [String] = []
      var ms: [Double] = []
      for k in Int64(0)..<90 {
        // 3 s patience for determinism; the 500 ms budget is reported (shared, loaded machine).
        let ack = await harness.exactSeek(k: k, fps: 30, timeoutMs: 3000)
        ms.append(ack.ms)
        if ack.acked {
          acked += 1
          if ack.ms <= 500 { onTime += 1 }
        } else {
          notAcked.append("k=\(k) seen \(ack.seen.map { $0.map(String.init) ?? "nil" })")
        }
        if !ack.itemTimeIsTarget {
          itemTimeOff.append(
            "k=\(k) item \(ack.itemTimeAfterSeek.value)/\(ack.itemTimeAfterSeek.timescale)")
        }
        if let b = ack.buffer { bad += g.check(b, k: k) }
      }
      let name = query == .seekTarget ? "seekTarget" : "itemTime"
      results[name] = [
        "acked": acked, "ackedWithin500ms": onTime, "of": 90, "contentErrors": bad.count, "notAcked": Array(notAcked.prefix(8)),
        "itemTimeNotTarget": itemTimeOff.count, "itemTimeNotTargetSample": Array(itemTimeOff.prefix(4)),
        "firstFrameMs": Stats.round2(harness.firstFrameMs ?? -1),
        "firstFrameNeededSeek": harness.firstFrameNeededSeek,
        "msP50": Stats.round2(Stats.percentile(ms, 50)), "msP95": Stats.round2(Stats.percentile(ms, 95)),
      ]
      if query == .seekTarget {
        XCTAssertEqual(acked, 90, "\(notAcked)")
        XCTAssertEqual(bad, [])
      }
    }
    Metrics.record("D-35.gridCuts.exactSeek", results)
  }

  /// Real-time playback: every frame the video output delivers carries the barcode of the frame it
  /// is stamped with, and its display item time maps to the same k.
  func testGridCutsPlaybackEveryDeliveredFrame() async throws {
    let g = try await GridCase.load()
    let built = try await g.build()
    let harness = PlayerHarness(built: built)
    try await harness.waitReady()
    harness.player.isMuted = true
    _ = await harness.exactSeek(k: 0, fps: 30)
    var bad: [String] = []
    var timeMismatch = 0
    let frames = await harness.capturePlayback(
      rate: 1, end: built.composition.duration, timeout: 10, keepBuffers: false
    ) { c in
      guard let k = c.stamp else {
        bad.append("unstamped buffer at \(c.itemTime.seconds)")
        return
      }
      bad += g.check(c.buffer, k: k)
      if c.itemTime.isNumeric, Grid.frameIndexNearest(c.itemTime, fps: 30) != k { timeMismatch += 1 }
    }
    let stamps = frames.compactMap(\.stamp)
    XCTAssertGreaterThan(stamps.count, 60, "too few frames delivered: \(stamps.count)")
    XCTAssertEqual(bad, [])
    XCTAssertEqual(timeMismatch, 0)
    let distinct = Set(stamps)
    Metrics.record(
      "D-35.gridCuts.playback",
      [
        "delivered": stamps.count, "distinctFrames": distinct.count, "of": 90,
        "contentErrors": bad.count, "itemTimeVsStampMismatches": timeMismatch,
        "cutFramesSeen": [30, 31, 32, 60, 61, 62].filter { distinct.contains($0) },
      ])
  }

  /// Negative control: the pre-D-35 µs CMTimes put the cut one frame late on iOS.
  func testMicrosecondGridIsWrong() async throws {
    let g = try await GridCase.load()
    let built = try await g.build(mode: .microseconds)
    var wrong: Set<Int64> = []
    _ = try await ExportPipeline.export(built: built, to: MediaFactory.url("grid_export_us.mp4")) {
      pb, _ in
      let k = SpikeCompositor.frameStamp(pb) ?? -1
      if !g.check(pb, k: k).isEmpty { wrong.insert(k) }
    }
    Metrics.record("D-35.microsecondControl", ["wrongFrames": wrong.sorted()])
    // Documented, not required: the µs build mis-renders the frames at the cuts.
    XCTAssertFalse(wrong.isEmpty, "expected the µs control to show the off-by-one at the cuts")
  }
}
