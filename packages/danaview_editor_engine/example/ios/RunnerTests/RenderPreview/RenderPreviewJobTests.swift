// OWNER: IOS-19
//
// IOS-19 acceptance, renderer side (ARCH D-45(A), §12.3 `renderPreview`):
// - a rendered range matches the live composition frame by frame: barcodes exact (base and every
//   PiP slot) and luma SSIM ≥ 0.99 at the preview render size;
// - the file is H.264, video only, every frame a sync sample, one frame per output frame on the
//   project grid, at the preview render size (the canvas fitted to maxPreviewLongSide);
// - cancel deletes the partial file (mid-render and while thermally paused); a failure too;
// - thermal `serious` pauses the render, which then completes;
// - the service queues the job on the JobRegistry (job events, result asset) and refuses
//   export or invalid plans (`planInvalid`).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class RenderPreviewJobTests: XCTestCase {
    private var harness: RenderPreviewHarness!

    override func setUpWithError() throws {
        harness = try RenderPreviewHarness()
    }

    override func tearDown() {
        harness?.remove()
        harness = nil
    }

    private var paths: Paths { harness.paths }

    private func job(_ plan: RenderPlan, output: URL? = nil, maxLongSide: Int = 1280,
                     configure: ((inout RenderPreviewOptions) -> Void)? = nil) -> RenderPreviewJob {
        var options = RenderPreviewFixtures.options(paths, maxLongSide: maxLongSide)
        configure?(&options)
        return RenderPreviewJob(plan: plan, outputURL: output ?? RenderPreviewFixtures.renderURL(paths), options: options)
    }

    // MARK: Parity with the live composition

    private func assertMatchesLive(_ full: RenderPlan, pips: Int, maxLongSide: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = RenderPreviewFixtures.rangeStartUs
        let b = RenderPreviewFixtures.rangeEndUs
        let range = RenderPreviewFixtures.cut(full, a, b)
        XCTAssertEqual(PlanValidator.validate(range).map(\.code), [], "range plan is valid", file: file, line: line)
        let j = job(range, maxLongSide: maxLongSide)
        let result = try harness.run(j)
        XCTAssertEqual(result.kind, .renderPreview, file: file, line: line)
        XCTAssertEqual(result.asset?.path, j.outputURL.path, file: file, line: line)
        XCTAssertEqual(result.asset?.durationUs, b - a, file: file, line: line)
        XCTAssertGreaterThan(result.asset?.sizeBytes ?? 0, 0, file: file, line: line)

        let grid = full.canvas.outputGrid
        let k0 = grid.frameIndexOf(a)
        let k1 = grid.frameIndexOf(b)
        let rendered = try RenderPreviewCheck.fileFrames(j.outputURL, pips: pips)
        XCTAssertEqual(rendered.frames.count, Int(k1 - k0), "one frame per output frame", file: file, line: line)
        XCTAssertEqual(CGSize(width: rendered.w, height: rendered.h), j.renderSize, "preview render size", file: file, line: line)

        let live = try RenderPreviewCheck.compose(full, size: j.renderSize, paths: paths, pips: pips, range: k0..<k1)
        defer { live.built.releaseMedia() }
        XCTAssertEqual(live.frames.map(\.k), Array(k0..<k1), file: file, line: line)
        var worst = 1.0
        for (i, r) in rendered.frames.enumerated() {
            let k = k0 + Int64(i)
            XCTAssertEqual(r.barcodes, RenderPreviewCheck.expected(k, pips: pips), "rendered frame \(i) (output \(k))", file: file, line: line)
            XCTAssertEqual(live.frames[i].barcodes, RenderPreviewCheck.expected(k, pips: pips), "live frame \(k)", file: file, line: line)
            let s = RenderPreviewCheck.ssim(r.luma, live.frames[i].luma, w: rendered.w, h: rendered.h)
            worst = min(worst, s)
            XCTAssertGreaterThanOrEqual(s, 0.99, "SSIM of frame \(k)", file: file, line: line)
        }
        print("IOS-19 parity \(rendered.w)x\(rendered.h) pips \(pips): worst SSIM \(String(format: "%.4f", worst))")
    }

    func testRenderedRangeMatchesLiveCompositionFrameByFrame() throws {
        try assertMatchesLive(try RenderPreviewFixtures.plan(), pips: 4, maxLongSide: 1280)
    }

    func testRenderedChromaKeyRangeMatchesLiveComposition() throws {
        try assertMatchesLive(RenderPreviewFixtures.chromaKeyed(try RenderPreviewFixtures.plan(pips: 3)), pips: 3, maxLongSide: 1280)
    }

    func testRenderSizeFollowsTheTierPreviewLongSide() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        let j = job(plan, maxLongSide: 480)
        XCTAssertEqual(j.renderSize, CGSize(width: 480, height: 270))
        _ = try harness.run(j)
        let facts = try MediaJobTestSupport.videoFacts(j.outputURL)
        XCTAssertEqual(facts.width, 480)
        XCTAssertEqual(facts.height, 270)
    }

    // MARK: File format

    func testFileIsIntraOnlyH264VideoOnlyOnTheFrameGrid() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 400_000, 1_200_000)
        let j = job(plan)
        _ = try harness.run(j)
        let facts = try MediaJobTestSupport.videoFacts(j.outputURL)
        XCTAssertEqual(ExportConformance.fourCC(facts.codec), "avc1")
        XCTAssertEqual(facts.sync.count, 20)
        XCTAssertTrue(facts.sync.allSatisfy { $0 }, "every frame is a sync sample")
        let grid = FrameGrid(RenderPreviewFixtures.fps)
        XCTAssertEqual(facts.ptsUs, (0..<20).map { grid.timeOfFrame(Int64($0)) }, "frames on the project grid")
        let asset = AVURLAsset(url: j.outputURL)
        let audio = try MediaBlocking.await { try await asset.loadTracks(withMediaType: .audio) }
        XCTAssertTrue(audio.isEmpty, "video only")
        XCTAssertEqual(harness.renderFiles(), [j.outputURL.lastPathComponent], "no partial file left")
    }

    // MARK: Cancel, failure, thermal

    func testCancelMidRenderDeletesThePartialFile() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(durUs: 4_000_000), 0, 4_000_000)
        let j = job(plan)
        var id = ""
        let registry = harness.registry
        let partialSeen = NSLock()
        var sawPartial = false
        j.onFrame = { n in
            guard n == 5 else { return }
            partialSeen.lock()
            sawPartial = FileManager.default.fileExists(atPath: j.partialURL.path)
            partialSeen.unlock()
            registry.cancel(jobId: id)
        }
        id = registry.enqueue(j, priority: .background)
        harness.recorder.waitForEnd(id, test: self)
        XCTAssertEqual(harness.recorder.failure(id)?.code, "cancelled")
        XCTAssertTrue(sawPartial, "the partial file existed while rendering")
        XCTAssertLessThan(j.framesWritten, 100, "stopped early")
        XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { self.harness.renderFiles().isEmpty }, "left: \(harness.renderFiles())")
    }

    func testThermalSeriousPausesTheRender() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        let start = Date()
        let lock = NSLock()
        var state = ProcessInfo.ThermalState.serious
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            lock.lock()
            state = .fair
            lock.unlock()
        }
        let j = job(plan) { o in
            o.thermalPollInterval = 0.05
            o.thermalState = {
                lock.lock()
                defer { lock.unlock() }
                return state
            }
        }
        _ = try harness.run(j)
        XCTAssertEqual(j.thermalPauses, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.55, "waited for the thermal state")
        XCTAssertEqual(j.framesWritten, 10)
    }

    func testCancelWhileThermallyPausedCleansUp() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        let j = job(plan) { o in
            o.thermalPollInterval = 0.02
            o.thermalState = { .critical }
        }
        let id = harness.registry.enqueue(j, priority: .interactive)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { j.thermalPauses == 1 })
        harness.registry.cancel(jobId: id)
        harness.recorder.waitForEnd(id, test: self)
        XCTAssertEqual(harness.recorder.failure(id)?.code, "cancelled")
        XCTAssertEqual(j.framesWritten, 0)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { self.harness.renderFiles().isEmpty }, "left: \(harness.renderFiles())")
    }

    func testFailureCleansUp() throws {
        var plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        for id in plan.assets.keys { plan.assets[id]?.uri = "file:///fixtures/missing_clip.mp4" }
        let j = job(plan)
        let id = harness.registry.enqueue(j, priority: .interactive)
        harness.recorder.waitForEnd(id, test: self)
        XCTAssertEqual(harness.recorder.failure(id)?.code, "mediaOffline")
        XCTAssertTrue(harness.renderFiles().isEmpty, "left: \(harness.renderFiles())")
    }

    // MARK: Service

    private func request(_ output: URL, priority: JobPriorityMsg = .background) -> JobRequestMsg {
        JobRequestMsg(
            kind: .renderPreview, media: ResolvedMediaMsg(uri: output.absoluteString, fingerprint: "render", isProxy: false),
            priority: priority, outputPath: output.path)
    }

    private func service() -> RenderPreviewJobService {
        let s = RenderPreviewJobService(context: harness.context)
        let registry = harness.registry
        s.registry = { registry }
        s.configure = { $0.resolveURL = RenderPreviewFixtures.resolve }
        return s
    }

    func testServiceQueuesTheJobOnTheRegistry() throws {
        let plan = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 400_000, 800_000)
        let output = RenderPreviewFixtures.renderURL(paths, "abc123")
        var reply: Result<String, Error>?
        service().start(request(output), plan: PlanEncoder.encode(plan), outputURL: output) { reply = $0 }
        let id = try XCTUnwrap(try reply?.get())
        harness.recorder.waitForEnd(id, test: self)
        let done = try XCTUnwrap(harness.recorder.done(id))
        XCTAssertEqual(done.kind, .renderPreview)
        XCTAssertEqual(done.asset?.path, output.path)
        XCTAssertEqual(done.asset?.durationUs, 400_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(harness.recorder.progressTimes[id, default: []].isEmpty, "progress events")
        XCTAssertEqual(harness.renderFiles(), ["abc123.mp4"])
    }

    func testServiceRefusesExportAndInvalidPlans() throws {
        let output = RenderPreviewFixtures.renderURL(paths)
        var export = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        export.target = .export
        var reply: Result<String, Error>?
        service().start(request(output), plan: PlanEncoder.encode(export), outputURL: output) { reply = $0 }
        XCTAssertThrowsError(try reply?.get()) { XCTAssertEqual(($0 as? EngineError)?.code, .planInvalid) }

        reply = nil
        service().start(request(output), plan: Data("{\"v\":1}".utf8), outputURL: output) { reply = $0 }
        XCTAssertThrowsError(try reply?.get()) { XCTAssertEqual(($0 as? EngineError)?.code, .planInvalid) }

        reply = nil
        var empty = RenderPreviewFixtures.cut(try RenderPreviewFixtures.plan(), 0, 400_000)
        empty.durUs = 10_000
        empty.layers = []
        empty.assets = [:]
        service().start(request(output), plan: PlanEncoder.encode(empty), outputURL: output) { reply = $0 }
        XCTAssertThrowsError(try reply?.get()) { XCTAssertEqual(($0 as? EngineError)?.code, .planInvalid) }
        XCTAssertEqual(harness.registry.jobCount, 0)
    }

    func testProductionServicesUseTheRenderPreviewClasses() {
        let context = EngineContext(messenger: FakeMessenger(), textures: nil, presentingViewController: { nil })
        let services = EngineServices.make(context: context)
        XCTAssertTrue(services.renderPreviews is RenderPreviewJobService)
        XCTAssertTrue(services.renderedRanges is RenderedRangeHandler)
        XCTAssertTrue(services.power is PowerStateMonitor)
    }
}
