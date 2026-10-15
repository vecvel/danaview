// OWNER: FIX-IOS-PREVIEW
//
// The preview session with IOS-19's rendered ranges and IOS-12's export suspension, through
// PreviewSessionManager (ARCH D-45, §12.2 'Rendered ranges', §13.2, §14.3):
// - the manager installs the session's RenderedRangeSwap from RenderedRangeRegistry (the one
//   RenderedRangeHandler feeds), with the session's plan as `planProvider`, and removes it on
//   dispose;
// - a rendered range plays through the session: while playing, the frames inside the range are
//   drawn from the render file only (`!render-0`), the frames outside never are, every composed
//   frame's barcodes are right and the boundaries are reported; pause goes back to the full
//   composition;
// - a param patch inside the range during playback drops it and rebuilds the live composition
//   while playing; a new set of ranges during playback is picked up without a play command;
// - PlaybackStills never turns a render layer into a still;
// - export suspension (`.danaviewExportSuspendsPreview` / `.danaviewExportResumesPreview`, object:
//   the EngineContext): the player stops and its item is released, the frame stays on the texture,
//   edits and seeks are recorded; resume rebuilds the latest plan at the current frame; another
//   context's notifications are ignored; a session opened during an export starts suspended.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PreviewRenderedRangeTests: XCTestCase {
    private var harness: RenderPreviewHarness!
    private var manager: PreviewSessionManager!
    private let registry = RecordingTextureRegistry()
    private let audio = FakeAudioSession()
    private var opened: [String] = []

    override func setUpWithError() throws {
        harness = try RenderPreviewHarness()
        manager = PreviewSessionManager(context: harness.context)
        let registry = self.registry
        let audio = self.audio
        manager.makeDependencies = { context, paths in
            var d = PreviewSession.Dependencies(registry: registry, events: context.events, spacerDirectory: paths.engineAssets)
            d.resolveURL = RenderPreviewFixtures.resolve
            d.maxPreviewLongSide = 640
            d.liveDecodeBudget = 8
            d.audioSession = audio
            d.observeLifecycle = false
            return d
        }
    }

    override func tearDown() async throws {
        if let manager {
            for id in opened {
                _ = try? await call(timeout: 10) { (r: @escaping EngineReply<Void>) in manager.dispose(sessionId: id, reply: r) }
            }
        }
        manager = nil
        harness?.remove()
        harness = nil
        try await super.tearDown()
    }

    private var queue: DispatchQueue { harness.context.queues.previewControl }
    private var a: Int64 { RenderPreviewFixtures.rangeStartUs }
    private var b: Int64 { RenderPreviewFixtures.rangeEndUs }

    struct Timeout: Error {}

    /// Runs a manager call with a reply on the control queue (as the glue does).
    private func call<T>(timeout: TimeInterval = 20, _ body: @escaping (@escaping EngineReply<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let once = Locked(false)
            let finish: (Result<T, Error>) -> Void = { r in
                var first = false
                once.mutate { done in
                    first = !done
                    done = true
                }
                if first { c.resume(with: r) }
            }
            queue.async { body { finish($0) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(Timeout())) }
        }
    }

    private func onQueue<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    private func open(_ plan: RenderPlan) async throws -> (id: String, session: PreviewSession) {
        let config = PreviewConfigMsg(
            canvasWidth: Int64(plan.canvas.w), canvasHeight: Int64(plan.canvas.h), fps: Int64(plan.canvas.fps), quality: .full,
            useProxies: false)
        let manager = self.manager!
        let msg = try await call { (r: @escaping EngineReply<PreviewOpenedMsg>) in manager.open(config, reply: r) }
        opened.append(msg.sessionId)
        let session = try XCTUnwrap(onQueue { manager.session(msg.sessionId) })
        return (msg.sessionId, session)
    }

    private func setPlan(_ id: String, _ plan: RenderPlan) async throws -> PlanAckMsg {
        let data = PlanEncoder.encode(plan)
        let manager = self.manager!
        return try await call { manager.setPlan(sessionId: id, plan: data, reply: $0) }
    }

    private func patch(_ id: String, _ patch: RenderPlanPatch) async throws -> PlanAckMsg {
        let data = PlanEncoder.encode(patch)
        let manager = self.manager!
        return try await call { manager.applyPatch(sessionId: id, patch: data, reply: $0) }
    }

    private func seek(_ id: String, frame k: Int64, fps: Int64 = 25) async throws -> SeekAckMsg {
        let manager = self.manager!
        let t = FrameGrid(fps: fps).timeOfFrame(k)
        return try await call { manager.seek(sessionId: id, timeUs: t, exact: true, reply: $0) }
    }

    private func play(_ id: String, loop: LoopMsg? = nil) async throws {
        let manager = self.manager!
        _ = try await call { manager.play(sessionId: id, loop: loop, reply: $0) }
    }

    private func pause(_ id: String) async throws {
        let manager = self.manager!
        _ = try await call { manager.pause(sessionId: id, reply: $0) }
    }

    private func setRanges(_ id: String, _ ranges: [RenderedRange]) async throws {
        let handler = RenderedRangeHandler(context: harness.context)
        let msgs = ranges.map { RenderedRangeMsg(startUs: $0.startUs, endUs: $0.endUs, uri: $0.fileURL.absoluteString, hash: $0.hash) }
        let urls = ranges.map(\.fileURL)
        try await call { handler.setRenderedRanges(sessionId: id, ranges: msgs, fileURLs: urls, reply: $0) }
    }

    /// Renders `[a, b)` of [plan] into the renders directory.
    private func render(_ plan: RenderPlan, _ a: Int64, _ b: Int64, name: String) throws -> RenderedRange {
        let url = RenderPreviewFixtures.renderURL(harness.paths, name)
        let job = RenderPreviewJob(plan: RenderPreviewFixtures.cut(plan, a, b), outputURL: url,
                                   options: RenderPreviewFixtures.options(harness.paths))
        _ = try harness.run(job)
        return RenderedRange(startUs: a, endUs: b, fileURL: url, hash: name)
    }

    /// Drawn layers and barcode problems of every composed frame (render queue).
    private final class ComposeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var drawn: [Int64: [String]] = [:]
        private var problems: [String] = []

        func record(_ f: DVRenderSession.ComposedFrame) {
            let got = RenderPreviewCheck.barcodes(f.buffer, pips: 4)
            let want = RenderPreviewCheck.expected(f.k, pips: 4)
            lock.lock()
            drawn[f.k] = f.drawn
            if got != want { problems.append("frame \(f.k): \(got) != \(want)") }
            lock.unlock()
        }

        func reset() {
            lock.lock()
            drawn.removeAll()
            problems.removeAll()
            lock.unlock()
        }

        var frames: [Int64: [String]] {
            lock.lock()
            defer { lock.unlock() }
            return drawn
        }

        var barcodeProblems: [String] {
            lock.lock()
            defer { lock.unlock() }
            return problems
        }
    }

    private static func isRender(_ id: String) -> Bool { id.hasPrefix(RenderedRangeRules.layerPrefix) }

    // MARK: Manager wiring

    func testManagerInstallsTheSessionSwapAndRemovesItOnDispose() async throws {
        let plan = try RenderPreviewFixtures.plan(rev: 3)
        let (id, session) = try await open(plan)
        let ranges = RenderedRangeRegistry.of(harness.context)
        let swap = try XCTUnwrap(ranges.existingSwap(for: id), "the swap exists before any setRenderedRanges")
        XCTAssertTrue(onQueue { session.renderedRangeHook === swap })
        _ = try await setPlan(id, plan)
        XCTAssertEqual(onQueue { swap.planProvider?()?.rev }, 3, "planProvider reads the session's plan")
        try await setRanges(id, [RenderedRange(startUs: a, endUs: b, fileURL: RenderPreviewFixtures.renderURL(harness.paths, "x"), hash: "x")])
        XCTAssertEqual(onQueue { swap.renderedRanges(planRev: 3) }, [10..<30])
        // setPlan drops every range (the swap was told about the new plan).
        var next = plan
        next.rev = 4
        _ = try await setPlan(id, next)
        XCTAssertEqual(onQueue { swap.allRanges }, [])
        let manager = self.manager!
        try await call { manager.dispose(sessionId: id, reply: $0) }
        opened.removeAll()
        XCTAssertNil(ranges.existingSwap(for: id), "dispose removes the swap")
    }

    // MARK: Rendered range playback

    func testRenderedRangePlaysThroughTheSession() async throws {
        let plan = try RenderPreviewFixtures.plan()
        let range = try render(plan, a, b, name: "play")
        let (id, session) = try await open(plan)
        _ = try await setPlan(id, plan)
        try await setRanges(id, [range])
        _ = try await seek(id, frame: 2)
        XCTAssertFalse(onQueue { session.playingRenderedRanges }, "paused: the full composition")
        let log = ComposeLog()
        session.render.onComposed = { log.record($0) }
        defer { session.render.onComposed = nil }

        try await play(id)
        let rendered = await PreviewHarness.wait(5) { self.onQueue { session.playing && session.playingRenderedRanges } }
        XCTAssertTrue(rendered, "playback runs the rendered playback plan")
        XCTAssertTrue(onQueue { session.snapshots.current.plan.layers.contains { Self.isRender($0.id) } },
                      "the snapshot comes from the playback plan")
        let passed = await PreviewHarness.wait(8) { (session.bridge.current?.k ?? 0) >= 36 }
        XCTAssertTrue(passed, "playback passed the range")
        try await pause(id)

        let frames = log.frames
        var problems: [String] = []
        let inside = frames.keys.filter { (10..<30).contains($0) }
        XCTAssertGreaterThanOrEqual(inside.count, 10, "frames composed inside the range: \(inside.sorted())")
        for (k, drawn) in frames where k <= 35 {
            if (10..<30).contains(k) {
                if drawn != ["!render-0"] { problems.append("frame \(k) draws \(drawn)") }
            } else if drawn.contains(where: Self.isRender) {
                problems.append("frame \(k) draws a render outside the range")
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertEqual(log.barcodeProblems, [], "every composed frame shows the right barcodes")
        let swap = try XCTUnwrap(RenderedRangeRegistry.of(harness.context).existingSwap(for: id))
        let crossings = swap.crossings
        XCTAssertEqual(crossings.map(\.entered), [true, false], "\(crossings)")
        if crossings.count == 2 {
            XCTAssertEqual(crossings[0].range, 10..<30)
            XCTAssertTrue((9...11).contains(crossings[0].frame), "entered at \(crossings[0].frame)")
            XCTAssertTrue((29...31).contains(crossings[1].frame), "left at \(crossings[1].frame)")
        }

        // Paused: back to the full composition; an exact seek inside the range is composed live.
        let full = await PreviewHarness.wait(5) { self.onQueue { !session.playingRenderedRanges && !session.rebuilding } }
        XCTAssertTrue(full, "pause leaves the rendered composition")
        XCTAssertFalse(onQueue { session.snapshots.current.plan.layers.contains { Self.isRender($0.id) } })
        log.reset()
        let ack = try await seek(id, frame: 15)
        XCTAssertEqual(ack.displayedFrame, 15)
        try await Task.sleep(nanoseconds: 200_000_000)
        let drawn15 = try XCTUnwrap(log.frames[15])
        XCTAssertFalse(drawn15.contains(where: Self.isRender), "paused exact seek: live layers \(drawn15)")
        XCTAssertEqual(log.barcodeProblems, [])
    }

    func testRangeChangesDuringPlaybackRebuildWhilePlaying() async throws {
        let plan = try RenderPreviewFixtures.plan()
        let range = try render(plan, a, b, name: "changes")
        let (id, session) = try await open(plan)
        _ = try await setPlan(id, plan)
        try await setRanges(id, [range])
        try await play(id, loop: LoopMsg(startUs: 0, endUs: plan.durUs))
        let rendered = await PreviewHarness.wait(5) { self.onQueue { session.playing && session.playingRenderedRanges } }
        XCTAssertTrue(rendered)

        // A param patch inside the range (PiP 2 opacity) drops the range: live composition, still playing.
        var pip2 = plan.layers.first { $0.id == "it_pip20000000#v" }!
        pip2.xf.op = 0.5
        var p = RenderPlanPatch(from: plan.rev, to: plan.rev + 1)
        p.layers.upsert = [pip2]
        let ack = try await patch(id, p)
        XCTAssertEqual(ack.rev, plan.rev + 1)
        XCTAssertTrue(ack.structural, "the playing item is rebuilt without the render")
        let live = await PreviewHarness.wait(5) {
            self.onQueue { session.playing && !session.playingRenderedRanges && !session.rebuilding }
        }
        XCTAssertTrue(live, "playback continues on the live composition")
        XCTAssertGreaterThanOrEqual(onQueue { session.rangeRebuildCount }, 1)
        let swap = try XCTUnwrap(RenderedRangeRegistry.of(harness.context).existingSwap(for: id))
        XCTAssertEqual(onQueue { swap.allRanges }, [])
        XCTAssertEqual(onQueue { session.snapshots.current.plan.layers.first { $0.id == "it_pip20000000#v" }?.xf.op }, 0.5)

        // A new set arrives during playback: picked up without a play command.
        let next = try XCTUnwrap(onQueue { session.plan })
        let again = try render(next, a, b, name: "again")
        try await setRanges(id, [again])
        let back = await PreviewHarness.wait(5) {
            self.onQueue { session.playing && session.playingRenderedRanges && !session.rebuilding }
        }
        XCTAssertTrue(back, "the new range plays from its file")
        XCTAssertEqual(onQueue { session.snapshots.current.plan.layers.first { $0.id == "it_pip20000000#v" }?.xf.op }, 0.5,
                       "the rendered snapshot keeps the patched params")
        try await pause(id)
        let paused = await PreviewHarness.wait(5) { self.onQueue { !session.playingRenderedRanges && !session.rebuilding } }
        XCTAssertTrue(paused)
    }

    func testPlaybackStillsNeverFreezeARenderLayer() throws {
        let plan = try RenderPreviewFixtures.plan()
        let playback = try XCTUnwrap(RenderedRangeRules.playbackPlan(
            plan, ranges: [RenderedRange(startUs: a, endUs: b, fileURL: URL(fileURLWithPath: "/tmp/r.mp4"), hash: "h")]))
        let stills = try XCTUnwrap(PlaybackStills.plan(playback, budget: 2, anchorFrame: 5))
        let render = try XCTUnwrap(stills.plan.layers.first { Self.isRender($0.id) })
        XCTAssertFalse(render.hold, "the render layer always decodes live")
        XCTAssertEqual(render.map, [MapSegment(a, b, 0, b - a)])
        XCTAssertFalse(stills.stillSlots.contains(try XCTUnwrap(render.seq)))
        XCTAssertLessThanOrEqual(PlaybackStills.peakLiveLayers(stills.plan.layers), 2)
    }

    // MARK: Export suspension

    func testExportSuspendsAndResumesThePreview() async throws {
        let plan = try RenderPreviewFixtures.plan()
        let (id, session) = try await open(plan)
        _ = try await setPlan(id, plan)
        _ = try await seek(id, frame: 5)
        try await play(id)
        _ = await PreviewHarness.wait(3) { self.onQueue { session.playing } }
        let textureFrames = registry.registered.count

        // Another context's export does nothing.
        let otherRoots = try TempRoots()
        defer { otherRoots.remove() }
        let other = try MediaJobTestSupport.context(otherRoots)
        NotificationPreviewSuspender(context: other).suspendPreviewForExport()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(onQueue { session.suspended })

        NotificationPreviewSuspender(context: harness.context).suspendPreviewForExport()
        let released = await PreviewHarness.wait(5) {
            self.onQueue { session.suspended && !session.playing && session.player.currentItem == nil && session.built == nil }
        }
        XCTAssertTrue(released, "the player stops and its item is released")
        XCTAssertNotNil(session.bridge.current, "the frame stays on the texture")
        XCTAssertEqual(registry.unregisteredIds, [], "the texture stays registered")
        XCTAssertEqual(registry.registered.count, textureFrames)
        XCTAssertEqual(onQueue { manager.exportSuspensions }, 1)

        // A session opened during the export starts suspended.
        let (_, second) = try await open(plan)
        XCTAssertTrue(onQueue { second.suspended })

        // Edits, seeks and play while suspended: recorded, nothing plays.
        var base = plan.layers.first { $0.id == "it_pip10000000#v" }!
        base.xf.op = 0.25
        var p = RenderPlanPatch(from: plan.rev, to: plan.rev + 1)
        p.layers.upsert = [base]
        let ack = try await patch(id, p)
        XCTAssertEqual(ack.rev, plan.rev + 1)
        XCTAssertEqual(onQueue { session.snapshots.current.plan.layers.first { $0.id == "it_pip10000000#v" }?.xf.op }, 0.25,
                       "the snapshot follows the edits")
        try await play(id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(onQueue { session.playing }, "play is refused while suspended")
        let seekAck = try await seek(id, frame: 20)
        XCTAssertEqual(seekAck.displayedFrame, 20)
        XCTAssertNil(onQueue { session.player.currentItem })

        NotificationPreviewSuspender(context: harness.context).resumePreviewAfterExport()
        let restored = await PreviewHarness.wait(8) {
            self.onQueue { !session.suspended && session.player.currentItem != nil && !session.rebuilding }
                && session.bridge.current?.k == 20
        }
        XCTAssertTrue(restored, "resume rebuilds the latest plan at the current frame")
        XCTAssertFalse(onQueue { session.playing }, "resume stays paused")
        XCTAssertEqual(onQueue { session.plan?.rev }, plan.rev + 1)
        XCTAssertEqual(onQueue { manager.exportSuspensions }, 0)
        XCTAssertFalse(onQueue { second.suspended })
        let pb = try XCTUnwrap(session.bridge.current?.buffer)
        XCTAssertEqual(RenderPreviewCheck.barcodes(pb, pips: 4).first, 20, "frame 20 of the base")
        // Playback works again.
        try await play(id)
        let playing = await PreviewHarness.wait(5) { self.onQueue { session.playing } && (session.bridge.current?.k ?? 0) > 21 }
        XCTAssertTrue(playing)
        try await pause(id)
    }

    func testZZLiveBarcodes() async throws {
        let plan = try RenderPreviewFixtures.plan()
        var bad: [String] = []
        let range = try render(plan, a, b, name: "zz")
        let useRanges = ProcessInfo.processInfo.environment["NO_RANGES"] == nil
        for _ in 0..<6 {
            let (id, session) = try await open(plan)
            _ = try await setPlan(id, plan)
            if useRanges { try await setRanges(id, [range]) }
            _ = try await seek(id, frame: 2)
            let log = ComposeLog()
            session.render.onComposed = { log.record($0) }
            try await play(id)
            _ = await PreviewHarness.wait(8) { (session.bridge.current?.k ?? 0) >= 36 }
            try await pause(id)
            session.render.onComposed = nil
            bad += log.barcodeProblems
        }
        XCTAssertEqual(bad, [])
    }
}
