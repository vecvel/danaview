// OWNER: IOS-05
//
// Media job registry (ARCH §12.3, §15, D-22). Runs the waveform (IOS-04), speechAudio (IOS-04),
// proxy (IOS-05), freeze (IOS-06) and reverse (IOS-07) jobs that `JobsHostApi.startJob` starts:
//
// - Job ids are opaque strings; progress, results and failures are events keyed by the id
//   (`EventHub.emitProgress/emitJobDone/emitJobFailure`). Progress is throttled to <= 4 Hz here
//   too (the hub enforces it again) and never moves backwards.
// - Priorities: interactive > normal (export-blocking) > background; equal priorities run in start
//   order. Concurrency: 1 job on the minimal and low tiers, 2 otherwise (ARCH §15).
// - Pre-emption: a queued interactive job that finds every slot busy stops the lowest running
//   job of lower priority, which goes back to the queue and resumes later (segmented jobs from
//   their checkpoint, the others restart). While an export runs (`setExportActive`, called by
//   IOS-12) background jobs are stopped and not started.
// - Cancellation: queued jobs end at once, running jobs are stopped; either way the job deletes
//   its partial outputs (`.part` files, work/ directories) and ends with a `cancelled` failure.
// - Background (IOS-17 JobInterruption, D-22): didEnterBackground stops every running job (proxy
//   and reverse keep their completed segments/chunks, the others restart); willEnterForeground
//   re-queues them. Jobs started in the background wait for the foreground.
//
// Job bodies (`MediaJobBody`) block a worker thread of the registry's concurrent queue and poll
// `JobControl` (or register an `onStop` handler) to stop promptly.

import Foundation
import Metal
import UIKit

/// Why a running job was asked to stop.
enum JobStopReason: Equatable {
    /// Cancelled by the caller: delete partial output, end with `cancelled`.
    case cancel
    /// Pre-empted by a more important job or an export: back to the queue.
    case preempt
    /// The app went to the background: wait for the foreground (D-22).
    case background
}

/// The handle a running job body polls (any thread).
final class JobControl {
    let jobId: String
    /// Cancelled on any stop; readers that take a `MediaCancellation` stop with it.
    let cancellation = MediaCancellation()

    private let lock = NSLock()
    private var reason: JobStopReason?
    private var handlers: [(JobStopReason) -> Void] = []
    private let progressSink: (Double) -> Void

    init(jobId: String, progress: @escaping (Double) -> Void = { _ in }) {
        self.jobId = jobId
        progressSink = progress
    }

    /// Why the job was stopped, nil while it may run.
    var stopReason: JobStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    var isStopped: Bool { stopReason != nil }

