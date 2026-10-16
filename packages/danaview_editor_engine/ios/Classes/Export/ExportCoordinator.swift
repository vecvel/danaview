// OWNER: IOS-12
//
// Export jobs of one Flutter engine (ARCH §12.4, §14.1, §14.2, D-22, D-38, D-39, D-45). The glue
// (Glue/ExportHostApiImpl.swift, ENG-07) calls every method on the export queue through
// `ExportCoordinating` and builds the coordinator with `init(context:)`. All coordinator state
// lives on that queue; the job itself runs on a private serial work queue and IOS-17's pump queue.
//
// preflight(plan, settings): decodes and checks the plan (target export, canvas = output size and
//   fps, ARCH §11.3 invariants) and answers ok (an encoder takes the size in some orientation and
//   the disk has the estimate plus one segment), maxHeightForPlan (largest standard short side the
//   device encodes for this plan: tier limit, 4K on mid only with ≤ 2 video layers, ARCH §14.4) and
//   warnings `softwareEncoder`, `hevcUnavailable`, `backgroundPauses`, `layersVsResolution` and
//   `portraitRetried` (predicted). It never refuses for layer counts (D-43(e) point 7, D-45).
// start(...): one job at a time (`busy` otherwise). HEVC falls back to H.264 when unavailable;
//   the layout is chosen by `EncodeLayout.choose` (portrait refused → landscape + rotation,
//   ARCH §14.1); free space must cover the estimate plus one 10 s segment. The job directory
//   `work/export-<jobId>/` gets `job.json` and `plan.json`; preview sessions are suspended on the
//   minimal/low/mid tiers (`ExportPreviewSuspending`); the job registers with IOS-17's
//   JobInterruption and runs the ReaderWriterPipeline. Progress events (phase, frames, background
//   flags, warnings) go through EventHub (≤ 4 Hz there).
//   Routing (D-45): when the plan needs more decoders than `decoderLimit` (iOS 16 composition
//   tracks), or a composition track fails with `decoderInitFailed`, the job goes to the multi-pass
//   hook (`MultiPassExporting`, implemented by IOS-20 in a class named `PrecomposeExporter`) and
//   that is never reported as a failure. Without the hook, a decoder limit runs the single pass
//   anyway and `decoderInitFailed` is reported.
//   Encoder refusal at start of the native layout of a portrait size → one retry with the rotated
//   layout (`portraitRetried`), then `encoderSizeLimit`.
//   Background (D-22, iPhone `paused`): the pumps stop, the in-progress segment is discarded, the
//   job reports `pausedInBackground` and continues from the next segment on return.
//   Completion: jobDone with ExportResult. With no Dart listener attached (D-39) the job directory
//   keeps a `completedDetached` record (output exempt from the work/ wipe) that `activeJobs()`
//   reports once as completedWhileDetached; IOS-13's lifecycle hook may save it to Photos.
// cancel(jobId): stops the job and deletes the partial output and every segment. Idempotent.
//   A pipeline that has not returned `cancelGrace` after the cancel (blocked inside AVFoundation)
//   is left behind and the job ends as cancelled anyway (FIX-IOS-EXPORT-STALL, QA-05 D2).
// Stalls (FIX-IOS-EXPORT-STALL, QA-05 D1/D2): each job runs on its own work queue, so a pipeline
//   left blocked inside AVFoundation never holds up a later job. Its writers get `stallTimeout`
//   and `stopGrace` (IOS-17 bounded waits: a pump without progress fails the job with a typed
//   `decodeFailed`/`encodingFailed` "export stalled" error). A watchdog on the export queue is the
//   backstop for every other wait: a running job without any heartbeat (frame, audio buffer,
//   concat sample, phase change) for `stallTimeout + watchdogSlack`, while not thermally paused,
//   is stopped and ended with the same typed error. A job that ended this way releases all
//   coordinator state at once (job table, preview suspension, JobInterruption registration), and
//   a late completion of its pipeline is ignored.
// resume(jobId): continues a paused job, or one whose checkpoint survived a process kill.
// activeJobs(): running jobs; on-disk jobs not running in this process (resumable with finished
//   segments, otherwise interrupted, one-shot); completedWhileDetached records; plus the records of
//   IOS-13's lifecycle hook.
// consumeJobRecord(jobId): forgets a one-shot record (its job directory; a detached output stays
//   for Dart to hand off and delete).
//
// Hooks for later tickets (they never edit this file):
// - IOS-20: `final class PrecomposeExporter: NSObject, MultiPassExporting` (found with
//   NSClassFromString, `init(context:)`); it gets a `MultiPassContext` (plan, settings, layout,
//   directory, output, the job's stop flags and progress window, the same composition factory, and
//   `runFinalPass` = this pipeline over a plan whose bottom layer is the intermediate).
// - IOS-13: make `ActiveExportStore` conform to `ExportJobLifecycle` (`init(context:)`); the
//   coordinator then reports starts, completions (with whether a Dart listener was attached) and
//   ends to it and merges its records into `activeJobs()`.
// - IOS-11 (follow-up): observe `Notification.Name.danaviewExportSuspendsPreview` /
//   `.danaviewExportResumesPreview` (object: the EngineContext) to suspend preview sessions.
// Nothing here logs paths, titles or plan content.

import Foundation
import QuartzCore
import UIKit

// MARK: - Hooks

/// Why a job goes to the multi-pass precompose (D-45).
enum MultiPassReason: Equatable {
    /// A composition track could not get a decoder at export start.
    case decoderInitFailed
    /// The plan needs more simultaneous decoders than the device sustains.
    case decoderLimit(needed: Int, limit: Int)
}

