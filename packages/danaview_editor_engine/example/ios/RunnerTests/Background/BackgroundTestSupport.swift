// OWNER: IOS-13
//
// Fakes of the IOS-13 tests: a continued-processing scheduler and task, a Photos library, a
// detached gallery saver, and a coordinator harness whose lifecycle hook is an ActiveExportStore
// over the harness roots.

import Photos
import XCTest

@testable import danaview_editor_engine

final class FakeContinuedTask: ContinuedTaskHandle {
    private let lock = NSLock()
    var expirationHandler: (() -> Void)?
    private(set) var progress: [(Int64, Int64)] = []
    private(set) var subtitles: [String] = []
    private(set) var completions: [Bool] = []

    func setProgress(completed: Int64, total: Int64) {
        lock.lock()
        progress.append((completed, total))
        lock.unlock()
    }

    func updateSubtitle(title: String, subtitle: String) {
        lock.lock()
        subtitles.append(subtitle)
        lock.unlock()
    }

    func complete(success: Bool) {
        lock.lock()
        completions.append(success)
        lock.unlock()
    }

    var lastProgress: (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        return progress.last
    }

    var completed: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return completions
    }
}

final class FakeContinuedScheduler: ContinuedTaskScheduling {
    struct Submission {
        var identifier: String
        var title: String
        var subtitle: String
        var launch: (ContinuedTaskHandle) -> Void
    }

    var refuse = false
    private(set) var submissions: [Submission] = []
    private(set) var cancelled: [String] = []

    func submit(identifier: String, title: String, subtitle: String, launch: @escaping (ContinuedTaskHandle) -> Void) throws {
        if refuse { throw NSError(domain: "BGTaskSchedulerErrorDomain", code: 1) }
        submissions.append(Submission(identifier: identifier, title: title, subtitle: subtitle, launch: launch))
    }

    func cancel(identifier: String) {
        cancelled.append(identifier)
    }

    /// The system launches the task of [identifier].
    @discardableResult
    func launch(_ identifier: String) -> FakeContinuedTask {
        let task = FakeContinuedTask()
        submissions.first { $0.identifier == identifier }?.launch(task)
        return task
    }
}

final class FakePhotoLibrary: PhotoLibraryAdding {
    var status: PHAuthorizationStatus
    var answer: PHAuthorizationStatus = .authorized
    var failure: Error?
    private(set) var requests = 0
    private(set) var added: [URL] = []

    init(status: PHAuthorizationStatus) {
        self.status = status
    }

    func addOnlyStatus() -> PHAuthorizationStatus { status }

    func requestAddOnly(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
        requests += 1
        status = answer
        DispatchQueue.global().async { completion(self.answer) }
    }

    func addVideo(_ fileURL: URL, completion: @escaping (Result<String?, Error>) -> Void) {
        if let failure = failure { return DispatchQueue.global().async { completion(.failure(failure)) } }
        added.append(fileURL)
        DispatchQueue.global().async { completion(.success("FAKE-ASSET-\(self.added.count)/L0/001")) }
    }
}

/// An ActiveExportStore over [harness]'s roots, wired into its coordinator.
enum BackgroundTestSupport {
    @discardableResult
    static func installStore(
        _ h: ExportHarness, library: FakePhotoLibrary = FakePhotoLibrary(status: .authorized),
        background: BackgroundExecution = BackgroundExecution(kind: .paused, scheduler: nil),
        now: @escaping () -> Date = Date.init
    ) -> ActiveExportStore {
        let store = makeStore(h.context, library: library, background: background, now: now)
        h.onExportQueue { h.coordinator.lifecycle = store }
        return store
    }

    static func makeStore(
        _ context: EngineContext, library: FakePhotoLibrary = FakePhotoLibrary(status: .authorized),
        background: BackgroundExecution = BackgroundExecution(kind: .paused, scheduler: nil), now: @escaping () -> Date = Date.init
    ) -> ActiveExportStore {
        ActiveExportStore(
            context: context, paths: { [weak context] in context?.paths },
            gallery: PhotosSaver(context: context, library: library), background: background, now: now)
    }

    /// Fails the writer of segment [segment] at frame [frame] once with AVFoundation −11847
    /// (the encoder loss a backgrounded iPhone sees); [before] runs on the pump queue first.
    static func injectWriterLoss(_ h: ExportHarness, segment: Int, frame: Int, before: (() -> Void)? = nil) -> () -> Int {
        let lock = NSLock()
        var fired = 0
        h.coordinator.configurePipeline = { pipeline in
            pipeline.configureWriter = { writer in
                writer.faultInjector = { s, f in
                    lock.lock()
                    defer { lock.unlock() }
                    guard fired == 0, s == segment, f == frame else { return nil }
                    fired += 1
                    before?()
                    return MediaJobTestSupport.interruptionError()
                }
            }
        }
        return {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }
}
