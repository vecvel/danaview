import AVFoundation
import QuartzCore
import XCTest

@testable import VWSpikeHost

/// V-N23 (native half): the DisplayLinkDriver of ARCH §13.2 asks the video output for
/// `itemTime(forHostTime: displayLink.targetTimestamp)`. This measures how far the buffer it gets
/// is from the audio clock at the moment the frame is meant to be displayed, before any Flutter
/// texture latency is added. The Flutter half (texture → raster → display) is measured by
/// flutter_texture_latency/ (tools/run_texture_latency.sh).
final class DisplayLinkLatencyTests: XCTestCase {
  final class Driver: NSObject {
    let harness: PlayerHarness
    var samples: [(target: CFTimeInterval, itemTarget: Double, stamp: Int64, callbackDelay: Double)] = []
    var link: CADisplayLink?

    init(harness: PlayerHarness) { self.harness = harness }

    @objc func tick(_ link: CADisplayLink) {
      let out = harness.bridge.output
      let itemTime = out.itemTime(forHostTime: link.targetTimestamp)
      guard out.hasNewPixelBuffer(forItemTime: itemTime),
        let b = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
        let k = SpikeCompositor.frameStamp(b)
      else { return }
      harness.bridge.push(b)
      samples.append(
        (link.targetTimestamp, itemTime.seconds, k, CACurrentMediaTime() - link.timestamp))
    }
  }

  @MainActor
  func testTargetTimestampMapping() async throws {
    let built = try await SeekCase.build(renderScale: 0.5)
    let harness = PlayerHarness(built: built)
    try await harness.waitReady()
    harness.player.isMuted = true
    _ = await harness.exactSeek(k: 0, fps: 30)
    let driver = Driver(harness: harness)
    let link = CADisplayLink(target: driver, selector: #selector(Driver.tick(_:)))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }
    link.add(to: .main, forMode: .common)
    harness.player.play()
    try await Task.sleep(nanoseconds: 4_000_000_000)
    link.invalidate()
    harness.player.pause()
    let s = driver.samples
    XCTAssertGreaterThan(s.count, 60)
    // Offset of the delivered frame against the item (audio) clock at the target display time,
    // in ms: positive = the video frame is older than what is audible at that moment.
    let all = s.map { ($0.itemTarget - Double($0.stamp) / 30) * 1000 }
    // The first 10 ticks after play() are the start-up transient (the item clock starts before
    // the first new frame is composited; one stale frame of up to ~750 ms was seen on a loaded
    // machine). Steady state is what the preview tolerance (§12.7) is about; the transient is
    // reported separately.
    let warmup = Array(all.prefix(10))
    let offsets = Array(all.dropFirst(10))
    let p50 = Stats.percentile(offsets, 50)
    let p95 = Stats.percentile(offsets.map(abs), 95)
    // The selected frame is the one whose interval contains the target item time: 0…33.3 ms.
    XCTAssertGreaterThanOrEqual(offsets.min() ?? -1, -1)
    XCTAssertLessThanOrEqual(offsets.max() ?? 99, 34.4)
    Metrics.record(
      "V-N23.displayLinkMapping",
      [
        "frames": s.count, "warmupOffsetMsMax": Stats.round2(warmup.max() ?? 0), "offsetMsP50": Stats.round2(p50), "absOffsetMsP95": Stats.round2(p95),
        "offsetMsMin": Stats.round2(offsets.min() ?? 0), "offsetMsMax": Stats.round2(offsets.max() ?? 0),
        "callbackDelayMsP50": Stats.round2(Stats.percentile(s.map { $0.callbackDelay * 1000 }, 50)),
        "displayPeriodMsP50": Stats.round2(
          Stats.percentile(zip(s, s.dropFirst()).map { ($1.target - $0.target) * 1000 }, 50)),
      ])
  }
}
