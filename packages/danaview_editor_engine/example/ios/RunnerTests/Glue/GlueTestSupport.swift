// OWNER: ENG-07
//
// Test doubles of the iOS glue tests (BUILD_PLAN ENG-07): a binary messenger that records channel
// handlers and outgoing messages, fake services that record the engine queue each call runs on,
// and temporary editor roots. RunnerTests is an Xcode synchronized folder, so these files join the
// target without pbxproj edits; the plugin's internal types are reached with @testable (the pod is
// built with ENABLE_TESTABILITY in Debug).

import Flutter
import XCTest

@testable import danaview_editor_engine

// MARK: - Messenger

/// Records the handlers the glue installs and the messages it sends (events).
final class FakeMessenger: NSObject, FlutterBinaryMessenger {
    private(set) var handlers: [String: FlutterBinaryMessageHandler] = [:]
    private(set) var sent: [(channel: String, message: Data?)] = []
    private var nextConnection: FlutterBinaryMessengerConnection = 1

    func send(onChannel channel: String, message: Data?) {
        sent.append((channel, message))
    }

    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {
        sent.append((channel, message))
        callback?(nil)
    }

    func setMessageHandlerOnChannel(
        _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil
    ) -> FlutterBinaryMessengerConnection {
        handlers[channel] = handler
        nextConnection += 1
        return nextConnection
    }

    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}

    /// Sends [message] to the handler of [channel] as Dart would; [onReply] receives the reply bytes.
    func deliver(_ channel: String, _ message: Data?, onReply: @escaping (Data?) -> Void) -> Bool {
        guard let handler = handlers[channel] else { return false }
        handler(message, onReply)
        return true
    }
}

/// Pigeon channel name of a host API method.
func pigeonChannel(_ api: String, _ method: String) -> String {
    "dev.flutter.pigeon.danaview_editor_engine.\(api).\(method)"
}

// MARK: - Roots

