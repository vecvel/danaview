// OWNER: ENG-07
//
// The installed glue answers over the real Pigeon channels with the production (placeholder)
// services: initialize + capabilities round-trip (placeholder capabilities: supported false,
// `engine_not_available`), a placeholder media call fails with `notSupportedOnDevice`, and
// V-N8: the generated Swift `@EventChannelApi` handler (`EngineEventsStreamHandler`) accepts
// `listen` and delivers `EngineEventMsg` envelopes on `EngineEventsApi.engineEvents`.

import Flutter
import XCTest

@testable import vwish_editor_engine

final class ChannelRoundTripTests: XCTestCase {
    private var fixture: GlueFixture!

    override func setUpWithError() throws {
        fixture = try GlueFixture()
        fixture.glue.install()
    }

    override func tearDown() {
        fixture.glue.uninstall()
        fixture = nil
    }

    private var messenger: FakeMessenger { fixture.messenger }
    private let codec = EngineApiPigeonCodec.shared

    /// Sends a Pigeon request and returns the decoded reply list ([result] or [code, message, details]).
    private func call(_ api: String, _ method: String, _ args: [Any?]?, file: StaticString = #filePath, line: UInt = #line) -> [Any?]? {
        let done = expectation(description: "\(api).\(method)")
        var reply: [Any?]?
        let message = args.flatMap { codec.encode($0) }
        let handled = messenger.deliver(pigeonChannel(api, method), message) { data in
            if let data = data {
                reply = self.codec.decode(data) as? [Any?]
            }
            done.fulfill()
        }
        XCTAssertTrue(handled, "no handler on \(api).\(method)", file: file, line: line)
        if !handled { return nil }
        wait(for: [done], timeout: 5)
        return reply
    }

    func testEveryHostApiMethodHasAHandler() {
        let methods: [String: [String]] = [
            "EngineHostApi": ["initialize", "capabilities", "compatibility", "probe", "freeBytes", "trimCaches"],
            "PreviewHostApi": [
                "open", "setPlan", "applyPatch", "setTransient", "clearTransient", "play", "pause", "seek", "setQuality",
                "setUseProxies", "setEditingMode", "showSourceFrame", "sampleColor", "renderLookStills", "refresh",
                "debugCaptureFrame", "dispose",
            ],
            "JobsHostApi": ["thumbnailTile", "cancelThumbnail", "startJob", "cancelJob", "setJobPriority", "proxyStatus"],
            "ExportHostApi": ["preflight", "start", "resume", "cancel", "activeJobs", "consumeJobRecord"],
            "RecorderHostApi": ["permission", "requestPermission", "openSettings", "start", "stop", "cancel"],
            "PlatformHostApi": [
                "pick", "saveToPhotos", "saveToFiles", "share", "createBookmark", "resolveBookmark", "persistUriGrant",
                "releaseUriGrant", "remainingGrantBudget", "stat", "quickHash", "excludeFromBackup",
                "requestNotificationPermission", "acquireBackground", "updateBackground", "releaseBackground",
                "setDropTargetEnabled",
            ],
        ]
        for (api, names) in methods {
            for name in names {
                XCTAssertNotNil(messenger.handlers[pigeonChannel(api, name)], "\(api).\(name) not installed")
            }
        }
        XCTAssertNotNil(messenger.handlers[EngineGlue.eventChannelName])
    }

    func testCapabilitiesRoundTripWithThePlaceholderEngine() throws {
        let initialized = call("EngineHostApi", "initialize", [fixture.roots.config])
        XCTAssertEqual(initialized?.count, 1, "initialize failed: \(String(describing: initialized))")

        let reply = try XCTUnwrap(call("EngineHostApi", "capabilities", nil))
        XCTAssertEqual(reply.count, 1, "capabilities failed: \(reply)")
        let caps = try XCTUnwrap(reply.first as? CapabilitiesMsg)
        XCTAssertFalse(caps.supported)
        XCTAssertEqual(caps.unsupportedReason, "engine_not_available")
        XCTAssertEqual(caps.tier, .minimal)
        XCTAssertFalse(caps.voiceRecording)
        XCTAssertEqual(caps.planVersions, [])
    }

