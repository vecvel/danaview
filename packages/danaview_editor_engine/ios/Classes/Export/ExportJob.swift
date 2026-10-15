// OWNER: IOS-12
//
// One export job (ARCH §14.1, §14.2, D-22, D-39): its id, decoded plan, settings and layout, the
// job directory `<cache>/danaview/editor/work/export-<jobId>/` (IOS-17 segments and checkpoint
// plus `job.json` and `plan.json`, so a job interrupted by the background or by a process kill can
// resume), its stop flags and its progress.
//
// - `job.json` (written atomically) is the job record: settings, output path, title, detached
//   handoff, layout, plan hash, state (`running`, `completedDetached`) and the result of a job that
//   completed with no Dart listener attached (D-39). `plan.json` keeps the plan bytes for a
//   resume after relaunch. Neither file holds anything but what Dart sent.
// - Stop semantics: `cancel()` stops the pipeline and the job's files are deleted; a background
//   interruption (`interruptForBackground`, IOS-17 JobInterruption) stops the running segment,
//   which IOS-17 discards while keeping the checkpoint.
// - Thermal: while the thermal state is `.critical` the pumps wait (`waitWhileThermalCritical`),
//   checked before every frame and audio buffer (ARCH §14.2).
// - Progress = last video PTS / duration (ARCH §14.2); frames on the export grid.
//
// Thread-safety: flags and progress are lock-protected and read from the pump queues, the export
// work queue and the export control queue.

import CryptoKit
import Foundation

/// The phase of an export job (`ExportPhase`).
enum ExportJobPhase: String, Codable {
    case preparing, rendering, finishing
}

/// The control surface the pipeline sees (implemented by `ExportJob`; tests use it directly).
protocol PipelineControl: AnyObject {
    /// True after `cancel()` (the pipeline stops and its files are removed).
    var isCancelled: Bool { get }
    /// True after `cancel()` or a background interruption (the pipeline stops at the next frame).
    var shouldStop: Bool { get }
    /// Routes stop requests to the running segmented writer.
    func attach(_ writer: SegmentedWriter?)
    /// Blocks while the device is thermally critical (ARCH §14.2) and not stopped.
    func waitWhileThermalCritical()
    /// The pipeline entered [phase].
    func enter(_ phase: ExportJobPhase)
    /// Output time of the last video frame handed to the encoder (µs).
    func videoProgress(lastPtsUs: Int64)
}

final class ExportJob: InterruptibleJob, PipelineControl {
    /// Persisted state of a job directory.
    enum State: String, Codable {
        /// Running or paused in this process; after a kill: resumable or interrupted.
        case running
        /// Finished while no Dart listener was attached (D-39); kept until consumed.
        case completedDetached
    }

    /// A result kept on disk (completedWhileDetached).
    struct StoredResult: Codable, Equatable {
        var path: String
        var bytes: Int64
        var durationUs: Int64
        var videoEncoderName: String
        var hardwareEncoder: Bool

        var msg: ExportResultMsg {
            ExportResultMsg(
                path: path, bytes: bytes, durationUs: durationUs, videoEncoderName: videoEncoderName,
                hardwareEncoder: hardwareEncoder)
        }
    }

    /// `job.json`.
    struct Record: Codable, Equatable {
        static let currentVersion = 1

        var version = Record.currentVersion
        var jobId: String
        var settings: EncoderSettings
        var outputPath: String
        var title: String
        /// `saveToGallery` or `keepForLater`.
        var whenDetached: String
        var layout: EncodeLayout
        var planHash: String
        var state: State
        var result: StoredResult?
        var savedToGallery = false
        var createdAt: Date

        var detachedHandoff: DetachedHandoffMsg { whenDetached == "keepForLater" ? .keepForLater : .saveToGallery }
    }

    static let jobKind = "export"
    static let recordFileName = "job.json"
    static let planFileName = "plan.json"
    /// Prefix of job directories under work/ (`export-<jobId>`; IOS-17 JobInterruption parses it).
    static let directoryPrefix = "export-"

    let id: String
    let directory: URL
    let plan: RenderPlan
    let planData: Data
    private(set) var record: Record