    /// Runs [handler] when the job is stopped (at once when it already was).
    func onStop(_ handler: @escaping (JobStopReason) -> Void) {
        lock.lock()
        if let reason = reason {
            lock.unlock()
            handler(reason)
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    /// Stops the job. The first reason wins, except that a cancel overrides a pause.
    func stop(_ newReason: JobStopReason) {
        lock.lock()
        if let current = reason, current == .cancel || newReason != .cancel {
            lock.unlock()
            return
        }
        let first = reason == nil
        reason = newReason
        let pending = handlers
        if newReason == .cancel { handlers.removeAll() }
        lock.unlock()
        cancellation.cancel()
        // Pause handlers ran already when this upgrades a pause to a cancel; run them again so a
        // segmented job switches from interrupt() to cancel().
        if first || newReason == .cancel { pending.forEach { $0(newReason) } }
    }

    /// Throws when the job was stopped: `cancelled` for a cancel, `interrupted` for a pause.
    func check() throws {
        switch stopReason {
        case .none: return
        case .cancel?: throw EngineError.cancelled
        case .preempt?, .background?: throw JobControl.paused
        }
    }

    /// Reports progress in 0...1.
    func progress(_ fraction: Double) {
        progressSink(fraction)
    }

    /// The error a paused body throws (resumable).
    static let paused = EngineError(.interrupted, "job paused", retryable: true)
}

/// The work of one job. Blocking: `run` executes on a registry worker thread.
protocol MediaJobBody: AnyObject {
    var kind: JobKindMsg { get }
    /// Jobs with the same non-nil key never run at the same time (proxies of one media).
    var exclusiveKey: String? { get }
    /// Runs or resumes the job. Throws `EngineError.cancelled` / `JobControl.paused` when stopped.
    func run(_ control: JobControl) throws -> JobResultMsg
    /// Deletes partial outputs and work files (after a cancel or a failure).
    func cleanUp()
}

extension MediaJobBody {
    var exclusiveKey: String? { nil }
}

final class JobRegistry: JobScheduling {
    /// Job state as seen by tests and IOS-13.
    enum State: Equatable {
        case queued, running, waitingForForeground
    }

    /// Builds the body of a request (injectable for tests).
    typealias BodyFactory = (_ request: JobRequestMsg, _ mediaURL: URL, _ outputURL: URL?, _ paths: Paths) throws -> MediaJobBody

    private final class Entry {
        let id: String
        let body: MediaJobBody
        var priority: JobPriorityMsg
        let seq: Int
        var state: State = .queued
        var control: JobControl?
        var handle: RegistryJobHandle?
        /// Foreground arrived while the job was still stopping.
        var foregroundSeen = false
        var interruptionRetries = 0
        var lastProgress: Double = 0
        var lastProgressSent: TimeInterval = 0
        var pendingProgress: Double?

        init(id: String, body: MediaJobBody, priority: JobPriorityMsg, seq: Int) {
            self.id = id
            self.body = body
            self.priority = priority
            self.seq = seq
        }
    }

    private let context: EngineContext
    let concurrency: Int
    let interruption: JobInterruption
    private let makeBody: BodyFactory
    private let stateQueue = DispatchQueue(label: "com.vecvel.vwish.editor.jobs.registry")
    private let workers = DispatchQueue(label: "com.vecvel.vwish.editor.jobs.workers", qos: .utility, attributes: .concurrent)
    private var entries: [String: Entry] = [:]
    private var nextSeq = 0
    private var activeExports: Set<String> = []

    /// Minimum interval between progress events of one job.
    static let progressInterval: TimeInterval = 0.25
    /// Unexpected encoder losses (outside a known background) retried before failing.
    static let maxInterruptionRetries = 3

    // MARK: Lookup (IOS-12 export pre-emption)

    private static let lookupLock = NSLock()
    private static var byContext: [ObjectIdentifier: WeakRegistry] = [:]

    private final class WeakRegistry {
        weak var registry: JobRegistry?
        init(_ registry: JobRegistry) { self.registry = registry }
    }

    /// The registry of [context] (IOS-12 calls `setExportActive` on it).
    static func registry(for context: EngineContext) -> JobRegistry? {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        return byContext[ObjectIdentifier(context)]?.registry
    }

    // MARK: Init

    convenience init(context: EngineContext) {
        let tier = DeviceProfile.current(hasMetal: MTLCreateSystemDefaultDevice() != nil).tier
        self.init(context: context, concurrency: JobRegistry.concurrency(for: tier))
    }

    init(
        context: EngineContext, concurrency: Int, interruption: JobInterruption = JobInterruption(),
        startInterruption: Bool = true, makeBody: BodyFactory? = nil
    ) {
        self.context = context
        self.concurrency = max(1, concurrency)
        self.interruption = interruption
        self.makeBody = makeBody ?? JobRegistry.defaultBody
        interruption.requeue = { [weak self] jobId in self?.foreground(jobId) }
        JobRegistry.lookupLock.lock()
        JobRegistry.byContext[ObjectIdentifier(context)] = WeakRegistry(self)
        JobRegistry.lookupLock.unlock()
        if startInterruption {
            let start = { [interruption] in
                interruption.start(initiallyBackgrounded: UIApplication.shared.applicationState == .background)
            }
            if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        }
    }

    /// Jobs at a time per tier (ARCH §15).
    static func concurrency(for tier: DeviceTierMsg) -> Int {
        switch tier {
        case .minimal, .low: return 1
        case .mid, .high: return 2
        }
    }

    /// The production bodies of every job kind.
    static func defaultBody(_ request: JobRequestMsg, mediaURL: URL, outputURL: URL?, paths: Paths) throws -> MediaJobBody {
        switch request.kind {
        case .waveform:
            return WaveformJobBody(url: mediaURL, fingerprint: request.media.fingerprint,
                                   audioStream: Int(request.audioStream ?? 0), paths: paths)
        case .speechAudio:
            guard let output = outputURL, let start = request.sourceStartUs, let end = request.sourceEndUs else {
                throw EngineError.invalidArgument("request", "speechAudio needs a range and an output")
            }
            return SpeechAudioJobBody(url: mediaURL, startUs: start, endUs: end,
                                      audioStream: request.audioStream.map(Int.init), output: output)
        case .proxy:
            return ProxyJob(mediaURL: mediaURL, fingerprint: request.media.fingerprint, paths: paths)
        case .freeze:
            guard let output = outputURL, let time = request.sourceTimeUs else {
                throw EngineError.invalidArgument("request", "freeze needs a time and an output")
            }
            return FreezeFrameJob(mediaURL: mediaURL, sourceTimeUs: time, output: output)
        case .reverse:
            guard let output = outputURL, let start = request.sourceStartUs, let end = request.sourceEndUs else {
                throw EngineError.invalidArgument("request", "reverse needs a range and an output")
            }
            return ReverseJob(mediaURL: mediaURL, fingerprint: request.media.fingerprint, startUs: start, endUs: end,
                              audioStream: request.audioStream.map(Int.init), output: output, paths: paths)
        case .export:
            throw EngineError.invalidArgument("request.kind", "exports start through ExportHostApi")
        }
    }

    // MARK: JobScheduling

    func start(_ request: JobRequestMsg, mediaURL: URL, outputURL: URL?, reply: @escaping EngineReply<String>) {
        do {
            let paths = try context.requirePaths()
            let body = try makeBody(request, mediaURL, outputURL, paths)
            if request.kind == .proxy { ProxyRegistry.mark(fingerprint: request.media.fingerprint, .queued) }
            reply(.success(enqueue(body, priority: request.priority)))
        } catch {
            reply(.failure(EngineError.from(error)))
        }
    }

    /// Queues [body] and returns its job id (tests and the glue).
    @discardableResult
    func enqueue(_ body: MediaJobBody, priority: JobPriorityMsg) -> String {
        let id = UUID().uuidString.lowercased()
        DiskCache.beginActivity()
        stateQueue.sync {
            nextSeq += 1
            entries[id] = Entry(id: id, body: body, priority: priority, seq: nextSeq)
            Log.info(.jobs, "job \(body.kind) queued (\(priority))")
            pump()
        }
        return id
    }

    func cancel(jobId: String) {
        stateQueue.async { [self] in
            guard let entry = entries[jobId] else { return }
            switch entry.state {
            case .running:
                entry.control?.stop(.cancel)
            case .queued, .waitingForForeground:
                entries[jobId] = nil
                interruption.unregister(jobId: jobId)
                workers.async { [self] in
                    entry.body.cleanUp()
                    finish(entry, failure: EngineError.cancelled)
                }
                pump()
            }
        }
    }

    func setPriority(jobId: String, priority: JobPriorityMsg) {
        stateQueue.async { [self] in
            guard let entry = entries[jobId], entry.priority != priority else { return }
            entry.priority = priority
            pump()
        }
    }

    // MARK: Export pre-emption (IOS-12)

    /// Marks export [jobId] running or finished. While any export runs, background jobs are
    /// stopped (they resume afterwards) and not started.
    func setExportActive(_ jobId: String, active: Bool) {
        stateQueue.async { [self] in
            if active { activeExports.insert(jobId) } else { activeExports.remove(jobId) }
            pump()
        }
    }

    // MARK: Introspection (tests, IOS-13)

    func state(of jobId: String) -> State? {
        stateQueue.sync { entries[jobId]?.state }
    }

    var jobCount: Int { stateQueue.sync { entries.count } }

    var runningCount: Int { stateQueue.sync { entries.values.filter { $0.state == .running }.count } }

    // MARK: Scheduling (stateQueue)

    private static func rank(_ priority: JobPriorityMsg) -> Int {
        switch priority {
        case .interactive: return 0
        case .normal: return 1
        case .background: return 2
        }
    }

    private func eligible(_ entry: Entry, runningKeys: Set<String>) -> Bool {
        if !activeExports.isEmpty && entry.priority == .background { return false }
        if let key = entry.body.exclusiveKey, runningKeys.contains(key) { return false }
        return true
    }

    private func pump() {
        // Exports stop running background jobs.
        if !activeExports.isEmpty {
            for entry in entries.values where entry.state == .running && entry.priority == .background {
                if entry.control?.stopReason == nil {
                    Log.info(.jobs, "job \(entry.body.kind) pre-empted by an export")
                    entry.control?.stop(.preempt)
                }
            }
        }
        while true {
            let running = entries.values.filter { $0.state == .running }
            let runningKeys = Set(running.compactMap { $0.body.exclusiveKey })
            let candidates = entries.values
                .filter { $0.state == .queued && eligible($0, runningKeys: runningKeys) }
                .sorted { (JobRegistry.rank($0.priority), $0.seq) < (JobRegistry.rank($1.priority), $1.seq) }
            guard let next = candidates.first else { return }
            if running.count < concurrency {
                launch(next)
                continue
            }
            // Pre-emption by interactive jobs: stop the lowest running job of lower priority.
            if next.priority == .interactive {
                let stopping = running.contains { $0.control?.stopReason == .preempt }
                if !stopping, let victim = running
                    .filter({ JobRegistry.rank($0.priority) > JobRegistry.rank(next.priority) && $0.control?.stopReason == nil })
                    .max(by: { (JobRegistry.rank($0.priority), $0.seq) < (JobRegistry.rank($1.priority), $1.seq) }) {
                    Log.info(.jobs, "job \(victim.body.kind) pre-empted by an interactive \(next.body.kind)")
                    victim.control?.stop(.preempt)
                }
            }
            return
        }
    }

    private func launch(_ entry: Entry) {
        let control = JobControl(jobId: entry.id) { [weak self, weak entry] fraction in
            guard let self = self, let entry = entry else { return }
            self.stateQueue.async { self.reportProgress(entry, fraction) }
        }
        let handle = RegistryJobHandle(jobId: entry.id, control: control)
        entry.control = control
        entry.handle = handle
        entry.foregroundSeen = false
        guard interruption.register(handle) else {
            // In the background: wait for the foreground re-queue (D-22).
            entry.state = .waitingForForeground
            entry.control = nil
            return
        }
        entry.state = .running
        if entry.body.kind == .proxy, let proxy = entry.body as? ProxyJob {
            ProxyRegistry.mark(fingerprint: proxy.fingerprint, .running)
        }
        workers.async { [self] in
            let outcome: Result<JobResultMsg, Error>
            do {
                outcome = .success(try entry.body.run(control))
            } catch {
                outcome = .failure(error)
            }
            stateQueue.async { self.completed(entry, control: control, outcome: outcome) }
        }
    }

    private func completed(_ entry: Entry, control: JobControl, outcome: Result<JobResultMsg, Error>) {
        interruption.unregister(jobId: entry.id)
        entry.control = nil
        entry.handle = nil
        switch outcome {
        case .success(let result):
            entries[entry.id] = nil
            flushProgress(entry)
            finish(entry, result: result)
        case .failure(let error):
            let engineError = EngineError.from(error)
            switch control.stopReason {
            case .cancel?:
                entries[entry.id] = nil
                workers.async { [self] in
                    entry.body.cleanUp()
                    finish(entry, failure: EngineError.cancelled)
                }
            case .preempt?:
                entry.state = .queued
                Log.info(.jobs, "job \(entry.body.kind) paused (pre-empted)")
            case .background?:
                entry.state = entry.foregroundSeen ? .queued : .waitingForForeground
                Log.info(.jobs, "job \(entry.body.kind) paused (background)")
            case nil:
                if engineError.code == .interrupted && entry.interruptionRetries < JobRegistry.maxInterruptionRetries {
                    // The encoder was taken away before the background notification arrived.
                    entry.interruptionRetries += 1
                    entry.state = interruption.isBackgrounded ? .waitingForForeground : .queued
                    if entry.state == .waitingForForeground { interruption.register(RegistryJobHandle(jobId: entry.id, control: nil)) }
                } else {
                    entries[entry.id] = nil
                    workers.async { [self] in
                        entry.body.cleanUp()
                        finish(entry, failure: engineError.code == .cancelled ? EngineError(.internal, "job stopped") : engineError)
                    }
                }
            }
        }
        pump()
    }

    private func foreground(_ jobId: String) {
        stateQueue.async { [self] in
            guard let entry = entries[jobId] else { return }
            switch entry.state {
            case .waitingForForeground:
                entry.state = .queued
                Log.info(.jobs, "job \(entry.body.kind) re-queued on foreground")
                pump()
            case .running:
                entry.foregroundSeen = true
            case .queued:
                break
            }
        }
    }

    // MARK: Events

    private func reportProgress(_ entry: Entry, _ fraction: Double) {
        guard entries[entry.id] != nil, fraction.isFinite else { return }
        let value = max(entry.lastProgress, min(1, max(0, fraction)))
        guard value > entry.lastProgress || entry.lastProgressSent == 0 else { return }
        entry.lastProgress = value
        let now = ProcessInfo.processInfo.systemUptime
        if now - entry.lastProgressSent >= JobRegistry.progressInterval {
            entry.lastProgressSent = now
            entry.pendingProgress = nil
            context.events.emitProgress(jobId: entry.id, value)
        } else {
            entry.pendingProgress = value
        }
    }

    private func flushProgress(_ entry: Entry) {
        if let pending = entry.pendingProgress {
            entry.pendingProgress = nil
            context.events.emitProgress(jobId: entry.id, pending)
        }
    }

    private func finish(_ entry: Entry, result: JobResultMsg) {
        if result.kind == .proxy, let proxy = entry.body as? ProxyJob {
            ProxyRegistry.mark(fingerprint: proxy.fingerprint, nil)
        }
        Log.info(.jobs, "job \(entry.body.kind) done")
        context.events.emitJobDone(jobId: entry.id, result)
        DiskCache.endActivity()
    }

    private func finish(_ entry: Entry, failure: EngineError) {
        if let proxy = entry.body as? ProxyJob {
            ProxyRegistry.mark(fingerprint: proxy.fingerprint, failure.code == .cancelled ? nil : .failed)
        }
        Log.info(.jobs, "job \(entry.body.kind) ended: \(failure.code.rawValue)")
        context.events.emitJobFailure(jobId: entry.id, failure)
        DiskCache.endActivity()
    }
}

/// Adapts a running job to JobInterruption.
private final class RegistryJobHandle: InterruptibleJob {
    let interruptionJobId: String
    private weak var control: JobControl?

    init(jobId: String, control: JobControl?) {
        interruptionJobId = jobId
        self.control = control
    }

    func interruptForBackground() {
        control?.stop(.background)
    }
}

// MARK: - IOS-04 job bodies

/// Waveform peaks (IOS-04 WaveformService, cached in waves/). Restarts after a pause.
final class WaveformJobBody: MediaJobBody {
    let kind = JobKindMsg.waveform
    private let url: URL
    private let fingerprint: String
    private let audioStream: Int
    private let paths: Paths

    init(url: URL, fingerprint: String, audioStream: Int, paths: Paths) {
        self.url = url
        self.fingerprint = fingerprint
        self.audioStream = audioStream
        self.paths = paths
    }

    var exclusiveKey: String? { "waveform-\(fingerprint)-\(audioStream)" }

    func run(_ control: JobControl) throws -> JobResultMsg {
        do {
            let peaks = try WaveformService.peaks(
                url: url, fingerprint: fingerprint, audioStream: audioStream, store: DiskCache.stores(for: paths).waves,
                cancellation: control.cancellation, progress: control.progress)
            return JobResultMsg(kind: .waveform, peaks: peaks)
        } catch {
            try control.check()
            throw error
        }
    }

    func cleanUp() {}
}

/// 16 kHz speech audio (IOS-04 SpeechAudioExtractor); the extractor deletes its partial output.
final class SpeechAudioJobBody: MediaJobBody {
    let kind = JobKindMsg.speechAudio
    private let url: URL
    private let startUs: Int64
    private let endUs: Int64
    private let audioStream: Int?
    private let output: URL

    init(url: URL, startUs: Int64, endUs: Int64, audioStream: Int?, output: URL) {
        self.url = url
        self.startUs = startUs
        self.endUs = endUs
        self.audioStream = audioStream
        self.output = output
    }

    func run(_ control: JobControl) throws -> JobResultMsg {
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try SpeechAudioExtractor.extract(
                url: url, startUs: startUs, endUs: endUs, audioStream: audioStream, output: output,
                cancellation: control.cancellation, progress: control.progress)
            return JobResultMsg(kind: .speechAudio, speech: result.message)
        } catch {
            try control.check()
            throw error
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: output.appendingPathExtension("part"))
    }
}
