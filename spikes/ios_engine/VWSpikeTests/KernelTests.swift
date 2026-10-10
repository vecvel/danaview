import CoreImage
import Metal
import VWSpikeKernels
import VWSpikeStitchable
import XCTest

@testable import VWSpikeHost

/// V-N9: precompiled Metal CI kernels from a CocoaPods library target load and run; V-N22: the
/// same kernels on a `.useSoftwareRenderer` CIContext.
final class KernelTests: XCTestCase {
  /// CPU reference of vw_look (ARCH §11.6 grade subset).
  static func referenceLook(_ c: [Double], _ p: SpikeLook) -> [Double] {
    var v = c.map { pow(pow(max($0, 0), 2.2) * pow(2, 2 * Double(p.exposure)), 1 / 2.2) }
    v = v.map { $0 + Double(p.brightness) / 4 }
    v = v.map { ($0 - 0.5) * (1 + Double(p.contrast)) + 0.5 }
    let y = 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    v = v.map { y + ($0 - y) * (1 + Double(p.saturation)) }
    return v.map { min(1, max(0, $0)) }
  }

  private func render(_ image: CIImage, context: CIContext, size: Int = 64) throws -> CVPixelBuffer {
    let out = Pixels.makeBGRA(width: size, height: size)
    let dest = CIRenderDestination(pixelBuffer: out)
    dest.colorSpace = nil
    _ = try context.startTask(toRender: image, to: dest).waitUntilCompleted()
    return out
  }

