// OWNER: IOS-16
//
// External drop target (BUILD_PLAN IOS-16, D-18): the delegate is driven with synthesized
// UIDropSession / NSItemProvider objects (movie, audio, image, .cube, unsupported). Asserts the
// accepted items, the temp copies under work/drops/<uuid>/<name>, the logical position, the single
// `drop` event, that unsupported-only sessions are refused, and that disabling removes the
// interaction. Dart moving the copies out of work/drops after import is covered by
// vwish_editor_core test/store/media/media_pool_service_test.dart ("external drop → managed copy
// moved out of work/drops").
//
// Manual checklist (QA-01): a cross-app drag from Files and from Photos onto the editor on the
// iPad simulator imports the items.

import UIKit
import XCTest

@testable import vwish_editor_engine

/// A synthesized drop session.
private final class FakeDropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    let point: CGPoint
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    let progress = Progress()

    init(_ providers: [NSItemProvider], at point: CGPoint) {
        items = providers.map { UIDragItem(itemProvider: $0) }
        self.point = point
    }

    func location(in view: UIView) -> CGPoint { point }
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    var localDragSession: UIDragSession? { nil }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        items.contains { item in typeIdentifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }

    func loadObjects(ofClass aClass: NSItemProviderReading.Type, completion: @escaping ([NSItemProviderReading]) -> Void) -> Progress {
        completion([])
        return Progress()
    }
}

final class DropTargetTests: XCTestCase {
    private var fixture: RecordingEngineFixture!
    private var target: DropTarget!
    private var view: UIView!

    override func setUpWithError() throws {
        fixture = try RecordingEngineFixture()
        target = DropTarget(context: fixture.context)
        view = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        target.hostView = { [unowned self] in self.view }
    }

    override func tearDown() {
        fixture.remove()
    }

    private func enable(_ on: Bool) throws {
        try awaitReply(self) { target.setEnabled(on, reply: $0) }
    }

    private func provider(_ url: URL) throws -> NSItemProvider {
        try XCTUnwrap(NSItemProvider(contentsOf: url))
    }

    private func file(_ name: String, size: Int = 512) throws -> URL {
        let url = fixture.roots.base.appendingPathComponent("outside/\(name)")
        try writePatternFile(url, size: size)
        return url
    }

    func testEnablingInstallsAndDisablingRemovesTheInteraction() throws {
        XCTAssertTrue(view.interactions.isEmpty)
        try enable(true)
        XCTAssertEqual(view.interactions.filter { $0 is UIDropInteraction }.count, 1)
        try enable(true)  // idempotent
        XCTAssertEqual(view.interactions.filter { $0 is UIDropInteraction }.count, 1)
        try enable(false)
        XCTAssertTrue(view.interactions.isEmpty)
        XCTAssertNil(target.interaction)
        try enable(false)  // idempotent
    }

    func testDropOfMovieAudioImageCubeAndUnsupported() throws {
        try enable(true)
        let interaction = try XCTUnwrap(target.interaction)
        let movie = try ProbeFixtures.url("frame_counter_720p24.mp4")
        let audio = try ProbeFixtures.url("tone_440hz.wav")
        let image = try ProbeFixtures.url("still_4k.jpg")
        let cube = try file("teal.cube")
        let text = try file("readme.txt")
        let sources = [movie, audio, image, cube]
        let session = FakeDropSession(
            [try provider(movie), try provider(audio), try provider(image), try provider(cube), try provider(text)],
            at: CGPoint(x: 120.5, y: 300.25))

        XCTAssertTrue(target.dropInteraction(interaction, canHandle: session))
        XCTAssertEqual(target.dropInteraction(interaction, sessionDidUpdate: session).operation, .copy)

        var handled: DropMsg??
        target.onDropHandled = { handled = .some($0) }
        target.dropInteraction(interaction, performDrop: session)
        XCTAssertTrue(spin(until: { handled != nil }, timeout: 30))
        let drop = try XCTUnwrap(handled ?? nil)

        XCTAssertEqual(drop.x, 120.5)
        XCTAssertEqual(drop.y, 300.25)
        XCTAssertEqual(drop.items.count, 4, "the .txt item is ignored")
        let drops = fixture.paths.workDrops.resolvingSymlinksInPath().path
        for (item, source) in zip(drop.items, sources) {
            XCTAssertEqual(item.origin, .drop)
            XCTAssertTrue(item.isTemporaryCopy)
            XCTAssertNil(item.bookmark)
            XCTAssertEqual((item.displayName as NSString).pathExtension, source.pathExtension)
            let copy = try XCTUnwrap(URL(string: item.uri))
            XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path, drops)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        }

        // One drop event with the same payload.
        XCTAssertTrue(spin(until: { self.fixture.events.contains { $0.kind == .drop } }))
        let events = fixture.events.filter { $0.kind == .drop }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.drop, drop)
    }

    func testUnsupportedOnlySessionIsRefused() throws {
        try enable(true)
        let interaction = try XCTUnwrap(target.interaction)
        let session = FakeDropSession([try provider(try file("a.txt")), try provider(try file("b.pdf"))], at: .zero)
        XCTAssertFalse(target.dropInteraction(interaction, canHandle: session))
        XCTAssertEqual(target.dropInteraction(interaction, sessionDidUpdate: session).operation, .forbidden)
    }

    func testDisabledTargetRefusesSessions() throws {
        try enable(true)
        let interaction = try XCTUnwrap(target.interaction)
        try enable(false)
        let session = FakeDropSession([try provider(try ProbeFixtures.url("still_4k.jpg"))], at: .zero)
        XCTAssertFalse(target.dropInteraction(interaction, canHandle: session))
        XCTAssertEqual(target.dropInteraction(interaction, sessionDidUpdate: session).operation, .forbidden)
    }

    func testEnableWithoutAViewFails() {
        target.hostView = { nil }
        XCTAssertEqual(awaitFailure(self) { target.setEnabled(true, reply: $0) }?.code, .internal)
        XCTAssertNoThrow(try enable(false))
    }
}
