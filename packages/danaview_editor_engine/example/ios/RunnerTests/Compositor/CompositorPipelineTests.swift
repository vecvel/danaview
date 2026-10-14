// OWNER: IOS-10
//
// DVCompositor through AVFoundation and the paused paths (BUILD_PLAN IOS-10):
// - grid_cuts_30fps.json composed for every frame through AVAssetReader + AVAssetReaderVideoComposition-
//   Output (the export path, render size 960×540): stamp danaview.frame == k, the drawn layers equal
//   expected_active.json and the base / PiP barcodes are the source frames of ARCH §11.5 (D-35);
// - the export variant (output fps 24 over the 30 fps grid, render size = output);
// - a 90°-rotated source is displayed upright;
// - redraw-from-cache: param patches, transients and editing modes re-render the cached sources
//   (≤ 30 ms at 1080p), matte and cropSource modes, typewriter reveal, cancellation (compositor
//   generation counter, coalescing redraw requests), compose time at 1080p with 2 layers + LUT +
//   sprite (simulator numbers; device numbers are QA-04's).

import AVFoundation
import CoreImage
import XCTest

@testable import danaview_editor_engine

final class CompositorPipelineTests: XCTestCase {
    private typealias Support = CompositorTestSupport

    // MARK: Grid cuts

    func testGridCutsComposeTheExpectedLayersAndFramesAtEveryFrame() async throws {
        let plan = try CompositionTestSupport.plan("grid_cuts_30fps.json")
        let expected = try CompositionTestSupport.json(.core, "render_plans/contract/grid_cuts_30fps.expected_active.json")
        let table = try XCTUnwrap(expected["frames"] as? [[String: Any]])
        let snapshot = ParamSnapshot(plan: plan)
        let session = try Support.session(snapshot: snapshot)
        let drawn = CompositorLocked<[Int64: [String]]>([:])
        session.onComposed = { f in drawn.mutate { $0[f.k] = f.drawn } }
        let built = try await CompositionBuilder.build(
            plan: plan, options: try Support.buildOptions(session: session, renderSize: CGSize(width: 960, height: 540)))

        var stamps: [Int64] = []
        var problems: [String] = []
        try Support.readFrames(built) { k, pts, pb in
            guard let k else {
                problems.append("unstamped frame at \(pts.seconds)")
                return
            }
            stamps.append(k)
            XCTAssertEqual(CMTimeCompare(pts, CMTime(value: k, timescale: 30)), 0, "frame \(k) pts")
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 960)
            let layers = snapshot.evaluate(atFrame: k)
            // Base layer: full canvas, barcode band in the top 10 %.
            if let base = layers.first(where: { $0.seq == 0 }) {
                let want = Self.displayedFrame(base, fps: 30)
                let got = Support.barcode(pb, region: FrameBarcodeRegion(x: 0, y: 0, width: 960, height: 540))
                if got != want { problems.append("frame \(k): base barcode \(String(describing: got)) != \(want)") }
            }
            // PiP (seq 1, 640×360 at (1440, 270) → render (560…880, 45…225)), 25 fps source.
            if let pip = layers.first(where: { $0.seq == 1 }) {
                let want = Self.displayedFrame(pip, fps: 25)
                let got = Support.barcode(pb, region: FrameBarcodeRegion(x: 560, y: 45, width: 320, height: 180))
                if got != want { problems.append("frame \(k): PiP barcode \(String(describing: got)) != \(want)") }
            }
        }
        XCTAssertEqual(stamps, Array(0..<90), "every frame composed once, in order")
        let composed = drawn.value
        for f in table {
            let k = (f["k"] as! NSNumber).int64Value
            XCTAssertEqual(composed[k], f["active"] as? [String], "drawn layers at frame \(k)")
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Greatest source frame with PTS ≤ s + 500 µs on a constant-rate source (ARCH §11.5).
    private static func displayedFrame(_ layer: EvaluatedLayer, fps: Int) -> Int {
        Int(((layer.sourceUs! + 500) * Double(fps) / 1_000_000 + 1e-9).rounded(.down))
    }

    func testExportVariantRendersAtTheExportRateAndSize() async throws {
        var plan = try CompositionTestSupport.plan("grid_cuts_30fps.json")
        plan.target = .export
        plan.canvas = PlanCanvas(w: 640, h: 360, fps: 24, gridFps: 30, bg: plan.canvas.bg)
        // Scale the layers into the 640×360 output (the compiler letterboxes; here the canvas just shrinks).
        plan.layers = plan.layers.map { l in
            var l = l
            let k = 640.0 / 1920
            l.base = l.base.map { PlanSize(w: $0.w * k, h: $0.h * k) }
            if let cx = l.xf.cx { l.xf.cx = cx * k }
            if let cy = l.xf.cy { l.xf.cy = cy * k }
            return l
        }
        let snapshot = ParamSnapshot(plan: plan)
        let session = try Support.session(snapshot: snapshot)
        let built = try await CompositionBuilder.build(plan: plan, options: try Support.buildOptions(session: session))
        XCTAssertEqual(built.videoComposition.frameDuration, CMTime(value: 1, timescale: 24))
        XCTAssertEqual(built.videoComposition.renderSize, CGSize(width: 640, height: 360))
        var stamps: [Int64] = []
        var problems: [String] = []
        try Support.readFrames(built) { k, pts, pb in
            guard let k else { return }
            stamps.append(k)
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 640)
            if let base = snapshot.evaluate(atFrame: k).first(where: { $0.seq == 0 }) {
                let want = Self.displayedFrame(base, fps: 30)
                let got = Support.barcode(pb, region: FrameBarcodeRegion(x: 0, y: 0, width: 640, height: 360))
                if got != want { problems.append("export frame \(k): \(String(describing: got)) != \(want)") }
            }
        }
        XCTAssertEqual(stamps, Array(0..<72), "3 s at 24 fps")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testRotatedSourceIsDisplayedUpright() async throws {
        let plan = RenderPlan(
            rev: 1, target: .preview, canvas: PlanCanvas(w: 720, h: 1280, fps: 30), durUs: 1_000_000,
            assets: ["md_rot": PlanAsset(kind: .video, uri: "file:///fixtures/rotated_90.mov", fp: "r90", w: 720, h: 1280, rot: 90, durUs: 3_000_000)],
            layers: [
                PlanLayer(id: "it_rot#v", z: 10, seq: 0, t0: 0, t1: 1_000_000, kind: .media, asset: "md_rot",
                          map: [MapSegment(0, 1_000_000, 0, 1_000_000)], base: PlanSize(w: 720, h: 1280)),
            ],
            audio: [])
        let session = try Support.session(snapshot: ParamSnapshot(plan: plan))
        let built = try await CompositionBuilder.build(
            plan: plan, options: try Support.buildOptions(session: session, renderSize: CGSize(width: 360, height: 640)))
        var read = 0
        try Support.readFrames(built, limit: 10) { k, _, pb in
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 360)
            XCTAssertEqual(Support.barcode(pb).map(Int64.init), k, "upright barcode at frame \(String(describing: k))")
            read += 1
        }
        XCTAssertEqual(read, 10)
    }