    func testPlaceholderServicesFailWithNotSupportedOnDevice() throws {
        _ = call("EngineHostApi", "initialize", [fixture.roots.config])
        let uri = "file://" + fixture.roots.support.appendingPathComponent("media/a.mp4").path
        let probe = try XCTUnwrap(call("EngineHostApi", "probe", [ResolvedMediaMsg(uri: uri, fingerprint: "fp", isProxy: false)]))
        XCTAssertEqual(probe.count, 3)
        XCTAssertEqual(probe[0] as? String, "notSupportedOnDevice")
        XCTAssertFalse((probe[1] as? String ?? "").contains("/"))
        XCTAssertEqual((probe[2] as? [String: Any])?["retryable"] as? Bool, false)

        let compatibility = try XCTUnwrap(call("EngineHostApi", "compatibility", [uri]))
        XCTAssertEqual(compatibility.first as? String, "notSupportedOnDevice")

        let open = try XCTUnwrap(call(
            "PreviewHostApi", "open",
            [PreviewConfigMsg(canvasWidth: 1080, canvasHeight: 1920, fps: 30, quality: .auto, useProxies: false)]))
        XCTAssertEqual(open.first as? String, "notSupportedOnDevice")

        // Idempotent and fire-and-forget calls succeed without an engine.
        XCTAssertEqual(call("PreviewHostApi", "dispose", ["s1"])?.count, 1)
        XCTAssertEqual(call("EngineHostApi", "trimCaches", [CacheTrimLevelMsg.memoryPressure])?.count, 1)
        XCTAssertEqual(call("ExportHostApi", "consumeJobRecord", ["e1"])?.count, 1)
        XCTAssertEqual(call("PlatformHostApi", "setDropTargetEnabled", [false])?.count, 1)

        // A synchronous method's validation error comes back as an error envelope.
        let refused = try XCTUnwrap(call("JobsHostApi", "cancelJob", [""]))
        XCTAssertEqual(refused.first as? String, "internal")
    }

    func testFreeBytesRoundTrip() throws {
        _ = call("EngineHostApi", "initialize", [fixture.roots.config])
        let reply = try XCTUnwrap(call("EngineHostApi", "freeBytes", [fixture.roots.cache.path]))
        let free = try XCTUnwrap(reply.first as? Int64)
        XCTAssertGreaterThan(free, 0)
    }

    /// V-N8 on iOS: Pigeon 29's generated `EngineEventsStreamHandler` registers the event channel,
    /// answers `listen`, and EventHub's events reach the messenger as success envelopes that decode
    /// back to `EngineEventMsg`.
    func testEventChannelDeliversEngineEvents() throws {
        let methodCodec = engineApiPigeonMethodCodec
        let channel = EngineGlue.eventChannelName

        // Emitted before Dart listens: kept and replayed.
        fixture.context.events.emitSignal(SignalMsg(kind: .thermal, thermalLevel: .serious))

        let listened = expectation(description: "listen")
        var listenReply: Any?
        let handled = messenger.deliver(channel, methodCodec.encode(FlutterMethodCall(methodName: "listen", arguments: nil))) { data in
            listenReply = data.map { methodCodec.decodeEnvelope($0) } ?? nil
            listened.fulfill()
        }
        XCTAssertTrue(handled)
        wait(for: [listened], timeout: 5)
        XCTAssertFalse(listenReply is FlutterError)

        fixture.context.events.emitJobFailure(jobId: "j1", EngineError(.diskFull, "no space", retryable: false))

        let events = messenger.sent.filter { $0.channel == channel }.compactMap { entry -> EngineEventMsg? in
            guard let data = entry.message else { return nil }
            return methodCodec.decodeEnvelope(data) as? EngineEventMsg
        }
        XCTAssertEqual(events.map(\.kind), [.signal, .failure])
        XCTAssertEqual(events.first?.signal?.thermalLevel, .serious)
        XCTAssertEqual(events.last?.jobId, "j1")
        XCTAssertEqual(events.last?.failure?.code, "diskFull")

        // cancel detaches the sink; later events wait in the backlog.
        let cancelled = expectation(description: "cancel")
        _ = messenger.deliver(channel, methodCodec.encode(FlutterMethodCall(methodName: "cancel", arguments: nil))) { _ in
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 5)
        XCTAssertFalse(fixture.context.events.isListening)
    }

    func testUninstallRemovesEveryHandler() {
        fixture.glue.uninstall()
        XCTAssertTrue(messenger.handlers.isEmpty, "left: \(messenger.handlers.keys.sorted())")
        fixture.glue.install()
    }
}
