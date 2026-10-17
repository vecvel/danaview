import CoreGraphics
import Foundation

/// The subset of RenderPlan v1 (ARCH §11.2) the spike needs: canvas, assets and media layers with
/// piecewise-linear maps and a centre/scale transform. Parsed from the CORE-29 contract fixtures
/// or built programmatically.
struct SpikePlan: Decodable {
  struct Canvas: Decodable {
    var w: Int
    var h: Int
    var fps: Int64
    var gridFps: Int64?
    var bg: String?

    /// Edit-point grid (D-35 rule 4): the project rate; output frames use `fps`.
    var editFps: Int64 { gridFps ?? fps }
  }

  struct Asset: Decodable {
    var kind: String
    var uri: String
    var w: Int?
    var h: Int?
    var durUs: Int64?

    var fileName: String { (uri as NSString).lastPathComponent }
  }

  struct Transform: Decodable {
    var cx: Double?
    var cy: Double?
    var s: Double?
  }

  struct Segment {
    var t0: Int64
    var t1: Int64
    var s0: Int64
    var s1: Int64

    /// Exact map s(t) on this segment (µs).
    func source(at t: Int64) -> Double {
      Double(s0) + Double(t - t0) * Double(s1 - s0) / Double(t1 - t0)
    }
  }

  struct Layer: Decodable {
    var id: String
    var z: Int
    var seq: Int
    var t: [Int64]
    var kind: String
    var asset: String
    var map: [[Int64]]
    var base: [Double]
    var xf: Transform?

    var t0: Int64 { t[0] }
    var t1: Int64 { t[1] }
    var segments: [Segment] { map.map { Segment(t0: $0[0], t1: $0[1], s0: $0[2], s1: $0[3]) } }

    func isActive(at time: Int64) -> Bool { t0 <= time && time < t1 }

    func segment(at time: Int64) -> Segment? {
      segments.first { $0.t0 <= time && time < $0.t1 }
    }
  }

  var v: Int
  var canvas: Canvas
  var durUs: Int64
  var assets: [String: Asset]
  var layers: [Layer]

  static func load(_ url: URL) throws -> SpikePlan {
    try JSONDecoder().decode(SpikePlan.self, from: Data(contentsOf: url))
  }

  /// Layers active at plan time `t`, bottom → top.
  func activeLayers(at time: Int64) -> [Layer] {
    layers.filter { $0.isActive(at: time) }.sorted { $0.z < $1.z }
  }

  /// Number of output frames: durUs is on the grid.
  var frameCount: Int64 { Grid.frameIndexOf(durUs, fps: canvas.fps) }

  /// Placement rectangle of a layer in canvas pixels (y-down), ARCH §11.6 `place` without
  /// rotation: base size × s, centred at (cx, cy) (default: canvas centre).
  func placementRect(_ layer: Layer) -> CGRect {
    let s = layer.xf?.s ?? 1
    let w = layer.base[0] * s
    let h = layer.base[1] * s
    let cx = layer.xf?.cx ?? Double(canvas.w) / 2
    let cy = layer.xf?.cy ?? Double(canvas.h) / 2
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
  }
}

/// Expected-active table shipped with the contract fixture (CORE-29).
struct ExpectedActive: Decodable {
  struct Frame: Decodable {
    var k: Int64
    var timeOfFrame: Int64
    var active: [String]
  }

  var plan: String
  var fps: Int64
  var frames: [Frame]
}
