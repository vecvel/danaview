import AVFoundation
import XCTest

@testable import DVSpikeHost

/// Measurements every spike test appends; printed as `DVSPIKE-METRIC {json}` lines that
/// tools/run_spike_tests.sh collects into the report.
enum Metrics {
  /// JSONSerialization raises (uncatchable) on NaN/inf: replace them with the string "nan".
  static func sanitize(_ x: Any) -> Any {
    switch x {
    case let d as Double: return d.isFinite ? d : "nan"
    case let f as Float: return f.isFinite ? Double(f) : "nan"
    case let a as [Any]: return a.map(sanitize)
    case let m as [String: Any]: return m.mapValues(sanitize)
    default: return x
    }
  }

  static func record(_ test: String, _ values: [String: Any]) {
    var v = values.mapValues(sanitize)
    v["test"] = test
    v["destination"] = destination
    // Timing numbers on the shared build Mac depend on what else runs: record the 1-minute load
    // average (on the simulator this is the host Mac's; 8 cores).
    if let load = hostLoad1m { v["hostLoad1m"] = (load * 10).rounded() / 10 }
    if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
      let s = String(data: data, encoding: .utf8)
    {
      print("DVSPIKE-METRIC \(s)")
    }
  }

  /// 1-minute load average (the host Mac's on the simulator).
  static var hostLoad1m: Double? {
    var load = [Double](repeating: 0, count: 3)
    return getloadavg(&load, 3) == 3 ? load[0] : nil
  }

  /// ARCH §23: simulator performance is reported, not failed. The spike still gates timing on
  /// the simulator while the shared host has a free core; when the host is oversubscribed (load
  /// above its core count, e.g. other engineers' Gradle/Xcode builds) the tail percentiles
  /// measure contention, so tests fall back to the median gate and record `hostBusy`.
  /// Always false on a device.
  static var hostBusy: Bool {
    #if targetEnvironment(simulator)
      return (hostLoad1m ?? 0) > Double(ProcessInfo.processInfo.activeProcessorCount)
    #else
      return false
    #endif
  }

  static var destination: String {
    var sys = utsname()
    uname(&sys)
    let machine = withUnsafePointer(to: &sys.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    #if targetEnvironment(simulator)
      let kind = "simulator"
      let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
    #else
      let kind = "device"
      let model = machine
    #endif
    return "\(kind) \(model) iOS \(UIDevice.current.systemVersion)"
  }
}

enum Stats {
  static func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let i = min(s.count - 1, max(0, Int((p / 100 * Double(s.count - 1)).rounded())))
    return s[i]
  }

  static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

/// Shared generated media for the grid / seek / export tests (ENG-05 fixture names, spike sizes).
enum SpikeMedia {
  static let clipA = 1
  static let clipB = 2

  /// frame_counter_1080p30 stand-in (8 s, 30 fps, barcode clip 1).
  static func a1080p30() async throws -> URL {
    try await MediaFactory.barcodeVideo(
      name: "frame_counter_1080p30.mp4", width: 1920, height: 1080, fps: 30, frames: 240, clip: clipA,
      color: (200, 90, 40))
  }

  /// frame_counter_720p25 stand-in (8 s, 25 fps, barcode clip 2).
  static func b720p25() async throws -> URL {
    try await MediaFactory.barcodeVideo(
      name: "frame_counter_720p25.mp4", width: 1280, height: 720, fps: 25, frames: 200, clip: clipB,
      color: (40, 160, 220))
  }

  /// Media by asset file name in the contract fixtures.
  static func mediaFor(_ plan: SpikePlan) async throws -> [String: URL] {
    var out: [String: URL] = [:]
    for (id, asset) in plan.assets {
      switch asset.fileName {
      case "frame_counter_1080p30.mp4": out[id] = try await a1080p30()
      case "frame_counter_720p25.mp4": out[id] = try await b720p25()
      default: XCTFail("no generated media for \(asset.fileName)")
      }
    }
    return out
  }

  static func fixtureURL(_ name: String) -> URL {
    Bundle(for: BundleToken.self).url(forResource: name, withExtension: nil)!
  }

  private final class BundleToken {}
}

/// Expected content of an output frame, derived from the plan alone (ARCH §11.5 source-frame
/// rule: greatest source PTS ≤ s + 500 µs).
enum Expectation {
  struct LayerExpectation {
    var layerID: String
    var rect: CGRect  // render pixels, y-down
    var value: Barcode.Value
  }

  static func sourceFrame(layer: SpikePlan.Layer, at t: Int64, sourceFps: Int64) -> Int {
    let seg = layer.segment(at: t)!
    let s = seg.source(at: t) + 500
    return Int((s * Double(sourceFps) / 1_000_000).rounded(.down))
  }

  /// Top layer expectations visible at frame k (layers whose barcode area is not covered by a
  /// higher layer; in the grid fixtures the PiP sits in the top half, above the base barcode).
  static func expected(
    plan: SpikePlan, k: Int64, renderSize: CGSize, sourceFps: [String: Int64], clipOf: [String: Int]
  ) -> [LayerExpectation] {
    let t = Grid.timeOfFrame(k, fps: plan.canvas.fps)
    let scale = renderSize.width / CGFloat(plan.canvas.w)
    return plan.activeLayers(at: t).map { layer in
      let r = plan.placementRect(layer)
      return LayerExpectation(
        layerID: layer.id,
        rect: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale),
        value: Barcode.Value(
          frame: sourceFrame(layer: layer, at: t, sourceFps: sourceFps[layer.asset]!),
          clip: clipOf[layer.asset]!))
    }
  }

  /// Checks one composited frame; returns mismatch descriptions (empty = correct).
  static func check(
    _ buffer: CVPixelBuffer, plan: SpikePlan, k: Int64, sourceFps: [String: Int64], clipOf: [String: Int]
  ) -> [String] {
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    var problems: [String] = []
    for e in expected(plan: plan, k: k, renderSize: size, sourceFps: sourceFps, clipOf: clipOf) {
      let got = Barcode.decode(buffer, rect: e.rect)
      if got != e.value {
        problems.append("k=\(k) \(e.layerID): expected \(e.value), got \(got.map { "\($0)" } ?? "unreadable")")
      }
    }
    // A layer that must NOT be visible (e.g. the PiP one frame early or late) must not show its
    // barcode in its own rectangle.
    let t = Grid.timeOfFrame(k, fps: plan.canvas.fps)
    let scale = size.width / CGFloat(plan.canvas.w)
    let activeRects = plan.activeLayers(at: t).map { plan.placementRect($0) }
    for layer in plan.layers where !layer.isActive(at: t) {
      let r = plan.placementRect(layer)
      guard !activeRects.contains(r) else { continue }
      let rect = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
      if let got = Barcode.decode(buffer, rect: rect), got.clip == clipOf[layer.asset] {
        problems.append("k=\(k) \(layer.id): visible while inactive (\(got))")
      }
    }
    return problems
  }
}
