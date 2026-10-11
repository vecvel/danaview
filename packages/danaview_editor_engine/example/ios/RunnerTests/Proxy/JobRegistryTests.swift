// OWNER: IOS-05
//
// JobRegistry (BUILD_PLAN IOS-05): priorities, concurrency, pre-emption by interactive jobs and by
// exports, cancellation (queued and running, partial outputs cleaned), progress <= 4 Hz, and the
// D-22 background semantics: didEnterBackground stops running jobs, willEnterForeground re-queues
// them, and a real proxy interrupted mid-way resumes from its last complete segment.
//
// Real-device background behaviour is deferred: no device available (D-43); the simulator never
// takes the encoder away, so the interruption is driven through JobInterruption directly.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// A job body that blocks until released or stopped.
final class FakeJobBody: MediaJobBody {
    let kind: JobKindMsg
    let name: String
    var exclusiveKey: String?
    private let lock = NSLock()
    private var released = false
    private(set) var runs = 0
    private(set) var stops: [JobStopReason] = []
    private(set) var cleanUps = 0
    /// Progress values reported in a burst at the start of each run.
    var progressBurst = 0
    static var log: [String] = []
    static let logLock = NSLock()

    init(_ name: String, kind: JobKindMsg = .waveform) {
        self.name = name
        self.kind = kind
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    var cleanUpCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanUps
    }

    var stopReasons: [JobStopReason] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func run(_ control: JobControl) throws -> JobResultMsg {
        lock.lock()
        runs += 1
        lock.unlock()
        FakeJobBody.logLock.lock()
        FakeJobBody.log.append("start \(name)")
        FakeJobBody.logLock.unlock()
        for i in 0..<progressBurst {
            control.progress(Double(i + 1) / Double(progressBurst))
            usleep(2_000)
        }
        while true {
            if let reason = control.stopReason {
                lock.lock()
                stops.append(reason)
                lock.unlock()
                try control.check()
            }
            lock.lock()
            let done = released
            lock.unlock()
            if done { break }
            usleep(2_000)
        }
        FakeJobBody.logLock.lock()
        FakeJobBody.log.append("end \(name)")
        FakeJobBody.logLock.unlock()
        return JobResultMsg(kind: kind, asset: GeneratedAssetMsg(path: "/tmp/\(name)", sizeBytes: 0))
    }

    func cleanUp() {
        lock.lock()
        cleanUps += 1
        lock.unlock()
    }
}

final class JobRegistryTests: XCTestCase {
    private var roots: TempRoots!
    private var recorder: JobEventRecorder!
    private var context: EngineContext!

    override func setUpWithError() throws {
        roots = try TempRoots()
        recorder = JobEventRecorder()
        context = try MediaJobTestSupport.context(roots, events: recorder.hub)
        FakeJobBody.logLock.lock()
        FakeJobBody.log = []
        FakeJobBody.logLock.unlock()
    }

    override func tearDown() {
        roots?.remove()
        super.tearDown()
    }

    private func registry(concurrency: Int) -> (JobRegistry, JobInterruption) {
        let interruption = JobInterruption(center: NotificationCenter())
        let registry = JobRegistry(context: context, concurrency: concurrency, interruption: interruption, startInterruption: false)
        interruption.start()
        return (registry, interruption)
    }

    private func spin(_ condition: () -> Bool) {
        XCTAssertTrue(JobEventRecorder.spin(until: condition), "condition not reached")
    }

    func testConcurrencyPerTier() {
        XCTAssertEqual(JobRegistry.concurrency(for: .minimal), 1)
        XCTAssertEqual(JobRegistry.concurrency(for: .low), 1)
        XCTAssertEqual(JobRegistry.concurrency(for: .mid), 2)
        XCTAssertEqual(JobRegistry.concurrency(for: .high), 2)
    }

    func testPrioritiesAndConcurrencyLimit() {
        let (registry, _) = registry(concurrency: 1)
        let first = FakeJobBody("first")
        let background = FakeJobBody("background")
        let normal = FakeJobBody("normal")
        let interactive = FakeJobBody("interactive")
        let firstId = registry.enqueue(first, priority: .interactive)
        spin { first.runCount == 1 }
        let bgId = registry.enqueue(background, priority: .background)
        let normalId = registry.enqueue(normal, priority: .normal)
        let interactiveId = registry.enqueue(interactive, priority: .interactive)
        XCTAssertEqual(registry.runningCount, 1)
        XCTAssertEqual(registry.state(of: bgId), .queued)
        [first, interactive, normal, background].forEach { $0.release() }
        for id in [firstId, interactiveId, normalId, bgId] { recorder.waitForEnd(id, test: self) }
        let starts = FakeJobBody.log.filter { $0.hasPrefix("start") }
        XCTAssertEqual(starts, ["start first", "start interactive", "start normal", "start background"])
        XCTAssertEqual(registry.jobCount, 0)
    }

