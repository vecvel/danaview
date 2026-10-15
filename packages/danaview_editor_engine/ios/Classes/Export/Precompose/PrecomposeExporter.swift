// OWNER: IOS-20
//
// The multi-pass precompose export (ARCH D-45(B), §14.2 'Multi-pass fallback'; owner decision
// 2026-10-11, D-43(e) point 7; parity with Android's AND-19). IOS-12's ExportCoordinator finds this
// class by name (`PrecomposeExporter`, NSClassFromString) and hands it a job whose plan needs more
// composition tracks than the device decodes at once, or whose single pass failed with
// `decoderInitFailed` at export start. Export never refuses for layer counts.
//
// Flow (export work queue, one job at a time):
//   1. PrecomposePlanner cuts the plan into passes for the decoder limit (after `decoderInitFailed`:
//      one track fewer than the plan needed; a pass that still fails that way lowers the limit and
//      re-plans, down to 2).
//   2. Disk: free space plus what the job directory already holds must cover the final export
//      (IOS-12's estimate) plus the intermediates alive at once (two while one pass reads the
//      previous intermediate), else `diskFull`.
//   3. PrecomposePass renders each intermediate `pre-<n>.mov` in the job directory; the previous
//      intermediate is deleted once the next one is complete.
//   4. The final pass is IOS-12's normal pipeline (`runFinalPass`) over the final plan, whose
//      bottom layer is the last intermediate, in the job directory (its checkpoint becomes the
//      job's checkpoint); audio is mixed once, there.
//   5. Done: every intermediate, pass directory and `precompose.json` is deleted.
//
// Resume (IOS-17 checkpoint): `precompose.json` (atomic) records the plan hash, the limit in use
// and the finished passes with their hashes; a pass hash covers its plan, its encode layout and
// (through the intermediate's fingerprint) every pass below it, so a resumed job (same process
// after a background pause, or after a kill through `resume(jobId)`) never redoes a finished pass
// and an interrupted pass continues from its next segment (its own checkpoint in
// `pre-<n>.work/`). While intermediate passes run, the job directory also holds a marker
// SegmentCheckpoint (kind `export`, input `precompose:<planHash>`, the overall fraction done as
// one completed range) so the coordinator reports the job resumable and keeps it through the
// launch wipe; the final pass's writer replaces it with its own checkpoint.
//
// Progress: one continuous fraction over every pass (each pass, the final included, gets an equal
// window of the job's fraction through `setProgressWindow`), within the existing phases; no
// message changes.
// Cancel and failure: the pass stops (`cancelled`), and every intermediate and pass directory is
// deleted (the coordinator then deletes the job directory and the partial output). An interruption
// keeps everything for the resume.
// Nothing here logs paths, titles or plan content.

import Foundation

final class PrecomposeExporter: NSObject, MultiPassExporting {
    /// `precompose.json` in the job directory.
    struct State: Codable, Equatable {
        static let fileName = "precompose.json"
        static let currentVersion = 1

        struct Pass: Codable, Equatable {
            var index: Int
            var hash: String
            var frames: Int
            var bytes: Int64
        }

        var version = State.currentVersion
        var planHash: String
        var limit: Int
        var done: [Pass] = []

        static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

        static func load(from directory: URL) -> State? {
            guard let data = try? Data(contentsOf: url(in: directory)),
                  let state = try? JSONDecoder().decode(State.self, from: data),
                  state.version == currentVersion else { return nil }
            return state
        }