/// What the multi-pass exporter (IOS-20) gets from IOS-12.
final class MultiPassContext {
    let jobId: String
    let plan: RenderPlan
    let planHash: String
    let settings: EncoderSettings
    let layout: EncodeLayout
    /// `work/export-<jobId>/` (intermediates live here; deleted when the job ends).
    let directory: URL
    let outputURL: URL
    let reason: MultiPassReason
    /// Composition tracks the device sustains at once.
    let decoderLimit: Int
    /// The job: stop flags (`shouldStop`, `isCancelled`), `attach(writer)` for interruptions,
    /// thermal pause, progress.
    let control: PipelineControl
    /// The single-pass composition factory (same compositor, export variant).
    let makeComposition: ExportCompositionFactory
    /// Runs IOS-12's pipeline over [plan] (the final pass, the intermediate as its bottom layer)
    /// into the job's output, with the job's settings and layout, in [directory].
    let runFinalPass: (_ plan: RenderPlan, _ directory: URL) throws -> ReaderWriterPipeline.Outcome
    /// Maps the next pass's progress into [start, start + span] of the whole job.
    let setProgressWindow: (_ start: Double, _ span: Double) -> Void

    init(
        jobId: String, plan: RenderPlan, planHash: String, settings: EncoderSettings, layout: EncodeLayout, directory: URL,
        outputURL: URL, reason: MultiPassReason, decoderLimit: Int, control: PipelineControl,
        makeComposition: @escaping ExportCompositionFactory,
        runFinalPass: @escaping (RenderPlan, URL) throws -> ReaderWriterPipeline.Outcome,
        setProgressWindow: @escaping (Double, Double) -> Void
    ) {
        self.jobId = jobId
        self.plan = plan
        self.planHash = planHash
        self.settings = settings
        self.layout = layout
        self.directory = directory
        self.outputURL = outputURL
        self.reason = reason
        self.decoderLimit = decoderLimit
        self.control = control
        self.makeComposition = makeComposition
        self.runFinalPass = runFinalPass
        self.setProgressWindow = setProgressWindow
    }
}

/// The multi-pass precompose (IOS-20, D-45). Runs on the export work queue; returns the final
/// pass's outcome (`.interrupted` keeps its checkpoints for a resume).
protocol MultiPassExporting: AnyObject {
    init(context: EngineContext)
    func export(_ job: MultiPassContext) throws -> ReaderWriterPipeline.Outcome
}

/// Export lifecycle observer (IOS-13's ActiveExportStore). Called on the export queue.
protocol ExportJobLifecycle: AnyObject {
    init(context: EngineContext)
    func exportStarted(jobId: String, settings: EncodeSettingsMsg, title: String, whenDetached: DetachedHandoffMsg)
    /// Returns true when the hook took over the detached handoff and its record (D-39).
    func exportCompleted(jobId: String, result: ExportResultMsg, listenerAttached: Bool, whenDetached: DetachedHandoffMsg) -> Bool
    /// The job failed or was cancelled.
    func exportEnded(jobId: String)
    func records() -> [ExportJobRecordMsg]
    func consume(jobId: String)
}

/// Suspends preview sessions during an export (ARCH §14.3 parity, native.md: low/mid tiers).
protocol ExportPreviewSuspending: AnyObject {
    func suspendPreviewForExport()
    func resumePreviewAfterExport()
}

extension Notification.Name {
    /// Posted (object: the EngineContext) when an export starts on a minimal/low/mid device.
    static let danaviewExportSuspendsPreview = Notification.Name("com.vecvel.danaview.editor.export.suspendPreview")
    /// Posted (object: the EngineContext) when that export ended.
    static let danaviewExportResumesPreview = Notification.Name("com.vecvel.danaview.editor.export.resumePreview")
}

/// Default suspender: posts the notifications IOS-11's PreviewSessionManager can observe.
final class NotificationPreviewSuspender: ExportPreviewSuspending {
    private weak var context: EngineContext?

    init(context: EngineContext) {
        self.context = context
    }

    func suspendPreviewForExport() {
        NotificationCenter.default.post(name: .danaviewExportSuspendsPreview, object: context)
    }

    func resumePreviewAfterExport() {
        NotificationCenter.default.post(name: .danaviewExportResumesPreview, object: context)
    }
}

// MARK: - Environment

/// Device facts and system services of the coordinator (tests inject their own).
struct ExportEnvironment {
    var tier: () -> DeviceTierMsg
    var encoders: () -> EncoderSupport
    var probe: EncoderProbe
    var backgroundKind: () -> BackgroundExportKindMsg
    /// Free bytes of the volume holding a path.
    var freeBytes: (URL) throws -> Int64
    /// Composition tracks decoded at once before the multi-pass precompose (iOS: 16, ARCH §12.5).
    var decoderLimit: Int
    /// Media URL resolution (tests map fixture URIs; nil = MediaURLResolver).
    var resolveURL: ((String, PlanAsset) throws -> URL)?
    /// Answers (any thread) whether a Dart listener is attached to the event stream.
    var listenerAttached: (@escaping (Bool) -> Void) -> Void
    var segmentDurationUs: Int64
    /// Thermal state source of the pumps.
    var thermalState: () -> ProcessInfo.ThermalState
    /// Seconds without progress before a job counts as stalled (FIX-IOS-EXPORT-STALL).
    var stallTimeout: TimeInterval = 60
    /// Extra seconds the coordinator's watchdog waits beyond `stallTimeout` (the writer's own
    /// bounded waits fire first).
    var watchdogSlack: TimeInterval = 15
    /// Seconds a stop request waits for a blocked writer pump.
    var stopGrace: TimeInterval = 2
    /// Seconds after a cancel before a pipeline that did not return is left behind.
    var cancelGrace: TimeInterval = 5
    /// Interval of the stall watchdog.
    var watchdogInterval: TimeInterval = 1

