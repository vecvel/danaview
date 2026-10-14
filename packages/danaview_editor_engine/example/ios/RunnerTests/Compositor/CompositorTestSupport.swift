// OWNER: IOS-10
//
// Helpers of the IOS-10 compositor tests: the API-03 reference goldens (engine_api/images: manifest,
// plans, synthetic sources), a LayerAssetSource over those sources, BGRA pixel buffers in and out,
// the ARCH §11.6 parity metrics (mean / p99 absolute error with layer edges excluded, SSIM) and
// fixture media for AVFoundation runs.

import AVFoundation
import CoreImage
import ImageIO
import XCTest

@testable import danaview_editor_engine

enum CompositorTestSupport {
    // MARK: Session

    static func session(snapshot: ParamSnapshot, assets: LayerAssetSource = StoreAssetSource()) throws -> DVRenderSession {
        let s = try DVRenderSession(snapshots: ParamSnapshotStore(snapshot), assets: assets, kernels: try Kernels.shared())
        s.prewarm()
        return s
    }

    /// A BGRA IOSurface/Metal-compatible pixel buffer.
    static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var attrs = DVRenderSession.pixelBufferAttributes as [String: Any]
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return try XCTUnwrap(pb)
    }

    /// RGBA8 bytes (top row first) of a BGRA buffer.
    static func rgba(_ pb: CVPixelBuffer) -> (w: Int, h: Int, px: [UInt8]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * row + x * 4
                let o = (y * w + x) * 4
                out[o] = base[s + 2]
                out[o + 1] = base[s + 1]
                out[o + 2] = base[s]
                out[o + 3] = base[s + 3]
            }
        }
        return (w, h, out)
    }

    /// A BGRA buffer filled from a CIImage (y up, extent at the origin) through a plain context.
    static func pixelBuffer(from image: CIImage, context: CIContext) throws -> CVPixelBuffer {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        let pb = try pixelBuffer(width: w, height: h)
        context.render(image, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        return pb
    }

    /// [display] (display-oriented) rotated back to how a decoder delivers a source whose asset has
    /// `rot` = [rotation] (the compositor rotates it to display orientation again); extent at the origin.
    static func encoded(_ display: CIImage, rotation: Int) -> CIImage {
        var out = display
        switch ((rotation % 360) + 360) % 360 {
        case 90: out = display.oriented(.left)
        case 180: out = display.oriented(.down)
        case 270: out = display.oriented(.right)
        default: break
        }
        let e = out.extent
        return out.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    // MARK: PNG

    /// Premultiplied RGBA8 (top row first) of a PNG, without colour conversion.
    static func pngRGBA(_ url: URL) throws -> (w: Int, h: Int, px: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = image.width
        let h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(ok, "cannot draw \(url.lastPathComponent)")
        return (w, h, px)
    }

    /// 16-bit grey PNG samples (top row first), read raw.
    static func png16(_ url: URL) throws -> (w: Int, h: Int, values: [UInt16]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let bytes = [UInt8](data)
        let little = image.bitmapInfo.contains(.byteOrder16Little)
        let step = image.bitsPerPixel / 8
        var out = [UInt16](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = y * image.bytesPerRow + x * step
                let a = UInt16(bytes[o])
                let b = UInt16(bytes[o + 1])
                out[y * image.width + x] = little ? (b << 8 | a) : (a << 8 | b)
            }
        }
        return (image.width, image.height, out)
    }

    /// A CIImage (premultiplied, extent at the origin, no colour space) of RGBA8 top-row-first bytes.
    static func ciImage(rgba px: [UInt8], w: Int, h: Int) -> CIImage {
        CIImage(bitmapData: Data(px), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: nil)
    }

    /// Writes RGBA8 (top row first) as a PNG (debug dumps: TEST_RUNNER_DANAVIEW_PARITY_DUMP=<dir>).
    static func writePNG(_ px: [UInt8], w: Int, h: Int, to url: URL) {
        var data = px
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: Goldens

    struct GoldenFrame {
        let k: Int64
        let png: String
        let layers: [String]
    }

    struct Golden {
        let name: String
        let plan: RenderPlan
        let size: (w: Int, h: Int)
        let frames: [GoldenFrame]
        let sources: [String: [String: Any]]
    }

    static func imagesRoot() throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engineApi, "images"), "engine_api/images missing from the test bundle")
    }

    static func goldens() throws -> [Golden] {
        let root = try imagesRoot()
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("goldens.json"))) as? [String: Any])
        let list = try XCTUnwrap(manifest["goldens"] as? [[String: Any]])
        return try list.map { g in
            let name = try XCTUnwrap(g["name"] as? String)
            let planPath = try XCTUnwrap(g["plan"] as? String)
            let plan = try RenderPlanDecoder.decodePlan(Data(contentsOf: root.appendingPathComponent(planPath)))
            let size = try XCTUnwrap(g["size"] as? [Int])
            let frames = try XCTUnwrap(g["frames"] as? [[String: Any]]).map { f in
                GoldenFrame(
                    k: Int64(try XCTUnwrap(f["k"] as? Int)), png: try XCTUnwrap(f["png"] as? String),
                    layers: (f["layers"] as? [String]) ?? [])
            }
            return Golden(
                name: name, plan: plan, size: (size[0], size[1]), frames: frames,
                sources: (g["sources"] as? [String: [String: Any]]) ?? [:])
        }
    }

    /// LUT, sprite and image content of one golden's synthetic sources, and its media frames.
    final class GoldenAssets: LayerAssetSource {
        let root: URL
        let sources: [String: [String: Any]]
        private let luts = LutStore()
        private var sprites: [String: SpriteImage] = [:]
        private var images: [String: CIImage] = [:]
        private var frames: [String: CIImage] = [:]

        init(root: URL, sources: [String: [String: Any]]) {
            self.root = root
            self.sources = sources
        }

        func lut(id: String, asset: PlanAsset) -> LutTexture? {
            guard let path = sources[id]?["vlut"] as? String else { return nil }
            return try? luts.texture(for: root.appendingPathComponent(path))
        }

        func sprite(id: String, asset: PlanAsset) -> SpriteImage? {
            if let hit = sprites[id] { return hit }
            guard let png = sources[id]?["png"] as? String,
                  let (w, h, px) = try? pngRGBA(root.appendingPathComponent(png)) else { return nil }
            var glyphs: [UInt16]?
            if let g = sources[id]?["glyphs"] as? String, let map = try? png16(root.appendingPathComponent(g)) {
                glyphs = map.values
            }
            let sprite = SpriteImage(width: w, height: h, scale: Float(asset.sscale ?? 1), rgba: Data(px), glyphs: glyphs)
            sprites[id] = sprite
            return sprite
        }

        func image(id: String, asset: PlanAsset, maxLongSide: Int) -> CIImage? {
            if let hit = images[id] { return hit }
            guard let png = sources[id]?["png"] as? String, let (w, h, px) = try? pngRGBA(root.appendingPathComponent(png)) else {
                return nil
            }
            let image = ciImage(rgba: px, w: w, h: h)
            images[id] = image
            return image
        }

        /// The displayed source frame of a media layer: greatest PTS ≤ s + 500 µs on a constant-rate
        /// source at the asset's fps (ARCH §11.5).
        func media(_ layer: EvaluatedLayer) -> CIImage? {
            guard let id = layer.asset, let s = layer.sourceUs, let src = sources[id], let fps = src["fps"] as? Int,
                  let list = src["frames"] as? [String: String] else { return nil }
            let j = Int(((s + 500) * Double(fps) / 1_000_000 + 1e-9).rounded(.down))
            let key = "\(id)#\(j)"
            if let hit = frames[key] { return hit }
            guard let png = list["\(j)"], let (w, h, px) = try? pngRGBA(root.appendingPathComponent(png)) else { return nil }
            let image = ciImage(rgba: px, w: w, h: h)
            frames[key] = image
            return image
        }
    }

    // MARK: Parity metrics

    struct Parity {
        /// Largest per-channel mean |Δ| (RGB, 0…1).
        let mean: Double
        /// 99th percentile |Δ| over RGB samples.
        let p99: Double
        /// Mean SSIM of luma over 8×8 windows without edge pixels.
        let ssim: Double
        let compared: Int
        let excluded: Int
    }

    /// Pixels within 1.5 px of a placed layer edge (the reference does not antialias edges).
    static func edgeMask(snapshot: ParamSnapshot, k: Int64, w: Int, h: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: w * h)
        let canvas = snapshot.plan.canvas
        let kx = Double(w) / Double(canvas.w)
        let ky = Double(h) / Double(canvas.h)
        var segments: [((Double, Double), (Double, Double))] = []
        for layer in snapshot.evaluate(atFrame: k) {
            let base = LayerRenderer.effectiveBase(layer, plan: snapshot.plan, own: snapshot.layer(layer.id)?.base)
            let placed = EvaluatedLayer(
                id: layer.id, kind: layer.kind, asset: layer.asset, seq: layer.seq, sourceUs: layer.sourceUs, color: layer.color,
                base: base, crop: layer.crop, cx: layer.cx, cy: layer.cy, scale: layer.scale, rotation: layer.rotation,
                flipX: layer.flipX, flipY: layer.flipY, opacity: layer.opacity, adjust: layer.adjust, detail: layer.detail,
                lut: layer.lut, chroma: layer.chroma, mask: layer.mask, cmasks: layer.cmasks, reveal: layer.reveal)
            let m = placed.placement
            let corners = [(0.0, 0.0), (base.w, 0.0), (base.w, base.h), (0.0, base.h)].map { p -> (Double, Double) in
                let c = CGPoint(x: p.0, y: p.1).applying(m)
                return (Double(c.x) * kx, Double(c.y) * ky)
            }
            for i in 0..<4 { segments.append((corners[i], corners[(i + 1) % 4])) }
            for cm in layer.cmasks {
                let (c, s) = Kernels.cosSinDeg(cm.r)
                let pts = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { p -> (Double, Double) in
                    let x = p.0 * cm.w / 2
                    let y = p.1 * cm.h / 2
                    return ((cm.cx + x * c - y * s) * kx, (cm.cy + x * s + y * c) * ky)
                }
                for i in 0..<4 { segments.append((pts[i], pts[(i + 1) % 4])) }
            }
        }
        func dist(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let l2 = dx * dx + dy * dy
            var t = l2 > 0 ? ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2 : 0
            t = max(0, min(1, t))
            let x = a.0 + t * dx - p.0
            let y = a.1 + t * dy - p.1
            return (x * x + y * y).squareRoot()
        }
        for y in 0..<h {
            for x in 0..<w {
                let p = (Double(x) + 0.5, Double(y) + 0.5)
                for (a, b) in segments where dist(p, a, b) < 1.5 {
                    mask[y * w + x] = true
                    break
                }
            }
        }
        return mask
    }

    static func parity(_ got: [UInt8], _ want: [UInt8], w: Int, h: Int, exclude: [Bool]) -> Parity {
        var sums = [Double](repeating: 0, count: 3)
        var diffs: [Double] = []
        var n = 0
        for i in 0..<(w * h) where !exclude[i] {
            n += 1
            for c in 0..<3 {
                let d = abs(Double(got[i * 4 + c]) - Double(want[i * 4 + c])) / 255
                sums[c] += d
                diffs.append(d)
            }
        }
        diffs.sort()
        let p99 = diffs.isEmpty ? 0 : diffs[min(diffs.count - 1, Int((Double(diffs.count) * 0.99).rounded(.up)) - 1)]
        let mean = n == 0 ? 0 : (sums.max() ?? 0) / Double(n)
        return Parity(mean: mean, p99: p99, ssim: ssim(got, want, w: w, h: h, exclude: exclude), compared: n, excluded: w * h - n)
    }

    /// Mean SSIM of luma (0…1) over 8×8 windows (stride 4) that contain no excluded pixel.
    static func ssim(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int, exclude: [Bool]) -> Double {
        func luma(_ px: [UInt8], _ i: Int) -> Double {
            (0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])) / 255
        }
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        var total = 0.0
        var count = 0
        let win = 8
        var y = 0
        while y + win <= h {
            var x = 0
            while x + win <= w {
                var skip = false
                var ma = 0.0, mb = 0.0
                for j in y..<(y + win) {
                    for i in x..<(x + win) {
                        if exclude[j * w + i] { skip = true }
                        ma += luma(a, j * w + i)
                        mb += luma(b, j * w + i)
                    }
                }
                if !skip {
                    let n = Double(win * win)
                    ma /= n
                    mb /= n
                    var va = 0.0, vb = 0.0, cov = 0.0
                    for j in y..<(y + win) {
                        for i in x..<(x + win) {
                            let da = luma(a, j * w + i) - ma
                            let db = luma(b, j * w + i) - mb
                            va += da * da
                            vb += db * db
                            cov += da * db
                        }
                    }
                    va /= n - 1
                    vb /= n - 1
                    cov /= n - 1
                    total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                    count += 1
                }
                x += 4
            }
            y += 4
        }
        return count == 0 ? 1 : total / Double(count)
    }

    // MARK: Fixture media

    /// A fixture file of the engine media corpus.
    static func media(_ name: String) throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engine, "media/\(name)"), "media/\(name) missing from the test bundle")
    }

    /// Build options resolving every asset by the file name of its URI in the engine media corpus.
    static func buildOptions(session: DVRenderSession, renderSize: CGSize? = nil) throws -> CompositionBuildOptions {
        var o = CompositionBuildOptions(spacerDirectory: try CompositionTestSupport.spacerDirectory())
        o.renderSize = renderSize
        o.validate = false
        o.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            guard let url = TestFixtures.url(.engine, "media/\(name)") else {
                throw EngineError(.mediaOffline, "fixture missing")
            }
            return url
        }
        session.configure(&o)
        return o
    }

    /// Every composed output buffer of [built] read through AVAssetReader (the export path), with its
    /// `danaview.frame` stamp; stops after [limit] frames.
    static func readFrames(_ built: BuiltComposition, limit: Int = .max, each: (Int64?, CMTime, CVPixelBuffer) -> Void) throws {
        let reader = try AVAssetReader(asset: built.composition)
        let tracks = built.composition.tracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = built.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        XCTAssertTrue(reader.startReading(), "reader: \(String(describing: reader.error))")
        var n = 0
        while n < limit, let sample = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                each(DVRenderSession.frameIndex(of: pb), CMSampleBufferGetPresentationTimeStamp(sample), pb)
                n += 1
            }
        }
        if n < limit { XCTAssertEqual(reader.status, .completed, "reader: \(String(describing: reader.error))") }
        reader.cancelReading()
    }

    /// The barcode index in the top band of a region of a BGRA buffer.
    static func barcode(_ pb: CVPixelBuffer, region: FrameBarcodeRegion? = nil) -> Int? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let raw = UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddress(pb), count: row * h)
        let r = FrameBarcode.read(pixels: raw, width: w, height: h, bytesPerRow: row, order: .bgra, region: region)
        return r.isReadable ? r.index : nil
    }
}
