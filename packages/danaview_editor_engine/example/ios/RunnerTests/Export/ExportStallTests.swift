// OWNER: FIX-IOS-EXPORT-STALL
//
// Exploratory reproduction of QA-05 D1 (work in progress).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class ExportStallTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    static func layer(_ id: String, asset: String, seq: Int, t0: Int64, t1: Int64, s0: Int64, rate: Double, w: Double, h: Double) -> String {
        let s1 = s0 + Int64((Double(t1 - t0) * rate).rounded())
        return "{\"id\":\"\(id)\",\"z\":10,\"seq\":\(seq),\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(asset)\",\"map\":[[\(t0),\(t1),\(s0),\(s1)]],\"base\":[\(w),\(h)]}"
    }

    /// The soak-stall-165 project, approximated.
    static func soakPlan() -> Data {
        let w = 1280.0, h = 720.0
        var layers: [String] = []
        var n = 0
        func media(_ t0: Int64, _ dur: Int64, _ s0: Int64, _ rate: Double) {
            n += 1
            layers.append(layer(String(format: "it_v%011d#v", n), asset: "md_fc0000000001", seq: 0, t0: t0, t1: t0 + dur, s0: s0, rate: rate, w: w, h: h))
        }
        func image(_ t0: Int64, _ dur: Int64) {
            n += 1
            layers.append(ExportPlans.imageLayer(String(format: "it_i%011d", n), asset: "md_still0000001", t0: t0, t1: t0 + dur, w: w, h: h))
        }
        media(0, 366_667, 6_849_999, 1.5)
        media(366_667, 366_667, 7_400_000, 1.5)
        media(733_334, 733_333, 6_849_999, 1.5)
        image(1_466_667, 3_000_000)
        image(4_466_667, 1_533_333)
        image(6_000_000, 1_133_334)
        image(7_133_334, 333_333)
        media(7_466_667, 666_667, 400_000, 1.5)
        media(8_133_334, 1_100_000, 2_600_000, 1.5)
        media(9_233_334, 1_733_333, 0, 1.5)
        image(10_966_667, 166_667)
        image(11_133_334, 1_300_000)
        image(12_433_334, 3_000_000)
        media(15_433_334, 666_666, 400_000, 1.5)
        media(16_100_000, 633_334, 5_600_000, 0.5)
        image(16_733_334, 1_300_000)
        media(18_033_334, 2_000_000, 5_600_000, 0.5)
        let audio = (0..<3).map { k -> String in
            let t0 = Int64(1_033_334 + k * 10_000_000)
            return ExportPlans.audioSeg(String(format: "it_a%011d#a", k), asset: "md_speech000001", t0: t0, t1: t0 + 10_000_000, s0: 0)
        }
        return ExportPlans.plan(
            w: 1280, h: 720, fps: 30, gridFps: 30, durUs: 31_033_334,
            assets: [
                ExportPlans.video("md_fc0000000001", file: "frame_counter_1080p30.mp4", w: 1920, h: 1080, durUs: 8_000_000, hasAudio: false),
                ExportPlans.image("md_still0000001", file: "still_4k.jpg", w: 3840, h: 2160),
                ExportPlans.audio("md_speech000001", file: "speech_10s.m4a", durUs: 10_000_000),
            ],
            layers: layers, audio: audio)
    }

    func testSoakPlanExports() throws {
        var options = ExportHarness.Options()
        options.segmentDurationUs = 10_000_000
        let h = try ExportHarness(options)
        harnesses.append(h)
        let settings = ExportPlans.settings(1280, 720, fps: 30, videoBitrate: 5_000_000, audioBitrate: 192_000)
        for round in 0..<3 {
            let out = h.outputURL()
            let id = try h.start(self, plan: ExportStallTests.soakPlan(), settings: settings, output: out)
            let ended = JobEventRecorder.spin(timeout: 150) { h.recorder.ended(id) }
            let last = h.progress(id).last
            print("STALLTEST round \(round) ended=\(ended) last=\(String(describing: last?.framesDone))/\(String(describing: last?.framesTotal)) phase=\(String(describing: last?.phase))")
            XCTAssertTrue(ended, "round \(round) stalled at \(String(describing: last?.framesDone))")
            if !ended { return }
            XCTAssertNotNil(h.recorder.done(id), "round \(round) failed: \(String(describing: h.recorder.failure(id)?.message))")
        }
    }
}
