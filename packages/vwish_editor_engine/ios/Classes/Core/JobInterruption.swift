// OWNER: IOS-17
//
// Background interruption and re-queue of reader/writer jobs (D-22, ARCH §14.2, §15). iOS takes
// the hardware encoder away from a backgrounded app, so on didEnterBackground every registered
// job is stopped immediately (a segmented job discards its in-progress segment and keeps its
// checkpoint; freeze frames and waveforms simply restart) and reported through `onInterrupted`;
// on willEnterForeground the interrupted jobs are handed to `requeue` (IOS-05 JobRegistry /
// IOS-12 ExportCoordinator call their run again, which resumes from the checkpoint). Jobs started
// while the app is in the background are interrupted at once. After a process kill,
// `resumableJobs(under:)` lists the checkpoints left in work/ (IOS-13 `activeJobs()` reports them
// as resumable; IOS-03's launch wipe keeps their directories).
//
// Owners create one JobInterruption per engine (or share one) and call `start()` on main.

import Foundation
import UIKit

/// A job JobInterruption can stop.
protocol InterruptibleJob: AnyObject {
    /// Stable id (the job id the Dart side knows).
    var interruptionJobId: String { get }
    /// Stops at once; called on the main thread. Must not block.
    func interruptForBackground()
}

final class JobInterruption {
    /// A checkpoint found on disk (cold start).
    struct ResumableJob: Equatable {
        var jobId: String
        var directory: URL
        var jobKind: String
        var inputHash: String
        var doneFraction: Double
        var updatedAt: Date
    }

    private let center: NotificationCenter
    private let lock = NSLock()
    private var jobs: [String: InterruptibleJob] = [:]
    private var interrupted: [String] = []
    private var backgrounded = false
    private var observers: [NSObjectProtocol] = []

    /// Called (main thread) with the ids of the jobs just interrupted.
    var onInterrupted: (([String]) -> Void)?
    /// Called (main thread) once per interrupted job when the app returns to the foreground.
    var requeue: ((String) -> Void)?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        observers.forEach(center.removeObserver)
    }

    /// Starts observing the app lifecycle. Idempotent.
    func start(initiallyBackgrounded: Bool = false) {
        lock.lock()
        let already = !observers.isEmpty
        if !already { backgrounded = initiallyBackgrounded }
        lock.unlock()
        guard !already else { return }
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.didEnterBackground() })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.willEnterForeground() })
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    var isBackgrounded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgrounded
    }

    /// Ids of the jobs waiting for the foreground.
    var interruptedJobIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// Registers a running job. Returns false (and interrupts it on main) when the app is already
    /// in the background: the job waits for the foreground re-queue.
    @discardableResult
    func register(_ job: InterruptibleJob) -> Bool {
        lock.lock()
        let id = job.interruptionJobId
        if backgrounded {
            if !interrupted.contains(id) { interrupted.append(id) }
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                job.interruptForBackground()
                self?.onInterrupted?([id])
            }
            return false
        }
        jobs[id] = job
        lock.unlock()
        return true
    }

    /// Removes a job that finished, failed or was cancelled (also from the re-queue list).
    func unregister(jobId: String) {
        lock.lock()
        jobs[jobId] = nil
        interrupted.removeAll { $0 == jobId }
        lock.unlock()
    }

    // MARK: Lifecycle

    func didEnterBackground() {
        lock.lock()
        backgrounded = true
        let running = Array(jobs.values)
        jobs.removeAll()
        for job in running where !interrupted.contains(job.interruptionJobId) {
            interrupted.append(job.interruptionJobId)
        }
        lock.unlock()
        guard !running.isEmpty else { return }
        running.forEach { $0.interruptForBackground() }
        let ids = running.map { $0.interruptionJobId }
        Log.info(.jobs, "background: interrupted \(ids.count) job(s)")
        onInterrupted?(ids)
    }

    func willEnterForeground() {
        lock.lock()
        backgrounded = false
        let ids = interrupted
        interrupted.removeAll()
        lock.unlock()
        guard !ids.isEmpty else { return }
        Log.info(.jobs, "foreground: re-queueing \(ids.count) job(s)")
        ids.forEach { requeue?($0) }
    }

    // MARK: Cold start

    /// Checkpoints in the direct subdirectories of [workDirectory] (`work/<kind>-<jobId>/`), newest
    /// first. The job id is the directory name after the first '-' (the whole name without one).
    static func resumableJobs(under workDirectory: URL) -> [ResumableJob] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path) else { return [] }
        var found: [ResumableJob] = []
        for name in names {
            let directory = workDirectory.appendingPathComponent(name, isDirectory: true)
            guard let checkpoint = SegmentCheckpoint.load(from: directory) else { continue }
            let jobId = name.firstIndex(of: "-").map { String(name[name.index(after: $0)...]) } ?? name
            found.append(ResumableJob(
                jobId: jobId.isEmpty ? name : jobId, directory: directory, jobKind: checkpoint.jobKind,
                inputHash: checkpoint.inputHash, doneFraction: checkpoint.doneFraction, updatedAt: checkpoint.updatedAt))
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Adapts a SegmentedWriter to JobInterruption.
final class SegmentedJobHandle: InterruptibleJob {
    let interruptionJobId: String
    private weak var writer: SegmentedWriter?

    init(jobId: String, writer: SegmentedWriter) {
        interruptionJobId = jobId
        self.writer = writer
    }

    func interruptForBackground() {
        writer?.interrupt()
    }
}
