// OWNER: FIX-IOS-END-HOLD
//
// Playback that reaches the end of the timeline holds the last frame (ARCH §12.2; QA-03 finding
// 5: the texture showed black after durUs). Over grid_cuts_30fps.json (90 frames, 960×540):
// - playing from frame 80 to the end stops playback, leaves frame 89 (stamp and barcodes) on the
//   texture, never pushes a frame past the end, and the clock reports the last frame, paused;
// - the held frame is still there a moment later (nothing pushes black after the end), and a
//   paused param patch redraws the last frame (the compositor's last request is not the end frame);
// - play again from the end starts over at frame 0.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PreviewEndHoldTests: XCTestCase {
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

    /// Mean luma (0…255) of a BGRA buffer, sampled on a coarse grid.
    private static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var sum = 0.0
        var n = 0.0
        for y in stride(from: 0, to: h, by: 8) {
            for x in stride(from: 0, to: w, by: 8) {
                let p = base + y * row + x * 4
                sum += 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
                n += 1
            }
        }
        return n > 0 ? sum / n : 0
    }

    func testPlaybackToTheEndHoldsTheLastFrame() async throws {
        let h = try PreviewHarness()
        harness = h
        await h.start()
        _ = try await h.setPlan(plan)
        let last = h.onQueue { $0.frameCount } - 1
        XCTAssertEqual(last, 89)
        let ack = try await h.seek(frame: last - 10)
        XCTAssertEqual(ack.displayedFrame, last - 10)

        // Every frame the texture shows from here on.
        let shown = Locked<[Int64?]>([])
        let stop = Locked(false)
        let poller = Task.detached {
            var serial: UInt64 = 0
            while !stop.value {
                if let f = h.session.bridge.current, f.serial != serial {
                    serial = f.serial
                    shown.mutate { $0.append(f.k) }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        _ = try await h.play()
        let started = await PreviewHarness.wait(3) { h.onQueue { $0.playing } }
        XCTAssertTrue(started)
        let ended = await PreviewHarness.wait(5) { !h.onQueue { $0.playing } }
        XCTAssertTrue(ended, "playback stops at the end of the timeline")
        // Anything that would replace the last frame (a late output buffer, a rebuild) lands now.
        try await Task.sleep(nanoseconds: 600_000_000)
        stop.mutate { $0 = true }
        _ = await poller.value

        let frames = shown.value
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { ($0 ?? -1) >= 0 && ($0 ?? Int64.max) <= last }, "frames shown: \(frames)")
        let held = try XCTUnwrap(h.session.bridge.current)
        XCTAssertEqual(held.k, last, "the last frame stays on the texture (shown: \(frames))")
        XCTAssertEqual(PreviewHarness.check(held.buffer, k: last, plan: plan), [])
        XCTAssertGreaterThan(Self.meanLuma(held.buffer), 20, "not black")
        XCTAssertEqual(h.onQueue { $0.currentFrame }, last)
        let clock = try XCTUnwrap(h.clocks.last)
        XCTAssertFalse(clock.playing)
        XCTAssertEqual(clock.timeUs, FrameGrid(30).timeOfFrame(last))

        // A paused param patch at the end redraws the last frame, not the end frame.
        let t = FrameGrid(30).timeOfFrame(last)
        var base = try XCTUnwrap(plan.layers.first { $0.seq == 0 && $0.kind == .media && $0.covers(t) })
        base.xf.op = 0.9
        var p = RenderPlanPatch(from: plan.rev, to: plan.rev + 1)
        p.layers = PatchSet(upsert: [base], remove: [])
        let redraws = h.onQueue { $0.redrawCount }
        let patched = try await h.patch(p)
        XCTAssertFalse(patched.structural)
        let redrawn = await PreviewHarness.wait(2) { h.onQueue { $0.redrawCount } > redraws }
        XCTAssertTrue(redrawn, "the param patch redraws while paused")
        XCTAssertEqual(h.session.bridge.current?.k, last, "the redraw composes the last frame")
        XCTAssertGreaterThan(Self.meanLuma(try XCTUnwrap(h.session.bridge.current?.buffer)), 15, "not black")

        // Play from the end starts over.
        _ = try await h.play()
        let restarted = await PreviewHarness.wait(3) {
            h.onQueue { $0.playing } && (h.session.bridge.current?.k ?? Int64.max) < 20
        }
        XCTAssertTrue(restarted, "play at the end restarts at frame 0")
        _ = try await h.pause()
    }
}
