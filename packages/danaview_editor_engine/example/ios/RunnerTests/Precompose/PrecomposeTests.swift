// OWNER: IOS-20
//
// IOS-20 acceptance (ARCH D-45(B), §14.2 'Multi-pass fallback'):
// - a precomposed export equals a single-pass export of the same plan: SSIM ≥ 0.995 per frame,
//   grid-cut barcodes 100% (base and every PiP slot), identical frame count and audio;
// - a forced decoder limit of 2 exports a 5-track project instead of failing;
// - an interruption during pass 1 and during the final pass resumes correctly (in process and
//   after a kill), and never redoes a finished pass;
// - cancel cleans every intermediate; failures clean them too; disk preflight counts them;
// - `decoderInitFailed` (at export start, and in a pass) re-plans with fewer tracks per pass;
// - the `.rotated` encode layout carries through the intermediates;
// - conformance (QA-11 rules, ExportConformance.check) on every output;
// - the planner: bottom prefixes in draw order, valid pass plans, hashes that cover every pass
//   below, placeholder uris.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class PrecomposeTests: XCTestCase {
    private var harnesses: [PrecomposeHarness] = []
    private var plain: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.h.remove() }
        plain.forEach { $0.remove() }
        harnesses = []
        plain = []
    }

    private func make(decoderLimit: Int, segmentDurationUs: Int64 = PrecomposeFixtures.segmentDurationUs, probe: EncoderProbe = .system,
                      roots: TempRoots? = nil) throws -> PrecomposeHarness {
        let p = try PrecomposeHarness(decoderLimit: decoderLimit, segmentDurationUs: segmentDurationUs, probe: probe, roots: roots)
        harnesses.append(p)
        return p
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func decoded(_ data: Data) throws -> RenderPlan { try RenderPlanDecoder.decodePlan(data) }

    /// A single-pass reference export of [plan].
    private func reference(_ plan: Data, settings: EncodeSettingsMsg, probe: EncoderProbe = .system) throws -> URL {
        let h = try ExportHarness(ExportHarness.Options(probe: probe, segmentDurationUs: PrecomposeFixtures.segmentDurationUs))
        plain.append(h)
        let output = h.outputURL()
        let id = try h.export(self, plan: plan, settings: settings, output: output)
        XCTAssertNil(h.recorder.failure(id), "reference export failed")
        return output
    }

    // MARK: Planner

    func testPlannerCutsBottomPrefixesThatFitTheLimit() throws {
        let plan = try decoded(PrecomposeFixtures.plan(durUs: 1_000_000))
        let s = try PrecomposePlanner.schedule(plan, limit: 2, rotated: false)
        XCTAssertEqual(s.passes.count, 3)
        XCTAssertEqual(s.passes.map(\.layerIds), [
            ["it_base00000001#v", "it_pip10000000#v"], ["it_pip20000000#v"], ["it_pip30000000#v"],
        ])
        XCTAssertEqual(s.finalPlan.layers.map(\.id), ["!precompose-3", "it_pip40000000#v"])
        for pass in s.passes {
            XCTAssertLessThanOrEqual(pass.decoderTracks, 2)
            XCTAssertTrue(pass.plan.audio.isEmpty, "intermediates are video only")
            XCTAssertEqual(PlanValidator.validate(pass.plan).map(\.code), [], "pass \(pass.index) plan is valid")
            XCTAssertEqual(pass.plan.canvas, plan.canvas, "export size and frame grid")
            XCTAssertEqual(pass.plan.target, .export)
        }
        XCTAssertLessThanOrEqual(s.finalDecoderTracks, 2)
        XCTAssertEqual(s.finalPlan.audio, plan.audio, "audio is mixed once, in the final pass")
        XCTAssertEqual(PlanValidator.validate(s.finalPlan).map(\.code), [])
        // Intermediates: full canvas, identity, whole duration, a fresh slot, below everything.
        let bottom = try XCTUnwrap(s.finalPlan.layers.first)
        XCTAssertEqual(bottom.kind, .media)
        XCTAssertEqual(bottom.seq, 5)
        XCTAssertEqual(bottom.t0, 0)
        XCTAssertEqual(bottom.t1, plan.durUs)
        XCTAssertEqual(bottom.map, [MapSegment(0, plan.durUs, 0, plan.durUs)])
        XCTAssertEqual(bottom.base, PlanSize(w: 640, h: 360))
        XCTAssertTrue(bottom.xf.isIdentity)
        let asset = try XCTUnwrap(s.finalPlan.assets[bottom.asset!])
        XCTAssertEqual(asset.uri, PrecomposePlanner.placeholderURI(3))
        XCTAssertEqual(asset.fp, "precompose:\(s.passes[2].hash)")
        XCTAssertEqual(asset.hasAudio, false)
        XCTAssertEqual(s.passes[1].plan.layers.first?.id, "!precompose-1")
        XCTAssertNil(s.passes[0].plan.assets[PrecomposePlanner.assetId(1)])

        // Within the limit: no passes, the plan itself.
        let fits = try PrecomposePlanner.schedule(plan, limit: 5, rotated: false)
        XCTAssertTrue(fits.passes.isEmpty)
        XCTAssertEqual(fits.finalPlan, plan)

        // A limit of 3: pass 1 takes three slots, the final the intermediate and two.
        let three = try PrecomposePlanner.schedule(plan, limit: 3, rotated: false)
        XCTAssertEqual(three.passes.map(\.layerIds), [["it_base00000001#v", "it_pip10000000#v", "it_pip20000000#v"]])
        XCTAssertEqual(three.finalDecoderTracks, 3)
    }

    func testPassHashesCoverEveryPassBelowAndTheLayout() throws {
        let plan = try decoded(PrecomposeFixtures.plan(durUs: 1_000_000))
        let a = try PrecomposePlanner.schedule(plan, limit: 2, rotated: false)
        let again = try PrecomposePlanner.schedule(plan, limit: 2, rotated: false)
        XCTAssertEqual(a.passes.map(\.hash), again.passes.map(\.hash), "stable")
        // A change in the bottom pass changes every hash above it.
        var changed = plan
        changed.layers[0].xf.op = 0.5
        let b = try PrecomposePlanner.schedule(changed, limit: 2, rotated: false)
        for (x, y) in zip(a.passes, b.passes) { XCTAssertNotEqual(x.hash, y.hash, "pass \(x.index)") }
        // A change above pass 1 keeps pass 1.
        var top = plan
        top.layers[3].xf.op = 0.5
        let c = try PrecomposePlanner.schedule(top, limit: 2, rotated: false)
        XCTAssertEqual(c.passes[0].hash, a.passes[0].hash)
        XCTAssertEqual(c.passes[1].hash, a.passes[1].hash)
        XCTAssertNotEqual(c.passes[2].hash, a.passes[2].hash)
        // The layout is part of the hash; rotated intermediates say rot 90.
        let r = try PrecomposePlanner.schedule(plan, limit: 2, rotated: true)
        XCTAssertNotEqual(r.passes[0].hash, a.passes[0].hash)
        XCTAssertEqual(r.finalPlan.assets[PrecomposePlanner.assetId(3)]?.rot, 90)
        // Placeholders resolve to real files.
        let dir = URL(fileURLWithPath: "/tmp/job", isDirectory: true)
        let resolved = PrecomposePlanner.resolve(a.finalPlan) { PrecomposeExporter.intermediateURL($0, directory: dir) }
        XCTAssertEqual(resolved.assets[PrecomposePlanner.assetId(3)]?.uri, "file:///tmp/job/pre-3.mov")
        XCTAssertEqual(resolved.assets["md_fc0000000001"], a.finalPlan.assets["md_fc0000000001"])
    }

    func testPlannerKeepsDrawOrderAtZeroZAndCarriesNonMediaLayers() throws {
        let durUs: Int64 = 1_000_000
        let data = ExportPlans.plan(
            w: 320, h: 180, fps: 25, durUs: durUs,
            assets: [ExportPlans.video("md_fc0000000001", file: "frame_counter_720p25.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false)],
            layers: [
                ExportPlans.mediaLayer("a0", asset: "md_fc0000000001", seq: 0, t0: 0, t1: durUs, w: 320, h: 180, z: 0),
                ExportPlans.solid("s0", t0: 0, t1: durUs, color: "#FF000080", w: 50, h: 50, cx: 40, cy: 40, z: 0),
                ExportPlans.mediaLayer("b0", asset: "md_fc0000000001", seq: 1, t0: 0, t1: durUs, w: 100, h: 60, z: 1),
                ExportPlans.mediaLayer("c0", asset: "md_fc0000000001", seq: 2, t0: 0, t1: durUs, w: 100, h: 60, z: 1),
                ExportPlans.solid("s1", t0: 0, t1: durUs, color: "#00FF0080", w: 50, h: 50, cx: 80, cy: 40, z: 2),
            ])
        let plan = try decoded(data)
        let s = try PrecomposePlanner.schedule(plan, limit: 2, rotated: false)
        // Draw order a0, s0, b0, c0, s1 (z 0, 0, 1, 1, 2): pass 1 takes a0, s0 (no decoder) and b0.
        XCTAssertEqual(s.passes.map(\.layerIds), [["a0", "s0", "b0"]])
        XCTAssertEqual(s.finalPlan.layers.map(\.id), ["!precompose-1", "c0", "s1"])
        XCTAssertEqual(s.finalPlan.layers.first?.z, 0, "z = min − 1")

        // The remaining layers start at z 0 behind an id that sorts first: they move up one z.
        let bottom = PrecomposePlanner.intermediate(pass: 1, hash: "h", plan: plan, seq: 9, rotated: false).layer
        var early = plan.layers[0]
        early.id = " "
        let stacked = PrecomposePlanner.stack([early, plan.layers[2]], over: bottom)
        XCTAssertEqual(stacked.map(\.id), ["!precompose-1", " ", "b0"])
        XCTAssertEqual(stacked.map(\.z), [0, 1, 2])
        // Otherwise z 0 is shared and the bottom still draws first.
        let shared = PrecomposePlanner.stack([plan.layers[0]], over: bottom)
        XCTAssertEqual(shared.map(\.id), ["!precompose-1", "a0"])
        XCTAssertEqual(shared.map(\.z), [0, 0])
    }

    func testLimits() {
        XCTAssertEqual(PrecomposePlanner.initialLimit(reason: .decoderLimit(needed: 5, limit: 2), decoderLimit: 2, needed: 5), 2)
        XCTAssertEqual(PrecomposePlanner.initialLimit(reason: .decoderLimit(needed: 5, limit: 1), decoderLimit: 1, needed: 5), 2)
        XCTAssertEqual(PrecomposePlanner.initialLimit(reason: .decoderInitFailed, decoderLimit: 16, needed: 4), 3)
        XCTAssertEqual(PrecomposePlanner.initialLimit(reason: .decoderInitFailed, decoderLimit: 16, needed: 30), 16)
        XCTAssertNil(PrecomposePlanner.initialLimit(reason: .decoderInitFailed, decoderLimit: 16, needed: 2), "nothing to split")
        XCTAssertEqual(PrecomposePlanner.reducedLimit(16), 12)
        XCTAssertEqual(PrecomposePlanner.reducedLimit(3), 2)
        XCTAssertNil(PrecomposePlanner.reducedLimit(2))
        // Intermediates: ≥ 4× the export bitrate, video only, export size.
        let settings = EncoderSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 10_000_000)
        XCTAssertEqual(PrecomposePass.bitrate(for: settings), 40_000_000)
        let seg = PrecomposePass.segmentSettings(settings, layout: .native)
        XCTAssertNil(seg.audio)
        XCTAssertEqual(seg.width, 1920)
        XCTAssertEqual(seg.fps, 30)
        XCTAssertEqual(seg.container, .mov)
        XCTAssertFalse(seg.allowFrameReordering)
        let rot = PrecomposePass.segmentSettings(EncoderSettings(width: 1080, height: 1920, fps: 30, videoBitrate: 1), layout: .rotated)
        XCTAssertEqual([rot.width, rot.height], [1920, 1080])
        XCTAssertGreaterThanOrEqual(rot.averageBitRate, Int(Double(1080 * 1920 * 30) * 0.2))
        // Disk counts the intermediates alive at once.
        let single = settings.requiredBytes(durationUs: 10_000_000)
        let one = PrecomposeExporter.requiredBytes(settings, durationUs: 10_000_000, remainingPasses: 1)
        let three = PrecomposeExporter.requiredBytes(settings, durationUs: 10_000_000, remainingPasses: 3)
        XCTAssertGreaterThan(one, single + 40_000_000 * 10 / 8)
        XCTAssertEqual(three - single, 2 * (one - single))
    }

    func testDiscoveryFindsThePrecomposeExporter() throws {
        let p = try make(decoderLimit: 16)
        XCTAssertTrue(ExportCoordinator.discoverMultiPass(context: p.h.context) is PrecomposeExporter)
    }

    // MARK: Equivalence

    func testDecoderLimit2Exports5TrackProjectMatchingSinglePass() throws {
        let durUs: Int64 = 2_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs)
        let settings = PrecomposeFixtures.settings()
        let single = try reference(plan, settings: settings)

        let p = try make(decoderLimit: 2)
        let output = p.h.outputURL()
        let preflight = try p.h.preflight(self, plan: plan, settings: settings)
        XCTAssertTrue(preflight.ok, "preflight never refuses for layer counts")
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        XCTAssertNil(p.h.recorder.failure(id), "a forced decoder limit of 2 exports instead of failing")
        XCTAssertNotNil(p.h.recorder.done(id))
        XCTAssertEqual(p.exporter.runs.map(\.index), [1, 2, 3])
        XCTAssertEqual(p.exporter.runs.map(\.startSegment), [0, 0, 0])

        // Conformance (QA-11 rules) and identical frame count.
        let multiFacts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        let singleFacts = try ExportConformance.check(single, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(multiFacts.frames, singleFacts.frames)
        XCTAssertEqual(multiFacts.frames, 50)

        // SSIM ≥ 0.995 per frame against the single pass.
        let ssim = try PrecomposeCheck.ssimPerFrame(single, output)
        XCTAssertEqual(ssim.count, 50)
        for (k, v) in ssim.enumerated() { XCTAssertGreaterThanOrEqual(v, 0.995, "SSIM of frame \(k)") }
        print("IOS-20 SSIM min \(ssim.min() ?? 0) mean \(ssim.reduce(0, +) / Double(max(1, ssim.count)))")

        // Grid-cut barcodes 100% in both.
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 4), [])
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(single, pips: 4), [])

        // Identical audio (mixed once, in the final pass): RMS per 20 ms within 0.5 dB.
        let a = PrecomposeCheck.rmsWindows(try ExportConformance.pcm(single))
        let b = PrecomposeCheck.rmsWindows(try ExportConformance.pcm(output))
        XCTAssertEqual(a.count, b.count)
        for (i, (x, y)) in zip(a, b).enumerated() where x > -60 || y > -60 {
            XCTAssertEqual(x, y, accuracy: 0.5, "RMS window \(i)")
        }

        // One continuous fraction over every pass, within the existing phases.
        let fractions = p.h.progress(id).map(\.fraction)
        for (x, y) in zip(fractions, fractions.dropFirst()) { XCTAssertGreaterThanOrEqual(y, x - 1e-9, "progress never goes back") }
        XCTAssertTrue(p.h.progress(id).contains { $0.phase == .rendering && $0.fraction > 0.05 && $0.fraction < 0.75 })
        XCTAssertEqual(p.h.progress(id).last?.fraction ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(p.h.progress(id).last?.framesTotal, 50)

        // Intermediates are gone with the job directory.
        XCTAssertFalse(exists(p.jobDirectory(id)))
        XCTAssertEqual(p.leftovers(), [])
    }

    func testRotatedLayoutCarriesThroughTheIntermediates() throws {
        // Portrait refused by the encoder probe: the job encodes landscape with rotation metadata
        // (ARCH §14.1); the intermediates are written rotated and turned back upright (rot 90).
        let probe = EncoderProbe.refusing { _, w, h in h > w }
        let durUs: Int64 = 1_000_000
        let plan = PrecomposeFixtures.plan(w: 360, h: 640, durUs: durUs, pips: 2, withAudio: false)
        let settings = PrecomposeFixtures.settings(w: 360, h: 640)
        let single = try reference(plan, settings: settings, probe: probe)
        let p = try make(decoderLimit: 2, probe: probe)
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        XCTAssertNil(p.h.recorder.failure(id))
        XCTAssertEqual(p.exporter.runs.map(\.index), [1])
        // Encoded landscape with a 90° clockwise display transform (ARCH §14.1), otherwise conformant.
        let facts = try ExportConformance.inspect(output)
        XCTAssertEqual([facts.width, facts.height], [640, 360])
        XCTAssertEqual(facts.transform, EncodeLayout.rotatedTransform(encodedHeight: 360))
        XCTAssertEqual(facts.codec, "avc1")
        XCTAssertEqual(Double(facts.nominalFps), 25, accuracy: 0.5)
        XCTAssertEqual(facts.frames, 25)
        XCTAssertEqual(facts.audioFormat, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.sampleRate, 48_000)
        XCTAssertEqual(facts.channels, 2)
        let ssim = try PrecomposeCheck.ssimPerFrame(single, output)
        XCTAssertEqual(ssim.count, 25)
        for (k, v) in ssim.enumerated() { XCTAssertGreaterThanOrEqual(v, 0.995, "SSIM of rotated frame \(k)") }
    }

    // MARK: Interruptions

    func testInterruptionDuringPass1ResumesFromItsNextSegment() throws {
        let durUs: Int64 = 2_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs)
        let settings = PrecomposeFixtures.settings()
        let p = try make(decoderLimit: 2)
        var injected = false
        p.exporter.configurePass = { index, pass in
            guard index == 1, !injected else { return }
            pass.configureWriter = { writer in
                writer.faultInjector = { segment, frame in
                    guard !injected, segment == 1, frame == 3 else { return nil }
                    injected = true
                    return MediaJobTestSupport.interruptionError()
                }
            }
        }
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        XCTAssertNil(p.h.recorder.failure(id))
        XCTAssertTrue(injected)
        let runs = p.exporter.runs
        XCTAssertEqual(runs.map(\.index), [1, 1, 2, 3], "only the interrupted pass runs again")
        XCTAssertEqual(runs[1].startSegment, 1, "pass 1 resumes from its next segment")
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 4), [])
        XCTAssertEqual(p.leftovers(), [])
    }

    func testInterruptionDuringTheFinalPassNeverRedoesAPass() throws {
        let durUs: Int64 = 2_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs)
        let settings = PrecomposeFixtures.settings()
        let p = try make(decoderLimit: 2)
        var injected = false
        var finals = 0
        p.h.coordinator.configurePipeline = { pipeline in
            finals += 1
            pipeline.configureWriter = { writer in
                writer.faultInjector = { segment, frame in
                    guard !injected, segment == 2, frame == 2 else { return nil }
                    injected = true
                    return MediaJobTestSupport.interruptionError()
                }
            }
        }
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        XCTAssertNil(p.h.recorder.failure(id))
        XCTAssertTrue(injected)
        XCTAssertEqual(finals, 2, "the final pass ran again")
        XCTAssertEqual(p.exporter.runs.map(\.index), [1, 2, 3], "no intermediate pass ran twice")
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 4), [])
        XCTAssertEqual(p.leftovers(), [])
    }

    func testKillDuringPass1ThenResumeAfterRelaunch() throws {
        let roots = try TempRoots()
        let durUs: Int64 = 2_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs, pips: 2)
        let settings = PrecomposeFixtures.settings()
        let first = try make(decoderLimit: 2, roots: roots)
        // Pass 1 runs slowly so the "kill" lands inside it.
        first.exporter.configurePass = { _, pass in
            pass.configureWriter = { writer in writer.faultInjector = { _, _ in Thread.sleep(forTimeInterval: 0.03); return nil } }
        }
        let output = first.h.outputURL()
        let id = try first.h.start(self, plan: plan, settings: settings, output: output)
        let directory = first.jobDirectory(id)
        let passDir = PrecomposeExporter.workDirectory(1, directory: directory)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 120) { (SegmentCheckpoint.load(from: passDir)?.completed.count ?? 0) >= 1 })
        first.h.interruption.didEnterBackground()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { first.h.onExportQueue { first.h.coordinator.isWaitingForForeground(id) } })
        let marker = try XCTUnwrap(SegmentCheckpoint.load(from: directory), "the job directory holds a resumable checkpoint")
        XCTAssertTrue(PrecomposeExporter.isMarker(marker))
        XCTAssertGreaterThan(marker.doneFraction, 0)

        // A new process on the same roots.
        let second = try make(decoderLimit: 2, roots: roots)
        XCTAssertTrue(exists(directory), "the launch wipe keeps the job")
        let record = try XCTUnwrap(try second.h.activeJobs(self).first { $0.jobId == id })
        XCTAssertEqual(record.state, .resumable)
        XCTAssertGreaterThan(record.doneFraction ?? 0, 0)
        let _: String = try second.h.call(self) { second.h.coordinator.resume(jobId: id, reply: $0) }
        second.h.recorder.waitForEnd(id, test: self, timeout: 300)
        XCTAssertNil(second.h.recorder.failure(id))
        let runs = second.exporter.runs
        XCTAssertEqual(runs.map(\.index), [1], "three tracks at limit 2: one intermediate pass")
        XCTAssertGreaterThanOrEqual(runs.first?.startSegment ?? 0, 1, "pass 1 resumed from its checkpoint")
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 2), [])
        XCTAssertFalse(exists(directory))
    }

    func testKillDuringTheFinalPassThenResumeAfterRelaunch() throws {
        let roots = try TempRoots()
        let durUs: Int64 = 2_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs, pips: 2)
        let settings = PrecomposeFixtures.settings()
        let first = try make(decoderLimit: 2, roots: roots)
        // The final pass runs slowly so the "kill" lands inside it.
        first.h.coordinator.configurePipeline = { pipeline in
            pipeline.configureWriter = { writer in writer.faultInjector = { _, _ in Thread.sleep(forTimeInterval: 0.03); return nil } }
        }
        let output = first.h.outputURL()
        let id = try first.h.start(self, plan: plan, settings: settings, output: output)
        let directory = first.jobDirectory(id)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 180) {
            guard let c = SegmentCheckpoint.load(from: directory) else { return false }
            return PrecomposeExporter.isFinal(c) && c.completed.count >= 1
        })
        first.h.interruption.didEnterBackground()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { first.h.onExportQueue { first.h.coordinator.isWaitingForForeground(id) } })
        XCTAssertEqual(first.exporter.runs.map(\.index), [1])
        XCTAssertTrue(exists(PrecomposeExporter.intermediateURL(1, directory: directory)), "the intermediate is kept")

        let second = try make(decoderLimit: 2, roots: roots)
        XCTAssertEqual(try second.h.activeJobs(self).first { $0.jobId == id }?.state, .resumable)
        let _: String = try second.h.call(self) { second.h.coordinator.resume(jobId: id, reply: $0) }
        second.h.recorder.waitForEnd(id, test: self, timeout: 300)
        XCTAssertNil(second.h.recorder.failure(id))
        XCTAssertEqual(second.exporter.runs, [], "the finished pass is not redone")
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 2), [])
        XCTAssertFalse(exists(directory))
    }

    // MARK: Cancel, failures, disk

    func testCancelCleansEveryIntermediate() throws {
        let durUs: Int64 = 2_000_000
        let p = try make(decoderLimit: 2)
        // Pass 2 runs slowly so the cancel lands inside it.
        p.exporter.configurePass = { index, pass in
            guard index == 2 else { return }
            pass.configureWriter = { writer in writer.faultInjector = { _, _ in Thread.sleep(forTimeInterval: 0.03); return nil } }
        }
        let output = p.h.outputURL()
        let id = try p.h.start(self, plan: PrecomposeFixtures.plan(durUs: durUs), settings: PrecomposeFixtures.settings(), output: output)
        let directory = p.jobDirectory(id)
        // Wait until pass 1 is complete and pass 2 has written a segment.
        XCTAssertTrue(JobEventRecorder.spin(timeout: 180) {
            (SegmentCheckpoint.load(from: PrecomposeExporter.workDirectory(2, directory: directory))?.completed.count ?? 0) >= 1
        })
        XCTAssertTrue(exists(PrecomposeExporter.intermediateURL(1, directory: directory)))
        try p.h.cancel(self, id)
        p.h.recorder.waitForEnd(id, test: self, timeout: 60)
        XCTAssertEqual(p.h.recorder.failure(id)?.code, "cancelled")
        XCTAssertFalse(exists(directory))
        XCTAssertFalse(exists(output))
        XCTAssertEqual(p.leftovers(), [], "no intermediate survives a cancel")
    }

    func testDiskPreflightCountsTheIntermediates() throws {
        let durUs: Int64 = 1_000_000
        let p = try make(decoderLimit: 2)
        let settings = try EncoderSettings(msg: PrecomposeFixtures.settings())
        // Room for the final export (the coordinator's check) but not for the intermediates.
        p.exporter.freeBytes = { _ in settings.requiredBytes(durationUs: durUs) + 1 }
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: PrecomposeFixtures.plan(durUs: durUs), settings: PrecomposeFixtures.settings(), output: output)
        XCTAssertEqual(p.h.recorder.failure(id)?.code, "diskFull")
        XCTAssertEqual(p.exporter.runs, [], "nothing rendered")
        XCTAssertFalse(exists(output))
        XCTAssertEqual(p.leftovers(), [])
    }

    func testDecoderInitFailedRePlansWithFewerTracksPerPass() throws {
        // The single pass fails at export start (injected), the precompose starts one track below
        // the plan's four, its first pass fails too, and it re-plans at two.
        let durUs: Int64 = 1_000_000
        let plan = PrecomposeFixtures.plan(durUs: durUs, pips: 3)
        let settings = PrecomposeFixtures.settings()
        let p = try make(decoderLimit: 16)
        var singleFaulted = false
        p.h.coordinator.configurePipeline = { pipeline in
            guard !singleFaulted else { return }
            singleFaulted = true
            pipeline.videoOpenFault = { _ in EngineError(.decoderInitFailed, "injected: no decoder for track 3") }
        }
        p.exporter.configurePass = { [weak exporter = p.exporter] _, pass in
            guard exporter?.schedules.last?.limit == 3 else { return }
            pass.videoOpenFault = { _ in EngineError(.decoderInitFailed, "injected: no decoder at 3 tracks") }
        }
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: plan, settings: settings, output: output, timeout: 300)
        XCTAssertNil(p.h.recorder.failure(id), "decoderInitFailed is never reported while a split helps")
        XCTAssertEqual(p.exporter.schedules.map(\.limit), [3, 2])
        XCTAssertEqual(p.exporter.runs.map(\.limit), [3, 2, 2])
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(try PrecomposeCheck.barcodeProblems(output, pips: 3), [])
        XCTAssertEqual(p.leftovers(), [])
    }

    func testDecoderInitFailedThatNoSplitHelpsIsReportedAndCleaned() throws {
        let durUs: Int64 = 1_000_000
        let p = try make(decoderLimit: 2)
        p.exporter.configurePass = { _, pass in
            pass.videoOpenFault = { _ in EngineError(.decoderInitFailed, "injected") }
        }
        let output = p.h.outputURL()
        let id = try p.h.export(self, plan: PrecomposeFixtures.plan(durUs: durUs, pips: 2), settings: PrecomposeFixtures.settings(),
                                output: output)
        XCTAssertEqual(p.h.recorder.failure(id)?.code, "decoderInitFailed")
        XCTAssertFalse(exists(output))
        XCTAssertFalse(exists(p.jobDirectory(id)))
        XCTAssertEqual(p.leftovers(), [])
    }
}
