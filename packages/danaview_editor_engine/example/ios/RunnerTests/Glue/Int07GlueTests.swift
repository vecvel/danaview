// OWNER: INT-07
//
// The INT-07 glue on iOS: `PlatformHostApi.materializePick` (PickMaterializer), the localized export
// notification texts (validated on `initialize` and `ExportHostApi.start`, otherwise ignored),
// `RecorderHostApi.isRecording`, and the recording bridge (one `recordingChanged` event per change,
// every preview session muted while a recording captures, `AVPlayer.isMuted` on the real manager).

import Flutter
import XCTest

@testable import danaview_editor_engine

/// A preview manager that records the mute state it is given (every other call is unused here).
private final class MutingPreviews: PreviewSessionManaging, PreviewRecordingMuting {
    private let lock = NSLock()
    private var states: [Bool] = []
    var muted: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    func setRecordingMuted(_ muted: Bool) {
        lock.lock()
        states.append(muted)
        lock.unlock()
    }

    func open(_ config: PreviewConfigMsg, reply: @escaping EngineReply<PreviewOpenedMsg>) {
        reply(.success(PreviewOpenedMsg(sessionId: "s1", textureId: 1)))
    }
    func setPlan(sessionId: String, plan: Data, reply: @escaping EngineReply<PlanAckMsg>) { reply(.failure(EngineError(.internal, "unused"))) }
    func applyPatch(sessionId: String, patch: Data, reply: @escaping EngineReply<PlanAckMsg>) { reply(.failure(EngineError(.internal, "unused"))) }
    func setTransient(sessionId: String, itemId: String, params: Data) {}
    func clearTransient(sessionId: String, itemId: String) {}
    func play(sessionId: String, loop: LoopMsg?, reply: @escaping EngineReply<Int64>) { reply(.success(0)) }
    func pause(sessionId: String, reply: @escaping EngineReply<Int64>) { reply(.success(0)) }
    func seek(sessionId: String, timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>) {
        reply(.failure(EngineError(.internal, "unused")))
    }
    func setQuality(sessionId: String, quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>) { reply(.success(())) }
    func setUseProxies(sessionId: String, on: Bool, reply: @escaping EngineReply<Void>) { reply(.success(())) }
    func setEditingMode(sessionId: String, mode: EditingModeMsg, reply: @escaping EngineReply<Void>) { reply(.success(())) }
    func showSourceFrame(sessionId: String, media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }
    func sampleColor(sessionId: String, itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>) { reply(.success(nil)) }
    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64, reply: @escaping EngineReply<[Data]>
    ) { reply(.success([])) }
    func refresh(sessionId: String, reply: @escaping EngineReply<Void>) { reply(.success(())) }
    func debugCaptureFrame(sessionId: String, reply: @escaping EngineReply<Data>) { reply(.success(Data())) }
    func dispose(sessionId: String, reply: @escaping EngineReply<Void>) { reply(.success(())) }
}

final class Int07GlueTests: XCTestCase {
    private var fake: FakeServices!
    private var previews: MutingPreviews!
    private var fixture: GlueFixture!
    private var delivered: [EngineEventMsg] = []