  func testFcikernelMetallibLoadsFromPodResourceBundle() throws {
    let kernels: SpikeKernels
    do {
      kernels = try SpikeKernels()
    } catch {
      Metrics.record("V-N9.fcikernel", ["loaded": false, "error": "\(error)"])
      XCTFail("V-N9 -fcikernel load failed: \(error)")
      return
    }
    XCTAssertTrue(kernels.metallibURL.path.contains("VWSpikeKernels.bundle"))
    let context = SpikeCompositor.makeContext()
    let p = SpikeLook(exposure: 0.25, brightness: 0.1, contrast: 0.2, saturation: -0.3)
    let input: [Double] = [0.6, 0.4, 0.2]
    let img = CIImage(color: CIColor(red: input[0], green: input[1], blue: input[2])).cropped(
      to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let out = try render(kernels.applyLook(img, p), context: context)
    let m = Pixels.mean(out, rect: CGRect(x: 8, y: 8, width: 48, height: 48))
    let ref = Self.referenceLook(input, p)
    XCTAssertEqual(m.r / 255, ref[0], accuracy: 1.5 / 255)
    XCTAssertEqual(m.g / 255, ref[1], accuracy: 1.5 / 255)
    XCTAssertEqual(m.b / 255, ref[2], accuracy: 1.5 / 255)

    // Identity look is a no-op within 1/255.
    let id = try render(kernels.applyLook(img, .identity), context: context)
    let mi = Pixels.mean(id, rect: CGRect(x: 8, y: 8, width: 48, height: 48))
    XCTAssertEqual(mi.r / 255, input[0], accuracy: 1 / 255)

    // Blur kernel (general kernel with a sampler + ROI) runs and keeps a flat field flat.
    let blurred = try render(kernels.applyBlur(img, sigma: 3), context: context)
    let mb = Pixels.mean(blurred, rect: CGRect(x: 8, y: 8, width: 48, height: 48))
    XCTAssertEqual(mb.g / 255, input[1], accuracy: 1.5 / 255)

    Metrics.record(
      "V-N9.fcikernel",
      [
        "loaded": true, "metallibBytes": kernels.metallibData.count,
        "kernelCreateMs": Stats.round2(kernels.loadMs),
        "metallibPath": kernels.metallibURL.pathComponents.suffix(3).joined(separator: "/"),
        "lookMeasured": [m.r / 255, m.g / 255, m.b / 255].map(Stats.round2),
        "lookReference": ref.map(Stats.round2),
      ])
  }

  func testStitchableKernelsLoadWithoutCustomFlags() throws {
    let kernels: StitchableKernels
    do {
      kernels = try StitchableKernels()
    } catch {
      Metrics.record("V-N9.stitchable", ["loaded": false, "error": "\(error)"])
      XCTFail("stitchable kernels failed to load: \(error)")
      return
    }
    let context = SpikeCompositor.makeContext()
    let input: [Double] = [0.6, 0.4, 0.2]
    let img = CIImage(color: CIColor(red: input[0], green: input[1], blue: input[2])).cropped(
      to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let p = SpikeLook(exposure: 0.25, brightness: 0.1, contrast: 0.2, saturation: -0.3)
    let out = try render(
      kernels.applyLook(
        img, exposure: p.exposure, brightness: p.brightness, contrast: p.contrast,
        saturation: p.saturation),
      context: context)
    let m = Pixels.mean(out, rect: CGRect(x: 8, y: 8, width: 48, height: 48))
    let ref = Self.referenceLook(input, p)
    XCTAssertEqual(m.r / 255, ref[0], accuracy: 1.5 / 255)
    let blurred = try render(kernels.applyBlurH(img, sigma: 3), context: context)
    XCTAssertEqual(
      Pixels.mean(blurred, rect: CGRect(x: 8, y: 8, width: 48, height: 48)).g / 255, input[1],
      accuracy: 1.5 / 255)
    Metrics.record(
      "V-N9.stitchable",
      ["loaded": true, "lookMeasured": [m.r / 255, m.g / 255, m.b / 255].map(Stats.round2)])
  }

  /// V-N22: the same kernels on the CPU renderer, 1080p frame with look (+ blur), vs Metal.
  func testKernelsOnSoftwareRenderer() throws {
    let kernels = try XCTUnwrap(SpikeCompositor.kernels)
    let sw = SpikeCompositor.makeContext(software: true)
    let gpu = SpikeCompositor.makeContext()
    let source = Pixels.makeBGRA(width: 1920, height: 1080)
    Barcode.draw(into: source, frame: 1234, clip: 3, color: (180, 120, 60))
    let p = SpikeLook(exposure: 0.2, brightness: 0.05, contrast: 0.1, saturation: 0.2)
    func pipeline(blur: Float) -> CIImage {
      kernels.applyBlur(
        kernels.applyLook(CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]), p),
        sigma: blur)
    }
    var results: [String: Any] = [:]
    for (name, blur) in [("look", Float(0)), ("look+blur4", Float(4))] {
      let gpuOut = Pixels.makeBGRA(width: 1920, height: 1080)
      let swOut = Pixels.makeBGRA(width: 1920, height: 1080)
      func once(_ ctx: CIContext, _ out: CVPixelBuffer) throws -> Double {
        let d = CIRenderDestination(pixelBuffer: out)
        d.colorSpace = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try ctx.startTask(toRender: pipeline(blur: blur), to: d).waitUntilCompleted()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
      }
      _ = try once(gpu, gpuOut)
      var swError: String?
      var swMs: [Double] = []
      do {
        _ = try once(sw, swOut)
        for _ in 0..<5 { swMs.append(try once(sw, swOut)) }
      } catch {
        swError = "\(error)"
      }
      var gpuMs: [Double] = []
      for _ in 0..<5 { gpuMs.append(try once(gpu, gpuOut)) }
      let a = Pixels.mean(gpuOut, rect: CGRect(x: 0, y: 0, width: 960, height: 540))
      let b = Pixels.mean(swOut, rect: CGRect(x: 0, y: 0, width: 960, height: 540))
      let decoded = Barcode.decode(swOut)
      let median = Stats.percentile(swMs, 50)
      results[name] = [
        "softwareRenders": swError == nil, "softwareError": swError ?? "",
        "softwareMsP50": Stats.round2(median),
        "gpuMsP50": Stats.round2(Stats.percentile(gpuMs, 50)),
        "softwareRealtimeAt30fps": Stats.round2((1000 / median) / 30),
        "meanDiffTopHalf": Stats.round2(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)),
        "softwareBarcode": decoded.map { "\($0)" } ?? "unreadable",
      ]
      XCTAssertNil(swError, "software renderer failed: \(swError ?? "")")
      XCTAssertEqual(decoded, Barcode.Value(frame: 1234, clip: 3))
    }
    Metrics.record("V-N22.softwareRenderer", results)
  }
  /// Two-layer composite offline (no AVFoundation): a 1080p base and a 720p PiP rendered by the
  /// compositor's own composite function into a half-size output, with and without the custom
  /// kernels, on the Metal and the software context. Isolates the iOS 18.2 simulator finding
  /// (base layer black whenever the PiP is present) from the playback path.
  func testTwoLayerCompositeVariants() throws {
    let plan = SeekCase.plan()
    let k: Int64 = 100
    let t = Grid.timeOfFrame(k, fps: 30)
    let layers = plan.activeLayers(at: t)
    XCTAssertEqual(layers.map(\.id), ["base", "pip"])
    let base = Pixels.makeBGRA(width: 1920, height: 1080)
    Barcode.draw(into: base, frame: 100, clip: 1, color: (200, 90, 40))
    let pip = Pixels.makeBGRA(width: 1280, height: 720)
    Barcode.draw(into: pip, frame: 83, clip: 2, color: (40, 160, 220))
    var results: [String: String] = [:]
    var failures: [String] = []
    for (ctxName, ctx) in [("metal", SpikeCompositor.makeContext()), ("software", SpikeCompositor.makeContext(software: true))] {
      // A Metal-texture CIImage needs the Metal context; the software context reads buffers.
      SpikeCompositor.sourcesViaMetalTextureCache = ctxName == "metal"
      defer { SpikeCompositor.sourcesViaMetalTextureCache = true }
      for useKernels in [true, false] {
        for size in [CGSize(width: 960, height: 540), CGSize(width: 1920, height: 1080)] {
          let out = Pixels.makeBGRA(width: Int(size.width), height: Int(size.height))
          try SpikeCompositor.renderComposite(
            context: ctx, plan: plan, layers: layers, sources: ["base": base, "pip": pip],
            look: .identity, blur: 0, size: size, into: out, useKernels: useKernels)
          let errs = Expectation.check(
            out, plan: plan, k: k, sourceFps: ["a": 30, "b": 25], clipOf: SeekCase.clipOf)
          // Expectation derives the source frame from the plan; compare only readability here.
          let baseRect = CGRect(origin: .zero, size: size)
          let decoded = Barcode.decode(out, rect: baseRect).map { "\($0)" } ?? "unreadable"
          let name = "\(ctxName).kernels=\(useKernels).\(Int(size.width))"
          results[name] = decoded
          if decoded != "clip 1 frame 100" { failures.append("\(name): base \(decoded); \(errs.prefix(1))") }
        }
      }
    }
    Metrics.record("composite.twoLayerOffline", results)
    XCTAssertEqual(failures, [])
  }
}
