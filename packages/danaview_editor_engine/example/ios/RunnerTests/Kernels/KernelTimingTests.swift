// OWNER: IOS-09
//
// Kernel loading from the pod's DVEditorKernels bundle and per-kernel timing (logged; simulator numbers
// only, device numbers are recorded in QA-04: no device available here). 1080p, Metal CIContext,
// IOSurface BGRA render target (the compositor's), median of 9 renders after a pre-warm.

import CoreImage
import CoreVideo
import XCTest

@testable import danaview_editor_engine

final class KernelTimingTests: XCTestCase {
    func testKernelsLoadFromPodBundle() throws {
        let url = try Kernels.metallibURL()
        XCTAssertTrue(url.path.contains("DVEditorKernels.bundle"), url.path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix(Kernels.metallibName))
        let k = try Kernels(metallibData: try Data(contentsOf: url))
        XCTAssertNotNil(k.look)
        print("IOS-09 kernels: \(Kernels.functionNames.count) created in \(String(format: "%.2f", k.loadMs)) ms from \(url.lastPathComponent)")
        XCTAssertTrue(try Kernels.shared() === Kernels.shared())
    }

    func testPrewarmRendersEveryKernel() throws {
        let k = try KernelTestSupport.kernels()
        let ms = k.prewarm(context: Kernels.makeContext())
        XCTAssertEqual(Set(ms.keys), ["dv_look", "dv_blur", "dv_sharpen", "dv_vignette_mask", "dv_cmask", "dv_reveal", "dv_matte"])
        print("IOS-09 prewarm ms: \(ms.mapValues { (($0 * 100).rounded()) / 100 }.sorted { $0.key < $1.key })")
    }

    func testPerKernelTimingAt1080p() throws {
        let k = try KernelTestSupport.kernels()
        let context = Kernels.makeContext()
        k.prewarm(context: context)
        let w = 1920, h = 1080
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let gradient = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(w), y: CGFloat(h)),
                "inputColor0": CIColor(red: 0.1, green: 0.7, blue: 0.3), "inputColor1": CIColor(red: 0.9, green: 0.4, blue: 0.2),
            ])!.outputImage!.cropped(to: rect)
        // Materialize the source once so timings measure the kernel, not the generator.
        var srcBytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(gradient, toBitmap: &srcBytes, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: nil)
        let src = CIImage(bitmapData: Data(srcBytes), bytesPerRow: w * 4, size: rect.size, format: .RGBA8, colorSpace: nil)
        let lut = try LutTexture.make(n: 33, rgb: KernelTestSupport.table(n: 33) { (min(1, $0 * 1.1), $1 * 0.9, $2) })
        let glyphs = CIImage(color: CIColor(red: 1.0 / 255, green: 0, blue: 0)).cropped(to: rect)
        let canvas = PlanSize(w: Double(w), h: Double(h))
        let cases: [(String, CIImage)] = [
            ("passthrough", src),
            ("dv_look grade", k.look(src, .init(adjust: [0.2, 0.1, 0.1, 0.1, 0.1, 0.2, 0.3, 0.1]), forceKernel: true)),
            ("dv_look chroma+grade+lut", k.look(src, .init(chroma: PlanChroma(key: 0x00B140), adjust: [0.2, 0, 0, 0, 0, 0.2, 0, 0], lut: lut))),
            ("dv_blur σ8", k.blur(src, sigma: 8)),
            ("dv_sharpen", k.sharpen(src, amount: 0.5)),
            ("dv_vignette_mask", k.vignetteMask(src, vignette: 0.5, aspect: 16.0 / 9, mask: PlanMask(shape: .rect, w: 0.6, h: 0.6, r: 10, corner: 0.2, feather: 0.2), base: canvas)),
            ("dv_cmask", k.canvasMask(src, CanvasMask(cx: 960, cy: 540, w: 800, h: 600, r: 15, feather: 20), canvasHeight: Double(h), renderScale: 1)),
            ("dv_reveal", k.reveal(src, glyphs: glyphs, shown: 2)),
            ("dv_matte", k.matte(src)),
        ]
        // IOSurface-backed BGRA target, as the compositor renders into (no CPU readback in the timing).
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let destination = CIRenderDestination(pixelBuffer: try XCTUnwrap(pb))
        destination.colorSpace = nil
        func once(_ image: CIImage) throws -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try context.startTask(toRender: image, to: destination).waitUntilCompleted()
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        var report: [String] = []
        var baseline = 0.0
        for (name, image) in cases {
            _ = try once(image)
            var samples: [Double] = []
            for _ in 0..<9 { samples.append(try once(image)) }
            samples.sort()
            let p50 = samples[4]
            if name == "passthrough" { baseline = p50 }
            report.append(
                "\(name): p50 \(String(format: "%.2f", p50)) ms (kernel ≈ \(String(format: "%.2f", max(0, p50 - baseline))) ms over passthrough), max \(String(format: "%.2f", samples[8])) ms")
        }
        let summary = "IOS-09 per-kernel timing (1080p, simulator GPU, BGRA IOSurface target):\n  " + report.joined(separator: "\n  ")
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "IOS-09 kernel timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
