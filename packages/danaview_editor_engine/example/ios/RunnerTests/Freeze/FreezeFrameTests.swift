// OWNER: IOS-06
//
// Freeze frame and source-frame cache (BUILD_PLAN IOS-06):
// - the PNG still at the Dart path carries the barcode of exactly the requested frame on
//   frame_counter (frame starts, frame middles, the last frame, a rotated source);
// - cancel removes the partial PNG; a missing source fails with mediaOffline;
// - sampleColor (3×3 average) is within ±2/255 of the reference: the 420v decode of the same
//   frame converted with the BT.709 matrix (gamma-encoded R'G'B', colour management off);
// - freeze stills keep the decoded colours (ARCH §11.6, colour management off; QA-03 finding 3):
//   mid-grey, a mid orange and a dark grey on a BT.709-tagged clip come back within ±2/255 of the
//   matrix-only decode, at full size and scaled;
// - the cache is bounded by the tier memory budget, evicts least recently used frames and serves
//   hits without decoding.

import AVFoundation
import ImageIO
import XCTest

@testable import danaview_editor_engine

final class FreezeFrameTests: XCTestCase {
    private var roots: TempRoots!

    override func setUpWithError() throws {
        roots = try TempRoots()
    }

    override func tearDown() {
        roots?.remove()
        super.tearDown()
    }

    private func stillPath(_ name: String) -> URL {
        roots.support.appendingPathComponent("projects/p1/assets/stills/\(name).png")
    }

    private static func loadPNG(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testStillCarriesTheRequestedFrame() throws {
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        // Frame k of a 30 fps file starts at k/30 s; µs times are rounded down from it.
        for (frame, timeUs) in [(0, Int64(0)), (1, Int64(33_333)), (29, Int64(966_666)), (160, Int64(5_350_000)),
                                (239, Int64(7_966_666))] {
            let output = stillPath("f\(frame)")
            let job = FreezeFrameJob(mediaURL: url, sourceTimeUs: timeUs, output: output)
            let result = try job.run(JobControl(jobId: "f\(frame)"))
            XCTAssertEqual(result.kind, .freeze)
            XCTAssertEqual(result.asset?.path, output.path)
            XCTAssertGreaterThan(result.asset?.sizeBytes ?? 0, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.partialURL.path))
            let image = try FreezeFrameTests.loadPNG(output)
            XCTAssertEqual(image.width, 1920)
            XCTAssertEqual(image.height, 1080)
            XCTAssertEqual(FrameBarcode.read(cgImage: image).index, frame, "time \(timeUs)")
        }
    }