    func testTwoJobsRunAtOnceOnMidTier() {
        let (registry, _) = registry(concurrency: 2)
        let a = FakeJobBody("a"), b = FakeJobBody("b"), c = FakeJobBody("c")
        let ids = [a, b, c].map { registry.enqueue($0, priority: .normal) }
        spin { a.runCount == 1 && b.runCount == 1 }
        XCTAssertEqual(registry.runningCount, 2)
        XCTAssertEqual(c.runCount, 0)
        [a, b, c].forEach { $0.release() }
        ids.forEach { recorder.waitForEnd($0, test: self) }
    }

    func testInteractiveJobPreemptsBackgroundJobWhichResumesLater() {
        let (registry, _) = registry(concurrency: 1)
        let background = FakeJobBody("background")
        let bgId = registry.enqueue(background, priority: .background)
        spin { background.runCount == 1 }
        let interactive = FakeJobBody("interactive")
        let interactiveId = registry.enqueue(interactive, priority: .interactive)
        spin { interactive.runCount == 1 }
        XCTAssertEqual(background.stopReasons, [.preempt])
        XCTAssertEqual(registry.state(of: bgId), .queued)
        XCTAssertFalse(recorder.ended(bgId), "a pre-empted job does not end")
        interactive.release()
        recorder.waitForEnd(interactiveId, test: self)
        spin { background.runCount == 2 }
        background.release()
        recorder.waitForEnd(bgId, test: self)
        XCTAssertNotNil(recorder.done(bgId))
        XCTAssertEqual(background.cleanUpCount, 0)
    }

    func testExportStopsAndHoldsBackgroundJobs() {
        let (registry, _) = registry(concurrency: 2)
        let background = FakeJobBody("background")
        let bgId = registry.enqueue(background, priority: .background)
        spin { background.runCount == 1 }
        registry.setExportActive("export-1", active: true)
        spin { registry.state(of: bgId) == .queued }
        XCTAssertEqual(background.stopReasons, [.preempt])
        // A normal job still runs during the export; a new background job waits.
        let normal = FakeJobBody("normal")
        let normalId = registry.enqueue(normal, priority: .normal)
        let other = FakeJobBody("other")
        let otherId = registry.enqueue(other, priority: .background)
        spin { normal.runCount == 1 }
        normal.release()
        recorder.waitForEnd(normalId, test: self)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(other.runCount, 0)
        XCTAssertEqual(background.runCount, 1)
        registry.setExportActive("export-1", active: false)
        spin { background.runCount == 2 && other.runCount == 1 }
        background.release()
        other.release()
        recorder.waitForEnd(bgId, test: self)
        recorder.waitForEnd(otherId, test: self)
    }

    func testCancelRunningAndQueuedJobsCleansUp() {
        let (registry, _) = registry(concurrency: 1)
        let running = FakeJobBody("running")
        let queued = FakeJobBody("queued")
        let runningId = registry.enqueue(running, priority: .normal)
        spin { running.runCount == 1 }
        let queuedId = registry.enqueue(queued, priority: .normal)
        registry.cancel(jobId: queuedId)
        recorder.waitForEnd(queuedId, test: self)
        XCTAssertEqual(recorder.failure(queuedId)?.code, "cancelled")
        XCTAssertEqual(queued.runCount, 0)
        XCTAssertEqual(queued.cleanUpCount, 1)
        registry.cancel(jobId: runningId)
        recorder.waitForEnd(runningId, test: self)
        XCTAssertEqual(recorder.failure(runningId)?.code, "cancelled")
        XCTAssertEqual(running.stopReasons, [.cancel])
        XCTAssertEqual(running.cleanUpCount, 1)
        XCTAssertEqual(registry.jobCount, 0)
        XCTAssertFalse(DiskCache.isActive, "activity released after cancel")
    }