    override func setUpWithError() throws {
        fake = FakeServices()
        previews = MutingPreviews()
        var services = fake.services
        services.previews = previews
        let hub = EventHub()
        hub.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { [unowned self] value in
            if let event = value as? EngineEventMsg { self.delivered.append(event) }
        })
        fixture = try GlueFixture(services: services, events: hub)
        try fixture.initialize(self)
    }

    override func tearDown() {
        fixture = nil
        fake = nil
        previews = nil
        delivered = []
    }

    private var glue: EngineGlue { fixture.glue }
    private var roots: TempRoots { fixture.roots }
    private var work: URL { roots.cache.appendingPathComponent("work", isDirectory: true) }

    private func wait<T>(_ name: String, _ call: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
        let done = expectation(description: name)
        var result: Result<T, Error>?
        call {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    /// Drains the previewControl queue and the main queue.
    private func drain() {
        fixture.context.queues.previewControl.sync {}
        let done = expectation(description: "main")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: materializePick

    func testMaterializePickCopiesAFileIntoANewDirectoryUnderIntoDir() throws {
        let source = roots.base.appendingPathComponent("Inbox/Beach day.mov")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: source)
        let into = work.appendingPathComponent("picks", isDirectory: true)
        let result = wait("materialize") { glue.platformApi.materializePick(uri: source.absoluteString, intoDir: into.path, completion: $0) }
        let path = try XCTUnwrap(result).get()
        let copy = URL(fileURLWithPath: path)
        XCTAssertEqual(copy.lastPathComponent, "Beach day.mov")
        XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path, into.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: copy), Data("movie".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays")
    }

    func testMaterializePickReturnsATemporaryCopyUnderWorkAsIs() throws {
        let temp = work.appendingPathComponent("drops/u1/a.mp4")
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: temp)
        let into = work.appendingPathComponent("picks").path
        let result = wait("temp") { glue.platformApi.materializePick(uri: temp.path, intoDir: into, completion: $0) }
        XCTAssertEqual(try XCTUnwrap(result).get(), temp.path)
        let gone = work.appendingPathComponent("drops/u2/b.mp4").path
        let missing = wait("gone") { glue.platformApi.materializePick(uri: gone, intoDir: into, completion: $0) }
        XCTAssertEqual(pigeonError(missing)?.code, "mediaOffline")
    }

    func testMaterializePickRefusals() {
        let into = work.appendingPathComponent("picks").path
        let outside = wait("outside") {
            glue.platformApi.materializePick(uri: "file:///tmp/a.mp4", intoDir: roots.cache.appendingPathComponent("media").path, completion: $0)
        }
        XCTAssertEqual(pigeonError(outside)?.code, "permissionDenied")
        let photos = wait("photos") { glue.platformApi.materializePick(uri: "ph://ABC/L0/001", intoDir: into, completion: $0) }
        XCTAssertEqual(pigeonError(photos)?.code, "notSupportedOnDevice")
        let content = wait("content") { glue.platformApi.materializePick(uri: "content://media/1", intoDir: into, completion: $0) }
        XCTAssertEqual(pigeonError(content)?.code, "notSupportedOnDevice")
        let missing = wait("missing") {
            glue.platformApi.materializePick(uri: roots.base.appendingPathComponent("nope.mp4").absoluteString, intoDir: into, completion: $0)
        }
        XCTAssertEqual(pigeonError(missing)?.code, "mediaOffline")
        XCTAssertEqual(PickMaterializer.safeName("../a/b:c"), "_a_b_c")
        XCTAssertEqual(PickMaterializer.safeName("..."), "pick")
    }

    // MARK: Notification texts

    private func texts(cancel: String = "Abbrechen") -> ExportNotificationTextsMsg {
        ExportNotificationTextsMsg(
            exportTitle: "Video wird exportiert", workTitle: "Arbeit im Hintergrund", exporting: "Export", exportingProgress: "Export · {percent} %",
            working: "Arbeit", workingProgress: "Arbeit · {percent} %", cancel: cancel, savedToGallery: "In Galerie gesichert",
            exportFinished: "Export fertig", more: "+{count} weitere", progressChannelName: "Videoexport",
            progressChannelDescription: "Fortschritt", doneChannelName: "Fertige Exporte", doneChannelDescription: "Fertig")
    }

    func testInitializeAndStartValidateTheNotificationTexts() {
        let ok = EngineConfigMsg(cacheRoot: roots.cache.path, supportRoot: roots.support.path, exportTexts: texts())
        XCTAssertNoThrow(try XCTUnwrap(wait("init") { glue.engineApi.initialize(config: ok, completion: $0) }).get())
        let bad = EngineConfigMsg(cacheRoot: roots.cache.path, supportRoot: roots.support.path, exportTexts: texts(cancel: ""))
        XCTAssertEqual(pigeonError(wait("bad init") { glue.engineApi.initialize(config: bad, completion: $0) })?.code, "internal")

        let output = work.appendingPathComponent("export-1.mp4").path
        let started = wait("start") {
            glue.exportApi.start(
                plan: bytes("{}"), settings: encodeSettings(), outputPath: output, title: "Trip", whenDetached: .saveToGallery,
                texts: texts(), completion: $0)
        }
        XCTAssertNotNil(try? XCTUnwrap(started).get())
        let refused = wait("bad start") {
            glue.exportApi.start(
                plan: bytes("{}"), settings: encodeSettings(), outputPath: output, title: "Trip", whenDetached: .saveToGallery,
                texts: texts(cancel: String(repeating: "x", count: 300)), completion: $0)
        }
        XCTAssertEqual(pigeonError(refused)?.code, "internal")
    }

    // MARK: Recording state

    func testIsRecordingAnswersTheRecorderState() throws {
        var recording = false
        let api = RecorderHostApiImpl(context: fixture.context, services: fixture.glue.services, isRecording: { recording })
        XCTAssertEqual(try XCTUnwrap(wait("off") { api.isRecording(completion: $0) }).get(), false)
        recording = true
        XCTAssertEqual(try XCTUnwrap(wait("on") { api.isRecording(completion: $0) }).get(), true)
        XCTAssertEqual(try XCTUnwrap(wait("default") { glue.recorderApi.isRecording(completion: $0) }).get(), VoiceRecorder.isRecording)
    }

    func testTheBridgeEmitsOneEventPerChangeAndMutesThePreview() {
        let bridge = glue.recordingMute
        bridge.recordingChanged(true)
        bridge.recordingChanged(true)
        bridge.recordingChanged(false)
        drain()
        let changes = delivered.filter { $0.kind == .recordingChanged }
        XCTAssertEqual(changes.map { $0.recording }, [true, false])
        XCTAssertEqual(previews.muted, [true, false])
    }

    func testTheBridgeFollowsTheRecorderNotification() {
        glue.recordingMute.start()
        defer { glue.recordingMute.stop() }
        NotificationCenter.default.post(name: VoiceRecorder.activityDidChange, object: nil, userInfo: ["active": true])
        NotificationCenter.default.post(name: VoiceRecorder.activityDidChange, object: nil, userInfo: ["active": false])
        drain()
        XCTAssertEqual(delivered.filter { $0.kind == .recordingChanged }.map { $0.recording }, [true, false])
        XCTAssertEqual(previews.muted, [true, false])
    }

    func testOpenAppliesTheCurrentRecordingStateToEverySession() throws {
        let result = wait("open") {
            glue.previewApi.open(config: PreviewConfigMsg(canvasWidth: 64, canvasHeight: 36, fps: 30, quality: .auto, useProxies: true), completion: $0)
        }
        XCTAssertEqual(try XCTUnwrap(result).get().sessionId, "s1")
        drain()
        XCTAssertEqual(previews.muted, [VoiceRecorder.isRecording])
    }

    func testTheRealManagerMutesItsPlayers() throws {
        let harness = try RenderPreviewHarness()
        defer { harness.roots.remove() }
        let manager = PreviewSessionManager(context: harness.context)
        let registry = RecordingTextureRegistry()
        let audio = FakeAudioSession()
        manager.makeDependencies = { context, paths in
            var d = PreviewSession.Dependencies(registry: registry, events: context.events, spacerDirectory: paths.engineAssets)
            d.audioSession = audio
            d.observeLifecycle = false
            return d
        }
        let queue = harness.context.queues.previewControl
        let config = PreviewConfigMsg(canvasWidth: 64, canvasHeight: 36, fps: 30, quality: .auto, useProxies: false)
        var opened: [String] = []
        for i in 0..<2 {
            let result = wait("open \(i)") { reply in queue.async { manager.open(config, reply: reply) } }
            opened.append(try XCTUnwrap(result).get().sessionId)
        }
        func mutedStates() -> [Bool] { queue.sync { opened.compactMap { manager.session($0)?.player.isMuted } } }
        XCTAssertEqual(mutedStates(), [false, false])
        RecordingMuteBridge.apply(true, to: manager, on: queue)
        XCTAssertEqual(mutedStates(), [true, true])
        RecordingMuteBridge.apply(false, to: manager, on: queue)
        XCTAssertEqual(mutedStates(), [false, false])
        for id in opened {
            _ = wait("dispose \(id)") { reply in queue.async { manager.dispose(sessionId: id, reply: reply) } }
        }
    }
}
