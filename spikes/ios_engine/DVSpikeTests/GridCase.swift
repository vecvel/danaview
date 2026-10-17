import AVFoundation
import XCTest

@testable import DVSpikeHost

/// The CORE-29 grid-cut contract case (D-35): `grid_cuts_30fps.json` with cuts at frames 31 and 61
/// (k ≡ 1 mod 3) on sequence 0 and a PiP on sequence 1 from frame 32 to 62 (k ≡ 2 mod 3), plus its
/// expected-active table, against self-generated barcode media.
struct GridCase {
  let plan: SpikePlan
  let expected: ExpectedActive
  let media: [String: URL]
  let spacer: URL
  let sourceFps: [String: Int64]
  let clipOf: [String: Int]

  static func load() async throws -> GridCase {
    let plan = try SpikePlan.load(SpikeMedia.fixtureURL("grid_cuts_30fps.json"))
    let expected = try JSONDecoder().decode(
      ExpectedActive.self,
      from: Data(contentsOf: SpikeMedia.fixtureURL("grid_cuts_30fps.expected_active.json")))
    let media = try await SpikeMedia.mediaFor(plan)
    var fps: [String: Int64] = [:]
    var clip: [String: Int] = [:]
    for (id, asset) in plan.assets {
      let is25 = asset.fileName.contains("720p25")
      fps[id] = is25 ? 25 : 30
      clip[id] = is25 ? SpikeMedia.clipB : SpikeMedia.clipA
    }
    return GridCase(
      plan: plan, expected: expected, media: media, spacer: try await MediaFactory.spacer(),
      sourceFps: fps, clipOf: clip)
  }

  func build(mode: CompositionBuilder.GridMode = .rational, renderScale: Double = 0.5) async throws
    -> BuiltComposition
  {
    try await CompositionBuilder.build(
      plan: plan, media: media, spacer: spacer, mode: mode, renderScale: renderScale)
  }

  /// Content check of one composited frame (barcodes of every visible layer, absent PiP).
  func check(_ buffer: CVPixelBuffer, k: Int64) -> [String] {
    Expectation.check(buffer, plan: plan, k: k, sourceFps: sourceFps, clipOf: clipOf)
  }

  /// Expected-active ids (bottom → top as in the table) for frame k.
  func expectedActive(_ k: Int64) -> [String]? {
    expected.frames.first { $0.k == k }?.active
  }
}

/// A longer composition for the exact-seek and texture tests: 8 s of frame_counter_1080p30 on
/// sequence 0 and the 720p25 clip as a PiP on sequence 1 over [2 s, 6 s).
enum SeekCase {
  static func plan() -> SpikePlan {
    let json: [String: Any] = [
      "v": 1, "canvas": ["w": 1920, "h": 1080, "fps": 30], "durUs": 8_000_000,
      "assets": [
        "a": ["kind": "video", "uri": "file:///fixtures/frame_counter_1080p30.mp4"],
        "b": ["kind": "video", "uri": "file:///fixtures/frame_counter_720p25.mp4"],
      ],
      "layers": [
        [
          "id": "base", "z": 10, "seq": 0, "t": [0, 8_000_000], "kind": "media", "asset": "a",
          "map": [[0, 8_000_000, 0, 8_000_000]], "base": [1920, 1080],
        ],
        [
          "id": "pip", "z": 20, "seq": 1, "t": [2_000_000, 6_000_000], "kind": "media", "asset": "b",
          "map": [[2_000_000, 6_000_000, 1_000_000, 5_000_000]], "base": [640, 360],
          "xf": ["cx": 1440, "cy": 270],
        ],
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(SpikePlan.self, from: data)
  }

  static let sourceFps: [String: Int64] = ["a": 30, "b": 25]
  static let clipOf: [String: Int] = ["a": SpikeMedia.clipA, "b": SpikeMedia.clipB]

  static func build(renderScale: Double) async throws -> BuiltComposition {
    let plan = plan()
    return try await CompositionBuilder.build(
      plan: plan, media: try await SpikeMedia.mediaFor(plan), spacer: try await MediaFactory.spacer(),
      renderScale: renderScale)
  }
}

/// Deterministic PRNG for reproducible seek sequences.
struct LCG {
  var state: UInt64

  mutating func next(_ bound: Int64) -> Int64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int64((state >> 33) % UInt64(bound))
  }
}
