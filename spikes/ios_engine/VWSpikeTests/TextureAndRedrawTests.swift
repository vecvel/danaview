import AVFoundation
import CoreVideo
import Metal
import VWSpikeKernels
import XCTest

@testable import VWSpikeHost

/// ARCH §12.7/§13.2: AVPlayerItemVideoOutput → FlutterTexture-style `copyPixelBuffer` is
/// zero-copy (the compositor's IOSurface reaches the texture), and redraw-from-cache of the last
/// source buffers is ≤ 30 ms.
final class TextureAndRedrawTests: XCTestCase {
  func testVideoOutputToTextureIsZeroCopy() async throws {
    let built = try await SeekCase.build(renderScale: 1)
    let harness = PlayerHarness(built: built)
    try await harness.waitReady()
    var sameSurface = 0
    var checked = 0
    var metalOK = 0
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    let textureCache = try XCTUnwrap(cache)
    for k in [Int64(10), 75, 140, 200] {
      let ack = await harness.exactSeek(k: k, fps: 30, timeoutMs: 3000)
      let b = try XCTUnwrap(ack.buffer)
      harness.bridge.push(b)
      // copyPixelBuffer hands out the very same CVPixelBuffer (+1), no conversion.
      let handed = try XCTUnwrap(harness.bridge.copyPixelBuffer()).takeRetainedValue()
      XCTAssertTrue(handed === b)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(handed), kCVPixelFormatType_32BGRA)
      let surface = try XCTUnwrap(Pixels.ioSurfaceID(handed), "not IOSurface-backed")
      // The compositor's render-context buffer for k has the same IOSurface: no copy in between.
      let rendered = built.state.log.all.last { $0.k == k }
      checked += 1
      if rendered?.surfaceID == surface { sameSurface += 1 }
      // Wrap as a Metal texture the way Flutter's engine does (CVMetalTextureCache, no copy).
      var tex: CVMetalTexture?
      let status = CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache, handed, nil, .bgra8Unorm, CVPixelBufferGetWidth(handed),
        CVPixelBufferGetHeight(handed), 0, &tex)
      if status == kCVReturnSuccess, let t = tex, CVMetalTextureGetTexture(t) != nil { metalOK += 1 }
    }
    XCTAssertEqual(sameSurface, checked, "video output copied the compositor buffer")
    XCTAssertEqual(metalOK, checked)
    Metrics.record(
      "texture.zeroCopy",
      ["frames": checked, "sameIOSurface": sameSurface, "metalTextureWrapped": metalOK])
  }

  /// Paused param patch: change the look and blur, re-render the cached source buffers of the
  /// last request (2 video layers, 1080p) and hand the result to the texture.
  func testRedrawFromCacheUnder30ms() async throws {
    let built = try await SeekCase.build(renderScale: 1)
    let harness = PlayerHarness(built: built)
    try await harness.waitReady()
    let k: Int64 = 100  // base + PiP active
    let ack = await harness.exactSeek(k: k, fps: 30, timeoutMs: 3000)
    XCTAssertTrue(ack.acked)
    let compositor = try XCTUnwrap(built.state.compositor)
    let plan = built.state.plan
    let looks = [
      SpikeLook(exposure: 0.3, contrast: 0.1, saturation: 0.2),
      SpikeLook(exposure: -0.2, brightness: 0.1, saturation: -0.4),
    ]
    var ms: [Double] = []
    var msNoBlur: [Double] = []
    var msBlur: [Double] = []
    var changed = 0
    var contentOK = 0
    var previousTop: Double?
    // Warm-up = the production pre-warm at session start (report §2.5): the first redraw creates
    // the pool, and every look/blur variant is rendered once so its CI render pipeline is
    // compiled before the measured paused edits.
    _ = try compositor.redrawFromCache()
    for look in looks {
      for blur: Float in [0, 4] {
        built.state.setParams(look: look, blur: blur)
        _ = try compositor.redrawFromCache()
      }
    }
    let busyBefore = Metrics.hostBusy
    for i in 0..<60 {
      built.state.setParams(look: looks[i % 2], blur: i % 4 < 2 ? 0 : 4)
      let r = try XCTUnwrap(try compositor.redrawFromCache())
      ms.append(r.ms)
      if built.state.params.blur == 0 { msNoBlur.append(r.ms) } else { msBlur.append(r.ms) }
      harness.bridge.push(r.buffer)
      XCTAssertEqual(r.k, k)
      let top = Pixels.mean(r.buffer, rect: CGRect(x: 0, y: 0, width: 400, height: 200)).r
      if let p = previousTop, abs(p - top) > 2 { changed += 1 }
      previousTop = top
      if built.state.params.blur == 0,
        Expectation.check(r.buffer, plan: plan, k: k, sourceFps: SeekCase.sourceFps, clipOf: SeekCase.clipOf)
          .isEmpty
      {
        contentOK += 1
      }
    }
    let p50 = Stats.percentile(ms, 50)
    let p95 = Stats.percentile(ms, 95)
    let hostBusy = busyBefore || Metrics.hostBusy
    XCTAssertLessThanOrEqual(p50, 30, "redraw p50 \(p50) ms")
    if !hostBusy {
      XCTAssertLessThanOrEqual(p95, 30, "redraw p95 \(p95) ms")
    }
    XCTAssertGreaterThan(changed, 20, "param patches did not change the pixels")
    XCTAssertEqual(contentOK, 30, "redraw shows other source frames")
    Metrics.record(
      "redrawFromCache.1080p.2layers",
      [
        "msP50": Stats.round2(p50), "msP95": Stats.round2(p95),
        "msMax": Stats.round2(ms.max() ?? 0), "redraws": ms.count, "pixelChanges": changed,
        "hostBusy": hostBusy, "p95Gated": !hostBusy,
        "lookOnlyMsP50": Stats.round2(Stats.percentile(msNoBlur, 50)),
        "lookBlur4MsP50": Stats.round2(Stats.percentile(msBlur, 50)),
      ])
  }

  /// HLG source with `supportsHDRSourceFrames = false`: the compositor receives 8-bit BGRA with
  /// the HDR transfer function converted away (SDR), and the frame renders.
  func testHLGClipArrivesAsSDR() async throws {
    let url = try await HDRMedia.hlgURL()
    let asset = AVURLAsset(url: url)
    let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
    let desc = try await track.load(.formatDescriptions).first!
    let srcTransfer =
      CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
      as? String
    XCTAssertEqual(srcTransfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, "fixture is not HLG")

    let json: [String: Any] = [
      "v": 1, "canvas": ["w": 640, "h": 360, "fps": 30], "durUs": 900_000,
      "assets": ["h": ["kind": "video", "uri": "file:///hlg.mov"]],
      "layers": [
        [
          "id": "hlg", "z": 10, "seq": 0, "t": [0, 900_000], "kind": "media", "asset": "h",
          "map": [[0, 900_000, 0, 900_000]], "base": [640, 360],
        ]
      ],
    ]
    let plan = try JSONDecoder().decode(SpikePlan.self, from: JSONSerialization.data(withJSONObject: json))
    let built = try await CompositionBuilder.build(
      plan: plan, media: ["h": url], spacer: try await MediaFactory.spacer())
    built.state.setParams(look: .identity, blur: 0)
    let harness = PlayerHarness(built: built)
    try await harness.waitReady()
    let ack = await harness.exactSeek(k: 5, fps: 30, timeoutMs: 3000)
    XCTAssertTrue(ack.acked)
    let record = try XCTUnwrap(built.state.log.all.last { $0.k == 5 })
    let fmt = try XCTUnwrap(record.sourceFormats["hlg"])
    XCTAssertEqual(fmt, kCVPixelFormatType_32BGRA, "source arrived as \(Pixels.fourCC(fmt))")
    let tf = record.sourceTransfer["hlg"] ?? "nil"
    XCTAssertFalse(tf.contains("2100_HLG"), "source still tagged HLG: \(tf)")
    let src = try XCTUnwrap(built.state.compositor?.cachedSources()["hlg"])
    let w = CVPixelBufferGetWidth(src)
    let h = CVPixelBufferGetHeight(src)
    let left = Pixels.mean(src, rect: CGRect(x: w / 8, y: h / 4, width: w / 4, height: h / 2))
    let right = Pixels.mean(src, rect: CGRect(x: 5 * w / 8, y: h / 4, width: w / 4, height: h / 2))
    XCTAssertGreaterThan(right.g, left.g + 10, "HLG 0.75 must render brighter than 0.50")
    XCTAssertLessThan(abs(left.r - left.b), 12, "neutral input must stay neutral")
    XCTAssertGreaterThan(left.g, 20)
    XCTAssertLessThan(right.g, 255.5)
    Metrics.record(
      "HDR.hlgAsSDR",
      [
        "sourceFormat": Pixels.fourCC(fmt), "sourceTransferAttachment": tf,
        "hlg050_rgb": [left.r, left.g, left.b].map(Stats.round2),
        "hlg075_rgb": [right.r, right.g, right.b].map(Stats.round2),
        "fixture": url.lastPathComponent,
      ])
  }
}

/// HLG media: generated with the HEVC Main10 encoder when available, otherwise the committed
/// ffmpeg-generated fixture (tools/make_hlg_fixture.sh).
enum HDRMedia {
  static func hlgURL() async throws -> URL {
    if let u = try await MediaFactory.hlgClip(name: "hlg_640x360.mov") { return u }
    return SpikeMedia.fixtureURL("hlg_bars_640x360.mov")
  }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
  try XCTUnwrap(value, file: file, line: line)
}