    // MARK: Redraw from cache

    func testRedrawFromCacheAppliesParamChangesWithin30ms() async throws {
        let plan = try CompositionTestSupport.plan("grid_cuts_30fps.json")
        let snapshot = ParamSnapshot(plan: plan)
        let session = try Support.session(snapshot: snapshot)
        let built = try await CompositionBuilder.build(plan: plan, options: try Support.buildOptions(session: session))
        try Support.readFrames(built, limit: 38) { _, _, _ in }
        let entry = try XCTUnwrap(session.redraw.last)
        XCTAssertEqual(entry.renderSize, CGSize(width: 1920, height: 1080))
        let k = entry.k
        XCTAssertGreaterThan(entry.sources.buffers.count, 0)

        // Unchanged params: the redraw reproduces the composed frame (same path).
        let first = try session.redraw.redraw()
        XCTAssertEqual(DVRenderSession.frameIndex(of: first.buffer), k)
        XCTAssertEqual(Support.barcode(first.buffer, region: FrameBarcodeRegion(x: 0, y: 0, width: 1920, height: 1080)).map(Int64.init), k)

        // Transients and param patches: alternate the base layer's exposure and the PiP opacity.
        let baseId = try XCTUnwrap(snapshot.activeLayers(atFrame: k).first { $0.seq == 0 }).id
        var times: [Double] = []
        var lumas: [Double] = []
        for i in 0..<30 {
            let exposure = i % 2 == 0 ? 0.6 : -0.6
            var fx = PlanEffects()
            fx.adj = PlanAdjust(values: [exposure, 0, 0, 0, 0, 0, 0, 0])
            session.snapshots.update {
                $0.applying(PlanTransient(item: DVEditingMode.itemId(ofLayer: baseId), layers: [TransientLayer(id: baseId, fx: fx)]))
            }
            let r = try session.redraw.redraw()
            times.append(r.renderMs)
            XCTAssertEqual(DVRenderSession.frameIndex(of: r.buffer), k)
            lumas.append(Self.meanLuma(r.buffer, x: 200, y: 700, size: 40))
        }
        for i in 1..<lumas.count {
            if i % 2 == 1 { XCTAssertLessThan(lumas[i] + 10, lumas[i - 1], "darker after exposure −0.6 (redraw \(i))") }
        }
        // A param-only patch (new plan revision, same layers) clears the transient and redraws.
        var patched = plan
        patched.rev += 1
        patched.layers = plan.layers.map { l in
            var l = l
            if l.id == baseId { l.xf.op = 0.5 }
            return l
        }
        session.snapshots.update { $0.replacingPlan(patched, touchedLayerIds: [baseId]) }
        let half = try session.redraw.redraw()
        XCTAssertLessThan(Self.meanLuma(half.buffer, x: 200, y: 700, size: 40), Self.meanLuma(first.buffer, x: 200, y: 700, size: 40) * 0.7)

        times.sort()
        let p50 = times[times.count / 2]
        let p95 = times[Int(Double(times.count) * 0.95) - 1]
        print(String(format: "IOS-10 redraw-from-cache 1080p (%d sources): p50 %.1f ms, p95 %.1f ms", entry.sources.buffers.count, p50, p95))
        XCTAssertLessThanOrEqual(p50, 30, "redraw-from-cache p50 ≤ 30 ms")
    }

