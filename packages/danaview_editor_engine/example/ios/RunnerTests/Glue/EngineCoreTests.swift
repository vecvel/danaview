// OWNER: ENG-07
//
// Engine core of the iOS plugin: Dart-supplied roots and derived directories (Paths, ARCH §8.1,
// §20.1), the context's roots lifecycle, queue identification, system signals (memory warning →
// signal + cache trim, thermal levels) and the D-33 placeholder capabilities.

import Flutter
import XCTest

@testable import danaview_editor_engine

final class EngineCoreTests: XCTestCase {
    func testRootsAreValidated() {
        XCTAssertThrowsError(try Paths(cacheRoot: "", supportRoot: "/s"))
        XCTAssertThrowsError(try Paths(cacheRoot: "relative", supportRoot: "/s"))
        XCTAssertThrowsError(try Paths(cacheRoot: "/c/../x", supportRoot: "/s"))
        XCTAssertThrowsError(try Paths(cacheRoot: "/same", supportRoot: "/same/"))
        XCTAssertThrowsError(try Paths(cacheRoot: "/a", supportRoot: "/a/b"))
        XCTAssertThrowsError(try Paths(cacheRoot: "/a/b", supportRoot: "/a"))
        XCTAssertNoThrow(try Paths(cacheRoot: "/a/cache/danaview/editor", supportRoot: "/a/support/danaview/editor"))
    }

    func testDerivedDirectories() throws {
        let paths = try Paths(cacheRoot: "/c/danaview/editor", supportRoot: "/s/danaview/editor")
        XCTAssertEqual(paths.speechRoot.path, "/s/danaview/speech")
        XCTAssertEqual(paths.thumbs.path, "/c/danaview/editor/thumbs")
        XCTAssertEqual(paths.waves.path, "/c/danaview/editor/waves")
        XCTAssertEqual(paths.proxies.path, "/c/danaview/editor/proxies")
        XCTAssertEqual(paths.sprites.path, "/c/danaview/editor/sprites")
        XCTAssertEqual(paths.looks.path, "/c/danaview/editor/looks")
        XCTAssertEqual(paths.engineAssets.path, "/c/danaview/editor/engine")
        XCTAssertEqual(paths.workPicks.path, "/c/danaview/editor/work/picks")
        XCTAssertEqual(paths.workDrops.path, "/c/danaview/editor/work/drops")
        XCTAssertEqual(paths.derived.path, "/s/danaview/editor/derived")
    }

    func testContainmentIsComponentWise() {
        let root = URL(fileURLWithPath: "/a/editor")
        XCTAssertTrue(Paths.contains(root, URL(fileURLWithPath: "/a/editor/x")))
        XCTAssertFalse(Paths.contains(root, URL(fileURLWithPath: "/a/editor2/x")))
        XCTAssertFalse(Paths.contains(root, root))
    }

    func testFileUrisAndPaths() throws {
        XCTAssertEqual(try Paths.fileURL(fromPathOrUri: "file:///a/b%20c.mp4", name: "u").path, "/a/b c.mp4")
        XCTAssertEqual(try Paths.fileURL(fromPathOrUri: "/a/./b.mp4", name: "u").path, "/a/b.mp4")
        XCTAssertThrowsError(try Paths.fileURL(fromPathOrUri: "content://x/1", name: "u"))
        XCTAssertThrowsError(try Paths.fileURL(fromPathOrUri: "https://example.com/a.mp4", name: "u"))
        XCTAssertThrowsError(try Paths.fileURL(fromPathOrUri: "file:///a/../b", name: "u"))
        XCTAssertThrowsError(try Paths.absoluteURL("/a/\u{0}b", name: "p"))
    }

    func testFreeBytesWalksUpToAnExistingDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("does/not/exist/x.mp4").path
        XCTAssertGreaterThan(try Paths.freeBytes(at: tmp), 0)
    }

    func testContextConfigureIsIdempotentAndRequiresRoots() throws {
        let context = EngineContext(messenger: FakeMessenger(), textures: nil, presentingViewController: { nil })
        XCTAssertNil(context.paths)
        XCTAssertThrowsError(try context.requirePaths()) { error in
            XCTAssertEqual((error as? EngineError)?.code, .internal)
        }
        XCTAssertTrue(try context.configure(cacheRoot: "/c/danaview/editor", supportRoot: "/s/danaview/editor"))
        XCTAssertFalse(try context.configure(cacheRoot: "/c/danaview/editor", supportRoot: "/s/danaview/editor"))
        XCTAssertTrue(try context.configure(cacheRoot: "/c2/danaview/editor", supportRoot: "/s/danaview/editor"))
        XCTAssertEqual(try context.requirePaths().cacheRoot.path, "/c2/danaview/editor")
    }

    func testQueuesAreNamed() {
        let queues = EngineQueues()
        XCTAssertEqual(EngineQueues.currentName, "main")
        let pairs: [(DispatchQueue, String)] = [
            (queues.engine, "engine"), (queues.previewControl, "previewControl"), (queues.jobs, "jobs"),
            (queues.export, "export"), (queues.recorder, "recorder"), (queues.io, "io"),
        ]
        for (queue, name) in pairs {
            XCTAssertEqual(queue.sync { EngineQueues.currentName }, name)
        }
    }

    func testMemoryWarningEmitsASignalAndTrimsCaches() throws {
        let fake = FakeServices()
        let fixture = try GlueFixture(services: fake.services)
        var events: [EngineEventMsg] = []
        fixture.context.events.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> {
            if let e = $0 as? EngineEventMsg { events.append(e) }
        })
        let trimmed = expectation(description: "trim")
        fake.onCall = { if $0.method == "trim" { trimmed.fulfill() } }
        fixture.glue.signals.memoryWarning()
        wait(for: [trimmed], timeout: 5)
        XCTAssertEqual(fake.calls("trim").last?.queue, "engine")
        XCTAssertEqual(events.map(\.kind), [.signal])
        XCTAssertEqual(events.first?.signal?.kind, .memoryWarning)

        fixture.glue.signals.thermalStateChanged(.serious)
        fixture.glue.signals.thermalStateChanged(.serious)
        fixture.glue.signals.thermalStateChanged(.nominal)
        XCTAssertEqual(events.compactMap(\.signal?.thermalLevel), [.serious, .nominal])
    }

    func testThermalLevels() {
        XCTAssertEqual(SystemSignals.thermalLevel(.nominal), .nominal)
        XCTAssertEqual(SystemSignals.thermalLevel(.fair), .fair)
        XCTAssertEqual(SystemSignals.thermalLevel(.serious), .serious)
        XCTAssertEqual(SystemSignals.thermalLevel(.critical), .critical)
    }

    func testPlaceholderCapabilitiesMirrorTheDartUnsupportedDefaults() {
        let caps = Capabilities.placeholder
        XCTAssertFalse(caps.supported)
        XCTAssertEqual(caps.unsupportedReason, "engine_not_available")
        XCTAssertEqual(caps.tier, .minimal)
        XCTAssertEqual(caps.maxExportWidth, 0)
        XCTAssertEqual(caps.maxExportHeight, 0)
        XCTAssertTrue(caps.maxFpsByHeight.isEmpty)
        XCTAssertEqual(caps.maxConcurrentVideoLayers, 0)
        XCTAssertEqual(caps.maxVisualSequences, 0)
        XCTAssertEqual(caps.backgroundKind, .noBackground)
        XCTAssertFalse(caps.voiceRecording)
        XCTAssertEqual(caps.minSpeed, 0.1)
        XCTAssertEqual(caps.maxSpeed, 10)
        XCTAssertEqual(caps.maxAudioSpeed, 4)
        XCTAssertEqual(caps.maxLutSize, 65)
        XCTAssertTrue(caps.planVersions.isEmpty)
    }
}
