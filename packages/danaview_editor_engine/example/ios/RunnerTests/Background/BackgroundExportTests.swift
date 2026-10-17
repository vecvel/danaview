// OWNER: IOS-13
//
// IOS-13 acceptance on the simulator (BUILD_PLAN IOS-13, D-22, D-39, ARCH §14.2):
// - background kind per device (iPhone paused, iPad iOS 26+ with the GPU resource continued) and
//   the continued-processing task (identifier, strategy inputs, progress, expiration, end) with a
//   fake scheduler; the real iPad run is deferred: no device available;
// - checkpoint/resume with an injected writer failure (AVFoundation −11847), since the simulator
//   does not reproduce the encoder loss: in the foreground the job continues from the last
//   complete segment; in the background it pauses (pausedInBackground) and resumes on return; the
//   result passes conformance with continuous barcodes. The real-iPhone runs on iOS 18 and 26 are
//   deferred: no device available;
// - ActiveExportStore: resumable after a kill, one-shot interrupted when the job directory is gone,
//   completedWhileDetached reported until consumed and never again (native Photos save when
//   saveToGallery and add-only access is authorized; output exempt from the wipe for 7 days, then
//   dropped), the temp output left for Dart's OwnedFileDeleter.

import AVFoundation
import Photos
import XCTest

@testable import danaview_editor_engine

final class BackgroundExportTests: XCTestCase {
    private var harnesses: [ExportHarness] = []

    override func tearDown() {
        harnesses.forEach { $0.remove() }
        harnesses = []
    }