    private static func meanLuma(_ pb: CVPixelBuffer, x: Int, y: Int, size: Int) -> Double {
        let (w, _, px) = Support.rgba(pb)
        var sum = 0.0
        for j in y..<(y + size) {
            for i in x..<(x + size) {
                let o = (j * w + i) * 4
                sum += 0.2126 * Double(px[o]) + 0.7152 * Double(px[o + 1]) + 0.0722 * Double(px[o + 2])
            }
        }
        return sum / Double(size * size)
    }

    func testRedrawRequestsCoalesceLatestWins() throws {
        let (session, _) = try Self.quadrantSession()
        session.redraw.store(RedrawCache.Entry(k: 0, compositionTime: .zero, sources: try Self.quadrantSources(), renderSize: CGSize(width: 640, height: 360)))
        let gate = DispatchSemaphore(value: 0)
        session.redraw.queue.async { gate.wait() }
        let results = CompositorLocked<[Int: Bool]>([:])
        let done = expectation(description: "redraws")
        done.expectedFulfillmentCount = 5
        for i in 0..<5 {
            session.redraw.requestRedraw { r in
                results.mutate { $0[i] = (try? r?.get()) != nil }
                done.fulfill()
            }
        }
        gate.signal()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(results.value, [0: false, 1: false, 2: false, 3: false, 4: true], "only the latest request renders")
    }