/// Temporary `<cache>/danaview/editor` and `<support>/danaview/editor` roots.
final class TempRoots {
    let base: URL
    let cache: URL
    let support: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("danaview-glue-\(UUID().uuidString)", isDirectory: true)
        cache = base.appendingPathComponent("cache/danaview/editor", isDirectory: true)
        support = base.appendingPathComponent("support/danaview/editor", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    var config: EngineConfigMsg { EngineConfigMsg(cacheRoot: cache.path, supportRoot: support.path) }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

// MARK: - Fake services

/// Implements every service protocol. Each call records the engine queue it runs on, optionally
/// blocks on [gate] (to prove handlers never wait for services), then replies with [failure] or a
/// canned value.
final class FakeServices:
    CapabilitiesProviding, CompatibilityChecking, MediaProbing, CacheMaintaining, ThumbnailProviding, JobScheduling,
    ProxyStatusProviding, PreviewSessionManaging, ExportCoordinating, VoiceRecording, MediaPicking, PhotosSaving,
    FileHandingOff, MediaAccessing, PermissionRequesting, BackgroundLeasing, DropTargeting
{
    struct Call {
        let method: String
        let queue: String?
        let isMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Error every replying call fails with (nil: success).
    var failure: Error?
    /// When set, every call waits for it before replying (on the engine queue).
    var gate: DispatchSemaphore?
    /// Called after each recorded call (any thread).
    var onCall: ((Call) -> Void)?
    /// Arguments of the last calls that carry URLs.
    private(set) var lastURL: URL?
    private(set) var lastOutputURL: URL?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }

    private func record(_ method: String) {
        let call = Call(method: method, queue: EngineQueues.currentName, isMainThread: Thread.isMainThread)
        lock.lock()
        recorded.append(call)
        lock.unlock()
        onCall?(call)
    }

    private func respond<T>(_ method: String, _ value: @autoclosure () -> T, _ reply: EngineReply<T>) {
        record(method)
        gate?.wait()
        if let failure = failure {
            reply(.failure(failure))
        } else {
            reply(.success(value()))
        }
    }

    private func note(url: URL? = nil, output: URL? = nil) {
        lock.lock()
        if let url = url { lastURL = url }
        if let output = output { lastOutputURL = output }
        lock.unlock()
    }

    var services: EngineServices {
        EngineServices(
            capabilities: self, compatibility: self, probe: self, caches: self, thumbnails: self, jobs: self,
            proxies: self, previews: self, exports: self, recorder: self, picker: self, photos: self, files: self,
            access: self, permissions: self, background: self, drops: self)
    }

    // Engine root
    func capabilities(reply: @escaping EngineReply<CapabilitiesMsg>) {
        respond("capabilities", Capabilities.placeholder, reply)
    }
    func compatibility(of url: URL, reply: @escaping EngineReply<CompatibilityMsg>) {
        note(url: url)
        respond("compatibility", CompatibilityMsg(editable: true), reply)
    }
    func probe(_ media: ResolvedMediaMsg, url: URL, reply: @escaping EngineReply<ProbeMsg>) {
        note(url: url)
        respond("probe", FakeServices.probeMsg, reply)
    }
    func engineDidInitialize(paths: Paths) { record("engineDidInitialize") }
    func trim(_ level: CacheTrimLevelMsg) { record("trim") }

    // Jobs
    func tile(
        requestId: String, request: ThumbnailRequestMsg, mediaURL: URL, priority: ThumbPriorityMsg,
        reply: @escaping EngineReply<ThumbnailTileMsg>
    ) {
        note(url: mediaURL)
        respond("tile", ThumbnailTileMsg(encoded: FlutterStandardTypedData(bytes: Data([1])), frames: 8, frameWidthPx: 10), reply)
    }
    func cancel(requestId: String) { record("cancelThumbnail") }
    func start(_ request: JobRequestMsg, mediaURL: URL, outputURL: URL?, reply: @escaping EngineReply<String>) {
        note(url: mediaURL, output: outputURL)
        respond("startJob", "job-1", reply)
    }
    func cancel(jobId: String) { record("cancelJob") }
    func setPriority(jobId: String, priority: JobPriorityMsg) { record("setJobPriority") }
    func status(fingerprint: String, reply: @escaping EngineReply<ProxyStatusMsg>) {
        respond("proxyStatus", ProxyStatusMsg.noProxy, reply)
    }

    // Preview
    func open(_ config: PreviewConfigMsg, reply: @escaping EngineReply<PreviewOpenedMsg>) {
        respond("open", PreviewOpenedMsg(sessionId: "s1", textureId: 7), reply)
    }
    func setPlan(sessionId: String, plan: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        respond("setPlan", PlanAckMsg(rev: 1, structural: true, applyMs: 1), reply)
    }
    func applyPatch(sessionId: String, patch: Data, reply: @escaping EngineReply<PlanAckMsg>) {
        respond("applyPatch", PlanAckMsg(rev: 2, structural: false, applyMs: 1), reply)
    }
    func setTransient(sessionId: String, itemId: String, params: Data) { record("setTransient") }
    func clearTransient(sessionId: String, itemId: String) { record("clearTransient") }
    func play(sessionId: String, loop: LoopMsg?, reply: @escaping EngineReply<Int64>) { respond("play", 1, reply) }
    func pause(sessionId: String, reply: @escaping EngineReply<Int64>) { respond("pause", 2, reply) }
    func seek(sessionId: String, timeUs: Int64, exact: Bool, reply: @escaping EngineReply<SeekAckMsg>) {
        respond("seek", SeekAckMsg(requestedUs: timeUs, displayedFrameTimeUs: timeUs, displayedFrame: 0, seq: 3), reply)
    }
    func setQuality(sessionId: String, quality: PreviewQualityMsg, reply: @escaping EngineReply<Void>) {
        respond("setQuality", (), reply)
    }
    func setUseProxies(sessionId: String, on: Bool, reply: @escaping EngineReply<Void>) {
        respond("setUseProxies", (), reply)
    }
    func setEditingMode(sessionId: String, mode: EditingModeMsg, reply: @escaping EngineReply<Void>) {
        respond("setEditingMode", (), reply)
    }
    func showSourceFrame(
        sessionId: String, media: ResolvedMediaMsg, mediaURL: URL, sourceTimeUs: Int64, reply: @escaping EngineReply<Void>
    ) {
        note(url: mediaURL)
        respond("showSourceFrame", (), reply)
    }
    func sampleColor(sessionId: String, itemId: String, x: Double, y: Double, reply: @escaping EngineReply<ColorMsg?>) {
        respond("sampleColor", ColorMsg(red: 1, green: 0, blue: 0, alpha: 1), reply)
    }
    func renderLookStills(
        sessionId: String, itemId: String, looks: [LookSpecMsg], lutURLs: [URL], heightPx: Int64,
        reply: @escaping EngineReply<[Data]>
    ) {
        respond("renderLookStills", lutURLs.map { _ in Data([0xFF, 0xD8]) }, reply)
    }
    func refresh(sessionId: String, reply: @escaping EngineReply<Void>) { respond("refresh", (), reply) }
    func debugCaptureFrame(sessionId: String, reply: @escaping EngineReply<Data>) {
        respond("debugCaptureFrame", Data([1, 2, 3, 4]), reply)
    }
    func dispose(sessionId: String, reply: @escaping EngineReply<Void>) { respond("dispose", (), reply) }

    // Export
    func preflight(plan: Data, settings: EncodeSettingsMsg, reply: @escaping EngineReply<ExportPreflightMsg>) {
        respond("preflight", ExportPreflightMsg(ok: true, warnings: []), reply)
    }
    func start(
        plan: Data, settings: EncodeSettingsMsg, outputURL: URL, title: String, whenDetached: DetachedHandoffMsg,
        reply: @escaping EngineReply<String>
    ) {
        note(output: outputURL)
        respond("exportStart", "export-1", reply)
    }
    func resume(jobId: String, reply: @escaping EngineReply<String>) { respond("resume", jobId, reply) }
    func cancel(jobId: String, reply: @escaping EngineReply<Void>) { respond("exportCancel", (), reply) }
    func activeJobs(reply: @escaping EngineReply<[ExportJobRecordMsg]>) { respond("activeJobs", [], reply) }
    func consumeJobRecord(jobId: String) { record("consumeJobRecord") }

    // Recorder
    func permission(reply: @escaping EngineReply<MicPermissionMsg>) { respond("permission", .granted, reply) }
    func requestPermission(reply: @escaping EngineReply<MicPermissionMsg>) { respond("requestPermission", .granted, reply) }
    func openSettings(reply: @escaping EngineReply<Void>) { respond("openSettings", (), reply) }
    func start(outputURL: URL, reply: @escaping EngineReply<String>) {
        note(output: outputURL)
        respond("recorderStart", "rec-1", reply)
    }
    func stop(recordingId: String, reply: @escaping EngineReply<RecordedAssetMsg>) {
        respond("recorderStop", RecordedAssetMsg(path: "x.wav", durationUs: 1, startLatencyUs: 1), reply)
    }
    func cancel(recordingId: String, reply: @escaping EngineReply<Void>) { respond("recorderCancel", (), reply) }

    // Platform
    func pick(_ request: MediaPickRequestMsg, reply: @escaping EngineReply<[PickedMediaMsg]>) { respond("pick", [], reply) }
    func saveToPhotos(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        respond("saveToPhotos", FileHandoffResultMsg(outcome: .done), reply)
    }
    func saveToFiles(fileURL: URL, suggestedName: String, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        respond("saveToFiles", FileHandoffResultMsg(outcome: .done), reply)
    }
    func share(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        respond("share", FileHandoffResultMsg(outcome: .done), reply)
    }
    func createBookmark(fileURL: URL, reply: @escaping EngineReply<Data>) { respond("createBookmark", Data([9]), reply) }
    func resolveBookmark(_ bookmark: Data, reply: @escaping EngineReply<ResolvedBookmarkMsg>) {
        respond("resolveBookmark", ResolvedBookmarkMsg(uri: "file:///x", stale: false), reply)
    }
    func persistUriGrant(uri: String, reply: @escaping EngineReply<Void>) { respond("persistUriGrant", (), reply) }
    func releaseUriGrant(uri: String, reply: @escaping EngineReply<Void>) { respond("releaseUriGrant", (), reply) }
    func remainingGrantBudget(reply: @escaping EngineReply<Int64>) { respond("remainingGrantBudget", Int64.max, reply) }
    func stat(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<MediaStatMsg?>) {
        respond("stat", MediaStatMsg(sizeBytes: 1), reply)
    }
    func quickHash(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<String>) {
        respond("quickHash", "hash", reply)
    }
    func excludeFromBackup(directoryURL: URL, reply: @escaping EngineReply<Void>) {
        note(url: directoryURL)
        respond("excludeFromBackup", (), reply)
    }
    func requestNotificationPermission(reply: @escaping EngineReply<Bool>) {
        respond("requestNotificationPermission", true, reply)
    }
    func acquire(title: String, reply: @escaping EngineReply<String?>) { respond("acquireBackground", "lease-1", reply) }
    func update(leaseId: String, progress: Double, reply: @escaping EngineReply<Void>) {
        respond("updateBackground", (), reply)
    }
    func release(leaseId: String, reply: @escaping EngineReply<Void>) { respond("releaseBackground", (), reply) }
    func setEnabled(_ enabled: Bool, reply: @escaping EngineReply<Void>) { respond("setDropTargetEnabled", (), reply) }

    static let probeMsg = ProbeMsg(
        kind: .video, durationUs: 1_000_000, hasVideo: true, hasAudio: false, rotation: 0, variableFrameRate: false,
        audioStreams: 0, transfer: .sdr, sizeBytes: 1, editable: true, issues: [])
}

// MARK: - Helpers

/// A glue over [services] with fresh queues and hub, plus temporary roots (not yet initialized).
final class GlueFixture {
    let messenger = FakeMessenger()
    let roots: TempRoots
    let context: EngineContext
    let glue: EngineGlue

    init(services: EngineServices? = nil, events: EventHub = EventHub()) throws {
        roots = try TempRoots()
        context = EngineContext(messenger: messenger, textures: nil, events: events, presentingViewController: { nil })
        glue = EngineGlue(context: context, services: services ?? EngineServices.make(context: context))
    }

    /// Runs `initialize` with the temporary roots and waits for its reply.
    func initialize(_ test: XCTestCase) throws {
        let done = test.expectation(description: "initialize")
        var result: Result<Void, Error>?
        glue.engineApi.initialize(config: roots.config) {
            result = $0
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        _ = try XCTUnwrap(result).get()
    }

    deinit {
        roots.remove()
    }
}

/// The `EnginePigeonError` of a failed result (fails the test otherwise).
func pigeonError<T>(_ result: Result<T, Error>?, file: StaticString = #filePath, line: UInt = #line) -> EnginePigeonError? {
    guard let result = result else {
        XCTFail("no reply", file: file, line: line)
        return nil
    }
    switch result {
    case .success:
        XCTFail("expected a failure", file: file, line: line)
        return nil
    case .failure(let error):
        guard let pigeon = error as? EnginePigeonError else {
            XCTFail("not an EnginePigeonError: \(error)", file: file, line: line)
            return nil
        }
        return pigeon
    }
}

/// `retryable` of an error's details.
func retryable(_ error: EnginePigeonError?) -> Bool? {
    (error?.details as? [String: Any])?["retryable"] as? Bool
}

func media(_ uri: String, fingerprint: String = "fp1") -> ResolvedMediaMsg {
    ResolvedMediaMsg(uri: uri, fingerprint: fingerprint, isProxy: false)
}

func encodeSettings(width: Int64 = 1920, height: Int64 = 1080) -> EncodeSettingsMsg {
    EncodeSettingsMsg(
        container: .mp4, codec: .h264, width: width, height: height, fps: 30, videoBitrate: 12_000_000,
        audioBitrate: 192_000, audioSampleRate: 48_000, audioChannels: 2, keyframeIntervalMs: 1000, stripLocation: true)
}

func bytes(_ text: String) -> FlutterStandardTypedData {
    FlutterStandardTypedData(bytes: Data(text.utf8))
}