    /// Thermal state source (tests inject sequences).
    var thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    /// Poll interval while thermally paused.
    var thermalPollInterval: TimeInterval = 0.5
    /// Called (any thread) whenever progress or a flag changed.
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var cancelled = false
    private var stopRequested = false
    private weak var writer: SegmentedWriter?
    private var _phase: ExportJobPhase = .preparing
    private var _lastPtsUs: Int64 = -1
    private var _backgrounded = false
    private var _pausedInBackground = false
    private var _warnings: [ExportWarningMsg] = []
    private var _thermalPauses = 0
    private var _window: (start: Double, span: Double) = (0, 1)

    init(id: String, directory: URL, plan: RenderPlan, planData: Data, record: Record) {
        self.id = id
        self.directory = directory
        self.plan = plan
        self.planData = planData
        self.record = record
    }

    /// A new job id ("ex_" + lowercase UUID; safe as a directory name).
    static func newId() -> String { "ex_" + UUID().uuidString.lowercased() }

    /// The directory of [jobId] under [work].
    static func directory(for jobId: String, work: URL) -> URL {
        work.appendingPathComponent(directoryPrefix + jobId, isDirectory: true)
    }

    /// Hex SHA-256 of the plan bytes (checkpoint input hash).
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Persistence

    /// Writes `job.json` (and `plan.json` when missing) atomically.
    func save() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let planURL = directory.appendingPathComponent(ExportJob.planFileName)
            if !FileManager.default.fileExists(atPath: planURL.path) {
                try planData.write(to: planURL, options: .atomic)
            }
            try ExportJob.encode(lockedRecord).write(to: directory.appendingPathComponent(ExportJob.recordFileName), options: .atomic)
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Updates the record and saves it (best effort).
    func update(_ change: (inout Record) -> Void) {
        lock.lock()
        change(&record)
        lock.unlock()
        do { try save() } catch { Log.error(.export, "job \(id): record not saved (\(EngineError.from(error).code.rawValue))") }
    }

    private var lockedRecord: Record {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    /// The record of the job directory [directory], or nil.
    static func loadRecord(_ directory: URL) -> Record? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(recordFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data), record.version == Record.currentVersion else { return nil }
        return record
    }

