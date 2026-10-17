// OWNER: IOS-13
//
// What an export does when the app leaves the foreground (D-22, ARCH §14.2 'Background').
//
// Kind per device (`decideKind`):
// - iPhone (and any device without the continued-processing GPU resource): `paused`. On
//   didEnterBackground IOS-17's JobInterruption stops the pumps, the in-progress segment is
//   discarded, the checkpoint is kept and progress reports `pausedInBackground`; on return the
//   coordinator (IOS-12) continues from the last complete segment by itself. Nothing in this file
//   runs for `paused`.
// - iPad on iOS 26+ whose `BGTaskScheduler.supportedResources` contains `.gpu` (reported only to
//   apps holding the GPU entitlement) and whose Info.plist permits `com.vecvel.danaview.export.*`:
//   `continued`. `begin` submits `BGContinuedProcessingTaskRequest("com.vecvel.danaview.export.
//   <jobId>", title, subtitle)` with `strategy = .fail` and `requiredResources = .gpu` while the
//   app is still in the foreground, reports the job's progress to the system (1 Hz, the system's
//   Live Activity shows it) and on expiration calls `onExpired`, which is the same checkpoint
//   interruption as `paused`. `end` completes the task.
// - No software-CIContext background path: IOS-01 measured it only on the simulator (V-N22), so it
//   stays off until a device run proves ≥ 0.2× real time.
//
// The device facts behind `continued` are unverified on hardware (IOS-01: the simulator reports no
// `.gpu`); the iPad run is deferred: no device available.

import BackgroundTasks
import Foundation
import UIKit

/// One running continued-processing task, as BackgroundExecution needs it (tests inject fakes).
protocol ContinuedTaskHandle: AnyObject {
    /// Called by the system when it expires the task (any thread).
    var expirationHandler: (() -> Void)? { get set }
    /// Progress shown by the system, `completed` of `total` units.
    func setProgress(completed: Int64, total: Int64)
    func updateSubtitle(title: String, subtitle: String)
    func complete(success: Bool)
}

/// `BGTaskScheduler` for continued-processing tasks (tests inject fakes).
protocol ContinuedTaskScheduling: AnyObject {
    /// Registers [launch] for [identifier] and submits the request. Throws when the system refuses
    /// (strategy `.fail`: busy system, missing permission or resource).
    func submit(identifier: String, title: String, subtitle: String, launch: @escaping (ContinuedTaskHandle) -> Void) throws
    /// Withdraws a request that has not launched yet.
    func cancel(identifier: String)
}

final class BackgroundExecution {
    /// Prefix of the continued-processing task identifiers (Info.plist permits `<prefix>*`, INT-03).
    static let taskIdentifierPrefix = "com.vecvel.danaview.export."
    /// Units of the progress reported to the system.
    static let progressUnits: Int64 = 1_000

    /// The task identifier of [jobId].
    static func taskIdentifier(jobId: String) -> String { taskIdentifierPrefix + jobId }

    /// The background kind of a device (D-22). [gpuResource] is
    /// `BGTaskScheduler.supportedResources.contains(.gpu)` with the task identifier permitted.
    static func decideKind(idiom: DeviceProfile.Idiom, iOS26: Bool, gpuResource: Bool) -> BackgroundExportKindMsg {
        idiom == .pad && iOS26 && gpuResource ? .continued : .paused
    }

    /// The kind of this device.
    static func currentKind() -> BackgroundExportKindMsg {
        let profile = DeviceProfile.current(hasMetal: true)
        return decideKind(
            idiom: profile.idiom, iOS26: profile.osAtLeast(26),
            gpuResource: Capabilities.backgroundGpuAvailable(profile: profile))
    }

    let kind: BackgroundExportKindMsg
    private let scheduler: ContinuedTaskScheduling?
    private let progressInterval: TimeInterval
    private let timerQueue = DispatchQueue(label: "com.vecvel.danaview.editor.export.background", qos: .utility)

    private final class Entry {
        let jobId: String
        let title: String
        let progress: () -> Double
        let onExpired: (String) -> Void
        var handle: ContinuedTaskHandle?
        var timer: DispatchSourceTimer?
        var lastUnits: Int64 = -1

