// OWNER: IOS-11
//
// The iOS preview session end to end on the simulator (BUILD_PLAN IOS-11 acceptance, ARCH §12.2,
// §12.7, §13.2, §13.4, D-35, D-43(e), D-45), over grid_cuts_30fps.json (1080p30 base with cuts at
// frames 31 and 61, 720p25 PiP on slot 1 for frames 32…61) rendered at 960×540, with the frame
// barcodes of the fixture media checked in the texture's buffers:
// - first frame event; exact seek ack 200/200 including every frame around the cuts, each acked
//   frame's barcodes equal the ARCH §11.5 source frames (stamp == k);
// - seq rules and clock samples; scrub coalescing (one seek in flight, latest wins);
// - param patch, transient (visible within 2 frames) and structural patch while paused, with the
//   old frame kept until the first new one; planOutOfSync;
// - quality: pinned and auto, degraded/recovered events, frame size; thermal cap; a pause, the
//   end of the plan or a paused seek return auto to the requested quality once (QA-05 D11);
// - playback over the live decode budget uses stills; paused and exact seeks stay exact;
// - rendered-range hook called at range boundaries (test double);
// - background/foreground keeps a non-black frame; dispose releases the texture and restores the
//   audio session.
// Timings are iOS simulator numbers (device numbers are QA-04's).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PreviewSessionTests: XCTestCase {
    private var harness: PreviewHarness!
    private var plan: RenderPlan!

    override func setUp() async throws {
        try await super.setUp()
        plan = try PreviewHarness.gridCutsPlan()
    }

    override func tearDown() async throws {
        if let h = harness { await h.dispose() }
        harness = nil
        try await super.tearDown()
    }

    private func open(quality: PreviewQualityMsg = .full, budget: Int = 4, hook: RenderedRangeHook = NoRenderedRanges()) async throws -> PreviewHarness {
        let h = try PreviewHarness(quality: quality, budget: budget, hook: hook)
        harness = h
        await h.start()
        let ack = try await h.setPlan(plan)
        XCTAssertEqual(ack.rev, plan.rev)
        XCTAssertTrue(ack.structural)
        print("IOS11 setPlan -> first frame \(ack.applyMs) ms (simulator)")
        return h
    }

    private func frame(_ h: PreviewHarness) throws -> CVPixelBuffer { try XCTUnwrap(h.session.bridge.current?.buffer) }

    // MARK: First frame, exact seeks

    func testFirstFrameAndExactSeekAck200of200AroundTheGridCuts() async throws {
        let h = try await open()
        XCTAssertGreaterThanOrEqual(h.textureId, 0)
        await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .firstFrame } }
        let first = try XCTUnwrap(h.previewEvents.first { $0.kind == .firstFrame })
        XCTAssertEqual(first.width, 960)
        XCTAssertEqual(first.height, 540)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 0, plan: plan), [])

        // Every frame around both cuts (the slot-1 edges at 32/62 and the slot-0 cuts at 31/61),
        // then seeded random frames, 200 in all; half of them request a time inside the frame.
        var frames: [Int64] = []
        for c: Int64 in [31, 32, 61, 62] { frames += (c - 3)...(c + 3) }
        frames += [0, 89, 1, 88]
        var rng = SystemRandomNumberGeneratorSeeded(seed: 0x1011)
        while frames.count < 200 { frames.append(Int64(rng.next() % 90)) }
        var problems: [String] = []
        var lastSeq: Int64 = -1
        var ms: [Double] = []
        for (i, k) in frames.enumerated() {
            let offset: Int64 = i.isMultiple(of: 2) ? 0 : 20_000
            let t0 = CACurrentMediaTime()
            let ack = try await h.seek(frame: k, offsetUs: offset)
            ms.append((CACurrentMediaTime() - t0) * 1000)
            XCTAssertEqual(ack.requestedUs, FrameGrid(30).timeOfFrame(k) + offset)
            XCTAssertGreaterThan(ack.seq, lastSeq)
            lastSeq = ack.seq
            if ack.displayedFrame != k { problems.append("seek \(k): acked \(ack.displayedFrame)") }
            XCTAssertEqual(ack.displayedFrameTimeUs, FrameGrid(30).timeOfFrame(ack.displayedFrame))
            problems += PreviewHarness.check(try frame(h), k: k, plan: plan)
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(20).joined(separator: "\n"))
        ms.sort()
        print("IOS11 exact seek 200: acked \(200 - problems.count)/200, p50 \(Int(ms[100])) ms, p95 \(Int(ms[190])) ms, max \(Int(ms.last!)) ms (simulator)")
    }

    // MARK: Seq, clock, scrub

    func testSeqRulesAndClockSamples() async throws {
        let h = try await open()
        let s1 = try await h.seek(frame: 5)
        let playSeq = try await h.play()
        XCTAssertGreaterThan(playSeq, s1.seq)
        let advanced = await PreviewHarness.wait(3) { (h.session.bridge.current?.k ?? 0) >= 20 }
        XCTAssertTrue(advanced, "playback advances the texture")
        let pauseSeq = try await h.pause()
        XCTAssertGreaterThan(pauseSeq, playSeq)
        let s2 = try await h.seek(frame: 70)
        XCTAssertGreaterThan(s2.seq, pauseSeq)
        try await Task.sleep(nanoseconds: 100_000_000)
        let clocks = h.clocks
        XCTAssertTrue(clocks.contains { $0.playing && $0.seq == playSeq }, "playing samples carry the play seq")
        for (a, b) in zip(clocks, clocks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.seq, b.seq, "clock seq never goes back")
        }
        XCTAssertFalse(clocks.contains { $0.playing && $0.seq >= pauseSeq }, "no playing sample after pause")
        let last = try XCTUnwrap(clocks.last)
        XCTAssertEqual(last.seq, s2.seq)
        XCTAssertFalse(last.playing)
        XCTAssertEqual(last.timeUs, FrameGrid(30).timeOfFrame(70))
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 70, plan: plan), [])
    }

    func testScrubsCoalesceWithOneSeekInFlight() async throws {
        let h = try await open()
        let before = h.onQueue { $0.seeks.issuedScrubs }
        let results = Locked<[SeekAckMsg]>([])
        let done = expectation(description: "scrubs")
        done.expectedFulfillmentCount = 30
        h.queue.async {
            for k in Int64(10)..<40 {
                h.session.seek(timeUs: FrameGrid(30).timeOfFrame(k), exact: false) { r in
                    if case .success(let a) = r { results.mutate { $0.append(a) } }
                    done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 10)
        let issued = h.onQueue { $0.seeks.issuedScrubs } - before
        print("IOS11 scrub: 30 requests -> \(issued) seeks")
        XCTAssertLessThanOrEqual(issued, 3, "latest wins: the first scrub and the last pending one")
        for a in results.value {
            XCTAssertTrue((0..<90).contains(a.displayedFrame))
            XCTAssertEqual(a.displayedFrameTimeUs, FrameGrid(30).timeOfFrame(a.displayedFrame))
        }
        XCTAssertEqual(results.value.count, 30)
        let settle = try await h.seek(frame: 39)
        XCTAssertEqual(settle.displayedFrame, 39)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 39, plan: plan), [])
    }

    // MARK: Paused edits

    private func patch(_ upserts: [PlanLayer] = [], remove: [String] = [], from: Int64) -> RenderPlanPatch {
        var p = RenderPlanPatch(from: from, to: from + 1)
        p.layers = PatchSet(upsert: upserts, remove: remove)
        return p
    }

    func testParamPatchTransientAndStructuralPatchWhilePaused() async throws {
        let h = try await open()
        _ = try await h.seek(frame: 45)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 45, plan: plan), [])
        var rev = plan.rev

        // Param patch: the PiP moves out of its region (no rebuild).
        var pip = plan.layers.first { $0.id == "it_gridD0000001#v" }!
        pip.xf.cx = 480
        pip.xf.cy = 810
        var paramMs: [Int64] = []
        let rebuildsBefore = h.onQueue { $0.rebuildCount }
        let ack = try await h.patch(patch([pip], from: rev))
        rev += 1
        XCTAssertFalse(ack.structural)
        XCTAssertEqual(ack.rev, rev)
        paramMs.append(ack.applyMs)
        XCTAssertEqual(h.onQueue { $0.rebuildCount }, rebuildsBefore)
        var moved = plan!
        moved.layers = moved.layers.map { $0.id == pip.id ? pip : $0 }
        moved.rev = rev
        XCTAssertEqual(CompositorTestSupport.barcode(try frame(h), region: FrameBarcodeRegion(x: 80, y: 315, width: 320, height: 180)),
                       PreviewHarness.displayedSourceFrame(ParamSnapshot(plan: moved).evaluate(atFrame: 45).first { $0.seq == 1 }!, fps: 25))
        for i in 0..<4 {
            pip.xf.op = i.isMultiple(of: 2) ? 0.5 : 1
            let a = try await h.patch(patch([pip], from: rev))
            rev += 1
            paramMs.append(a.applyMs)
        }
        print("IOS11 param patch applyMs \(paramMs) (simulator)")
        XCTAssertLessThanOrEqual(paramMs.sorted()[paramMs.count / 2], 30, "median param patch within the mid budget")

        // Transients: base opacity 0 hides the base barcode; measured until the texture changes.
        var latencies: [Double] = []
        let base = "it_gridB0000001#v"
        for i in 0..<6 {
            let serial = h.session.bridge.currentSerial
            let t0 = CACurrentMediaTime()
            let op = i.isMultiple(of: 2) ? 0.0 : 1.0
            let data = PlanEncoder.encode(PlanTransient(item: "it_gridB0000001", layers: [TransientLayer(id: base, xf: PlanTransform(op: op))]))
            h.queue.async { h.session.setTransient(itemId: "it_gridB0000001", params: data) }
            let shown = await PreviewHarness.wait(1) { h.session.bridge.currentSerial > serial }
            XCTAssertTrue(shown)
            latencies.append((CACurrentMediaTime() - t0) * 1000)
            let code = CompositorTestSupport.barcode(try frame(h), region: PreviewHarness.baseRegion)
            if op == 0 { XCTAssertNil(code, "transient hides the base") } else { XCTAssertNotNil(code) }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        h.queue.async { h.session.clearTransient(itemId: "it_gridB0000001") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(CompositorTestSupport.barcode(try frame(h), region: PreviewHarness.baseRegion))
        let sortedLat = latencies.dropFirst().sorted()
        print("IOS11 transient -> texture ms \(latencies.map { Int($0) }) (simulator)")
        XCTAssertLessThanOrEqual(sortedLat[sortedLat.count / 2], 2000.0 / 30, "transient visible within 2 frames")

        // Structural: remove the PiP; the frame stays on screen until the rebuilt one arrives.
        let watching = Locked(true)
        let blank = Locked(0)
        Task.detached {
            while watching.value {
                if h.session.bridge.current == nil { blank.mutate { $0 += 1 } }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let s = try await h.patch(patch(remove: [pip.id], from: rev))
        rev += 1
        watching.mutate { $0 = false }
        XCTAssertTrue(s.structural)
        XCTAssertEqual(s.rev, rev)
        XCTAssertEqual(blank.value, 0, "the old frame stays until the new one")
        print("IOS11 structural patch (paused) applyMs \(s.applyMs) phases \(h.onQueue { $0.lastRebuildPhases }) (simulator)")
        XCTAssertLessThanOrEqual(s.applyMs, 1000, "simulator bound; mid-device budget 250 ms is QA-04's")
        var removed = plan!
        removed.layers.removeAll { $0.id == pip.id }
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 45, plan: removed, checkPip: false), [])
        let movedPip = PreviewHarness.displayedSourceFrame(ParamSnapshot(plan: moved).evaluate(atFrame: 45).first { $0.seq == 1 }!, fps: 25)
        XCTAssertNotEqual(CompositorTestSupport.barcode(try frame(h), region: FrameBarcodeRegion(x: 80, y: 315, width: 320, height: 180)),
                          movedPip, "PiP gone")

        // Out of sync patches are refused.
        do {
            _ = try await h.patch(patch([pip], from: rev - 2))
            XCTFail("expected planOutOfSync")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, .planOutOfSync)
        }
    }

    func testStructuralPatchWhilePlayingRestoresPlayback() async throws {
        let h = try await open()
        _ = try await h.play()
        _ = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) >= 10 }
        var bg = plan.layers.first { $0.id == "it_gridA0000001#v" }!
        bg.t1 = 1_000_000  // structural (timing)
        bg.map = [MapSegment(0, 1_000_000, 0, 1_000_000)]
        var p = RenderPlanPatch(from: plan.rev, to: plan.rev + 1)
        p.layers = PatchSet(upsert: [bg], remove: [])
        let ack = try await h.patch(p)
        XCTAssertTrue(ack.structural)
        print("IOS11 structural patch (playing) applyMs \(ack.applyMs) (simulator)")
        let resumed = await PreviewHarness.wait(2) { h.onQueue { $0.playing } }
        XCTAssertTrue(resumed, "play state restored")
        let k0 = h.session.bridge.current?.k ?? 0
        let advanced = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) > k0 + 5 }
        XCTAssertTrue(advanced)
        _ = try await h.pause()
    }

    // MARK: Quality

    func testQualityPinnedAutoDegradedAndRecovered() async throws {
        let h = try await open(quality: .full)
        // Pinned half: frame size event, half-size frame, exact content.
        try await h.call { (s: PreviewSession, r: @escaping EngineReply<Void>) in s.setQuality(.half, reply: r) }
        XCTAssertEqual(CVPixelBufferGetWidth(try frame(h)), 480)
        let ok1 = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .frameSize && $0.width == 480 && $0.height == 270 } }
        XCTAssertTrue(ok1)
        // The governor never changes a pinned quality.
        h.queue.sync { for i in 0..<300 { h.session.governorSample(missed: true, at: CACurrentMediaTime() + Double(i) / 30) } }
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 480, height: 270))
        XCTAssertFalse(h.previewEvents.contains { $0.kind == .degraded })

        // Auto: missed frames step down with degraded(q); clean playback recovers.
        try await h.call { (s: PreviewSession, r: @escaping EngineReply<Void>) in s.setQuality(.auto, reply: r) }
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 960, height: 540))
        let t0 = CACurrentMediaTime()
        h.queue.sync { for i in 0...60 { h.session.governorSample(missed: i % 4 == 0, at: t0 + Double(i) / 30) } }
        _ = await PreviewHarness.wait(2) { CVPixelBufferGetWidth((h.session.bridge.current?.buffer)!) == 480 }
        let ok2 = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .degraded && $0.quality == .half } }
        XCTAssertTrue(ok2)
        XCTAssertEqual(CVPixelBufferGetWidth(try frame(h)), 480)
        h.queue.sync { for i in 0..<330 { h.session.governorSample(missed: false, at: t0 + 2.1 + Double(i) / 30) } }
        _ = await PreviewHarness.wait(2) { CVPixelBufferGetWidth((h.session.bridge.current?.buffer)!) == 960 }
        print("IOS11 quality after recovery: renderSize \(h.onQueue { $0.renderSize }) level \(h.onQueue { $0.governor.level }) frame \(CVPixelBufferGetWidth(try frame(h))) events \(h.previewEvents.map(\.kind))")
        let ok3 = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .degraded && $0.quality == .full } }
        XCTAssertTrue(ok3)
        let ok4 = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .recovered } }
        XCTAssertTrue(ok4)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 0, plan: plan), [])

        // Thermal serious forces auto to at most half.
        h.queue.sync { h.session.handleThermal(.serious) }
        _ = await PreviewHarness.wait(2) { CVPixelBufferGetWidth((h.session.bridge.current?.buffer)!) == 480 }
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 480, height: 270))
    }

    // MARK: Quality reset on stop (QA-05 D11)

    /// Quality events from index [from] on.
    private func qualityEvents(_ h: PreviewHarness, from: Int) -> [PreviewEventMsg] {
        Array(h.previewEvents.dropFirst(from)).filter { $0.kind == .degraded || $0.kind == .recovered }
    }

    /// Steps auto down twice (to a quarter) with injected missed playback frames, in one queue turn.
    private func degradeToQuarter(_ h: PreviewHarness) {
        h.queue.sync {
            let t0 = CACurrentMediaTime()
            for i in 0...60 { h.session.governorSample(missed: i % 4 == 0, at: t0 + Double(i) / 30) }
            for i in 0...60 { h.session.governorSample(missed: i % 4 == 0, at: t0 + 2.1 + Double(i) / 30) }
        }
    }

    func testPauseAfterDegradedPlaybackRestoresRequestedQualityOnce() async throws {
        let h = try await open(quality: .auto)
        _ = try await h.play()
        _ = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) >= 5 }
        degradeToQuarter(h)
        XCTAssertEqual(h.onQueue { $0.governor.level }, .quarter)
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 240, height: 136))
        // Events are delivered asynchronously: mark after the step to a quarter has arrived.
        let stepped = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .degraded && $0.quality == .quarter } }
        XCTAssertTrue(stepped)
        let mark = h.previewEvents.count
        let rebuilds = h.onQueue { $0.rebuildCount }

        _ = try await h.pause()
        XCTAssertEqual(h.onQueue { $0.governor.level }, .full)
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 960, height: 540))
        let full = await PreviewHarness.wait(3) { h.session.bridge.current.map { CVPixelBufferGetWidth($0.buffer) } == 960 }
        XCTAssertTrue(full, "the paused frame is composed again at the requested quality")
        // Steps while playing never re-reported the frame size, so none is due here (still 960).
        XCTAssertFalse(h.previewEvents.dropFirst(mark).contains { $0.kind == .frameSize && $0.width != 960 })
        let settled = await PreviewHarness.wait(3) { h.onQueue { !$0.rebuilding } }
        XCTAssertTrue(settled)
        XCTAssertEqual(h.onQueue { $0.rebuildCount }, rebuilds + 1, "one redraw (rebuild at the paused frame)")
        _ = await PreviewHarness.wait(1) { false }
        let k = h.onQueue { $0.currentFrame }
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: k, plan: plan), [], "exact paused frame \(k)")
        let events = qualityEvents(h, from: mark)
        print("IOS D11 pause after degraded: events \(events.map { "\($0.kind)\($0.quality.map { "(\($0))" } ?? "")" })")
        XCTAssertEqual(events.filter { $0.kind == .recovered }.count, 1, "exactly one recovered")
        XCTAssertEqual(events.filter { $0.kind == .degraded }.map(\.quality), [.full], "reported as the step to full")

        // Play again: starts at the requested quality; repeated pause/play adds no events.
        let mark2 = h.previewEvents.count
        for _ in 0..<3 {
            _ = try await h.play()
            XCTAssertEqual(h.onQueue { $0.governor.level }, .full)
            XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 960, height: 540))
            _ = await PreviewHarness.wait(0.4) { false }
            _ = try await h.pause()
        }
        _ = await PreviewHarness.wait(0.5) { false }
        XCTAssertEqual(qualityEvents(h, from: mark2).count, 0, "\(qualityEvents(h, from: mark2).map(\.kind))")
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 960, height: 540))
    }

    func testPauseWhenNotDegradedSendsNoQualityEvent() async throws {
        let h = try await open(quality: .auto)
        let mark = h.previewEvents.count
        // Short plays (under one 2 s window): the governor cannot step.
        for _ in 0..<2 {
            _ = try await h.play()
            _ = await PreviewHarness.wait(0.5) { false }
            _ = try await h.pause()
        }
        _ = await PreviewHarness.wait(0.5) { false }
        XCTAssertEqual(qualityEvents(h, from: mark).count, 0)
        XCTAssertEqual(h.onQueue { $0.renderSize }, CGSize(width: 960, height: 540))
    }

    func testEndOfPlanAfterDegradedPlaybackRestoresRequestedQuality() async throws {
        let h = try await open(quality: .auto)
        _ = try await h.seek(frame: 60)
        _ = try await h.play()
        _ = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) >= 62 }
        XCTAssertTrue(h.onQueue { $0.playing })
        degradeToQuarter(h)
        _ = await PreviewHarness.wait(2) { h.previewEvents.contains { $0.kind == .degraded && $0.quality == .quarter } }
        let mark = h.previewEvents.count
        let ended = await PreviewHarness.wait(4) { h.onQueue { !$0.playing } }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.onQueue { $0.governor.level }, .full)
        let full = await PreviewHarness.wait(3) { h.session.bridge.current.map { CVPixelBufferGetWidth($0.buffer) } == 960 }
        XCTAssertTrue(full)
        _ = await PreviewHarness.wait(0.5) { false }
        XCTAssertEqual(qualityEvents(h, from: mark).filter { $0.kind == .recovered }.count, 1)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 89, plan: plan), [], "holds the last frame")
    }

    func testPausedSeekRendersAtTheRequestedQuality() async throws {
        let h = try await open(quality: .auto)
        // A lowered level found while paused (injected).
        let t0 = CACurrentMediaTime()
        h.queue.sync { for i in 0...60 { h.session.governorSample(missed: i % 4 == 0, at: t0 + Double(i) / 30) } }
        _ = await PreviewHarness.wait(2) { h.session.bridge.current.map { CVPixelBufferGetWidth($0.buffer) } == 480 }
        let mark = h.previewEvents.count
        let ack = try await h.seek(frame: 40)
        XCTAssertEqual(ack.displayedFrame, 40)
        XCTAssertEqual(h.onQueue { $0.governor.level }, .full)
        XCTAssertEqual(CVPixelBufferGetWidth(try frame(h)), 960)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 40, plan: plan), [])
        _ = try await h.seek(frame: 20)
        XCTAssertEqual(qualityEvents(h, from: mark).filter { $0.kind == .recovered }.count, 1)
    }

    // MARK: Decoder budget, rendered ranges

    func testPlaybackOverTheDecodeBudgetUsesStillsWhilePausedAndSeeksStayExact() async throws {
        let h = try await open(budget: 1)
        _ = try await h.seek(frame: 35)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 35, plan: plan), [])
        _ = try await h.play()
        let stills = await PreviewHarness.wait(3) { h.onQueue { $0.playing && $0.playingStills } }
        XCTAssertTrue(stills, "playback over budget runs the stills composition")
        // During playback the PiP shows its exact frame at the play position (frame 35).
        let pipAt35 = PreviewHarness.displayedSourceFrame(ParamSnapshot(plan: plan).evaluate(atFrame: 35).first { $0.seq == 1 }!, fps: 25)
        _ = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) >= 42 }
        let playing = try frame(h)
        let k = try XCTUnwrap(DVRenderSession.frameIndex(of: playing))
        if k < 61 {
            XCTAssertEqual(CompositorTestSupport.barcode(playing, region: PreviewHarness.pipRegion), pipAt35, "still PiP at frame \(k)")
            XCTAssertEqual(PreviewHarness.check(playing, k: k, plan: plan, checkPip: false), [], "live base")
        }
        _ = try await h.pause()
        let full = await PreviewHarness.wait(3) { h.onQueue { !$0.playingStills && !$0.rebuilding } }
        XCTAssertTrue(full, "paused on the full composition")
        for k: Int64 in [40, 50, 33] {
            let ack = try await h.seek(frame: k)
            XCTAssertEqual(ack.displayedFrame, k)
            XCTAssertEqual(try PreviewHarness.check(frame(h), k: k, plan: plan), [], "exact paused frame \(k)")
        }
    }

    func testRenderedRangeHookIsCalledAtRangeBoundaries() async throws {
        let hook = RecordingRangeHook([40..<50])
        let h = try await open(hook: hook)
        _ = try await h.seek(frame: 30)
        _ = try await h.play()
        let passed = await PreviewHarness.wait(4) { (h.session.bridge.current?.k ?? 0) >= 56 }
        XCTAssertTrue(passed)
        _ = try await h.pause()
        let calls = hook.calls
        XCTAssertEqual(calls.map(\.entered), [true, false], "\(calls)")
        if calls.count == 2 {
            XCTAssertEqual(calls[0].range, 40..<50)
            XCTAssertTrue((39...41).contains(calls[0].k), "entered at \(calls[0].k)")
            XCTAssertTrue((49...51).contains(calls[1].k), "left at \(calls[1].k)")
        }
    }

    // MARK: Lifecycle, dispose

    func testBackgroundAndForegroundKeepAFrameAndRefresh() async throws {
        let h = try await open()
        _ = try await h.seek(frame: 20)
        _ = try await h.play()
        _ = await PreviewHarness.wait(2) { (h.session.bridge.current?.k ?? 0) >= 25 }
        h.queue.sync {
            h.session.handleResignActive()
            h.session.handleBackground()
        }
        XCTAssertFalse(h.onQueue { $0.playing }, "resign active pauses")
        XCTAssertFalse(h.session.displayLink.isRunning)
        h.queue.sync { h.session.handleBecomeActive() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let pb = try frame(h)
        let k = h.onQueue { $0.currentFrame }
        XCTAssertEqual(PreviewHarness.check(pb, k: k, plan: plan), [], "a real frame after 1 s, never black")
        h.queue.sync { h.session.handleMemoryWarning() }
        let ack = try await h.seek(frame: 60)
        XCTAssertEqual(ack.displayedFrame, 60)
    }

    func testDisposeReleasesTheTextureAndRestoresTheAudioSession() async throws {
        let h = try await open()
        _ = try await h.play()
        XCTAssertEqual(h.audio.category, .playback)
        _ = try await h.pause()
        let id = h.textureId
        await h.dispose()
        harness = nil
        XCTAssertEqual(h.registry.unregisteredIds, [id])
        XCTAssertNil(h.session.bridge.current)
        XCTAssertNil(h.session.player.currentItem)
        XCTAssertEqual(h.audio.category, .ambient, "previous category restored")
        do {
            _ = try await h.play()
            XCTFail("calls after dispose fail")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, .cancelled)
        }
        await h.dispose()  // idempotent
        XCTAssertEqual(h.registry.unregisteredIds, [id])
    }

    // MARK: Source frames, colours, look stills, capture

    func testShowSourceFrameSampleColorLookStillsAndCapture() async throws {
        let h = try await open()
        _ = try await h.seek(frame: 10)
        let url = try CompositorTestSupport.media("frame_counter_720p25.mp4")
        let media = ResolvedMediaMsg(uri: url.absoluteString, fingerprint: "bbbb", isProxy: false)
        try await h.call { (s: PreviewSession, r: @escaping EngineReply<Void>) in
            s.showSourceFrame(media: media, mediaURL: url, sourceTimeUs: 2_000_000, reply: r)
        }
        let shown = try frame(h)
        XCTAssertNil(DVRenderSession.frameIndex(of: shown), "source frame is not a composed frame")
        XCTAssertEqual(CVPixelBufferGetWidth(shown), 960)
        XCTAssertEqual(CompositorTestSupport.barcode(shown), 50, "source frame 2.0 s at 25 fps")
        let ack = try await h.seek(frame: 10)
        XCTAssertEqual(ack.displayedFrame, 10)
        XCTAssertEqual(try PreviewHarness.check(frame(h), k: 10, plan: plan), [], "seek clears the source frame")

        let color = try await h.call { (s: PreviewSession, r: @escaping EngineReply<ColorMsg?>) in
            s.sampleColor(itemId: "it_gridA0000001", x: 0.5, y: 0.9, reply: r)
        }
        XCTAssertNotNil(color)
        let none = try await h.call { (s: PreviewSession, r: @escaping EngineReply<ColorMsg?>) in
            s.sampleColor(itemId: "it_unknown", x: 0.5, y: 0.5, reply: r)
        }
        XCTAssertNil(none)

        let lut = try XCTUnwrap(TestFixtures.url(.engineApi, "images/sources/lut_17.vlut"))
        let looks = [LookSpecMsg(id: "a", lutUri: lut.absoluteString, lutSize: 17, intensity: 1),
                     LookSpecMsg(id: "b", lutUri: lut.absoluteString, lutSize: 17, intensity: 0.5)]
        let stills = try await h.call { (s: PreviewSession, r: @escaping EngineReply<[Data]>) in
            s.renderLookStills(itemId: "it_gridA0000001", looks: looks, lutURLs: [lut, lut], heightPx: 90, reply: r)
        }
        XCTAssertEqual(stills.count, 2)
        for still in stills {
            XCTAssertEqual(Array(still.prefix(2)), [0xFF, 0xD8], "JPEG")
            let src = try XCTUnwrap(CGImageSourceCreateWithData(still as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(image.height, 90)
            XCTAssertEqual(image.width, 160)
        }

        let rgba = try await h.call { (s: PreviewSession, r: @escaping EngineReply<Data>) in s.debugCaptureFrame(reply: r) }
        XCTAssertEqual(rgba.count, 960 * 540 * 4)
    }
}

/// Deterministic generator (SplitMix64).
struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
