// OWNER: ENG-07
//
// Queue hops of the iOS glue (ARCH §12.6, §18.1): every host handler returns before its service
// runs, the service runs on the documented engine queue (or asynchronously on main for UIKit
// work), and the reply reaches Dart on the main thread exactly once.

import Flutter
import XCTest

@testable import vwish_editor_engine

final class GlueQueueHopTests: XCTestCase {
    private var fake: FakeServices!
    private var fixture: GlueFixture!

    override func setUpWithError() throws {
        fake = FakeServices()
        fixture = try GlueFixture(services: fake.services)
        try fixture.initialize(self)
    }

    override func tearDown() {
        fake.gate?.signal()
        fixture = nil
        fake = nil
    }

    private var glue: EngineGlue { fixture.glue }
    private var roots: TempRoots { fixture.roots }
    private var mediaURI: String { "file://" + roots.support.appendingPathComponent("media/a.mp4").path }

    /// Calls [invoke] on main with the service blocked, checks the handler returned first, then
    /// releases the service and checks queue, thread and reply.
    private func check<T>(
        _ method: String, queue expected: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ invoke: (@escaping (Result<T, Error>) -> Void) -> Void
    ) {
        let blocking = expected != "main"
        let gate = DispatchSemaphore(value: 0)
        fake.gate = blocking ? gate : nil
        let done = expectation(description: method)
        var replied = false
        var replyOnMain = false
        var result: Result<T, Error>?
        invoke { r in
            replied = true
            replyOnMain = Thread.isMainThread
            result = r
            done.fulfill()
        }
        XCTAssertFalse(replied, "\(method) replied before the handler returned", file: file, line: line)
        if blocking { gate.signal() }
        wait(for: [done], timeout: 5)
        fake.gate = nil
        XCTAssertTrue(replyOnMain, "\(method) replied off the main thread", file: file, line: line)
        if case .failure(let error)? = result {
            XCTFail("\(method) failed: \(error)", file: file, line: line)
        }
        let call = fake.calls(method).last
        XCTAssertNotNil(call, "\(method) never reached its service", file: file, line: line)
        XCTAssertEqual(call?.queue, expected, "\(method) ran on the wrong queue", file: file, line: line)
        XCTAssertEqual(call?.isMainThread, expected == "main", file: file, line: line)
    }

    /// Fire-and-forget methods: the call returns at once and the service runs later on [expected].
    private func checkPosted(
        _ method: String, queue expected: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ invoke: () throws -> Void
    ) {
        let reached = expectation(description: method)
        fake.onCall = { call in
            if call.method == method { reached.fulfill() }
        }
        XCTAssertNoThrow(try invoke(), file: file, line: line)
        wait(for: [reached], timeout: 5)
        fake.onCall = nil
        XCTAssertEqual(fake.calls(method).last?.queue, expected, "\(method) ran on the wrong queue", file: file, line: line)
    }

    func testEngineHostApiHopsToTheEngineQueue() {
        XCTAssertEqual(fake.calls("engineDidInitialize").last?.queue, "engine")
        check("capabilities", queue: "engine") { glue.engineApi.capabilities(completion: $0) }
        check("compatibility", queue: "engine") { glue.engineApi.compatibility(uri: mediaURI, completion: $0) }
        check("probe", queue: "engine") { glue.engineApi.probe(media: media(mediaURI), completion: $0) }
        checkPosted("trim", queue: "engine") { try glue.engineApi.trimCaches(level: .background) }
    }