    func testStillAppliesThePreferredTransform() throws {
        let output = stillPath("rotated")
        _ = try FreezeFrameJob(mediaURL: try ProbeFixtures.url("rotated_90.mov"), sourceTimeUs: 1_000_000, output: output)
            .run(JobControl(jobId: "r"))
        let image = try FreezeFrameTests.loadPNG(output)
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 1280)
        // Same orientation as AVFoundation's own display-oriented decode (the generator lifts the
        // colours a little, a wrong rotation or flip differs by far more).
        let asset = AVURLAsset(url: try ProbeFixtures.url("rotated_90.mov"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let display = try generator.copyCGImage(at: CMTime(value: 1_000_001, timescale: 1_000_000), actualTime: nil)
        XCTAssertEqual(display.width, 720)
        XCTAssertLessThan(try FreezeFrameTests.meanDifference(image, display), 15)
    }

    /// Mean |Δ| (0...255) over R, G, B of two same-size images, both read as 8-bit RGBA raw values.
    private static func meanDifference(_ a: CGImage, _ b: CGImage) throws -> Double {
        func raw(_ image: CGImage) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            XCTAssertTrue(ok)
            return pixels
        }
        let pa = try raw(a), pb = try raw(b)
        XCTAssertEqual(pa.count, pb.count)
        var sum = 0.0, n = 0.0
        for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) {
            for c in 0..<3 { sum += abs(Double(pa[i + c]) - Double(pb[i + c])); n += 1 }
        }
        return n > 0 ? sum / n : 0
    }

    func testHdrSourceGivesAnSdrStill() throws {
        let output = stillPath("hlg")
        _ = try FreezeFrameJob(mediaURL: try ProbeFixtures.url("hlg_10bit_720p.mov"), sourceTimeUs: 1_000_000, output: output)
            .run(JobControl(jobId: "h"))
        let image = try FreezeFrameTests.loadPNG(output)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(FrameBarcode.read(cgImage: image).index, 30)
    }

    func testCancelLeavesNoFiles() throws {
        let output = stillPath("cancel")
        let job = FreezeFrameJob(mediaURL: try ProbeFixtures.url("frame_counter_1080p30.mp4"), sourceTimeUs: 0, output: output)
        let control = JobControl(jobId: "c")
        control.stop(.cancel)
        XCTAssertThrowsError(try job.run(control)) { error in
            XCTAssertEqual(EngineError.from(error).code, .cancelled)
        }
        job.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.partialURL.path))
    }

    func testMissingSourceFailsWithMediaOffline() {
        let job = FreezeFrameJob(mediaURL: roots.base.appendingPathComponent("missing.mp4"), sourceTimeUs: 0,
                                 output: stillPath("missing"))
        XCTAssertThrowsError(try job.run(JobControl(jobId: "m"))) { error in
            XCTAssertEqual(EngineError.from(error).code, .mediaOffline)
        }
    }

    func testFreezeJobThroughTheRegistry() throws {
        let recorder = JobEventRecorder()
        let context = try MediaJobTestSupport.context(roots, events: recorder.hub)
        let interruption = JobInterruption(center: NotificationCenter())
        let registry = JobRegistry(context: context, concurrency: 1, interruption: interruption, startInterruption: false)
        interruption.start()
        let output = stillPath("registry")
        let request = JobRequestMsg(
            kind: .freeze, media: ResolvedMediaMsg(uri: "file://x", fingerprint: "fp", isProxy: false), priority: .interactive,
            sourceTimeUs: 4_000_000, outputPath: output.path)
        var jobId: String?
        registry.start(request, mediaURL: try ProbeFixtures.url("frame_counter_1080p30.mp4"), outputURL: output) {
            jobId = try? $0.get()
        }
        let id = try XCTUnwrap(jobId)
        recorder.waitForEnd(id, test: self)
        XCTAssertEqual(recorder.done(id)?.asset?.path, output.path)
        XCTAssertEqual(FrameBarcode.read(cgImage: try FreezeFrameTests.loadPNG(output)).index, 120)
    }

    // MARK: Source-frame cache

    /// Reference R'G'B' of the source frame at [timeUs]: the 420v (video range) decode converted
    /// with the BT.709 matrix, 3×3 average around the normalized point (ARCH §13: gamma-encoded
    /// BT.709, colour management off).
    private static func referenceColor(_ url: URL, timeUs: Int64, points: [(Double, Double)]) throws -> [(Double, Double, Double)] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: timeUs + 1, timescale: 1_000_000), duration: CMTime(value: 1, timescale: 1_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var buffer: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if let image = CMSampleBufferGetImageBuffer(sample) { buffer = image; break }
        }
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        return points.map { point in
            let cx = min(w - 1, Int(point.0 * Double(w))), cy = min(h - 1, Int(point.1 * Double(h)))
            var sum = (0.0, 0.0, 0.0)
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = min(w - 1, max(0, cx + dx)), y = min(h - 1, max(0, cy + dy))
                    let yv = (Double(yBase[y * yStride + x]) - 16) / 219
                    let cb = (Double(cBase[(y / 2) * cStride + (x / 2) * 2]) - 128) / 224
                    let cr = (Double(cBase[(y / 2) * cStride + (x / 2) * 2 + 1]) - 128) / 224
                    let r = yv + 1.5748 * cr
                    let g = yv - 0.1873 * cb - 0.4681 * cr
                    let b = yv + 1.8556 * cb
                    sum.0 += min(1, max(0, r)); sum.1 += min(1, max(0, g)); sum.2 += min(1, max(0, b))
                }
            }
            return (sum.0 / 9, sum.1 / 9, sum.2 / 9)
        }
    }

    func testSampledColourMatchesTheReferenceFrame() throws {
        let cache = SourceFrameCache(tier: .high)
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        // Points in flat regions (background, barcode cells, digits area).
        let points = [(0.25, 0.5), (0.75, 0.8), (0.5, 0.3), (0.0179, 0.05), (0.0536, 0.05)]
        let reference = try FreezeFrameTests.referenceColor(url, timeUs: 5_350_000, points: points)
        for (point, expected) in zip(points, reference) {
            let sampled = try cache.sampleColor(url: url, sourceTimeUs: 5_350_000, x: point.0, y: point.1)
            XCTAssertEqual(sampled.red, expected.0, accuracy: 2.0 / 255, "red at \(point)")
            XCTAssertEqual(sampled.green, expected.1, accuracy: 2.0 / 255, "green at \(point)")
            XCTAssertEqual(sampled.blue, expected.2, accuracy: 2.0 / 255, "blue at \(point)")
            XCTAssertEqual(sampled.alpha, 1, accuracy: 1e-6)
        }
        XCTAssertEqual(cache.decodeCount, 1, "one decode serves every sample of the frame")
    }

    /// Writes a 1 s 30 fps H.264 clip (BT.709 tagged) of vertical stripes in [colors] (0xRRGGBB).
    private func makeStripeClip(_ url: URL, colors: [Int], width: Int = 640, height: Int = 360) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 30],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let c = colors[min(colors.count - 1, x * colors.count / width)]
                    let p = y * bpr + x * 4
                    base[p] = UInt8(c & 0xFF); base[p + 1] = UInt8((c >> 8) & 0xFF)
                    base[p + 2] = UInt8((c >> 16) & 0xFF); base[p + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    /// The 8-bit R, G, B of [image] at pixel ([x], [y]) (top-left origin), read in the image's own
    /// space (no conversion).
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let color = try SourceFrameCache.averageColor(
            of: image, x: (Double(x) + 0.5) / Double(image.width), y: (Double(y) + 0.5) / Double(image.height))
        return [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    func testFreezeStillsKeepTheDecodedColours() throws {
        let colors = [0x808080, 0xC08040, 0x202020, 0xFF0000, 0x00FF00, 0x0000FF]
        let url = roots.base.appendingPathComponent("stripes.mp4")
        try makeStripeClip(url, colors: colors)
        let points = colors.indices.map { ((Double($0) + 0.5) / Double(colors.count), 0.5) }
        let reference = try FreezeFrameTests.referenceColor(url, timeUs: 333_333, points: points)
        let output = stillPath("colours")
        _ = try FreezeFrameJob(mediaURL: url, sourceTimeUs: 333_333, output: output).run(JobControl(jobId: "colour"))
        let still = try FreezeFrameTests.loadPNG(output)
        XCTAssertEqual(still.width, 640)
        XCTAssertEqual(still.height, 360)
        let scaled = try SourceFrameCache(tier: .high).frame(url: url, sourceTimeUs: 333_333, maxLongSide: 320)
        XCTAssertEqual(scaled.width, 320)
        XCTAssertEqual(scaled.height, 180)
        var worst = 0
        for (i, (point, expected)) in zip(points, reference).enumerated() {
            let want = [expected.0, expected.1, expected.2].map { Int(($0 * 255).rounded()) }
            for image in [still, scaled] {
                let got = try FreezeFrameTests.pixel(image, Int(point.0 * Double(image.width)), image.height / 2)
                for ch in 0..<3 {
                    worst = max(worst, abs(got[ch] - want[ch]))
                    XCTAssertEqual(got[ch], want[ch], accuracy: 2, "colour #\(String(colors[i], radix: 16)) channel \(ch) at \(image.width) px")
                }
            }
        }
        // The encode itself is close to the painted colours (mid-grey 128 is not lifted to 139).
        let grey = try FreezeFrameTests.pixel(still, 640 / 12, 180)
        XCTAssertEqual(grey[0], 128, accuracy: 3)
        print("FreezeColour|worstDelta=\(worst)")
    }

    func testAverageColourOfASyntheticImage() throws {
        // 4x4 image: left half red, right half blue; a 3x3 window at the left edge is all red.
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let p = (y * 4 + x) * 4
                pixels[p] = x < 2 ? 255 : 0
                pixels[p + 2] = x < 2 ? 0 : 255
                pixels[p + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let left = try SourceFrameCache.averageColor(of: image, x: 0, y: 0.5)
        XCTAssertEqual(left.red, 2.0 / 3, accuracy: 1e-6)   // window x 0..2: red, red, blue
        XCTAssertEqual(left.blue, 1.0 / 3, accuracy: 1e-6)
        let right = try SourceFrameCache.averageColor(of: image, x: 0.99, y: 0.99)
        XCTAssertEqual(right.blue, 2.0 / 3, accuracy: 1e-6)
    }

    func testShowSourceFrameScalesAndHitsTheCache() throws {
        let cache = SourceFrameCache(tier: .low)
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        let missStarted = Date()
        let image = try cache.frame(url: url, media: "fc", sourceTimeUs: 2_000_000, maxLongSide: 640)
        let missTime = Date().timeIntervalSince(missStarted)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 640)
        XCTAssertEqual(FrameBarcode.read(cgImage: image).index, 60)
        let started = Date()
        _ = try cache.frame(url: url, media: "fc", sourceTimeUs: 2_000_000, maxLongSide: 640)
        // DV_PERF_STRICT=1: 20 ms; loose: 4×, or half the decode measured above.
        PerfGate.assertAtMost(Date().timeIntervalSince(started), 0.02, baseline: missTime / 2, "cache hit")
        XCTAssertEqual(cache.decodeCount, 1)
        let still = try cache.lookStill(url: url, media: "fc", sourceTimeUs: 2_000_000, heightPx: 120)
        XCTAssertEqual(still.height, 120)
        XCTAssertEqual(still.width, 213)
    }

    func testCacheIsBoundedByTheTierBudget() throws {
        for tier in [DeviceTierMsg.minimal, .low, .mid, .high] {
            XCTAssertGreaterThan(SourceFrameCache.budgetBytes(for: tier), 0)
        }
        XCTAssertLessThan(SourceFrameCache.budgetBytes(for: .minimal), SourceFrameCache.budgetBytes(for: .high))
        // Full 1080p RGBA frames are ~8 MB: the 16 MB minimal budget holds at most two.
        let cache = SourceFrameCache(tier: .minimal)
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        for k in 0..<5 {
            _ = try cache.frame(url: url, media: "fc", sourceTimeUs: Int64(k) * 1_000_000)
            XCTAssertLessThanOrEqual(cache.totalBytes, cache.budgetBytes)
        }
        XCTAssertLessThanOrEqual(cache.count, 2)
        // The most recent frame is a hit, the oldest was evicted.
        let decodes = cache.decodeCount
        _ = try cache.frame(url: url, media: "fc", sourceTimeUs: 4_000_000)
        XCTAssertEqual(cache.decodeCount, decodes)
        _ = try cache.frame(url: url, media: "fc", sourceTimeUs: 0)
        XCTAssertEqual(cache.decodeCount, decodes + 1)
        cache.remove(media: "fc")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testFrameLargerThanTheBudgetIsReturnedButNotKept() throws {
        let cache = SourceFrameCache(budgetBytes: 1_000_000)
        let image = try cache.frame(url: try ProbeFixtures.url("frame_counter_1080p30.mp4"), sourceTimeUs: 0)
        XCTAssertEqual(image.width, 1920)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
    }
}