    func testProgressIsThrottledTo4Hz() {
        let (registry, _) = registry(concurrency: 1)
        let body = FakeJobBody("progress")
        body.progressBurst = 400   // ~0.8 s of updates every 2 ms
        let id = registry.enqueue(body, priority: .normal)
        spin { body.runCount == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        body.release()
        recorder.waitForEnd(id, test: self)
        let times = recorder.progressTimes[id] ?? []
        XCTAssertGreaterThan(times.count, 1)
        // At most 4 per second (plus the final flush).
        let span = max(0.001, (times.last ?? 0) - (times.first ?? 0))
        XCTAssertLessThanOrEqual(Double(times.count - 1) / span, 4.5)
        let values = recorder.events.filter { $0.jobId == id }.compactMap(\.progress)
        XCTAssertEqual(values, values.sorted(), "progress never moves backwards")
    }

    func testBackgroundStopsRunningJobsAndForegroundRequeuesThem() {
        let (registry, interruption) = registry(concurrency: 1)
        let body = FakeJobBody("bg")
        let id = registry.enqueue(body, priority: .normal)
        spin { body.runCount == 1 }
        interruption.didEnterBackground()
        spin { registry.state(of: id) == .waitingForForeground }
        XCTAssertEqual(body.stopReasons, [.background])
        // Jobs started in the background wait too.
        let late = FakeJobBody("late")
        let lateId = registry.enqueue(late, priority: .interactive)
        spin { registry.state(of: lateId) == .waitingForForeground }
        XCTAssertEqual(late.runCount, 0)
        interruption.willEnterForeground()
        spin { late.runCount == 1 }
        late.release()
        recorder.waitForEnd(lateId, test: self)
        spin { body.runCount == 2 }
        body.release()
        recorder.waitForEnd(id, test: self)
        XCTAssertNotNil(recorder.done(id))
    }

    func testProxyInterruptedInTheBackgroundResumesFromItsLastSegment() throws {
        let (registry, interruption) = registry(concurrency: 1)
        let paths = try context.requirePaths()
        let proxy = ProxyJob(mediaURL: try ProbeFixtures.url("frame_counter_720p25.mp4"), fingerprint: "fp-bg",
                             paths: paths, segmentDurationUs: 2_000_000)
        let lock = NSLock()
        var backgrounded = false
        var segmentsSeen: [[Int]] = [[]]
        proxy.configureWriter = { writer in
            lock.lock()
            if !segmentsSeen.last!.isEmpty { segmentsSeen.append([]) }
            lock.unlock()
            writer.faultInjector = { segment, frame in
                lock.lock()
                if !segmentsSeen[segmentsSeen.count - 1].contains(segment) { segmentsSeen[segmentsSeen.count - 1].append(segment) }
                let fire = !backgrounded && segment == 2 && frame == 10
                if fire { backgrounded = true }
                lock.unlock()
                if fire { interruption.didEnterBackground() }
                return nil
            }
        }
        let id = registry.enqueue(proxy, priority: .background)
        spin { registry.state(of: id) == .waitingForForeground }
        let checkpoint = try XCTUnwrap(SegmentCheckpoint.load(from: proxy.workDirectory))
        XCTAssertEqual(checkpoint.completed.map(\.index), [0, 1], "finished segments kept in the background")
        interruption.willEnterForeground()
        recorder.waitForEnd(id, test: self)
        let asset = try XCTUnwrap(recorder.done(id)?.asset, "\(String(describing: recorder.failure(id)))")
        lock.lock()
        let runs = segmentsSeen
        lock.unlock()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.last?.first, 2, "resumed at the interrupted segment")
        let frames = try SegmentTestSupport.readBack(URL(fileURLWithPath: asset.path))
        XCTAssertEqual(frames.compactMap(\.index), Array(0..<200))
        let source = try MediaJobTestSupport.videoFacts(try ProbeFixtures.url("frame_counter_720p25.mp4"))
        let output = try MediaJobTestSupport.videoFacts(URL(fileURLWithPath: asset.path))
        XCTAssertEqual(output.ptsUs.count, source.ptsUs.count)
        for (a, b) in zip(output.ptsUs, source.ptsUs) { XCTAssertLessThanOrEqual(abs(a - b), 2) }
        XCTAssertEqual(ProxyRegistry.status(fingerprint: "fp-bg", paths: paths), .ready)
    }
}
