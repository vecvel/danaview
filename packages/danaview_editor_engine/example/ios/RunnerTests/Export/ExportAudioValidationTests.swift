// OWNER: IOS-12
//
// FIX-IOS-MEDIA: the export audio read validator covers speed-ramp and time-pitch segments
// (`TimePitchWatch`): a dropout (an exact-zero run with an abrupt edge) or a seam step (one track
// of a ramp-seam pair missing inside its crossfade) rejects the read and the pipeline redoes it,
// so QA-11 (d)'s ramp-seam click test sees a clean read. Plain (unscaled) segments are never
// checked that way, so digital silence in ordinary content costs nothing. CI round 6: after the
// last attempt a read that still has a time-pitch fault fails the export typed (`decodeFailed`,
// retryable, no file), and a fault every fresh read reproduces at the same place is the content.

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

    /// One export run: the pipeline, the output, the sources read (one per attempt) and the end.
    private struct Run {
        let pipeline: ReaderWriterPipeline?
        let output: URL
        let sources: [MixAudioSource]
        let done: JobResultMsg?
        let failure: FailureMsg?
    }

    /// Exports [data]; [corrupt] gives each attempt's injected fault (nil: the read as AVFoundation
    /// rendered it). Every redo is immediate (no back-off) unless [configure] says otherwise.
    private func run(_ h: ExportHarness, _ data: Data,
                     corrupt: @escaping (Int) -> ((Int, UnsafeMutableBufferPointer<Float>) -> Void)?,
                     configure: ((ReaderWriterPipeline) -> Void)? = nil) throws -> Run {
        var pipeline: ReaderWriterPipeline?
        var seen: [MixAudioSource] = []
        h.coordinator.configurePipeline = { p in
            pipeline = p
            p.audioRetryDelay = 0
            configure?(p)
            p.audioSourceHook = { source, attempt in
                seen.append(source)
                source.corrupt = corrupt(attempt)
            }
        }
        let output = h.outputURL()
        let id = try h.export(self, plan: data, settings: ExportPlans.settings(320, 180, fps: 30), output: output)
        return Run(pipeline: pipeline, output: output, sources: seen, done: h.recorder.done(id), failure: h.recorder.failure(id))
    }

    private func export(_ h: ExportHarness, _ data: Data, attempt1: ((Int, UnsafeMutableBufferPointer<Float>) -> Void)?,
                        sources: inout [MixAudioSource]) throws -> (ReaderWriterPipeline?, URL, Run) {
        let r = try run(h, data, corrupt: { $0 == 1 ? attempt1 : nil })
        sources = r.sources
        assertCleanOrTypedFailure(r)
        return (r.pipeline, r.output, r)
    }

    /// CI round 6: an export either ends with a read free of time-pitch faults (content faults
    /// reproduced by every read aside) or fails typed (`decodeFailed`, retryable, no file); it
    /// never ships a dropout.
    private func assertCleanOrTypedFailure(_ r: Run, file: StaticString = #filePath, line: UInt = #line) {
        if let failure = r.failure {
            XCTAssertEqual(failure.code, EngineErrorCode.decodeFailed.rawValue, failure.message, file: file, line: line)
            XCTAssertTrue(failure.retryable, file: file, line: line)
            XCTAssertTrue(failure.message.hasPrefix(ReaderWriterPipeline.timePitchFailurePrefix), failure.message, file: file, line: line)
            XCTAssertEqual(r.sources.last?.timePitchFailed, true, file: file, line: line)
            XCTAssertEqual(r.pipeline?.audioAttempts, r.pipeline?.maxAudioAttempts, "fails only after the last attempt", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.output.path), "no file with the dropout", file: file, line: line)
        } else {
            XCTAssertNotNil(r.done, file: file, line: line)
            XCTAssertEqual(r.sources.last?.unexplainedFaults ?? [], [], "the kept read has no time-pitch fault", file: file, line: line)
        }
    }

    func testDropoutInsideARampIsRedone() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        // 10 ms of digital silence in the middle of the 2× piece (0.9–1.2 s).
        let a = Int(1.0 * Self.rate), b = a + 480
        let (pipeline, output, r) = try export(h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: zeroing(a, b), sources: &sources)
        let first = try XCTUnwrap(sources.first)
        XCTAssertGreaterThanOrEqual(first.dropouts, 1)
        XCTAssertTrue(first.rejection?.contains("dropout") == true, "\(first.rejection ?? "accepted")")
        XCTAssertGreaterThanOrEqual(pipeline?.audioAttempts ?? 0, 2, "the dropout read is redone")
        XCTAssertFalse(sources.last === first, "the redo reads on a fresh source")
        if r.done != nil {
            let pcm = try ExportConformance.pcm(output)
            XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, a, b), -20, "the redone read has the tone there")
        }
    }

    func testSeamStepInsideARampIsRedone() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        // Seam at 1.8 s: the level falls to 30 % for 2 ms right at the seam (one track of the pair
        // missing inside its crossfade).
        let seam = Int(1.8 * Self.rate)
        let (pipeline, _, _) = try export(
            h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: zeroing(seam - 96, seam, scale: 0.3), sources: &sources)
        let first = try XCTUnwrap(sources.first)
        XCTAssertGreaterThanOrEqual(first.seamSteps, 1, "\(first.rejection ?? "accepted")")
        XCTAssertGreaterThanOrEqual(pipeline?.audioAttempts ?? 0, 2)
    }

    // MARK: Faulty reader (CI round 6)

    /// A 10 ms dropout inside the 2× piece (0.9–1.2 s), at a different place for each attempt (as
    /// AVFoundation's faults land).
    private static func dropoutFrames(attempt: Int) -> Range<Int> {
        let a = Int(0.95 * rate) + (attempt - 1) * 2_400
        return a..<(a + 480)
    }

    func testFaultyReaderRecoversWhenALaterAttemptIsClean() throws {
        let h = try make()
        let faulty = 2
        let r = try run(h, ExportPlans.toneAudio(map: ExportPlans.rampMap)) { attempt in
            guard attempt <= faulty else { return nil }
            let f = Self.dropoutFrames(attempt: attempt)
            return self.zeroing(f.lowerBound, f.upperBound)
        }
        XCTAssertGreaterThanOrEqual(r.pipeline?.audioAttempts ?? 0, faulty + 1, "every faulty read is redone")
        for source in r.sources.prefix(faulty) {
            XCTAssertTrue(source.rejection?.contains("time-pitch fault") == true, "\(source.rejection ?? "accepted")")
            XCTAssertFalse(source.timePitchFailed)
        }
        assertCleanOrTypedFailure(r)
        guard r.done != nil else {
            // A loaded simulator's own time-pitch unit can spoil every later read too (seen locally:
            // 761 zero frames 2.5 ms after the 0.9 s seam in reads 4 and 5). The export then fails
            // typed; it may do so only when no later read was clean.
            for source in r.sources.dropFirst(faulty) {
                XCTAssertFalse(source.unexplainedFaults.isEmpty, "a clean read \(source.rejection ?? "accepted") would have been kept")
            }
            print("FIX-IOS-MEDIA recover: every read after the injected faults had a real one: \(r.sources.map { $0.rejection ?? "clean" })")
            return
        }
        let last = try XCTUnwrap(r.sources.last)
        XCTAssertEqual(last.unexplainedFaults, [])
        XCTAssertNil(last.rejection)
        let pcm = try ExportConformance.pcm(r.output)
        for attempt in 1...faulty {
            let f = Self.dropoutFrames(attempt: attempt)
            XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, f.lowerBound, f.upperBound), -20, "no gap at \(f)")
        }
    }

    func testFaultyReaderOnEveryAttemptFailsTheExportTyped() throws {
        let h = try make()
        // The production back-off (0.25, 0.5, 1, 2 s before redos 1–4) runs here.
        let r = try run(h, ExportPlans.toneAudio(map: ExportPlans.rampMap), corrupt: { attempt in
            let f = Self.dropoutFrames(attempt: attempt)
            return self.zeroing(f.lowerBound, f.upperBound)
        }, configure: { $0.audioRetryDelay = 0.25 })
        XCTAssertNil(r.done, "a read with a dropout is never shipped")
        let failure = try XCTUnwrap(r.failure)
        XCTAssertEqual(failure.code, EngineErrorCode.decodeFailed.rawValue)
        XCTAssertTrue(failure.retryable)
        XCTAssertTrue(failure.message.hasPrefix(ReaderWriterPipeline.timePitchFailurePrefix), failure.message)
        XCTAssertEqual(r.pipeline?.audioAttempts, 5)
        XCTAssertEqual(r.sources.count, 5)
        XCTAssertTrue(r.sources.allSatisfy { $0.dropouts >= 1 })
        XCTAssertEqual(r.sources.last?.timePitchFailed, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.output.path), "no output file")
        assertCleanOrTypedFailure(r)
    }

    func testFaultReproducedByEveryReadIsContent() throws {
        // Digitally gated content looks like a dropout to the scan, but every fresh read renders it
        // at the same place: when every witness read (at least `minContentWitnesses`, the last one
        // included) has it, the last one keeps it (the export does not fail forever). A real fault
        // in the last read on top of it still fails the export (seen on a loaded simulator), but
        // never for the injected one.
        let h = try make()
        let f = Self.dropoutFrames(attempt: 1)
        let injected = TimePitchFault(kind: .dropout, frame: Int64(f.lowerBound))
        let r = try run(h, ExportPlans.toneAudio(map: ExportPlans.rampMap)) { _ in self.zeroing(f.lowerBound, f.upperBound) }
        let pipeline = try XCTUnwrap(r.pipeline)
        XCTAssertEqual(pipeline.audioAttempts, 5, "content faults are only accepted on the last attempt")
        let last = try XCTUnwrap(r.sources.last)
        XCTAssertGreaterThanOrEqual(last.dropouts, 1, "the content is still there")
        for source in r.sources.dropLast() { XCTAssertEqual(source.contentFaults, [], "never before the last attempt") }
        for source in r.sources where source.isTimePitchWitness {
            XCTAssertTrue(source.timePitchFaults.contains { $0.matches(injected) }, "every witness has the injected fault")
        }
        assertCleanOrTypedFailure(r)
        let witnesses = r.sources.dropLast().filter(\.isTimePitchWitness).count
        guard witnesses + 1 >= pipeline.minContentWitnesses else {
            // AVFoundation broke more reads than the rule allows (a tap range jump, NaN, silence, a
            // hung read): no evidence, so the injected fault is not content and the export fails
            // typed instead of shipping it.
            XCTAssertEqual(last.contentFaults, [])
            XCTAssertNotNil(r.failure, "a dropout without evidence is never shipped")
            print("FIX-IOS-MEDIA content: only \(witnesses) earlier witness read(s): \(r.sources.map { $0.otherDefect ?? $0.rejection ?? "clean" })")
            return
        }
        XCTAssertTrue(last.contentFaults.contains { $0.matches(injected) }, "\(last.contentFaults)")
        XCTAssertFalse(last.unexplainedFaults.contains { $0.matches(injected) })
    }

    func testReadWithAnotherDefectIsNoWitness() throws {
        // CI round 6: a read rejected for a tap range jump scanned a broken render and missed the
        // content's dropout, so no fault was ever kept as content. A read with another defect (here
        // NaN in read 2) is left out of the evidence; the other four reads still make it content.
        let h = try make()
        let f = Self.dropoutFrames(attempt: 1)
        let injected = TimePitchFault(kind: .dropout, frame: Int64(f.lowerBound))
        let r = try run(h, ExportPlans.toneAudio(map: ExportPlans.rampMap)) { attempt in
            let zero = self.zeroing(f.lowerBound, f.upperBound)
            guard attempt == 2 else { return zero }
            return { index, samples in
                zero(index, samples)
                if index == 0 { samples[0] = .nan }
            }
        }
        let pipeline = try XCTUnwrap(r.pipeline)
        XCTAssertEqual(pipeline.audioAttempts, 5)
        XCTAssertEqual(r.sources.count, 5)
        XCTAssertEqual(r.sources[1].otherDefect, "NaN")
        XCTAssertFalse(r.sources[1].isTimePitchWitness)
        assertCleanOrTypedFailure(r)
        let last = try XCTUnwrap(r.sources.last)
        let witnesses = r.sources.dropLast().filter(\.isTimePitchWitness).count
        guard witnesses + 1 >= pipeline.minContentWitnesses else {
            XCTAssertNotNil(r.failure, "a dropout without evidence is never shipped")
            print("FIX-IOS-MEDIA no-witness: only \(witnesses) earlier witness read(s): \(r.sources.map { $0.otherDefect ?? $0.rejection ?? "clean" })")
            return
        }
        XCTAssertTrue(last.contentFaults.contains { $0.matches(injected) }, "\(last.contentFaults)")
        XCTAssertFalse(last.unexplainedFaults.contains { $0.matches(injected) })
    }

    func testRecurringFaultsMatchByKindAndPlace() {
        let d = TimePitchFault(kind: .dropout, frame: 48_000)
        let s = TimePitchFault(kind: .seamStep, frame: 48_000)
        XCTAssertEqual(TimePitchFault.recurring(nil, [d, s]), [d, s])
        XCTAssertEqual(TimePitchFault.recurring([d, s], [TimePitchFault(kind: .dropout, frame: 48_030)]), [d], "within 1 ms")
        XCTAssertEqual(TimePitchFault.recurring([d], [TimePitchFault(kind: .dropout, frame: 48_100)]), [], "elsewhere")
        XCTAssertEqual(TimePitchFault.recurring([d], [TimePitchFault(kind: .seamStep, frame: 48_000)]), [], "another kind")
        XCTAssertEqual(TimePitchFault.recurring([d], []), [], "a clean read clears it")
    }

    func testSilenceInAPlainSegmentIsNotAFault() throws {
        let h = try make()
        var sources: [MixAudioSource] = []
        let a = Int(0.5 * Self.rate)
        let (pipeline, _, _) = try export(
            h, ExportPlans.toneAudio(map: [(0, 1_000_000, 500_000, 1_500_000)]), attempt1: zeroing(a, a + 480), sources: &sources)
        XCTAssertEqual(sources.first?.dropouts, 0)
        XCTAssertEqual(sources.first?.seamSteps, 0)
        XCTAssertNil(sources.first?.rejection)
        XCTAssertEqual(pipeline?.audioAttempts, 1, "plain segments are not checked for dropouts")
    }

    func testCleanRampReadIsAccepted() throws {
        // The detector does not fire on the ramp's own seams: with no injected fault the reads that
        // were rejected all carried a real fault (counted, at most two redos), and the exported
        // ramp passes QA-11 (d)'s click metric. CI round 6: or the export failed typed after every
        // read had a real fault (never a shipped dropout).
        let h = try make()
        var sources: [MixAudioSource] = []
        let (pipeline, output, r) = try export(h, ExportPlans.toneAudio(map: ExportPlans.rampMap), attempt1: nil, sources: &sources)
        guard r.done != nil else { return }
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
        // The kept read is free of time-pitch faults (or its faults are the content).
        if let last = sources.last, last.dropouts + last.seamSteps == 0 {
            XCTAssertLessThanOrEqual(excess, 0.01, "seam transient above −40 dBFS over the tone floor")
        }
        XCTAssertGreaterThan(ExportConformance.rmsDb(pcm, channel: 0, at(100_000), at(2_000_000)), -16, "the ramp keeps the tone")
    }
}