    static func production(context: EngineContext) -> ExportEnvironment {
        ExportEnvironment(
            tier: { DeviceProfile.current(hasMetal: true).tier },
            encoders: { Capabilities.encoderSupport(profile: DeviceProfile.current(hasMetal: true)) },
            probe: .system,
            backgroundKind: {
                let profile = DeviceProfile.current(hasMetal: true)
                return Capabilities.compute(
                    profile: profile, encoders: Capabilities.encoderSupport(profile: profile),
                    backgroundGpu: Capabilities.backgroundGpuAvailable(profile: profile)
                ).backgroundKind
            },
            freeBytes: { try Paths.freeBytes(at: $0.path) },
            decoderLimit: 16,
            resolveURL: nil,
            listenerAttached: { [weak context] answer in
                // EventHub state lives on main; never block the export queue on it.
                DispatchQueue.main.async { answer(context?.events.isListening ?? false) }
            },
            segmentDurationUs: SegmentedWriter.defaultSegmentDurationUs,
            thermalState: { ProcessInfo.processInfo.thermalState })
    }
}

/// Export warning codes (match `ExportStrings.warning` on the Dart side and Android's).
enum ExportWarnings {
    static func softwareEncoder() -> ExportWarningMsg {
        ExportWarningMsg(code: "softwareEncoder", message: "software video encoder")
    }

    static func hevcUnavailable() -> ExportWarningMsg {
        ExportWarningMsg(code: "hevcUnavailable", message: "no HEVC encoder takes this size; H.264 is used")
    }

    static func backgroundPauses() -> ExportWarningMsg {
        ExportWarningMsg(code: "backgroundPauses", message: "the export pauses in the background and resumes on return")
    }

    static func layersVsResolution(multiPass: Bool) -> ExportWarningMsg {
        ExportWarningMsg(
            code: "layersVsResolution",
            message: multiPass
                ? "more layers than the device decodes at once; the export runs in several passes"
                : "many layers for this resolution; the export may be slow")
    }

    static func portraitRetried() -> ExportWarningMsg {
        ExportWarningMsg(code: "portraitRetried", message: "portrait size encoded landscape with rotation metadata")
    }

    static func lowDisk() -> ExportWarningMsg {
        ExportWarningMsg(code: "lowDisk", message: "not enough free space for this export")
    }
}

// MARK: - Coordinator

final class ExportCoordinator: ExportCoordinating {
    /// Class name the IOS-20 multi-pass exporter is looked up by (module-qualified at runtime).
    static let multiPassClassName = "PrecomposeExporter"
    /// Interruption-only stops (no background) re-run at once at most this many times.
    static let maxInterruptionRetries = 3

    private let context: EngineContext
    var environment: ExportEnvironment
    let interruption: JobInterruption
    var previewSuspender: ExportPreviewSuspending
    /// The multi-pass hook (IOS-20; discovered on first use when nil).
    var multiPass: MultiPassExporting?
    /// The lifecycle hook (IOS-13; discovered at init when ActiveExportStore conforms).
    var lifecycle: ExportJobLifecycle?
    /// Test hook: overrides the composition factory.
    var makeComposition: ExportCompositionFactory?
    /// Test hook: configures each pipeline before it runs.
    var configurePipeline: ((ReaderWriterPipeline) -> Void)?

    private var queue: DispatchQueue { context.queues.export }
    /// Pipelines left behind blocked inside AVFoundation (tests).
    private(set) var abandonedPipelines = 0
    private var multiPassLookedUp = false

    /// A job of this process.
    private final class Running {
        enum State { case running, waitingForForeground }
        let job: ExportJob
        var state: State = .running
        var interruptionRetries = 0
        var suspendedPreview = false
        let throttle = NSLock()
        var lastEmit: TimeInterval = 0
        var lastMsg: ExportProgressMsg?
        /// Set once the job ended (normally, by cancel grace or by the watchdog).
        var ended = false
        /// Runs of the pipeline started for this job (a late completion of an older run is ignored).
        var runs = 0
        var watchdog: DispatchSourceTimer?

        init(job: ExportJob) {
            self.job = job
        }
    }

    // Export-queue state.
    private var jobs: [String: Running] = [:]

    convenience init(context: EngineContext) {
        self.init(context: context, environment: .production(context: context), interruption: JobInterruption(), startInterruption: true)
    }

    init(context: EngineContext, environment: ExportEnvironment, interruption: JobInterruption, startInterruption: Bool) {
        self.context = context
        self.environment = environment
        self.interruption = interruption
        previewSuspender = NotificationPreviewSuspender(context: context)
        lifecycle = ExportCoordinator.discoverLifecycle(context: context)
        interruption.requeue = { [weak self] jobId in self?.foreground(jobId) }
        if startInterruption {
            let start = { [interruption] in
                interruption.start(initiallyBackgrounded: UIApplication.shared.applicationState == .background)
            }
            if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        }
    }

    // MARK: Discovery

    private static var moduleName: String {
        String(reflecting: ExportCoordinator.self).components(separatedBy: ".").first ?? "danaview_editor_engine"
    }

