// OWNER: IOS-11
//
// Pure parts of the IOS-11 preview session (BUILD_PLAN IOS-11, ARCH §12.2, §13.2, D-43(e)):
// QualityGovernor (auto steps on missed frames and recovers, pinned qualities never change,
// thermal cap, render size), PlaybackStills (decoder budget → hold stills), AudioSessionCoordinator
// (playback category while playing, previous one restored on dispose).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class QualityGovernorTests: XCTestCase {
    /// Feeds [seconds] of 30 fps playback with every [missEvery]-th frame missed (0 = none).
    private func play(_ g: QualityGovernor, from t0: TimeInterval, seconds: Double, missEvery: Int) -> (end: TimeInterval, steps: [QualityGovernor.Level]) {
        var steps: [QualityGovernor.Level] = []
        let n = Int(seconds * 30)
        for i in 0..<n {
            let t = t0 + Double(i) / 30
            if let s = g.record(missed: missEvery > 0 && i % missEvery == 0, at: t) { steps.append(s) }
        }
        return (t0 + Double(n) / 30, steps)
    }

    func testAutoStepsDownAfterTenPercentMissedOverTwoSeconds() {
        let g = QualityGovernor(requested: .auto)
        g.playbackStarted(at: 0)
        // 1 in 20 missed (5 %): no step.
        var r = play(g, from: 0, seconds: 4, missEvery: 20)
        XCTAssertEqual(r.steps, [])
        XCTAssertEqual(g.level, .full)
        // 1 in 5 missed (20 %): one step per 2 s window, down to a quarter, never below.
        r = play(g, from: r.end, seconds: 7, missEvery: 5)
        XCTAssertEqual(r.steps, [.half, .quarter])
        XCTAssertEqual(g.level, .quarter)
    }

    func testAutoRecoversAfterTenSecondsClean() {
        let g = QualityGovernor(requested: .auto)
        g.playbackStarted(at: 0)
        var r = play(g, from: 0, seconds: 2.5, missEvery: 3)
        XCTAssertEqual(r.steps, [.half])
        r = play(g, from: r.end, seconds: 9.5, missEvery: 0)
        XCTAssertEqual(r.steps, [], "not yet 10 s clean")
        r = play(g, from: r.end, seconds: 1, missEvery: 0)
        XCTAssertEqual(r.steps, [.full])
    }

    func testPausedTimeDoesNotCount() {
        let g = QualityGovernor(requested: .auto)
        g.playbackStarted(at: 0)
        let r = play(g, from: 0, seconds: 2.5, missEvery: 3)
        XCTAssertEqual(g.level, .half)
        g.playbackStopped()
        // 60 s later, 1 s of clean playback: still half.
        g.playbackStarted(at: r.end + 60)
        XCTAssertEqual(play(g, from: r.end + 60, seconds: 1, missEvery: 0).steps, [])
        XCTAssertEqual(g.level, .half)
    }

    func testPinnedQualitiesNeverChange() {
        for q in [PreviewQualityMsg.full, .half, .quarter] {
            let g = QualityGovernor(requested: q)
            g.playbackStarted(at: 0)
            XCTAssertEqual(play(g, from: 0, seconds: 10, missEvery: 2).steps, [], "\(q)")
            XCTAssertNil(g.setThermal(.critical, at: 11), "\(q)")
            XCTAssertEqual(play(g, from: 11, seconds: 12, missEvery: 0).steps, [], "\(q)")
            XCTAssertEqual(g.level, QualityGovernor.Level.of(q))
        }
    }

    func testThermalSeriousCapsAutoAtHalf() {
        let g = QualityGovernor(requested: .auto)
        XCTAssertEqual(g.setThermal(.serious, at: 0), .half)
        g.playbackStarted(at: 0)
        XCTAssertEqual(play(g, from: 0, seconds: 15, missEvery: 0).steps, [], "no recovery above half while hot")
        XCTAssertNil(g.setThermal(.nominal, at: 15))
        XCTAssertEqual(play(g, from: 15, seconds: 10.5, missEvery: 0).steps, [.full])
        // Switching to auto while hot starts at half.
        let h = QualityGovernor(requested: .full)
        h.setThermal(.critical, at: 0)
        XCTAssertEqual(h.level, .full, "pinned")
        XCTAssertEqual(h.setRequested(.auto, at: 1), .half)
    }

    func testRenderSizeScalesAndCapsTheLongSide() {
        typealias G = QualityGovernor
        XCTAssertEqual(G.renderSize(canvasWidth: 1920, canvasHeight: 1080, level: .full, maxLongSide: 0), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(G.renderSize(canvasWidth: 1920, canvasHeight: 1080, level: .half, maxLongSide: 1920), CGSize(width: 960, height: 540))
        XCTAssertEqual(G.renderSize(canvasWidth: 1920, canvasHeight: 1080, level: .quarter, maxLongSide: 1920), CGSize(width: 480, height: 270))
        XCTAssertEqual(G.renderSize(canvasWidth: 1920, canvasHeight: 1080, level: .full, maxLongSide: 1280), CGSize(width: 1280, height: 720))
        XCTAssertEqual(G.renderSize(canvasWidth: 1080, canvasHeight: 1920, level: .full, maxLongSide: 640), CGSize(width: 360, height: 640))
        XCTAssertEqual(G.renderSize(canvasWidth: 1080, canvasHeight: 1350, level: .quarter, maxLongSide: 960), CGSize(width: 270, height: 338))
    }
}