    func testCompositorCancelsQueuedRequestsByGeneration() {
        let compositor = DVCompositor()
        let gate = DispatchSemaphore(value: 0)
        let cancelled = CompositorLocked<[Int: Bool]>([:])
        let done = expectation(description: "jobs")
        done.expectedFulfillmentCount = 4
        // Holds the render queue busy (may itself be running or cancelled; not recorded).
        compositor.enqueue(qos: .userInitiated) { _ in gate.wait() }
        for i in 1...3 {
            compositor.enqueue(qos: .userInitiated) { c in
                cancelled.mutate { $0[i] = c }
                done.fulfill()
            }
        }
        compositor.cancelAllPendingVideoCompositionRequests()
        compositor.enqueue(qos: .userInitiated) { c in
            cancelled.mutate { $0[4] = c }
            done.fulfill()
        }
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cancelled.value, [1: true, 2: true, 3: true, 4: false])
        XCTAssertEqual(compositor.currentGeneration, 1)
        XCTAssertFalse(compositor.supportsHDRSourceFrames)
        XCTAssertEqual(
            compositor.sourcePixelBufferAttributes?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType, kCVPixelFormatType_32BGRA)
    }

    // MARK: Editing modes

    /// Canvas 640×360: item A (track 1, yellow) fills the canvas; item B (track 2, four quadrants: red
    /// TL, green TR, blue BL, white BR) is a 320×180 PiP at (480, 90) cropped to its TR quadrant (green)
    /// with an elliptic mask of half its size.
    private static func quadrantSession() throws -> (DVRenderSession, RenderPlan) {
        var mask = PlanMask(shape: .ellipse)
        mask.w = 0.5
        mask.h = 0.5
        var fx = PlanEffects()
        fx.mask = mask
        let plan = RenderPlan(
            rev: 1, target: .preview, canvas: PlanCanvas(w: 640, h: 360, fps: 30), durUs: 1_000_000,
            assets: [
                "md_a": PlanAsset(kind: .video, uri: "file:///a.mov", fp: "a", w: 64, h: 36),
                "md_b": PlanAsset(kind: .video, uri: "file:///b.mov", fp: "b", w: 64, h: 36),
            ],
            layers: [
                PlanLayer(id: "it_a#v", z: 10, seq: 0, t0: 0, t1: 1_000_000, kind: .media, asset: "md_a",
                          map: [MapSegment(0, 1_000_000, 0, 1_000_000)], base: PlanSize(w: 640, h: 360)),
                PlanLayer(id: "it_b#v", z: 10010, seq: 1, t0: 0, t1: 1_000_000, kind: .media, asset: "md_b",
                          map: [MapSegment(0, 1_000_000, 0, 1_000_000)], base: PlanSize(w: 320, h: 180),
                          crop: PlanCrop(l: 0.5, t: 0, r: 1, b: 0.5), xf: PlanTransform(cx: 480, cy: 90), fx: fx),
            ],
            audio: [])
        return (try Support.session(snapshot: ParamSnapshot(plan: plan)), plan)
    }

    private static func quadrantSources() throws -> DVRenderSession.Sources {
        let context = Kernels.makeContext()
        func solid(_ c: CIColor, _ r: CGRect) -> CIImage { CIImage(color: c).cropped(to: r) }
        let yellow = solid(CIColor(red: 1, green: 1, blue: 0), CGRect(x: 0, y: 0, width: 64, height: 36))
        // CI is y up: the top half is y ∈ [18, 36).
        let quads = solid(CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: 18, width: 32, height: 18))
            .composited(over: solid(CIColor(red: 0, green: 1, blue: 0), CGRect(x: 32, y: 18, width: 32, height: 18)))
            .composited(over: solid(CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: 32, height: 18)))
            .composited(over: solid(CIColor(red: 1, green: 1, blue: 1), CGRect(x: 32, y: 0, width: 32, height: 18)))
        return DVRenderSession.Sources(
            buffers: [1: try Support.pixelBuffer(from: yellow, context: context), 2: try Support.pixelBuffer(from: quads, context: context)],
            trackIDByLayer: ["it_a#v": 1, "it_b#v": 2])
    }

    private static func pixel(_ px: [UInt8], w: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * w + x) * 4
        return Array(px[o..<(o + 3)])
    }

    private static func near(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 3) -> Bool {
        zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    func testNormalMatteAndCropSourceModes() throws {
        let (session, plan) = try Self.quadrantSession()
        let snapshot = ParamSnapshot(plan: plan)
        let sources = try Self.quadrantSources()
        func render(_ mode: DVEditingMode) throws -> [UInt8] {
            let pb = try Support.pixelBuffer(width: 640, height: 360)
            try session.render(snapshot: snapshot, frame: 0, sources: sources, mode: mode, into: pb)
            return Support.rgba(pb).px
        }
        // Normal: yellow canvas, green PiP inside the ellipse, yellow outside it.
        let normal = try render(.normal)
        XCTAssertTrue(Self.near(Self.pixel(normal, w: 640, 100, 300), [255, 255, 0]))
        XCTAssertTrue(Self.near(Self.pixel(normal, w: 640, 480, 90), [0, 255, 0]))
        XCTAssertTrue(Self.near(Self.pixel(normal, w: 640, 330, 10), [255, 255, 0]), "outside the ellipse")

        // Matte(B): only B's alpha after its mask, as grey: white inside the ellipse, black elsewhere.
        let matte = try render(.matte(item: "it_b"))
        XCTAssertTrue(Self.near(Self.pixel(matte, w: 640, 480, 90), [255, 255, 255]))
        XCTAssertTrue(Self.near(Self.pixel(matte, w: 640, 330, 10), [0, 0, 0]), "masked out")
        XCTAssertTrue(Self.near(Self.pixel(matte, w: 640, 100, 300), [0, 0, 0]), "other items hidden")

        // cropSource(B): B's whole source, untransformed, fitted to the canvas (64×36 → 640×360).
        let crop = try render(.cropSource(item: "it_b"))
        XCTAssertTrue(Self.near(Self.pixel(crop, w: 640, 160, 90), [255, 0, 0]), "top left red")
        XCTAssertTrue(Self.near(Self.pixel(crop, w: 640, 480, 90), [0, 255, 0]), "top right green")
        XCTAssertTrue(Self.near(Self.pixel(crop, w: 640, 160, 270), [0, 0, 255]), "bottom left blue")
        XCTAssertTrue(Self.near(Self.pixel(crop, w: 640, 480, 270), [255, 255, 255]), "bottom right white")

        // The session mode drives redraws.
        session.redraw.store(RedrawCache.Entry(k: 0, compositionTime: .zero, sources: sources, renderSize: CGSize(width: 640, height: 360)))
        session.mode = .matte(item: "it_b")
        let redrawn = Support.rgba(try session.redraw.redraw(snapshot: snapshot).buffer).px
        XCTAssertTrue(Self.near(Self.pixel(redrawn, w: 640, 100, 300), [0, 0, 0]))
        session.mode = .normal
        let still = try session.redraw.still(snapshot: snapshot, heightPx: 90)
        XCTAssertEqual(still.height, 90)
        XCTAssertEqual(still.width, 160)
    }

    // MARK: Typewriter

    func testTypewriterRevealGrowsGlyphByGlyph() throws {
        let golden = try XCTUnwrap(try Support.goldens().first { $0.name == "api03_typewriter" })
        let assets = Support.GoldenAssets(root: try Support.imagesRoot(), sources: golden.sources)
        let snapshot = ParamSnapshot(plan: golden.plan)
        let session = try Support.session(snapshot: snapshot, assets: assets)
        var counts: [Int] = []
        for k in stride(from: Int64(0), through: 33, by: 3) {
            let pb = try Support.pixelBuffer(width: 256, height: 144)
            let out = try session.render(snapshot: snapshot, frame: k, sources: .none, mode: .normal, into: pb)
            let px = Support.rgba(pb).px
            let bg: [UInt8] = [0x20, 0x30, 0x40]
            var n = 0
            for i in 0..<(256 * 144) where !Self.near(Array(px[(i * 4)..<(i * 4 + 3)]), bg, tolerance: 2) { n += 1 }
            counts.append(n)
            if k == 0 { XCTAssertEqual(out.drawn, ["it_bg0000000001#v"], "no glyph before the first reveal step") }
        }
        XCTAssertEqual(counts.first, 0)
        XCTAssertEqual(counts, counts.sorted(), "monotonic reveal: \(counts)")
        XCTAssertGreaterThan(Set(counts).count, 5, "glyphs appear step by step: \(counts)")
    }

    // MARK: Compose time

    func testComposeTimeAt1080pWithTwoLayersLutAndSprite() throws {
        let lut = try LutTexture.make(n: 33, rgb: KernelTestSupport.table(n: 33) { r, g, b in (g, b, r) })
        var px = [UInt8](repeating: 0, count: 1100 * 160 * 4)
        for i in stride(from: 0, to: px.count, by: 4) where (i / 4) % 7 < 4 {
            px[i] = 255
            px[i + 1] = 255
            px[i + 2] = 255
            px[i + 3] = 255
        }
        let sprite = SpriteImage(width: 1100, height: 160, scale: 1, rgba: Data(px), glyphs: nil)
        let assets = MemoryAssets(lut: lut, sprite: sprite)
        var look = PlanEffects()
        look.lut = PlanLut(asset: "lt", i: 0.8)
        look.adj = PlanAdjust(values: [0.1, 0, 0.1, 0, 0, 0.2, 0, 0])
        let plan = RenderPlan(
            rev: 1, target: .preview, canvas: PlanCanvas(w: 1920, h: 1080, fps: 30), durUs: 1_000_000,
            assets: [
                "md_a": PlanAsset(kind: .video, uri: "file:///a.mov", fp: "a", w: 1920, h: 1080),
                "md_b": PlanAsset(kind: .video, uri: "file:///b.mov", fp: "b", w: 1920, h: 1080),
                "lt": PlanAsset(kind: .lut, uri: "file:///l.vlut", fp: "l", n: 33),
                "sp": PlanAsset(kind: .sprite, uri: "file:///s.vsprite", fp: "s", sw: 1100, sh: 160, sscale: 1),
            ],
            layers: [
                PlanLayer(id: "it_a#v", z: 10, seq: 0, t0: 0, t1: 1_000_000, kind: .media, asset: "md_a",
                          map: [MapSegment(0, 1_000_000, 0, 1_000_000)], base: PlanSize(w: 1920, h: 1080), fx: look),
                PlanLayer(id: "it_b#v", z: 10010, seq: 1, t0: 0, t1: 1_000_000, kind: .media, asset: "md_b",
                          map: [MapSegment(0, 1_000_000, 0, 1_000_000)], base: PlanSize(w: 640, h: 360),
                          xf: PlanTransform(cx: 1400, cy: 300, r: 5)),
                PlanLayer(id: "it_t#v", z: 20010, t0: 0, t1: 1_000_000, kind: .sprite, asset: "sp", xf: PlanTransform(cx: 960, cy: 900)),
            ],
            audio: [])
        let snapshot = ParamSnapshot(plan: plan)
        let session = try Support.session(snapshot: snapshot, assets: assets)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 1920, y: 1080),
            "inputColor0": CIColor(red: 0.1, green: 0.3, blue: 0.6), "inputColor1": CIColor(red: 0.9, green: 0.6, blue: 0.2),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let a = try Support.pixelBuffer(from: gradient, context: session.context)
        let b = try Support.pixelBuffer(from: gradient.applyingFilter("CIColorInvert"), context: session.context)
        let sources = DVRenderSession.Sources(buffers: [1: a, 2: b], trackIDByLayer: ["it_a#v": 1, "it_b#v": 2])
        let out = try Support.pixelBuffer(width: 1920, height: 1080)
        for _ in 0..<5 { try session.render(snapshot: snapshot, frame: 0, sources: sources, mode: .normal, into: out) }
        var times: [Double] = []
        for k in 0..<30 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = try session.render(snapshot: snapshot, frame: Int64(k), sources: sources, mode: .normal, into: out)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            XCTAssertEqual(r.drawn, ["it_a#v", "it_b#v", "it_t#v"])
        }
        times.sort()
        let p50 = times[times.count / 2]
        print(String(format: "IOS-10 compose 1080p, 2 layers + LUT + sprite: p50 %.1f ms, p90 %.1f ms (target ≤ 8 ms mid on device)",
                     p50, times[Int(Double(times.count) * 0.9) - 1]))
        XCTAssertLessThan(p50, 30, "simulator compose budget (device target 8 ms is QA-04's)")
    }
}

/// In-memory LUT and sprite content.
private final class MemoryAssets: LayerAssetSource {
    let lutTexture: LutTexture
    let spriteImage: SpriteImage

    init(lut: LutTexture, sprite: SpriteImage) {
        lutTexture = lut
        spriteImage = sprite
    }

    func lut(id: String, asset: PlanAsset) -> LutTexture? { lutTexture }
    func sprite(id: String, asset: PlanAsset) -> SpriteImage? { spriteImage }
    func image(id: String, asset: PlanAsset, maxLongSide: Int) -> CIImage? { nil }
}

/// A value guarded by a lock (test bookkeeping across queues).
final class CompositorLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        _value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func mutate(_ f: (inout T) -> Void) {
        lock.lock()
        f(&_value)
        lock.unlock()
    }
}
