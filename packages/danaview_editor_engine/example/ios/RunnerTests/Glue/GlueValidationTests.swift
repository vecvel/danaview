// OWNER: ENG-07
//
// Argument validation of the iOS glue (ARCH §12.6, §20.1, D-44): contract violations fail with
// `internal` before any service runs, empty plans with `planInvalid`, writes and backup exclusions
// outside the editor roots with `permissionDenied`; no error message repeats a path.

import Flutter
import XCTest

@testable import danaview_editor_engine

final class GlueValidationTests: XCTestCase {
    private var fake: FakeServices!
    private var fixture: GlueFixture!

    override func setUpWithError() throws {
        fake = FakeServices()
        fixture = try GlueFixture(services: fake.services)
        try fixture.initialize(self)
    }

    override func tearDown() {
        fixture = nil
        fake = nil
    }

    private var glue: EngineGlue { fixture.glue }
    private var roots: TempRoots { fixture.roots }

    /// Runs [invoke] and returns its reply.
    private func reply<T>(_ invoke: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
        let done = expectation(description: "reply")
        var result: Result<T, Error>?
        invoke {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    private func assertRefused<T>(
        _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ invoke: (@escaping (Result<T, Error>) -> Void) -> Void
    ) {
        let before = fake.calls.count
        let error = pigeonError(reply(invoke), file: file, line: line)
        XCTAssertEqual(error?.code, code, file: file, line: line)
        XCTAssertEqual(retryable(error), false, file: file, line: line)
        XCTAssertFalse((error?.message ?? "").contains(roots.base.path), "message leaks a path", file: file, line: line)
        XCTAssertFalse((error?.message ?? "").contains("/private/"), "message leaks a path", file: file, line: line)
        XCTAssertEqual(fake.calls.count, before, "a refused call reached its service", file: file, line: line)
    }

    func testMediaUrisMustBeFileUrisOrAbsolutePaths() {
        assertRefused("internal") { glue.engineApi.compatibility(uri: "relative/a.mp4", completion: $0) }
        assertRefused("internal") { glue.engineApi.compatibility(uri: "content://media/1", completion: $0) }
        assertRefused("internal") { glue.engineApi.compatibility(uri: "", completion: $0) }
        assertRefused("internal") { glue.engineApi.probe(media: media("/a/../b.mp4"), completion: $0) }
        assertRefused("internal") { glue.engineApi.probe(media: media("/a/b.mp4", fingerprint: ""), completion: $0) }
        assertRefused("internal") { glue.engineApi.freeBytes(path: "tmp", completion: $0) }
    }

    func testFileUriIsConvertedToAStandardizedURL() {
        let path = roots.support.appendingPathComponent("media/./a b.mp4").path
        let uri = URL(fileURLWithPath: path).absoluteString
        _ = reply { glue.engineApi.compatibility(uri: uri, completion: $0) }
        XCTAssertEqual(fake.lastURL?.path, roots.support.appendingPathComponent("media/a b.mp4").path)
    }

    func testIdsAreChecked() {
        assertRefused("internal") { glue.previewApi.pause(sessionId: "", completion: $0) }
        assertRefused("internal") { glue.previewApi.pause(sessionId: "../s1", completion: $0) }
        assertRefused("internal") { glue.previewApi.pause(sessionId: String(repeating: "x", count: 300), completion: $0) }
        assertRefused("internal") { glue.exportApi.resume(jobId: "a\nb", completion: $0) }
        assertRefused("internal") { glue.recorderApi.stop(recordingId: "..", completion: $0) }
    }

    func testPreviewArgumentsAreChecked() {
        let api = glue.previewApi
        assertRefused("internal") {
            api.open(config: PreviewConfigMsg(canvasWidth: 0, canvasHeight: 1080, fps: 30, quality: .auto, useProxies: false), completion: $0)
        }
        assertRefused("internal") {
            api.open(config: PreviewConfigMsg(canvasWidth: 1920, canvasHeight: 1080, fps: 0, quality: .auto, useProxies: false), completion: $0)
        }
        assertRefused("planInvalid") { api.setPlan(sessionId: "s1", plan: FlutterStandardTypedData(bytes: Data()), completion: $0) }
        assertRefused("planInvalid") { api.applyPatch(sessionId: "s1", patch: FlutterStandardTypedData(bytes: Data()), completion: $0) }
        assertRefused("internal") { api.seek(sessionId: "s1", timeUs: -1, exact: true, completion: $0) }
        assertRefused("internal") { api.play(sessionId: "s1", loop: LoopMsg(startUs: 10, endUs: 10), completion: $0) }
        assertRefused("internal") { api.sampleColor(sessionId: "s1", itemId: "it1", x: 1.5, y: 0, completion: $0) }
        assertRefused("internal") { api.sampleColor(sessionId: "s1", itemId: "it1", x: .nan, y: 0, completion: $0) }
        assertRefused("internal") { api.setEditingMode(sessionId: "s1", mode: EditingModeMsg(kind: .cropSource), completion: $0) }
        assertRefused("internal") { api.renderLookStills(sessionId: "s1", itemId: "it1", looks: [], heightPx: 120, completion: $0) }
        let outside = LookSpecMsg(id: "warm", lutUri: "file:///etc/l.vlut", lutSize: 33, intensity: 1)
        assertRefused("permissionDenied") { api.renderLookStills(sessionId: "s1", itemId: "it1", looks: [outside], heightPx: 120, completion: $0) }
        let badSize = LookSpecMsg(
            id: "warm", lutUri: "file://" + roots.support.appendingPathComponent("l.vlut").path, lutSize: 129, intensity: 1)
        assertRefused("internal") { api.renderLookStills(sessionId: "s1", itemId: "it1", looks: [badSize], heightPx: 120, completion: $0) }
    }

    func testSynchronousMethodsThrowValidationErrors() {
        XCTAssertThrowsError(try glue.previewApi.setTransient(sessionId: "", itemId: "it1", params: bytes("{}"))) { error in
            XCTAssertEqual((error as? EnginePigeonError)?.code, "internal")
        }
        XCTAssertThrowsError(try glue.previewApi.setTransient(sessionId: "s1", itemId: "it1", params: FlutterStandardTypedData(bytes: Data())))
        XCTAssertThrowsError(try glue.jobsApi.cancelJob(jobId: "a/b"))
        XCTAssertThrowsError(try glue.exportApi.consumeJobRecord(jobId: ""))
        XCTAssertThrowsError(try glue.jobsApi.cancelThumbnail(requestId: ""))
    }

    func testJobRequestsAreCheckedPerKind() {
        let api = glue.jobsApi
        let source = media("file://" + roots.support.appendingPathComponent("media/a.mp4").path)
        let derived = roots.support.appendingPathComponent("derived/r.mp4").path
        assertRefused("internal") {
            api.startJob(request: JobRequestMsg(kind: .reverse, media: source, priority: .normal, outputPath: derived), completion: $0)
        }
        assertRefused("internal") {
            api.startJob(
                request: JobRequestMsg(kind: .reverse, media: source, priority: .normal, sourceStartUs: 5, sourceEndUs: 5, outputPath: derived),
                completion: $0)
        }
        assertRefused("internal") {
            api.startJob(request: JobRequestMsg(kind: .freeze, media: source, priority: .normal, outputPath: derived), completion: $0)
        }
        assertRefused("internal") {
            api.startJob(request: JobRequestMsg(kind: .export, media: source, priority: .normal), completion: $0)
        }
        assertRefused("permissionDenied") {
            api.startJob(
                request: JobRequestMsg(kind: .freeze, media: source, priority: .normal, sourceTimeUs: 0, outputPath: "/tmp/still.png"),
                completion: $0)
        }
        // A valid reverse request passes the validated output URL to the registry.
        let ok = reply {
            api.startJob(
                request: JobRequestMsg(kind: .reverse, media: source, priority: .normal, sourceStartUs: 0, sourceEndUs: 1_000_000, outputPath: derived),
                completion: $0)
        }
        XCTAssertEqual(try ok?.get(), "job-1")
        XCTAssertEqual(fake.lastOutputURL?.path, derived)
        // Speech audio may write below the speech root (sibling of the editor support root).
        let speech = roots.base.appendingPathComponent("support/danaview/speech/work/a.wav").path
        let okSpeech = reply {
            api.startJob(
                request: JobRequestMsg(kind: .speechAudio, media: source, priority: .normal, sourceStartUs: 0, sourceEndUs: 10, outputPath: speech),
                completion: $0)
        }
        XCTAssertEqual(try okSpeech?.get(), "job-1")
    }

    func testThumbnailRequestsAreChecked() {
        let source = media("file://" + roots.support.appendingPathComponent("media/a.mp4").path)
        let bad = ThumbnailRequestMsg(media: source, intervalMs: 0, tileIndex: 0, heightPx: 64, framesPerTile: 8, proxy: false)
        assertRefused("internal") { glue.jobsApi.thumbnailTile(requestId: "r1", request: bad, priority: .visible, completion: $0) }
    }

    func testExportArgumentsAreChecked() {
        let api = glue.exportApi
        let output = roots.cache.appendingPathComponent("work/e.mp4").path
        assertRefused("internal") { api.preflight(plan: bytes("{}"), settings: encodeSettings(width: 1919), completion: $0) }
        assertRefused("planInvalid") { api.preflight(plan: FlutterStandardTypedData(bytes: Data()), settings: encodeSettings(), completion: $0) }
        assertRefused("permissionDenied") {
            api.start(plan: bytes("{}"), settings: encodeSettings(), outputPath: "/tmp/e.mp4", title: "t", whenDetached: .keepForLater, completion: $0)
        }
        assertRefused("internal") {
            api.start(
                plan: bytes("{}"), settings: encodeSettings(), outputPath: output + "/../../../x.mp4", title: "t",
                whenDetached: .keepForLater, completion: $0)
        }
    }

    func testOutputsCannotEscapeTheRootsThroughSymlinks() throws {
        let outside = roots.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = roots.cache.appendingPathComponent("work/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        assertRefused("permissionDenied") {
            glue.recorderApi.start(outputPath: link.appendingPathComponent("r.wav").path, completion: $0)
        }
    }

    func testBackupExclusionIsLimitedToEditorAndSpeechRoots() {
        let api = glue.platformApi
        assertRefused("permissionDenied") { api.excludeFromBackup(path: roots.base.appendingPathComponent("Documents").path, completion: $0) }
        assertRefused("permissionDenied") { api.excludeFromBackup(path: "/var/mobile", completion: $0) }
        let speech = roots.base.appendingPathComponent("support/danaview/speech/models").path
        let result = reply { api.excludeFromBackup(path: speech, completion: $0) }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(fake.lastURL?.path, speech)
    }

    func testPlatformArgumentsAreChecked() {
        let api = glue.platformApi
        assertRefused("internal") { api.pick(request: MediaPickRequestMsg(source: .files, kinds: [], multiple: false), completion: $0) }
        assertRefused("internal") { api.saveToFiles(path: "/a/b.mp4", suggestedName: "../x.mp4", completion: $0) }
        assertRefused("internal") { api.share(path: "b.mp4", completion: $0) }
        assertRefused("internal") { api.resolveBookmark(bookmark: FlutterStandardTypedData(bytes: Data()), completion: $0) }
        assertRefused("internal") { api.updateBackground(leaseId: "lease-1", progress: 2, completion: $0) }
        assertRefused("internal") { api.stat(media: MediaRefMsg(uri: "content://x"), completion: $0) }
    }

    func testCallsBeforeInitializeFailWithInternal() throws {
        let other = try GlueFixture(services: fake.services)
        let error = pigeonError(reply {
            other.glue.previewApi.open(
                config: PreviewConfigMsg(canvasWidth: 1920, canvasHeight: 1080, fps: 30, quality: .auto, useProxies: false), completion: $0)
        })
        XCTAssertEqual(error?.code, "internal")
        XCTAssertTrue(error?.message?.contains("not initialized") ?? false)
    }

    func testInitializeRefusesBadRoots() {
        let api = glue.engineApi
        assertRefused("internal") { api.initialize(config: EngineConfigMsg(cacheRoot: "cache", supportRoot: "/support"), completion: $0) }
        assertRefused("internal") { api.initialize(config: EngineConfigMsg(cacheRoot: "/a", supportRoot: "/a"), completion: $0) }
        assertRefused("internal") { api.initialize(config: EngineConfigMsg(cacheRoot: "/a", supportRoot: "/a/b"), completion: $0) }
        // The installed roots did not change.
        XCTAssertEqual(fixture.context.paths?.cacheRoot.path, roots.cache.standardizedFileURL.path)
    }
}