        func save(to directory: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(self).write(to: State.url(in: directory), options: .atomic)
            } catch {
                throw EngineError.from(error)
            }
        }
    }

    /// One pass run (tests: which passes ran and from which segment).
    struct PassRun: Equatable {
        var index: Int
        var limit: Int
        var startSegment: Int
    }

    private weak var context: EngineContext?

    // Tunables and test hooks.
    /// Segment length of the intermediates' writers.
    var segmentDurationUs = SegmentedWriter.defaultSegmentDurationUs
    /// Free bytes of the volume holding a URL (nil: `Paths.freeBytes`).
    var freeBytes: ((URL) throws -> Int64)?
    /// Configures every pass before it runs (pass index, pass).
    var configurePass: ((Int, PrecomposePass) -> Void)?

    private let lock = NSLock()
    private var _runs: [PassRun] = []
    private var _schedules: [PrecomposeSchedule] = []

    /// Passes that rendered (tests).
    var runs: [PassRun] {
        lock.lock()
        defer { lock.unlock() }
        return _runs
    }

    /// Schedules planned (tests).
    var schedules: [PrecomposeSchedule] {
        lock.lock()
        defer { lock.unlock() }
        return _schedules
    }

    init(context: EngineContext) {
        self.context = context
        super.init()
    }

    // MARK: Files

    static func intermediateURL(_ pass: Int, directory: URL) -> URL {
        directory.appendingPathComponent(PrecomposePlanner.fileName(pass))
    }

    static func workDirectory(_ pass: Int, directory: URL) -> URL {
        directory.appendingPathComponent("pre-\(pass).work", isDirectory: true)
    }

    /// Deletes every intermediate, pass directory, the state and the marker checkpoint in
    /// [directory] (the final pass's own files stay).
    static func removeIntermediates(in directory: URL, keepMarker: Bool = false) {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix("pre-") {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: State.url(in: directory))
        if !keepMarker, let checkpoint = SegmentCheckpoint.load(from: directory), isMarker(checkpoint) {
            SegmentCheckpoint.delete(in: directory)
        }
    }

    static func markerHash(_ planHash: String) -> String { "precompose:\(planHash)" }

    /// Whether [checkpoint] is the final pass's (IOS-12 hashes the final plan with a `-final` suffix).
    static func isFinal(_ checkpoint: SegmentCheckpoint) -> Bool { checkpoint.inputHash.hasSuffix("-final") }

    /// Deletes the job directory's checkpoint and segments (a single pass's or a final pass's).
    static func removeRootSegments(in directory: URL) {
        SegmentCheckpoint.delete(in: directory)
        SegmentedWriter.removeSegmentFiles(in: directory)
    }

    static func isMarker(_ checkpoint: SegmentCheckpoint) -> Bool {
        checkpoint.jobKind == ExportJob.jobKind && checkpoint.inputHash.hasPrefix("precompose:")
    }

    /// Disk the precompose needs beyond what the job directory holds: the final export plus the
    /// intermediates alive at once.
    static func requiredBytes(_ settings: EncoderSettings, durationUs: Int64, remainingPasses: Int) -> Int64 {
        let alive = Int64(min(2, max(0, remainingPasses)))
        return settings.requiredBytes(durationUs: durationUs) + alive * PrecomposePass.estimatedBytes(settings, durationUs: durationUs)
    }

    // MARK: MultiPassExporting

    func export(_ job: MultiPassContext) throws -> ReaderWriterPipeline.Outcome {
        do {
            let outcome = try run(job)
            if case .completed = outcome {
                PrecomposeExporter.removeIntermediates(in: job.directory)
            }
            return outcome
        } catch {
            // Cancel and failure delete every intermediate (the coordinator deletes the rest).
            PrecomposeExporter.removeIntermediates(in: job.directory)
            if job.control.isCancelled { throw EngineError.cancelled }
            throw EngineError.from(error)
        }
    }

    private func run(_ job: MultiPassContext) throws -> ReaderWriterPipeline.Outcome {
        let directory = job.directory
        let needed = PrecomposePlanner.decoderSeqs(job.plan.layers).count
        var state = PrecomposeExporter.State.load(from: directory)
        if state?.planHash != job.planHash { state = nil }
        guard let initial = state?.limit
            ?? PrecomposePlanner.initialLimit(reason: job.reason, decoderLimit: job.decoderLimit, needed: needed) else {
            throw EngineError(.decoderInitFailed, "a composition track has no decoder and the plan cannot be split")
        }
        var current = state ?? State(planHash: job.planHash, limit: initial)
        // A single pass that failed with decoderInitFailed leaves its checkpoint and segments here.
        if let checkpoint = SegmentCheckpoint.load(from: directory),
           !PrecomposeExporter.isMarker(checkpoint), !PrecomposeExporter.isFinal(checkpoint) {
            PrecomposeExporter.removeRootSegments(in: directory)
        }
        let rotated = job.layout == .rotated
        let url: (Int) -> URL = { PrecomposeExporter.intermediateURL($0, directory: directory) }

        while true {
            let schedule = try PrecomposePlanner.schedule(job.plan, limit: current.limit, rotated: rotated)
            lock.lock()
            _schedules.append(schedule)
            lock.unlock()
            Log.info(.export, "export \(job.jobId): precompose, limit \(schedule.limit), \(schedule.passes.count) intermediate passes")
            if schedule.passes.isEmpty {
                job.setProgressWindow(0, 1)
                return try finalPass(job, plan: schedule.finalPlan, state: &current)
            }

            // Passes already finished (their hash matches and their file exists).
            var first = 0
            for (i, spec) in schedule.passes.enumerated().reversed() {
                if current.done.contains(where: { $0.index == spec.index && $0.hash == spec.hash }),
                   FileManager.default.fileExists(atPath: url(spec.index).path) {
                    first = i + 1
                    break
                }
            }
            current.done.removeAll { d in !schedule.passes.contains { $0.index == d.index && $0.hash == d.hash } }
            try current.save(to: directory)

            let total = Double(schedule.totalPasses)
            try checkDisk(job, remainingPasses: schedule.passes.count - first)

            var lowered = false
            for spec in schedule.passes[first...] {
                if job.control.shouldStop {
                    if job.control.isCancelled { throw EngineError.cancelled }
                    writeMarker(job, fraction: Double(spec.index - 1) / total)
                    return .interrupted
                }
                let start = Double(spec.index - 1) / total
                job.setProgressWindow(start, 1 / total)
                writeMarker(job, fraction: start)
                let pass = PrecomposePass(
                    input: PrecomposePass.Input(
                        index: spec.index, plan: PrecomposePlanner.resolve(spec.plan, url: url), hash: spec.hash,
                        settings: job.settings, layout: job.layout,
                        workDirectory: PrecomposeExporter.workDirectory(spec.index, directory: directory),
                        outputURL: url(spec.index), segmentDurationUs: segmentDurationUs),
                    control: job.control, makeComposition: job.makeComposition)
                var lastMarked = -1
                pass.onProgress = { [weak self] fraction in
                    // Refresh the marker about every 5% of the pass (and at segment ends).
                    let step = Int(fraction * 20)
                    guard step != lastMarked else { return }
                    lastMarked = step
                    self?.writeMarker(job, fraction: start + fraction / total)
                }
                configurePass?(spec.index, pass)
                let outcome: PrecomposePass.Outcome
                do {
                    outcome = try pass.run()
                } catch let error as EngineError where error.code == .decoderInitFailed && !job.control.isCancelled {
                    lock.lock()
                    _runs.append(PassRun(index: spec.index, limit: schedule.limit, startSegment: pass.startSegment))
                    lock.unlock()
                    guard let lower = PrecomposePlanner.reducedLimit(schedule.limit) else { throw error }
                    Log.info(.export, "export \(job.jobId): pass \(spec.index) has no decoder at limit \(schedule.limit); re-planning at \(lower)")
                    try? FileManager.default.removeItem(at: PrecomposeExporter.workDirectory(spec.index, directory: directory))
                    current.limit = lower
                    try current.save(to: directory)
                    lowered = true
                    break
                }
                lock.lock()
                _runs.append(PassRun(index: spec.index, limit: schedule.limit, startSegment: pass.startSegment))
                lock.unlock()
                switch outcome {
                case .interrupted:
                    writeMarker(job, fraction: start + passFraction(spec.index, directory: directory) / total)
                    return .interrupted
                case .completed(let frames, let bytes):
                    current.done.removeAll { $0.index == spec.index }
                    current.done.append(State.Pass(index: spec.index, hash: spec.hash, frames: frames, bytes: bytes))
                    // The previous intermediate is baked into this one.
                    if spec.index > 1 {
                        try? FileManager.default.removeItem(at: url(spec.index - 1))
                        current.done.removeAll { $0.index < spec.index }
                    }
                    try current.save(to: directory)
                    writeMarker(job, fraction: Double(spec.index) / total)
                }
            }
            if lowered { continue }

            if job.control.shouldStop {
                if job.control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
            job.setProgressWindow(Double(schedule.passes.count) / total, 1 / total)
            do {
                return try finalPass(job, plan: PrecomposePlanner.resolve(schedule.finalPlan, url: url), state: &current)
            } catch let error as EngineError where error.code == .decoderInitFailed && !job.control.isCancelled {
                guard let lower = PrecomposePlanner.reducedLimit(schedule.limit) else { throw error }
                Log.info(.export, "export \(job.jobId): final pass has no decoder at limit \(schedule.limit); re-planning at \(lower)")
                PrecomposeExporter.removeRootSegments(in: directory)
                current.limit = lower
                try current.save(to: directory)
            }
        }
    }

    private func finalPass(_ job: MultiPassContext, plan: RenderPlan, state: inout State) throws -> ReaderWriterPipeline.Outcome {
        if let checkpoint = SegmentCheckpoint.load(from: job.directory), PrecomposeExporter.isMarker(checkpoint) {
            SegmentCheckpoint.delete(in: job.directory)
        }
        return try job.runFinalPass(plan, job.directory)
    }

    // MARK: Disk

    private func checkDisk(_ job: MultiPassContext, remainingPasses: Int) throws {
        guard remainingPasses > 0 else { return }
        let root = context?.paths?.cacheRoot ?? job.directory
        let free: Int64
        do {
            free = try freeBytes.map { try $0(root) } ?? Paths.freeBytes(at: root.path)
        } catch {
            return  // Unknown free space: the writers report diskFull if it runs out.
        }
        let held = SegmentedWriter.directorySize(job.directory)
        let needed = PrecomposeExporter.requiredBytes(job.settings, durationUs: job.plan.durUs, remainingPasses: remainingPasses)
        if free + held < needed {
            throw EngineError(.diskFull, "not enough free space for the precompose intermediates")
        }
    }

    // MARK: Marker

    /// Fraction of pass [index] already written (its checkpoint).
    private func passFraction(_ index: Int, directory: URL) -> Double {
        SegmentCheckpoint.load(from: PrecomposeExporter.workDirectory(index, directory: directory))?.doneFraction ?? 0
    }

    /// Writes the job directory's marker checkpoint with the overall [fraction] done.
    private func writeMarker(_ job: MultiPassContext, fraction: Double) {
        let dur = job.plan.durUs
        let doneUs = min(dur, max(0, Int64((Double(dur) * min(1, max(0, fraction))).rounded(.down))))
        var marker = SegmentCheckpoint(
            jobKind: ExportJob.jobKind, inputHash: PrecomposeExporter.markerHash(job.planHash),
            settings: job.settings.segmentSettings(layout: job.layout), startUs: 0, endUs: dur, segmentDurationUs: dur)
        if doneUs > 0 {
            marker.completed = [SegmentCheckpoint.Segment(
                index: 0, startUs: 0, endUs: doneUs, frames: 1, bytes: 0, firstPts: CodableTime(.zero))]
        }
        lock.lock()
        defer { lock.unlock() }
        // Never replace the final pass's own checkpoint.
        if let existing = SegmentCheckpoint.load(from: job.directory), PrecomposeExporter.isFinal(existing) { return }
        try? marker.save(to: job.directory)
    }
}
