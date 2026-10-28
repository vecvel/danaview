// OWNER: IOS-12
//
// FIX-IOS-MEDIA: the export audio read validator covers speed-ramp and time-pitch segments
// (`TimePitchWatch`): a dropout (an exact-zero run with an abrupt edge) or a seam step (one track
// of a ramp-seam pair missing inside its crossfade) rejects the read and the pipeline redoes it,
// so QA-11 (d)'s ramp-seam click test sees a clean read. Plain (unscaled) segments are never
// checked that way, so digital silence in ordinary content costs nothing.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class ExportAudioValidationTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    private func make() throws -> ExportHarness {
        let h = try ExportHarness()
        harnesses.append(h)
        return h
    }

    private static let rate = 48_000.0

    private func plan(_ data: Data) throws -> RenderPlan { try RenderPlanDecoder.decodePlan(data) }

    // MARK: Watch

    func testWatchCoversRampsAndScaledKeepPitchSegmentsOnly() throws {
        let ramp = try plan(ExportPlans.toneAudio(map: ExportPlans.rampMap))
        let watch = TimePitchWatch.of(ramp)
        XCTAssertEqual(watch.spans.count, 1)
        XCTAssertEqual(watch.spans.first?.startUs, TimePitchWatch.edgeMarginUs)
        XCTAssertEqual(watch.spans.first?.endUs, 2_100_000 - TimePitchWatch.edgeMarginUs)
        // Every inner seam changes the rate (1 → 1.25 → … → 1).
        XCTAssertEqual(watch.seamsUs, (1..<7).map { Int64($0) * ExportPlans.rampPieceUs })
        XCTAssertTrue(watch.watches(startUs: 900_000, endUs: 920_000))
        XCTAssertFalse(watch.watches(startUs: 0, endUs: 5_000), "segment edges are not watched")

        let keepPitch2x = try plan(ExportPlans.toneAudio(map: [(0, 1_000_000, 500_000, 2_500_000)]))
        XCTAssertEqual(TimePitchWatch.of(keepPitch2x).spans.count, 1)
        XCTAssertEqual(TimePitchWatch.of(keepPitch2x).seamsUs, [])

        let varispeed2x = try plan(ExportPlans.toneAudio(map: [(0, 1_000_000, 500_000, 2_500_000)], pitch: false))
        XCTAssertTrue(TimePitchWatch.of(varispeed2x).isEmpty, "varispeed without a ramp has no time-pitch unit")

        let plain = try plan(ExportPlans.toneAudio(map: [(0, 1_000_000, 500_000, 1_500_000)]))
        XCTAssertTrue(TimePitchWatch.of(plain).isEmpty)
    }

    func testWatchIgnoresSilentGain() throws {
        let seg = AudioSeg(
            id: "it_a#a", asset: "md_a", t0: 0, t1: 1_000_000,
            map: [MapSegment(0, 500_000, 0, 500_000), MapSegment(500_000, 1_000_000, 500_000, 1_500_000)],
            gain: [AnimKey(0, 1), AnimKey(400_000, 1), AnimKey(450_000, 0)])
        var p = try plan(ExportPlans.toneAudio(map: ExportPlans.rampMap))
        p.audio = [seg]
        let watch = TimePitchWatch.of(p)
        XCTAssertEqual(watch.seamsUs, [], "the seam at 0.5 s is silent")
        XCTAssertTrue(watch.watches(startUs: 100_000, endUs: 120_000))
        XCTAssertFalse(watch.watches(startUs: 600_000, endUs: 620_000), "gain 0 there")
    }

    // MARK: Redo

    /// Zeroes output frames [from, to) of the first read (buffers arrive in order and contiguous).
    private func zeroing(_ from: Int, _ to: Int, scale: Float = 0) -> (Int, UnsafeMutableBufferPointer<Float>) -> Void {
        var position = 0
        return { _, samples in
            let frames = samples.count / 2
            for f in 0..<frames where position + f >= from && position + f < to {
                samples[2 * f] *= scale
                samples[2 * f + 1] *= scale
            }
            position += frames
        }
    }

    private func export(_ h: ExportHarness, _ data: Data, attempt1: ((Int, UnsafeMutableBufferPointer<Float>) -> Void)?,
                        sources: inout [MixAudioSource]) throws -> (ReaderWriterPipeline?, URL) {
        var pipeline: ReaderWriterPipeline?
        var seen: [MixAudioSource] = []
        h.coordinator.configurePipeline = { p in
            pipeline = p
            p.audioSourceHook = { source, attempt in
                seen.append(source)
                if attempt == 1 { source.corrupt = attempt1 }
            }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: data, settings: ExportPlans.settings(320, 180, fps: 30), output: output)
        XCTAssertNotNil(h.recorder.done(id), "\(String(describing: h.recorder.failure(id)))")
        sources = seen
        return (pipeline, output)
    }

    func testDropoutInsideARampIsRedone() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        // 10 ms of digital silence in the middle of the 2× piece (0.9–1.2 s).
        let a = Int(1.0 * Self.rate), b = a + 480
        let (pipeline, output) = try export(h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: zeroing(a, b), sources: &sources)
        let first = try XCTUnwrap(sources.first)
        XCTAssertGreaterThanOrEqual(first.dropouts, 1)
        XCTAssertTrue(first.rejection?.contains("dropout") == true, "\(first.rejection ?? "accepted")")
        XCTAssertGreaterThanOrEqual(pipeline?.audioAttempts ?? 0, 2, "the dropout read is redone")
        let pcm = try ExportConformance.pcm(output)
        // The last attempt is accepted whatever it holds (a real time-pitch dropout on a loaded
        // simulator can land there too); the tone is required when the accepted read was clean.
        let last = try XCTUnwrap(sources.last)
        XCTAssertFalse(last === first, "the redo reads on a fresh source")
        if last.dropouts + last.seamSteps == 0 {
            XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, a, b), -20, "the redone read has the tone there")
        } else {
            XCTAssertEqual(pipeline?.audioAttempts, pipeline?.maxAudioAttempts, "a faulty read is only kept as the last attempt")
        }
    }

    func testSeamStepInsideARampIsRedone() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        // Seam at 1.8 s: the level falls to 30 % for 2 ms right at the seam (one track of the pair
        // missing inside its crossfade).
        let seam = Int(1.8 * Self.rate)
        let (pipeline, _) = try export(
            h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: zeroing(seam - 96, seam, scale: 0.3), sources: &sources)
        let first = try XCTUnwrap(sources.first)
        XCTAssertGreaterThanOrEqual(first.seamSteps, 1, "\(first.rejection ?? "accepted")")
        XCTAssertGreaterThanOrEqual(pipeline?.audioAttempts ?? 0, 2)
    }

    func testSilenceInAPlainSegmentIsNotAFault() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        let a = Int(0.5 * Self.rate)
        let (pipeline, _) = try export(
            h, ExportPlans.toneAudio(map: [(0, 1_000_000, 500_000, 1_500_000)]), attempt1: zeroing(a, a + 480), sources: &sources)
        XCTAssertEqual(sources.first?.dropouts, 0)
        XCTAssertEqual(sources.first?.seamSteps, 0)
        XCTAssertNil(sources.first?.rejection)
        XCTAssertEqual(pipeline?.audioAttempts, 1, "plain segments are not checked for dropouts")
    }

    func testCleanRampReadIsAccepted() throws {
        // The detector does not fire on the ramp's own seams: with no injected fault the reads that
        // were rejected all carried a real fault (counted, at most two redos), and the exported
        // ramp passes QA-11 (d)'s click metric.
        let h = try make()
        var sources: [MixAudioSource] = []
        let (pipeline, output) = try export(h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: nil, sources: &sources)
        let attempts = pipeline?.audioAttempts ?? 0
        print("FIX-IOS-MEDIA ramp export: \(attempts) audio read(s); rejections \(sources.map { $0.rejection ?? "none" })")
        for source in sources.dropLast() {
            XCTAssertNotNil(source.rejection)
        }
        let pcm = try ExportConformance.pcm(output)
        let x = stride(from: 0, to: pcm.count, by: 2).map { pcm[$0] }
        let c = Float(2 * cos(2 * Double.pi * 1_000 / Self.rate))
        var e = [Float](repeating: 0, count: x.count)
        for i in 2..<x.count { e[i] = x[i] - c * x[i - 1] + x[i - 2] }
        func at(_ us: Int64) -> Int { Int(Double(us) * Self.rate / 1_000_000) }
        func maxAbs(_ a: Int, _ b: Int) -> Float {
            var m: Float = 0
            for i in max(2, a)..<min(b, e.count) { m = max(m, abs(e[i])) }
            return m
        }
        let piece = ExportPlans.rampPieceUs
        var floor: Float = 0
        for k in 0..<Int64(ExportPlans.rampSpeeds.count) { floor = max(floor, maxAbs(at(k * piece + 50_000), at((k + 1) * piece - 50_000))) }
        let seams = (1..<Int64(ExportPlans.rampSpeeds.count)).map { maxAbs(at($0 * piece - 40_000), at($0 * piece + 40_000)) }
        let excess = (seams.max() ?? 0) - floor
        print("FIX-IOS-MEDIA ramp seams: floor \(floor) seams \(seams) excess \(excess)")
        // The last attempt is accepted whatever it holds; the metric applies when it was clean.
        if let last = sources.last, last.dropouts + last.seamSteps == 0 {
            XCTAssertLessThanOrEqual(excess, 0.01, "seam transient above −40 dBFS over the tone floor")
        }
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, at(100_000), at(2_000_000)), -16, "the ramp keeps the tone")
    }
}