    /// IOS-20's `PrecomposeExporter`, when it is linked.
    static func discoverMultiPass(context: EngineContext) -> MultiPassExporting? {
        guard let type = NSClassFromString("\(moduleName).\(multiPassClassName)") as? MultiPassExporting.Type else { return nil }
        return type.init(context: context)
    }

    /// IOS-13's ActiveExportStore, once it conforms to `ExportJobLifecycle`.
    static func discoverLifecycle(context: EngineContext) -> ExportJobLifecycle? {
        let type: Any.Type = ActiveExportStore.self
        guard let lifecycle = type as? ExportJobLifecycle.Type else { return nil }
        return lifecycle.init(context: context)
    }

    private func multiPassHook() -> MultiPassExporting? {
        if multiPass == nil && !multiPassLookedUp {
            multiPassLookedUp = true
            multiPass = ExportCoordinator.discoverMultiPass(context: context)
        }
        return multiPass
    }

    // MARK: Checks

    /// Throws `planInvalid` unless [plan] is an export plan for [settings].
    static func checkPlan(_ plan: RenderPlan, _ settings: EncoderSettings) throws {
        guard plan.target == .export else { throw EngineError(.planInvalid, "not an export plan") }
        guard plan.canvas.w == settings.width, plan.canvas.h == settings.height else {
            throw EngineError(.planInvalid, "plan canvas differs from the output size")
        }
        guard plan.canvas.fps == settings.fps else { throw EngineError(.planInvalid, "plan fps differs from the export fps") }
        guard plan.durUs > 0 else { throw EngineError(.planInvalid, "empty export plan") }
        if let first = PlanValidator.validate(plan).first {
            throw EngineError(.planInvalid, "plan violation \(first.code.rawValue)", itemId: first.id)
        }
    }

    /// Decoder-backed composition tracks the plan needs (CORE-36 slots).
    static func decoderTracks(_ plan: RenderPlan) -> Int {
        Set(plan.layers.filter { $0.kind == .media }.compactMap(\.seq)).count
    }

    /// Most decoder-backed video layers active at once.
    static func peakVideoLayers(_ plan: RenderPlan) -> Int {
        var events: [(Int64, Int)] = []
        for l in plan.layers where l.kind == .media {
            events.append((l.t0, 1))
            events.append((l.t1, -1))
        }
        events.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var current = 0
        var peak = 0
        for e in events {
            current += e.1
            peak = max(peak, current)
        }
        return peak
    }

    /// Largest standard short side the device encodes for [plan] (ARCH §14.4).
    func maxShortSide(plan: RenderPlan, settings: EncoderSettings) -> Int? {
        let tier = environment.tier()
        var tierMax: Int
        switch tier {
        case .minimal, .low: tierMax = 1080
        case .mid: tierMax = ExportCoordinator.peakVideoLayers(plan) <= 2 ? 2160 : 1440
        case .high: tierMax = 2160
        }
        let long = Double(max(settings.width, settings.height))
        let short = Double(max(1, settings.shortSide))
        for candidate in [2160, 1440, 1080, 720] where candidate <= tierMax {
            func even(_ v: Double) -> Int { let i = Int(v.rounded()); return i - i % 2 }
            let otherSide = even(long * Double(candidate) / short)
            let w = settings.width >= settings.height ? otherSide : candidate
            let h = settings.width >= settings.height ? candidate : otherSide
            var trial = settings
            trial.width = w
            trial.height = h
            if (try? EncodeLayout.choose(trial, probe: environment.probe)) != nil { return candidate }
        }
        return nil
    }

    /// The settings actually used: HEVC falls back to H.264 when no HEVC encoder takes the size.
    private func effectiveSettings(_ requested: EncoderSettings, warnings: inout [ExportWarningMsg]) -> EncoderSettings {
        guard requested.codec == .hevc else { return requested }
        let support = environment.encoders()
        if support.hevc, (try? EncodeLayout.choose(requested, probe: environment.probe)) != nil { return requested }
        warnings.append(ExportWarnings.hevcUnavailable())
        return requested.with(codec: .h264)
    }

    private func hardware(_ codec: EncoderSettings.Codec) -> Bool {
        let support = environment.encoders()
        return codec == .hevc ? support.hardwareHevc : support.hardwareH264
    }

    private func baseWarnings(_ settings: EncoderSettings, plan: RenderPlan) -> [ExportWarningMsg] {
        var warnings: [ExportWarningMsg] = []
        if !hardware(settings.codec) { warnings.append(ExportWarnings.softwareEncoder()) }
        if environment.backgroundKind() == .paused { warnings.append(ExportWarnings.backgroundPauses()) }
        if ExportCoordinator.decoderTracks(plan) > environment.decoderLimit {
            warnings.append(ExportWarnings.layersVsResolution(multiPass: true))
        }
        return warnings
    }

    // MARK: ExportCoordinating