    func testPreviewHostApiHopsToThePreviewControlQueue() {
        let api = glue.previewApi
        let lut = "file://" + roots.support.appendingPathComponent("projects/p1/assets/luts/l1.vlut").path
        let look = LookSpecMsg(id: "warm", lutUri: lut, lutSize: 33, intensity: 0.8)
        let config = PreviewConfigMsg(canvasWidth: 1920, canvasHeight: 1080, fps: 30, quality: .auto, useProxies: false)
        check("open", queue: "previewControl") { api.open(config: config, completion: $0) }
        check("setPlan", queue: "previewControl") { api.setPlan(sessionId: "s1", plan: bytes("{}"), completion: $0) }
        check("applyPatch", queue: "previewControl") { api.applyPatch(sessionId: "s1", patch: bytes("{}"), completion: $0) }
        check("play", queue: "previewControl") { api.play(sessionId: "s1", loop: LoopMsg(startUs: 0, endUs: 10), completion: $0) }
        check("pause", queue: "previewControl") { api.pause(sessionId: "s1", completion: $0) }
        check("seek", queue: "previewControl") { api.seek(sessionId: "s1", timeUs: 33_366, exact: true, completion: $0) }
        check("setQuality", queue: "previewControl") { api.setQuality(sessionId: "s1", quality: .half, completion: $0) }
        check("setUseProxies", queue: "previewControl") { api.setUseProxies(sessionId: "s1", on: true, completion: $0) }
        check("setEditingMode", queue: "previewControl") {
            api.setEditingMode(sessionId: "s1", mode: EditingModeMsg(kind: .matte, itemId: "it1"), completion: $0)
        }
        check("showSourceFrame", queue: "previewControl") {
            api.showSourceFrame(sessionId: "s1", media: media(mediaURI), sourceTimeUs: 0, completion: $0)
        }
        check("sampleColor", queue: "previewControl") { api.sampleColor(sessionId: "s1", itemId: "it1", x: 0.5, y: 0.5, completion: $0) }
        check("renderLookStills", queue: "previewControl") {
            api.renderLookStills(sessionId: "s1", itemId: "it1", looks: [look], heightPx: 120, completion: $0)
        }
        check("refresh", queue: "previewControl") { api.refresh(sessionId: "s1", completion: $0) }
        check("debugCaptureFrame", queue: "previewControl") { api.debugCaptureFrame(sessionId: "s1", completion: $0) }
        check("dispose", queue: "previewControl") { api.dispose(sessionId: "s1", completion: $0) }
        checkPosted("setTransient", queue: "previewControl") {
            try api.setTransient(sessionId: "s1", itemId: "it1", params: bytes("{\"opacity\":0.5}"))
        }
        checkPosted("clearTransient", queue: "previewControl") { try api.clearTransient(sessionId: "s1", itemId: "it1") }
    }

    func testJobsHostApiHopsToTheJobQueue() {
        let api = glue.jobsApi
        let request = ThumbnailRequestMsg(media: media(mediaURI), intervalMs: 1000, tileIndex: 0, heightPx: 64, framesPerTile: 8, proxy: false)
        check("tile", queue: "jobs") { api.thumbnailTile(requestId: "r1", request: request, priority: .visible, completion: $0) }
        check("startJob", queue: "jobs") {
            api.startJob(request: JobRequestMsg(kind: .waveform, media: media(mediaURI), priority: .normal), completion: $0)
        }
        check("proxyStatus", queue: "jobs") { api.proxyStatus(fingerprint: "fp1", completion: $0) }
        checkPosted("cancelThumbnail", queue: "jobs") { try api.cancelThumbnail(requestId: "r1") }
        checkPosted("cancelJob", queue: "jobs") { try api.cancelJob(jobId: "j1") }
        checkPosted("setJobPriority", queue: "jobs") { try api.setJobPriority(jobId: "j1", priority: .background) }
    }

    func testExportHostApiHopsToTheExportQueue() {
        let api = glue.exportApi
        let output = roots.cache.appendingPathComponent("work/export-1.mp4").path
        check("preflight", queue: "export") { api.preflight(plan: bytes("{}"), settings: encodeSettings(), completion: $0) }
        check("exportStart", queue: "export") {
            api.start(
                plan: bytes("{}"), settings: encodeSettings(), outputPath: output, title: "Trip", whenDetached: .saveToGallery,
                completion: $0)
        }
        XCTAssertEqual(fake.lastOutputURL?.path, URL(fileURLWithPath: output).standardizedFileURL.path)
        check("resume", queue: "export") { api.resume(jobId: "export-1", completion: $0) }
        check("exportCancel", queue: "export") { api.cancel(jobId: "export-1", completion: $0) }
        check("activeJobs", queue: "export") { api.activeJobs(completion: $0) }
        checkPosted("consumeJobRecord", queue: "export") { try api.consumeJobRecord(jobId: "export-1") }
    }