    /// Reopens the job in [directory] (resume after a pause or a relaunch).
    static func load(_ directory: URL) throws -> ExportJob {
        guard let record = loadRecord(directory) else { throw EngineError(.interrupted, "no resumable export with this id") }
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent(planFileName))
        } catch {
            throw EngineError(.interrupted, "the export's plan is gone")
        }
        let plan = try RenderPlanDecoder.decodePlan(data)
        return ExportJob(id: record.jobId, directory: directory, plan: plan, planData: data, record: record)
    }

    // MARK: Stop flags

    var interruptionJobId: String { id }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested || cancelled
    }

    /// Stops the job for good; the coordinator deletes its files.
    func cancel() {
        lock.lock()
        cancelled = true
        stopRequested = true
        let w = writer
        lock.unlock()
        w?.cancel()
    }

    /// IOS-17 JobInterruption (main thread): stop at once, keep the checkpoint.
    func interruptForBackground() {
        lock.lock()
        stopRequested = true
        _backgrounded = true
        _pausedInBackground = true
        let w = writer
        lock.unlock()
        w?.interrupt()
        onChange?()
    }

    /// Clears the stop request before a (re)run; the job is no longer paused.
    func prepareRun() {
        lock.lock()
        stopRequested = false
        _pausedInBackground = false
        _backgrounded = false
        _phase = .preparing
        lock.unlock()
        onChange?()
    }

    /// The job paused (background or interruption) and waits to resume.
    func markPaused(backgrounded: Bool) {
        lock.lock()
        _pausedInBackground = true
        if backgrounded { _backgrounded = true }
        lock.unlock()
        onChange?()
    }

    func attach(_ writer: SegmentedWriter?) {
        lock.lock()
        self.writer = writer
        let stop = stopRequested
        let cancel = cancelled
        lock.unlock()
        if cancel {
            writer?.cancel()
        } else if stop {
            writer?.interrupt()
        }
    }

    // MARK: Thermal

    /// Times the pumps waited for a critical thermal state to clear (tests).
    var thermalPauses: Int {
        lock.lock()
        defer { lock.unlock() }
        return _thermalPauses
    }

    func waitWhileThermalCritical() {
        var counted = false
        while thermalState() == .critical && !shouldStop {
            if !counted {
                counted = true
                lock.lock()
                _thermalPauses += 1
                lock.unlock()
                Log.info(.export, "job \(id): thermal critical, pumps paused")
            }
            Thread.sleep(forTimeInterval: thermalPollInterval)
        }
    }

    // MARK: Progress

    var phase: ExportJobPhase {
        lock.lock()
        defer { lock.unlock() }
        return _phase
    }

    func enter(_ phase: ExportJobPhase) {
        lock.lock()
        let changed = _phase != phase
        _phase = phase
        lock.unlock()
        if changed { onChange?() }
    }

    func videoProgress(lastPtsUs: Int64) {
        lock.lock()
        _lastPtsUs = max(_lastPtsUs, lastPtsUs)
        lock.unlock()
        onChange?()
    }

    /// Sets the progress from a checkpoint (resume): everything before [us] is done.
    func restoreProgress(doneUs: Int64) {
        lock.lock()
        let grid = plan.canvas.outputGrid
        if doneUs > 0 { _lastPtsUs = max(_lastPtsUs, grid.timeOfFrame(grid.frameIndexOf(doneUs) - 1)) }
        lock.unlock()
    }

    /// Maps this pass's progress into [start, start + span] of the job (multi-pass exports, D-45:
    /// one continuous fraction over every pass).
    func setProgressWindow(start: Double, span: Double) {
        lock.lock()
        _window = (min(1, max(0, start)), min(1, max(0, span)))
        _lastPtsUs = -1
        lock.unlock()
        onChange?()
    }

    func addWarning(_ warning: ExportWarningMsg) {
        lock.lock()
        let added = !_warnings.contains { $0.code == warning.code }
        if added { _warnings.append(warning) }
        lock.unlock()
        if added { onChange?() }
    }

    var warnings: [ExportWarningMsg] {
        lock.lock()
        defer { lock.unlock() }
        return _warnings
    }

    /// Frames of the output (export grid).
    var framesTotal: Int64 { ExportJob.frameCount(durUs: plan.durUs, fps: plan.canvas.fps) }

    /// Output frames of a plan: frames whose start lies before the end.
    static func frameCount(durUs: Int64, fps: Int) -> Int64 {
        let grid = FrameGrid(fps)
        let k = grid.frameIndexOf(durUs)
        return grid.timeOfFrame(k) < durUs ? k + 1 : k
    }

    /// Fraction of the video written (last video PTS / duration).
    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        guard plan.durUs > 0, _lastPtsUs >= 0 else { return 0 }
        let frameUs = 1_000_000 / Double(max(1, plan.canvas.fps))
        return min(1, max(0, (Double(_lastPtsUs) + frameUs) / Double(plan.durUs)))
    }

    /// The progress event payload.
    func progressMsg() -> ExportProgressMsg {
        lock.lock()
        let phase = _phase
        let last = _lastPtsUs
        let backgrounded = _backgrounded
        let paused = _pausedInBackground
        let warnings = _warnings
        let window = _window
        lock.unlock()
        let total = framesTotal
        let done: Int64 = last < 0 ? 0 : min(total, plan.canvas.outputGrid.frameIndexNearest(last) + 1)
        let pass = phase == .finishing ? 1 : (total > 0 ? Double(done) / Double(total) : 0)
        let fraction = window.start + window.span * pass
        return ExportProgressMsg(
            phase: phase == .preparing ? .preparing : (phase == .rendering ? .rendering : .finishing),
            fraction: min(1, max(0, fraction)), framesDone: phase == .finishing ? total : done, framesTotal: total,
            backgrounded: backgrounded, pausedInBackground: paused, warnings: warnings)
    }
}