    func preflight(plan: Data, settings: EncodeSettingsMsg, reply: @escaping EngineReply<ExportPreflightMsg>) {
        queue.async { [self] in
            do {
                let requested = try EncoderSettings(msg: settings)
                let decoded = try RenderPlanDecoder.decodePlan(plan)
                try ExportCoordinator.checkPlan(decoded, requested)
                var warnings: [ExportWarningMsg] = []
                let used = effectiveSettings(requested, warnings: &warnings)
                var ok = true
                do {
                    if try EncodeLayout.choose(used, probe: environment.probe) == .rotated {
                        warnings.append(ExportWarnings.portraitRetried())
                    }
                } catch {
                    ok = false
                }
                warnings.append(contentsOf: baseWarnings(used, plan: decoded))
                let maxShort = maxShortSide(plan: decoded, settings: used)
                if let maxShort = maxShort, used.shortSide > maxShort,
                   !warnings.contains(where: { $0.code == "layersVsResolution" }) {
                    warnings.append(ExportWarnings.layersVsResolution(multiPass: false))
                }
                if let paths = context.paths {
                    let free = (try? environment.freeBytes(paths.cacheRoot)) ?? Int64.max
                    if free < used.requiredBytes(durationUs: decoded.durUs) {
                        ok = false
                        warnings.append(ExportWarnings.lowDisk())
                    }
                }
                reply(.success(ExportPreflightMsg(ok: ok, maxHeightForPlan: maxShort.map(Int64.init), warnings: warnings)))
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    func start(
        plan: Data, settings: EncodeSettingsMsg, outputURL: URL, title: String, whenDetached: DetachedHandoffMsg,
        reply: @escaping EngineReply<String>
    ) {
        queue.async { [self] in
            let running: Running
            do {
                running = try prepare(plan: plan, settings: settings, outputURL: outputURL, title: title, whenDetached: whenDetached)
            } catch {
                return reply(.failure(EngineError.from(error)))
            }
            let job = running.job
            Log.info(
                .export,
                "export \(job.id): \(job.record.settings.codec.rawValue) \(job.record.settings.width)x\(job.record.settings.height)@\(job.record.settings.fps) layout=\(job.record.layout.rawValue) tracks=\(ExportCoordinator.decoderTracks(job.plan))")
            reply(.success(job.id))
            launch(running)
        }
    }

    /// Validates, creates the job directory and registers the job (export queue).
    private func prepare(
        plan data: Data, settings: EncodeSettingsMsg, outputURL: URL, title: String, whenDetached: DetachedHandoffMsg
    ) throws -> Running {
        let paths = try context.requirePaths()
        guard jobs.isEmpty else { throw EngineError(.busy, "another export is running", retryable: true) }
        let requested = try EncoderSettings(msg: settings)
        let plan = try RenderPlanDecoder.decodePlan(data)
        try ExportCoordinator.checkPlan(plan, requested)
        var warnings: [ExportWarningMsg] = []
        let used = effectiveSettings(requested, warnings: &warnings)
        let layout = try EncodeLayout.choose(used, probe: environment.probe)
        if layout == .rotated { warnings.append(ExportWarnings.portraitRetried()) }
        warnings.append(contentsOf: baseWarnings(used, plan: plan))
        try paths.ensureDirectory(paths.work)
        let free = try environment.freeBytes(paths.cacheRoot)
        if free < used.requiredBytes(durationUs: plan.durUs) {
            throw EngineError(.diskFull, "not enough free space for the export")
        }
        let id = ExportJob.newId()
        let directory = ExportJob.directory(for: id, work: paths.work)
        let record = ExportJob.Record(
            jobId: id, settings: used, outputPath: outputURL.path, title: title,
            whenDetached: whenDetached == .keepForLater ? "keepForLater" : "saveToGallery", layout: layout,
            planHash: ExportJob.hash(data), state: .running, result: nil, createdAt: Date())
        let job = ExportJob(id: id, directory: directory, plan: plan, planData: data, record: record)
        try job.save()
        warnings.forEach(job.addWarning)
        lifecycle?.exportStarted(jobId: id, settings: used.msg, title: title, whenDetached: whenDetached)
        return register(job)
    }

    private func register(_ job: ExportJob) -> Running {
        let running = Running(job: job)
        job.thermalState = environment.thermalState
        job.stallTimeout = environment.stallTimeout
        job.stopGrace = environment.stopGrace
        job.onChange = { [weak self, weak running] in
            guard let self = self, let running = running else { return }
            self.emitProgress(running, force: false)
        }
        jobs[job.id] = running
        DiskCache.markActive(job.directory)
        DiskCache.markActive(URL(fileURLWithPath: job.record.outputPath))
        let tier = environment.tier()
        if tier != .high {
            running.suspendedPreview = true
            previewSuspender.suspendPreviewForExport()
        }
        return running
    }

    func resume(jobId: String, reply: @escaping EngineReply<String>) {
        queue.async { [self] in
            if let running = jobs[jobId] {
                if running.state == .waitingForForeground && !interruption.isBackgrounded {
                    launch(running)
                }
                return reply(.success(jobId))
            }
            do {
                let paths = try context.requirePaths()
                guard jobs.isEmpty else { throw EngineError(.busy, "another export is running", retryable: true) }
                let directory = ExportJob.directory(for: jobId, work: paths.work)
                guard SegmentCheckpoint.load(from: directory) != nil else {
                    throw EngineError(.interrupted, "no resumable export with this id")
                }
                let job = try ExportJob.load(directory)
                guard job.record.state == .running else { throw EngineError(.interrupted, "the export already finished") }
                warningsOnResume(job)
                let running = register(job)
                reply(.success(jobId))
                launch(running)
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    private func warningsOnResume(_ job: ExportJob) {
        if job.record.layout == .rotated { job.addWarning(ExportWarnings.portraitRetried()) }
        baseWarnings(job.record.settings, plan: job.plan).forEach(job.addWarning)
    }

    func cancel(jobId: String, reply: @escaping EngineReply<Void>) {
        queue.async { [self] in
            if let running = jobs[jobId] {
                running.job.cancel()
                if running.state == .waitingForForeground {
                    interruption.unregister(jobId: jobId)
                    end(running, failure: EngineError.cancelled)
                } else {
                    // A running job ends through `completed` once its pipeline stops; a pipeline
                    // blocked inside AVFoundation is left behind after the grace (QA-05 D2).
                    let run = running.runs
                    queue.asyncAfter(deadline: .now() + environment.cancelGrace) { [weak self, weak running] in
                        guard let self = self, let running = running, !running.ended, running.runs == run else { return }
                        Log.error(.export, "export \(jobId): pipeline did not stop \(self.environment.cancelGrace) s after cancel; left behind")
                        self.abandonedPipelines += 1
                        self.end(running, failure: EngineError.cancelled)
                    }
                }
                return reply(.success(()))
            }
            if let paths = context.paths {
                let directory = ExportJob.directory(for: jobId, work: paths.work)
                if let record = ExportJob.loadRecord(directory), record.state == .running {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: record.outputPath))
                }
                try? FileManager.default.removeItem(at: directory)
            }
            reply(.success(()))
        }
    }

    func activeJobs(reply: @escaping EngineReply<[ExportJobRecordMsg]>) {
        queue.async { [self] in
            var out: [ExportJobRecordMsg] = []
            var seen = Set<String>()
            for running in jobs.values.sorted(by: { $0.job.record.createdAt < $1.job.record.createdAt }) {
                let job = running.job
                seen.insert(job.id)
                out.append(ExportJobRecordMsg(
                    jobId: job.id, state: .running, doneFraction: job.fraction, result: nil, savedToGallery: false,
                    savedUri: nil, settings: job.record.settings.msg))
            }
            if let paths = context.paths {
                for record in ExportCoordinator.diskRecords(work: paths.work) where !seen.contains(record.jobId) {
                    seen.insert(record.jobId)
                    out.append(record)
                }
            }
            for record in lifecycle?.records() ?? [] where !seen.contains(record.jobId) {
                seen.insert(record.jobId)
                out.append(record)
            }
            reply(.success(out))
        }
    }

    /// Records of the job directories under [work] (jobs not running in this process).
    static func diskRecords(work: URL) -> [ExportJobRecordMsg] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: work.path) else { return [] }
        var out: [(Date, ExportJobRecordMsg)] = []
        for name in names where name.hasPrefix(ExportJob.directoryPrefix) {
            let directory = work.appendingPathComponent(name, isDirectory: true)
            guard let record = ExportJob.loadRecord(directory) else { continue }
            switch record.state {
            case .completedDetached:
                out.append((record.createdAt, ExportJobRecordMsg(
                    jobId: record.jobId, state: .completedWhileDetached, doneFraction: 1, result: record.result?.msg,
                    savedToGallery: record.savedToGallery, savedUri: nil, settings: record.settings.msg)))
            case .running:
                let checkpoint = SegmentCheckpoint.load(from: directory)
                let done = checkpoint?.completed.contains { $0.frames > 0 } ?? false
                out.append((record.createdAt, ExportJobRecordMsg(
                    jobId: record.jobId, state: done ? .resumable : .interrupted,
                    doneFraction: checkpoint?.doneFraction ?? 0, result: nil, savedToGallery: false, savedUri: nil,
                    settings: record.settings.msg)))
            }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func consumeJobRecord(jobId: String) {
        queue.async { [self] in
            guard jobs[jobId] == nil else { return }
            lifecycle?.consume(jobId: jobId)
            guard let paths = context.paths else { return }
            let directory = ExportJob.directory(for: jobId, work: paths.work)
            if let record = ExportJob.loadRecord(directory) {
                let output = URL(fileURLWithPath: record.outputPath)
                if record.state == .completedDetached {
                    // The output stays for Dart's handoff (OwnedFileDeleter); only the wipe exemption ends.
                    WorkExemptions.remove(output, paths: paths)
                    WorkExemptions.remove(directory, paths: paths)
                } else {
                    try? FileManager.default.removeItem(at: output)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Running

    private func launch(_ running: Running) {
        let job = running.job
        guard interruption.register(job) else {
            // In the background: wait for the foreground re-queue (D-22).
            running.state = .waitingForForeground
            job.markPaused(backgrounded: true)
            emitProgress(running, force: true)
            return
        }
        running.state = .running
        running.runs += 1
        let run = running.runs
        job.prepareRun()
        emitProgress(running, force: true)
        startWatchdog(running)
        let paths = context.paths
        // One work queue per run: a pipeline left behind blocked never holds up a later job.
        let workQueue = DispatchQueue(label: "com.vecvel.danaview.editor.export.work.\(job.id).\(run)", qos: .userInitiated)
        workQueue.async { [self] in
            let outcome: Result<ReaderWriterPipeline.Outcome, Error>
            do {
                guard let paths = paths else { throw EngineError.notInitialized }
                outcome = .success(try execute(job, paths: paths))
            } catch {
                outcome = .failure(error)
            }
            queue.async {
                guard !running.ended, running.runs == run else {
                    Log.info(.export, "export \(job.id): late pipeline completion ignored")
                    return
                }
                self.completed(running, outcome)
            }
        }
    }

    // MARK: Stall watchdog (FIX-IOS-EXPORT-STALL)

    /// The typed failure of a job without progress for [seconds].
    static func stallFailure(seconds: TimeInterval, phase: ExportJobPhase) -> EngineError {
        EngineError(.encodingFailed, "export stalled: no progress for \(Int(seconds.rounded())) s (phase \(phase.rawValue))", retryable: true)
    }

    private func startWatchdog(_ running: Running) {
        guard running.watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + environment.watchdogInterval, repeating: environment.watchdogInterval)
        timer.setEventHandler { [weak self, weak running] in
            guard let self = self, let running = running else { return }
            self.checkStall(running)
        }
        running.watchdog = timer
        timer.resume()
    }

    private func stopWatchdog(_ running: Running) {
        running.watchdog?.cancel()
        running.watchdog = nil
    }

    /// Export queue: ends a running job without a heartbeat for `stallTimeout + watchdogSlack`.
    private func checkStall(_ running: Running) {
        let job = running.job
        guard !running.ended, running.state == .running, jobs[job.id] === running else { return }
        if job.isThermallyPaused {
            job.heartbeat()
            return
        }
        let limit = environment.stallTimeout + environment.watchdogSlack
        let idle = job.secondsSinceActivity
        guard idle >= limit else { return }
        let failure = ExportCoordinator.stallFailure(seconds: idle, phase: job.phase)
        Log.error(.export, "export \(job.id): \(failure.message); left behind")
        abandonedPipelines += 1
        // Stop whatever may still wake up, then end the job now.
        job.cancel()
        end(running, failure: failure)
    }

    /// The composition factory of [paths] (export variant: originals, output render size).
    private func compositionFactory(paths: Paths) -> ExportCompositionFactory {
        if let override = makeComposition { return override }
        let resolve = environment.resolveURL
        return { plan in
            let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
            var options = CompositionBuildOptions(spacerDirectory: paths.engineAssets)
            options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
            options.useProxies = false
            options.access = SessionMediaAccess()
            options.validate = false
            options.resolveURL = resolve
            session.configure(&options)
            let input = UncheckedSendable((plan, options))
            let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
            return ExportComposition(built: built, session: session)
        }
    }

    private func pipeline(_ job: ExportJob, plan: RenderPlan, planHash: String, layout: EncodeLayout, directory: URL,
                          factory: @escaping ExportCompositionFactory) -> ReaderWriterPipeline {
        let input = ReaderWriterPipeline.Input(
            jobId: job.id, plan: plan, planHash: planHash, settings: job.record.settings, layout: layout,
            directory: directory, outputURL: URL(fileURLWithPath: job.record.outputPath))
        let p = ReaderWriterPipeline(input: input, control: job, makeComposition: factory)
        p.segmentDurationUs = environment.segmentDurationUs
        p.probe = environment.probe
        configurePipeline?(p)
        return p
    }

    /// Runs [job] on the work queue: single pass, portrait retry, multi-pass routing.
    private func execute(_ job: ExportJob, paths: Paths) throws -> ReaderWriterPipeline.Outcome {
        let factory = compositionFactory(paths: paths)
        let needed = ExportCoordinator.decoderTracks(job.plan)
        if needed > environment.decoderLimit, let hook = multiPassHookOnWork() {
            Log.info(.export, "export \(job.id): \(needed) decoder tracks > \(environment.decoderLimit): multi-pass")
            return try hook.export(multiPassContext(job, reason: .decoderLimit(needed: needed, limit: environment.decoderLimit), factory: factory))
        }
        do {
            return try pipeline(job, plan: job.plan, planHash: job.record.planHash, layout: job.record.layout,
                                directory: job.directory, factory: factory).run()
        } catch {
            let e = EngineError.from(error)
            if job.isCancelled { throw EngineError.cancelled }
            if e.code == .decoderInitFailed, let hook = multiPassHookOnWork() {
                Log.info(.export, "export \(job.id): decoderInitFailed: multi-pass")
                return try hook.export(multiPassContext(job, reason: .decoderInitFailed, factory: factory))
            }
            let settings = job.record.settings
            if (e.code == .encoderSizeLimit || e.code == .encoderUnavailable) && settings.isPortrait && job.record.layout == .native
                && environment.probe.canEncode(settings.codec, settings.height, settings.width) {
                // ARCH §14.1: one retry with a landscape-encoded buffer and rotation metadata.
                Log.info(.export, "export \(job.id): portrait refused by the writer; retrying rotated")
                job.update { $0.layout = .rotated }
                job.addWarning(ExportWarnings.portraitRetried())
                do {
                    return try pipeline(job, plan: job.plan, planHash: job.record.planHash, layout: .rotated,
                                        directory: job.directory, factory: factory).run()
                } catch {
                    let retry = EngineError.from(error)
                    if retry.code == .encoderUnavailable || retry.code == .encoderSizeLimit {
                        throw EngineError(.encoderSizeLimit, "encoder refused \(settings.width)x\(settings.height) in both orientations")
                    }
                    throw retry
                }
            }
            throw e
        }
    }

    private func multiPassHookOnWork() -> MultiPassExporting? {
        queue.sync { multiPassHook() }
    }

    private func multiPassContext(_ job: ExportJob, reason: MultiPassReason, factory: @escaping ExportCompositionFactory) -> MultiPassContext {
        MultiPassContext(
            jobId: job.id, plan: job.plan, planHash: job.record.planHash, settings: job.record.settings, layout: job.record.layout,
            directory: job.directory, outputURL: URL(fileURLWithPath: job.record.outputPath), reason: reason,
            decoderLimit: environment.decoderLimit, control: job, makeComposition: factory,
            runFinalPass: { [weak self, weak job] plan, directory in
                guard let self = self, let job = job else { throw EngineError.cancelled }
                let data = PlanEncoder.encode(plan)
                return try self.pipeline(job, plan: plan, planHash: ExportJob.hash(data) + "-final", layout: job.record.layout,
                                         directory: directory, factory: factory).run()
            },
            setProgressWindow: { [weak job] start, span in job?.setProgressWindow(start: start, span: span) })
    }

    private func completed(_ running: Running, _ outcome: Result<ReaderWriterPipeline.Outcome, Error>) {
        let job = running.job
        interruption.unregister(jobId: job.id)
        switch outcome {
        case .success(.completed(let result)):
            environment.listenerAttached { [weak self] attached in
                self?.queue.async { self?.finish(running, result: result, listenerAttached: attached) }
            }
        case .success(.interrupted):
            if job.isCancelled { return end(running, failure: EngineError.cancelled) }
            if interruption.isBackgrounded {
                running.state = .waitingForForeground
                job.markPaused(backgrounded: true)
                // Re-registering while backgrounded puts the job on the foreground re-queue list.
                if interruption.register(job) {
                    // The foreground arrived in between.
                    interruption.unregister(jobId: job.id)
                    return launch(running)
                }
                emitProgress(running, force: true)
                Log.info(.export, "export \(job.id): paused in the background")
            } else if running.interruptionRetries < ExportCoordinator.maxInterruptionRetries {
                running.interruptionRetries += 1
                Log.info(.export, "export \(job.id): interrupted, continuing from the last segment")
                launch(running)
            } else {
                end(running, failure: EngineError(.interrupted, "export interrupted", retryable: true))
            }
        case .failure(let error):
            end(running, failure: job.isCancelled ? EngineError.cancelled : EngineError.from(error))
        }
    }

    private func finish(_ running: Running, result: ReaderWriterPipeline.Result, listenerAttached attached: Bool) {
        let job = running.job
        let settings = job.record.settings
        let msg = ExportResultMsg(
            path: result.path, bytes: result.bytes, durationUs: result.durationUs, videoEncoderName: settings.encoderName,
            hardwareEncoder: hardware(settings.codec))
        let handled = lifecycle?.exportCompleted(
            jobId: job.id, result: msg, listenerAttached: attached, whenDetached: job.record.detachedHandoff) ?? false
        let output = URL(fileURLWithPath: result.path)
        if !attached && !handled, let paths = context.paths {
            // D-39: keep a one-shot record and protect the output from the work/ wipe.
            job.update {
                $0.state = .completedDetached
                $0.result = ExportJob.StoredResult(
                    path: msg.path, bytes: msg.bytes, durationUs: msg.durationUs, videoEncoderName: msg.videoEncoderName,
                    hardwareEncoder: msg.hardwareEncoder)
            }
            WorkExemptions.add(output, paths: paths)
            WorkExemptions.add(job.directory, paths: paths)
            try? FileManager.default.removeItem(at: job.directory.appendingPathComponent(ExportJob.planFileName))
            SegmentCheckpoint.delete(in: job.directory)
        } else {
            try? FileManager.default.removeItem(at: job.directory)
        }
        Log.info(.export, "export \(job.id): done (\(result.frames) frames, \(result.bytes) bytes, listener=\(attached))")
        emitProgress(running, force: true)
        context.events.emitJobDone(jobId: job.id, JobResultMsg(kind: .export, exportResult: msg))
        release(running)
    }

    /// Ends [running] with [failure]: deletes the partial output and every segment.
    private func end(_ running: Running, failure: EngineError) {
        let job = running.job
        let directory = job.directory
        let output = URL(fileURLWithPath: job.record.outputPath)
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: directory)
        lifecycle?.exportEnded(jobId: job.id)
        if failure.code == .cancelled {
            Log.info(.export, "export \(job.id): cancelled")
        } else {
            Log.error(.export, "export \(job.id): failed \(failure.code.rawValue): \(failure.message)")
        }
        context.events.emitJobFailure(jobId: job.id, failure)
        release(running)
    }

    private func release(_ running: Running) {
        let job = running.job
        running.ended = true
        stopWatchdog(running)
        job.onChange = nil
        jobs[job.id] = nil
        interruption.unregister(jobId: job.id)
        DiskCache.unmarkActive(job.directory)
        DiskCache.unmarkActive(URL(fileURLWithPath: job.record.outputPath))
        if running.suspendedPreview {
            running.suspendedPreview = false
            previewSuspender.resumePreviewAfterExport()
        }
    }

    /// Foreground re-queue from JobInterruption (main thread).
    private func foreground(_ jobId: String) {
        queue.async { [self] in
            guard let running = jobs[jobId], running.state == .waitingForForeground else { return }
            Log.info(.export, "export \(jobId): back in the foreground, resuming")
            launch(running)
        }
    }

    // MARK: Events

    /// Minimum interval between progress samples sent to the hub (it limits to 4 Hz again).
    static let progressInterval: TimeInterval = 0.1

    private func emitProgress(_ running: Running, force: Bool) {
        let msg = running.job.progressMsg()
        let now = CACurrentMediaTime()
        running.throttle.lock()
        let last = running.lastMsg
        let changed = last == nil || last!.phase != msg.phase || last!.pausedInBackground != msg.pausedInBackground
            || last!.backgrounded != msg.backgrounded || last!.warnings != msg.warnings
        let due = force || changed || now - running.lastEmit >= ExportCoordinator.progressInterval
        if due {
            running.lastEmit = now
            running.lastMsg = msg
        }
        running.throttle.unlock()
        if due { context.events.emitExportProgress(jobId: running.job.id, msg) }
    }

    // MARK: Tests

    /// Ids of the jobs of this process (export queue).
    var jobIds: [String] { jobs.keys.sorted() }

    /// The job [jobId] of this process (export queue; tests).
    func job(_ jobId: String) -> ExportJob? { jobs[jobId]?.job }

    /// Whether [jobId] stopped and waits for the foreground (export queue; tests).
    func isWaitingForForeground(_ jobId: String) -> Bool { jobs[jobId]?.state == .waitingForForeground }
}