        init(jobId: String, title: String, progress: @escaping () -> Double, onExpired: @escaping (String) -> Void) {
            self.jobId = jobId
            self.title = title
            self.progress = progress
            self.onExpired = onExpired
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// The production instance: this device's kind and the system scheduler on iOS 26+.
    convenience init() {
        let kind = BackgroundExecution.currentKind()
        var scheduler: ContinuedTaskScheduling?
        if kind == .continued, #available(iOS 26.0, *) { scheduler = SystemContinuedTaskScheduler() }
        self.init(kind: kind, scheduler: scheduler)
    }

    init(kind: BackgroundExportKindMsg, scheduler: ContinuedTaskScheduling?, progressInterval: TimeInterval = 1) {
        self.kind = kind
        self.scheduler = scheduler
        self.progressInterval = progressInterval
    }

    /// Ids of the jobs with a submitted or running continued task (tests).
    var activeJobIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    /// Starts the continued-processing task of [jobId] when this device's kind is `continued`.
    /// Returns whether a task was submitted. [progress] (0...1, any thread) is sampled for the
    /// system; [onExpired] runs once when the system expires the task.
    @discardableResult
    func begin(jobId: String, title: String, progress: @escaping () -> Double, onExpired: @escaping (String) -> Void) -> Bool {
        guard kind == .continued, let scheduler = scheduler else { return false }
        let entry = Entry(jobId: jobId, title: title, progress: progress, onExpired: onExpired)
        lock.lock()
        let existing = entries[jobId] != nil
        if !existing { entries[jobId] = entry }
        lock.unlock()
        if existing { return true }
        do {
            try scheduler.submit(
                identifier: BackgroundExecution.taskIdentifier(jobId: jobId), title: title,
                subtitle: BackgroundExecution.subtitle(0)
            ) { [weak self] handle in self?.launched(jobId: jobId, handle: handle) }
            Log.info(.export, "export \(jobId): continued-processing task submitted")
            return true
        } catch {
            lock.lock()
            entries[jobId] = nil
            lock.unlock()
            // strategy .fail: the export still runs and pauses in the background like an iPhone.
            Log.info(.export, "export \(jobId): continued-processing task refused (\(EngineError.from(error).code.rawValue))")
            return false
        }
    }

    /// Ends the task of [jobId] (export finished, failed or cancelled). Idempotent.
    func end(jobId: String, success: Bool) {
        lock.lock()
        let entry = entries.removeValue(forKey: jobId)
        lock.unlock()
        guard let entry = entry else { return }
        entry.timer?.cancel()
        if let handle = entry.handle {
            handle.expirationHandler = nil
            if success { handle.setProgress(completed: BackgroundExecution.progressUnits, total: BackgroundExecution.progressUnits) }
            handle.complete(success: success)
        } else {
            scheduler?.cancel(identifier: BackgroundExecution.taskIdentifier(jobId: jobId))
        }
    }

    // MARK: Task

    private func launched(jobId: String, handle: ContinuedTaskHandle) {
        lock.lock()
        guard let entry = entries[jobId], entry.handle == nil else {
            lock.unlock()
            // The job ended before the system launched the task.
            handle.complete(success: false)
            return
        }
        entry.handle = handle
        lock.unlock()
        handle.expirationHandler = { [weak self] in self?.expired(jobId: jobId) }
        report(entry)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + progressInterval, repeating: progressInterval)
        timer.setEventHandler { [weak self, weak entry] in
            guard let entry = entry else { return }
            self?.report(entry)
        }
        lock.lock()
        entry.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func report(_ entry: Entry) {
        let value = entry.progress()
        let fraction = value.isFinite ? min(1, max(0, value)) : 0
        let units = Int64((fraction * Double(BackgroundExecution.progressUnits)).rounded(.down))
        lock.lock()
        let handle = entry.handle
        let changed = units != entry.lastUnits
        entry.lastUnits = units
        lock.unlock()
        guard changed, let handle = handle else { return }
        handle.setProgress(completed: units, total: BackgroundExecution.progressUnits)
        handle.updateSubtitle(title: entry.title, subtitle: BackgroundExecution.subtitle(fraction))
    }

    private func expired(jobId: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: jobId)
        lock.unlock()
        guard let entry = entry else { return }
        entry.timer?.cancel()
        Log.info(.export, "export \(jobId): continued-processing task expired; checkpoint interruption")
        entry.onExpired(jobId)
        entry.handle?.complete(success: false)
    }

    /// The task subtitle: the locale's percent of [fraction].
    static func subtitle(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(1, max(0, fraction)))) ?? "\(Int(fraction * 100))%"
    }
}

// MARK: - System scheduler (iOS 26+)

@available(iOS 26.0, *)
final class SystemContinuedTaskScheduler: ContinuedTaskScheduling {
    private final class Handle: ContinuedTaskHandle {
        let task: BGContinuedProcessingTask

        init(task: BGContinuedProcessingTask) {
            self.task = task
        }

        var expirationHandler: (() -> Void)? {
            get { task.expirationHandler }
            set { task.expirationHandler = newValue }
        }

        func setProgress(completed: Int64, total: Int64) {
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = completed
        }

        func updateSubtitle(title: String, subtitle: String) {
            task.updateTitle(title, subtitle: subtitle)
        }

        func complete(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }

    func submit(identifier: String, title: String, subtitle: String, launch: @escaping (ContinuedTaskHandle) -> Void) throws {
        // Continued-processing registrations are exempt from the before-launch rule.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            launch(Handle(task: task))
        }
        guard registered else { throw EngineError(.notSupportedOnDevice, "continued-processing identifier not permitted") }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        request.requiredResources = .gpu
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