    func testRecorderHostApiUsesMainForPermissionsAndTheRecorderQueueForRecording() {
        let api = glue.recorderApi
        let output = roots.support.appendingPathComponent("projects/p1/assets/recordings/r1.wav").path
        check("permission", queue: "main") { api.permission(completion: $0) }
        check("requestPermission", queue: "main") { api.requestPermission(completion: $0) }
        check("openSettings", queue: "main") { api.openSettings(completion: $0) }
        check("recorderStart", queue: "recorder") { api.start(outputPath: output, completion: $0) }
        check("recorderStop", queue: "recorder") { api.stop(recordingId: "rec-1", completion: $0) }
        check("recorderCancel", queue: "recorder") { api.cancel(recordingId: "rec-1", completion: $0) }
    }

    func testPlatformHostApiUsesMainForUIKitAndIoForFiles() {
        let api = glue.platformApi
        let file = roots.cache.appendingPathComponent("work/export-1.mp4").path
        let ref = MediaRefMsg(uri: mediaURI)
        check("pick", queue: "main") {
            api.pick(request: MediaPickRequestMsg(source: .photos, kinds: [.video, .image], multiple: true), completion: $0)
        }
        check("saveToPhotos", queue: "io") { api.saveToPhotos(path: file, completion: $0) }
        check("saveToFiles", queue: "main") { api.saveToFiles(path: file, suggestedName: "Trip.mp4", completion: $0) }
        check("share", queue: "main") { api.share(path: file, completion: $0) }
        check("createBookmark", queue: "io") { api.createBookmark(uri: mediaURI, completion: $0) }
        check("resolveBookmark", queue: "io") { api.resolveBookmark(bookmark: FlutterStandardTypedData(bytes: Data([1])), completion: $0) }
        check("persistUriGrant", queue: "io") { api.persistUriGrant(uri: mediaURI, completion: $0) }
        check("releaseUriGrant", queue: "io") { api.releaseUriGrant(uri: mediaURI, completion: $0) }
        check("remainingGrantBudget", queue: "io") { api.remainingGrantBudget(completion: $0) }
        check("stat", queue: "io") { api.stat(media: ref, completion: $0) }
        check("quickHash", queue: "io") { api.quickHash(media: ref, completion: $0) }
        check("excludeFromBackup", queue: "io") { api.excludeFromBackup(path: roots.support.appendingPathComponent("media").path, completion: $0) }
        check("requestNotificationPermission", queue: "main") { api.requestNotificationPermission(completion: $0) }
        check("acquireBackground", queue: "main") { api.acquireBackground(title: "Exporting", completion: $0) }
        check("updateBackground", queue: "main") { api.updateBackground(leaseId: "lease-1", progress: 0.5, completion: $0) }
        check("releaseBackground", queue: "main") { api.releaseBackground(leaseId: "lease-1", completion: $0) }
        check("setDropTargetEnabled", queue: "main") { api.setDropTargetEnabled(enabled: true, completion: $0) }
    }

    func testFreeBytesIsAnsweredByTheEngineCore() {
        let done = expectation(description: "freeBytes")
        var value: Int64 = 0
        glue.engineApi.freeBytes(path: roots.cache.appendingPathComponent("work/not-yet.mp4").path) {
            value = (try? $0.get()) ?? -1
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThan(value, 0)
    }

    func testInitializeIsIdempotent() throws {
        try fixture.initialize(self)
        // Same roots again (Dart hot restart): no second launch maintenance.
        XCTAssertEqual(fake.calls("engineDidInitialize").count, 1)
    }

    func testServiceReplyIsDeliveredOnlyOnce() {
        let done = expectation(description: "once")
        done.expectedFulfillmentCount = 1
        done.assertForOverFulfill = true
        var count = 0
        let reply: EngineReply<Int> = GlueDispatch.once("test.once") { _ in
            count += 1
            done.fulfill()
        }
        DispatchQueue.global().async {
            reply(.success(1))
            reply(.success(2))
            reply(.failure(EngineError.cancelled))
        }
        wait(for: [done], timeout: 5)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(count, 1)
    }
}