final class PlaybackStillsTests: XCTestCase {
    private func layer(_ id: String, seq: Int, _ t0: Int64, _ t1: Int64, s0: Int64 = 0) -> PlanLayer {
        PlanLayer(id: id, z: seq * 10, seq: seq, t0: t0, t1: t1, kind: .media, asset: "a",
                  map: [MapSegment(t0, t1, s0, s0 + (t1 - t0))])
    }

    private func plan(_ layers: [PlanLayer]) -> RenderPlan {
        RenderPlan(rev: 1, target: .preview, canvas: PlanCanvas(w: 640, h: 360, fps: 30), durUs: 4_000_000,
                   assets: ["a": PlanAsset(kind: .video, uri: "file:///a.mp4")], layers: layers, audio: [])
    }

    func testWithinBudgetNeedsNoStills() throws {
        let p = plan([layer("a#v", seq: 0, 0, 4_000_000), layer("b#v", seq: 1, 1_000_000, 2_000_000)])
        XCTAssertEqual(PlaybackStills.peakLiveLayers(p.layers), 2)
        XCTAssertNil(PlaybackStills.plan(p, budget: 2, anchorFrame: 0))
    }

    func testExcessSlotsBecomeExactStillsAndTheMainTrackStaysLive() throws {
        let p = plan([
            layer("a#v", seq: 0, 0, 4_000_000),
            layer("b#v", seq: 1, 0, 3_000_000, s0: 5_000_000),
            layer("c#v", seq: 2, 1_000_000, 2_000_000, s0: 300_000),
            layer("d#v", seq: 2, 3_000_000, 4_000_000, s0: 700_000),
        ])
        XCTAssertEqual(PlaybackStills.peakLiveLayers(p.layers), 3)
        // Budget 2: the top slot (2) becomes stills.
        let k: Int64 = 45  // 1.5 s
        let r = try XCTUnwrap(PlaybackStills.plan(p, budget: 2, anchorFrame: k))
        XCTAssertEqual(r.stillSlots, [2])
        XCTAssertEqual(PlaybackStills.peakLiveLayers(r.plan.layers), 2)
        let byId = Dictionary(uniqueKeysWithValues: r.plan.layers.map { ($0.id, $0) })
        XCTAssertFalse(byId["a#v"]!.hold)
        XCTAssertFalse(byId["b#v"]!.hold)
        // c covers 1.5 s: still of its exact source time there (300 000 + 500 000).
        XCTAssertTrue(byId["c#v"]!.hold)
        XCTAssertEqual(byId["c#v"]!.map.first?.s0, 800_000)
        XCTAssertEqual(byId["c#v"]!.t0, 1_000_000)
        XCTAssertEqual(byId["c#v"]!.t1, 2_000_000)
        // d does not cover the anchor: its first frame.
        XCTAssertTrue(byId["d#v"]!.hold)
        XCTAssertEqual(byId["d#v"]!.map.first?.s0, 700_000)
        // Budget 1: slots 2 and 1 become stills; slot 0 stays live.
        let one = try XCTUnwrap(PlaybackStills.plan(p, budget: 1, anchorFrame: k))
        XCTAssertEqual(one.stillSlots, [1, 2])
        XCTAssertFalse(one.plan.layers.first { $0.id == "a#v" }!.hold)
        // The paused (full) plan is untouched.
        XCTAssertTrue(p.layers.allSatisfy { !$0.hold })
    }

    func testStillShowsTheSameFrameAsTheLiveLayerAtTheAnchor() {
        let l = PlanLayer(id: "x#v", z: 0, seq: 0, t0: 0, t1: 2_000_000, kind: .media, asset: "a",
                          map: [MapSegment(0, 2_000_000, 0, 1_000_000)])  // 0.5× speed
        let t = FrameGrid(30).timeOfFrame(31)  // 1 033 334 µs
        let still = PlaybackStills.still(l, at: t)
        let live = ParamSnapshot.sourceTime(l, at: t)!
        XCTAssertEqual(ParamSnapshot.sourceTime(still, at: t)!, live.rounded(.down))
        // Greatest PTS ≤ s + 500 µs is the same for every integer-µs PTS.
        XCTAssertEqual(Int64(live.rounded(.down)) + 500, Int64((live + 500).rounded(.down)))
    }
}

final class AudioSessionCoordinatorTests: XCTestCase {
    func testPlaybackCategoryWhilePlayingAndPreviousRestoredOnDispose() {
        let port = FakeAudioSession()
        let c = AudioSessionCoordinator(port: port)
        c.beginPlayback()
        XCTAssertEqual(port.category, .playback)
        XCTAssertEqual(port.mode, .moviePlayback)
        XCTAssertEqual(port.activations, [true])
        c.beginPlayback()
        XCTAssertEqual(port.setCalls, 1, "already in playback")
        XCTAssertEqual(c.savedConfiguration?.category, .ambient)
        c.restore()
        XCTAssertEqual(port.category, .ambient)
        XCTAssertEqual(port.mode, .default)
        XCTAssertEqual(port.categoryOptions, [.mixWithOthers])
        c.restore()
        XCTAssertEqual(port.setCalls, 2, "restore is idempotent")
    }

    func testRestoreWithoutPlaybackDoesNothing() {
        let port = FakeAudioSession()
        AudioSessionCoordinator(port: port).restore()
        XCTAssertEqual(port.setCalls, 0)
    }
}