    private func make(_ options: ExportHarness.Options = ExportHarness.Options(), roots: TempRoots? = nil) throws -> ExportHarness {
        let h = try ExportHarness(options, roots: roots)
        harnesses.append(h)
        return h
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func barcodes(_ url: URL) throws -> [Int?] {
        var codes: [Int?] = []
        try ExportConformance.frames(url) { _, pb in codes.append(CompositorTestSupport.barcode(pb)) }
        return codes
    }

    // MARK: Background kind and continued task

    func testBackgroundKindPerDevice() {
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .phone, iOS26: true, gpuResource: true), .paused)
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .phone, iOS26: false, gpuResource: false), .paused)
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .pad, iOS26: false, gpuResource: true), .paused)
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .pad, iOS26: true, gpuResource: false), .paused)
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .pad, iOS26: true, gpuResource: true), .continued)
        XCTAssertEqual(BackgroundExecution.decideKind(idiom: .other, iOS26: true, gpuResource: true), .paused)
        // The simulator reports no .gpu resource (IOS-01): paused, the same answer as Capabilities.
        let profile = DeviceProfile.current(hasMetal: true)
        let capabilities = Capabilities.compute(
            profile: profile, encoders: Capabilities.encoderSupport(profile: profile),
            backgroundGpu: Capabilities.backgroundGpuAvailable(profile: profile))
        XCTAssertEqual(BackgroundExecution.currentKind(), .paused)
        XCTAssertEqual(capabilities.backgroundKind, BackgroundExecution.currentKind())
        XCTAssertEqual(BackgroundExecution.taskIdentifier(jobId: "ex_abc"), "com.vecvel.danaview.export.ex_abc")
        XCTAssertTrue(BackgroundExecution.taskIdentifier(jobId: "x").hasPrefix(
            String(Capabilities.exportTaskIdentifierPattern.dropLast())))
    }

    func testPausedKindSubmitsNoContinuedTask() {
        let scheduler = FakeContinuedScheduler()
        let background = BackgroundExecution(kind: .paused, scheduler: scheduler)
        XCTAssertFalse(background.begin(jobId: "ex_1", title: "Video", progress: { 0.5 }, onExpired: { _ in }))
        XCTAssertTrue(scheduler.submissions.isEmpty)
        background.end(jobId: "ex_1", success: true)
        XCTAssertTrue(scheduler.cancelled.isEmpty)
    }

    func testContinuedTaskReportsProgressAndCompletes() {
        let scheduler = FakeContinuedScheduler()
        let background = BackgroundExecution(kind: .continued, scheduler: scheduler, progressInterval: 0.02)
        let lock = NSLock()
        var fraction = 0.0
        XCTAssertTrue(background.begin(jobId: "ex_2", title: "Holiday", progress: {
            lock.lock()
            defer { lock.unlock() }
            return fraction
        }, onExpired: { _ in XCTFail("not expired") }))
        XCTAssertEqual(scheduler.submissions.map(\.identifier), ["com.vecvel.danaview.export.ex_2"])
        XCTAssertEqual(scheduler.submissions.first?.title, "Holiday")
        XCTAssertFalse(scheduler.submissions.first?.subtitle.isEmpty ?? true)
        // Submitting twice for the same job is a no-op.
        XCTAssertTrue(background.begin(jobId: "ex_2", title: "Holiday", progress: { 0 }, onExpired: { _ in }))
        XCTAssertEqual(scheduler.submissions.count, 1)

        let task = scheduler.launch("com.vecvel.danaview.export.ex_2")
        XCTAssertNotNil(task.expirationHandler)
        XCTAssertEqual(task.lastProgress?.0, 0)
        XCTAssertEqual(task.lastProgress?.1, BackgroundExecution.progressUnits)
        lock.lock()
        fraction = 0.42
        lock.unlock()
        XCTAssertTrue(spin(until: { task.lastProgress?.0 == 420 }, timeout: 5), "progress reported to the system")
        background.end(jobId: "ex_2", success: true)
        XCTAssertEqual(task.completed, [true])
        XCTAssertEqual(task.lastProgress?.0, BackgroundExecution.progressUnits)
        XCTAssertTrue(background.activeJobIds.isEmpty)
        background.end(jobId: "ex_2", success: true)
        XCTAssertEqual(task.completed, [true], "end is idempotent")
    }

    func testContinuedTaskExpirationIsTheCheckpointInterruption() {
        let scheduler = FakeContinuedScheduler()
        let background = BackgroundExecution(kind: .continued, scheduler: scheduler, progressInterval: 0.05)
        var expired: [String] = []
        background.begin(jobId: "ex_3", title: "t", progress: { 0.1 }, onExpired: { expired.append($0) })
        let task = scheduler.launch("com.vecvel.danaview.export.ex_3")
        task.expirationHandler?()
        XCTAssertEqual(expired, ["ex_3"])
        XCTAssertEqual(task.completed, [false])
        background.end(jobId: "ex_3", success: true)
        XCTAssertEqual(task.completed, [false], "an expired task is not completed again")
    }

    func testContinuedTaskEndedBeforeLaunchIsWithdrawnAndRefusalFallsBackToPaused() {
        let scheduler = FakeContinuedScheduler()
        let background = BackgroundExecution(kind: .continued, scheduler: scheduler)
        background.begin(jobId: "ex_4", title: "t", progress: { 0 }, onExpired: { _ in })
        background.end(jobId: "ex_4", success: false)
        XCTAssertEqual(scheduler.cancelled, ["com.vecvel.danaview.export.ex_4"])
        let late = scheduler.launch("com.vecvel.danaview.export.ex_4")
        XCTAssertEqual(late.completed, [false], "a late launch is completed at once")

        scheduler.refuse = true
        XCTAssertFalse(background.begin(jobId: "ex_5", title: "t", progress: { 0 }, onExpired: { _ in }))
        XCTAssertTrue(background.activeJobIds.isEmpty)
    }

    func testStoreBeginsContinuedTaskWithCheckpointProgress() throws {
        let h = try make(ExportHarness.Options(segmentDurationUs: 500_000))
        let scheduler = FakeContinuedScheduler()
        let background = BackgroundExecution(kind: .continued, scheduler: scheduler, progressInterval: 0.05)
        BackgroundTestSupport.installStore(h, background: background)
        let id = try h.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 2_000_000),
                             settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
        XCTAssertEqual(scheduler.submissions.map(\.identifier), [BackgroundExecution.taskIdentifier(jobId: id)])
        XCTAssertEqual(scheduler.submissions.first?.title, "Test")
        let task = scheduler.launch(BackgroundExecution.taskIdentifier(jobId: id))
        h.recorder.waitForEnd(id, test: self)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(task.completed, [true])
        XCTAssertEqual(task.lastProgress?.0, BackgroundExecution.progressUnits)
    }

    // MARK: Checkpoint and resume (injected writer failure)

    func testForegroundWriterLossContinuesFromTheLastCompleteSegment() throws {
        let h = try make(ExportHarness.Options(segmentDurationUs: 500_000))
        BackgroundTestSupport.installStore(h)
        let lock = NSLock()
        var resumedFrom: [Int] = []
        let fired = BackgroundTestSupport.injectWriterLoss(h, segment: 3, frame: 4)
        let inject = h.coordinator.configurePipeline
        h.coordinator.configurePipeline = { pipeline in
            inject?(pipeline)
            let configure = pipeline.configureWriter
            pipeline.configureWriter = { writer in
                configure?(writer)
                lock.lock()
                resumedFrom.append(writer.checkpoint.nextSegment)
                lock.unlock()
            }
        }
        let durUs: Int64 = 3_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30)
        let output = h.outputURL()
        let id = try h.start(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                             settings: settings, output: output)
        h.recorder.waitForEnd(id, test: self, timeout: 180)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(fired(), 1, "the −11847 loss was injected")
        lock.lock()
        let starts = resumedFrom
        lock.unlock()
        XCTAssertEqual(starts, [0, 3], "the second run starts at the segment the loss hit")
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(facts.frames, 90)
        for (k, code) in try barcodes(output).enumerated() where code != nil { XCTAssertEqual(code, k, "continuous barcodes") }
        XCTAssertTrue(BackgroundTestSupport.makeStore(h.context).entries.isEmpty, "no record left with a listener attached")
    }

    func testBackgroundWriterLossPausesAndResumesOnReturn() throws {
        let h = try make(ExportHarness.Options(segmentDurationUs: 500_000))
        BackgroundTestSupport.installStore(h)
        let fired = BackgroundTestSupport.injectWriterLoss(h, segment: 2, frame: 5) { [interruption = h.interruption] in
            // The app went to the background and the encoder was taken away.
            DispatchQueue.main.async { interruption.didEnterBackground() }
        }
        let durUs: Int64 = 3_000_000
        let settings = ExportPlans.settings(640, 360, fps: 30)
        let output = h.outputURL()
        let id = try h.start(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: durUs, withAudio: true),
                             settings: settings, output: output)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { h.onExportQueue { h.coordinator.isWaitingForForeground(id) } },
                      "paused in the background")
        XCTAssertEqual(fired(), 1)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) { h.progress(id).last?.pausedInBackground == true })
        let directory = ExportJob.directory(for: id, work: h.paths.work)
        XCTAssertGreaterThanOrEqual(SegmentCheckpoint.load(from: directory)?.completed.count ?? 0, 2, "checkpoint kept")
        XCTAssertFalse(h.recorder.ended(id))
        // > 30 s in the background on a device; here the return comes at once.
        h.interruption.willEnterForeground()
        h.recorder.waitForEnd(id, test: self, timeout: 180)
        XCTAssertNil(h.recorder.failure(id))
        XCTAssertEqual(h.progress(id).last?.pausedInBackground, false)
        let facts = try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertEqual(facts.frames, 90)
        for (k, code) in try barcodes(output).enumerated() where code != nil { XCTAssertEqual(code, k, "continuous barcodes after resume") }
    }

    // MARK: ActiveExportStore records

    func testResumableAfterKillThenResumedClearsTheRecord() throws {
        let roots = try TempRoots()
        let first = try make(ExportHarness.Options(segmentDurationUs: 500_000), roots: roots)
        BackgroundTestSupport.installStore(first)
        let durUs: Int64 = 2_000_000
        // 30 fps: 0.5 s segments hold whole frames (see the IOS-17 defect for fractional ones).
        let settings = ExportPlans.settings(320, 180, fps: 30)
        let output = first.outputURL()
        let id = try first.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 30, durUs: durUs),
                                 settings: settings, output: output)
        let directory = ExportJob.directory(for: id, work: first.paths.work)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 60) { (SegmentCheckpoint.load(from: directory)?.completed.count ?? 0) >= 1 })
        first.interruption.didEnterBackground()
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { first.onExportQueue { first.coordinator.isWaitingForForeground(id) } })

        // Relaunch: the launch wipe keeps the checkpoint; the store and the coordinator agree.
        let second = try make(ExportHarness.Options(segmentDurationUs: 500_000), roots: roots)
        let store = BackgroundTestSupport.installStore(second)
        let own = try XCTUnwrap(store.records().first { $0.jobId == id })
        XCTAssertEqual(own.state, .resumable)
        XCTAssertGreaterThan(own.doneFraction ?? 0, 0)
        XCTAssertEqual(own.settings?.width, 320)
        let reported = try second.activeJobs(self).filter { $0.jobId == id }
        XCTAssertEqual(reported.count, 1, "deduplicated")
        XCTAssertEqual(reported.first?.state, .resumable)
        let resumed: String = try second.call(self) { second.coordinator.resume(jobId: id, reply: $0) }
        XCTAssertEqual(resumed, id)
        second.recorder.waitForEnd(id, test: self, timeout: 120)
        XCTAssertNil(second.recorder.failure(id))
        try ExportConformance.check(output, settings: settings, durUs: durUs, brand: "mp42", codec: "avc1", checkBitrate: false)
        XCTAssertTrue(store.entries.isEmpty, "the record ends with the job")
        XCTAssertFalse(try second.activeJobs(self).contains { $0.jobId == id })
    }

    func testInterruptedAfterKillWithoutJobDirectoryIsReportedUntilConsumed() throws {
        let h = try make()
        let store = BackgroundTestSupport.makeStore(h.context)
        // A process killed right after start: the store's entry survives, the job directory does not.
        store.exportStarted(jobId: "ex_gone00000001", settings: ExportPlans.settings(320, 180, fps: 25), title: "t",
                            whenDetached: .saveToGallery)
        DiskCache.wipeWork(paths: h.paths)
        let relaunched = BackgroundTestSupport.installStore(h)
        let records = try h.activeJobs(self).filter { $0.jobId == "ex_gone00000001" }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .interrupted)
        XCTAssertEqual(records.first?.doneFraction, 0)
        XCTAssertEqual(records.first?.settings?.height, 180)
        h.coordinator.consumeJobRecord(jobId: "ex_gone00000001")
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == "ex_gone00000001" }, "one-shot")
        XCTAssertTrue(relaunched.entries.isEmpty)
    }

    func testCompletedWhileDetachedSavedToPhotosNativelyAndReportedOnce() throws {
        let h = try make(ExportHarness.Options(listenerAttached: false))
        let library = FakePhotoLibrary(status: .authorized)
        BackgroundTestSupport.installStore(h, library: library)
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                              settings: ExportPlans.settings(320, 180, fps: 25), output: output, timeout: 120)
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertFalse(exists(ExportJob.directory(for: id, work: h.paths.work)), "the store took the record over")
        XCTAssertTrue(JobEventRecorder.spin(timeout: 10) {
            (try? h.activeJobs(self).first { $0.jobId == id }?.savedToGallery) == true
        }, "saved to Photos natively")
        XCTAssertEqual(library.added, [output])
        XCTAssertEqual(library.requests, 0, "never prompts while detached")

        // Relaunch: the record and the output survive the wipe.
        DiskCache.wipeWork(paths: h.paths)
        XCTAssertTrue(exists(output))
        BackgroundTestSupport.installStore(h, library: library)
        let records = try h.activeJobs(self).filter { $0.jobId == id }
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.state, .completedWhileDetached)
        XCTAssertEqual(record.result?.path, output.path)
        XCTAssertEqual(record.result?.bytes, SegmentedWriter.fileSize(output))
        XCTAssertTrue(record.savedToGallery)
        XCTAssertEqual(record.savedUri, "FAKE-ASSET-1/L0/001")
        XCTAssertEqual(record.settings?.width, 320)

        h.coordinator.consumeJobRecord(jobId: id)
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == id })
        BackgroundTestSupport.installStore(h, library: library)
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == id }, "never reported again")
        XCTAssertTrue(exists(output), "the temp file is left for Dart's OwnedFileDeleter")
        DiskCache.wipeWork(paths: h.paths)
        XCTAssertFalse(exists(output), "the wipe exemption ended with the record")
    }

    /// The native save into the real Photos library (needs `simctl privacy grant photos-add`).
    func testCompletedWhileDetachedRealPhotosSaveWhenGranted() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("add-only Photos access not granted on this simulator")
        }
        let h = try make(ExportHarness.Options(listenerAttached: false))
        let store = ActiveExportStore(
            context: h.context, paths: { [context = h.context] in context.paths },
            gallery: PhotosSaver(context: h.context), background: BackgroundExecution(kind: .paused, scheduler: nil))
        h.onExportQueue { h.coordinator.lifecycle = store }
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.toneVideo(w: 640, h: 360, fps: 30, durUs: 1_000_000, withAudio: true),
                              settings: ExportPlans.settings(640, 360, fps: 30), output: output, timeout: 120)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { store.records().first { $0.jobId == id }?.savedToGallery == true },
                      "saved to Photos while detached")
        XCTAssertNotNil(store.records().first?.savedUri)
        XCTAssertTrue(exists(output))
    }

    func testCompletedWhileDetachedWithoutPhotosAccessOrKeepForLaterIsNotSaved() throws {
        let h = try make(ExportHarness.Options(listenerAttached: false))
        let library = FakePhotoLibrary(status: .notDetermined)
        BackgroundTestSupport.installStore(h, library: library)
        let first = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                                 settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL(), timeout: 120)
        let denied = try XCTUnwrap(try h.activeJobs(self).first { $0.jobId == first })
        XCTAssertEqual(denied.state, .completedWhileDetached)
        XCTAssertFalse(denied.savedToGallery)
        XCTAssertEqual(library.requests, 0)
        XCTAssertTrue(library.added.isEmpty)

        library.status = .authorized
        let output = h.outputURL()
        let id = try h.call(self) {
            h.coordinator.start(plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                                settings: ExportPlans.settings(320, 180, fps: 25), outputURL: output, title: "t",
                                whenDetached: .keepForLater, reply: $0)
        } as String
        h.recorder.waitForEnd(id, test: self)
        let kept = try XCTUnwrap(try h.activeJobs(self).first { $0.jobId == id })
        XCTAssertEqual(kept.state, .completedWhileDetached)
        XCTAssertFalse(kept.savedToGallery)
        XCTAssertTrue(library.added.isEmpty, "keepForLater never saves")
    }

    func testListenerAttachedLeavesNoRecordAndFailureClearsIt() throws {
        let h = try make()
        let store = BackgroundTestSupport.installStore(h)
        let output = h.outputURL()
        let id = try h.export(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 1_000_000),
                              settings: ExportPlans.settings(320, 180, fps: 25), output: output)
        XCTAssertNotNil(h.recorder.done(id))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(try h.activeJobs(self).contains { $0.jobId == id })
        XCTAssertTrue(exists(output), "the output is Dart's to hand off and delete")

        let cancelled = try h.start(self, plan: ExportPlans.noAudioVideo(w: 320, h: 180, fps: 25, durUs: 4_000_000),
                                    settings: ExportPlans.settings(320, 180, fps: 25), output: h.outputURL())
        XCTAssertEqual(store.entries.map(\.jobId), [cancelled])
        try h.cancel(self, cancelled)
        h.recorder.waitForEnd(cancelled, test: self)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDetachedRecordExpiresAfterSevenDays() throws {
        let h = try make()
        var clock = Date()
        let store = BackgroundTestSupport.makeStore(h.context, library: FakePhotoLibrary(status: .denied), now: { clock })
        let output = h.paths.work.appendingPathComponent("export-ex_old.mp4")
        try h.paths.ensureDirectory(h.paths.work)
        try Data([1, 2, 3]).write(to: output)
        store.exportStarted(jobId: "ex_old", settings: ExportPlans.settings(320, 180, fps: 25), title: "t", whenDetached: .saveToGallery)
        XCTAssertTrue(store.exportCompleted(
            jobId: "ex_old",
            result: ExportResultMsg(path: output.path, bytes: 3, durationUs: 1_000_000, videoEncoderName: "e", hardwareEncoder: false),
            listenerAttached: false, whenDetached: .saveToGallery))
        XCTAssertEqual(store.records().map(\.state), [.completedWhileDetached])
        DiskCache.wipeWork(paths: h.paths, now: clock.addingTimeInterval(6 * 24 * 3600))
        XCTAssertTrue(exists(output), "exempt for 7 days")
        clock = clock.addingTimeInterval(7 * 24 * 3600 + 1)
        XCTAssertTrue(store.records().isEmpty, "dropped after 7 days")
        DiskCache.wipeWork(paths: h.paths, now: clock)
        XCTAssertFalse(exists(output))
    }

    func testCoordinatorDiscoversTheStore() throws {
        let h = try make()
        XCTAssertTrue(ExportCoordinator.discoverLifecycle(context: h.context) is ActiveExportStore)
        XCTAssertTrue(ExportCoordinator(context: h.context, environment: .production(context: h.context),
                                        interruption: JobInterruption(center: NotificationCenter()), startInterruption: false)
            .lifecycle is ActiveExportStore)
    }
}
