// OWNER: IOS-15
//
// Pickers (BUILD_PLAN IOS-15): the PHPicker configuration asks for the `.current` representation
// (HEVC without transcode), and the provider path the picker uses clones the provider's temp file
// into `work/picks/<uuid>/<name>` inside the completion handler: the copy still exists after the
// handler returned and a 1 s delay, byte-identical to the HEVC source. Document picker types,
// extension checks and bookmarks.
//
// Manual (no UI automation of the system pickers): picking an HEVC clip from Photos on a device
// returns the original file (QA-00 import scenario).

import Flutter
import PhotosUI
import UniformTypeIdentifiers
import XCTest

@testable import vwish_editor_engine

final class MediaPickerTests: XCTestCase {
    private var fixture: RecordingEngineFixture!

    override func setUpWithError() throws {
        fixture = try RecordingEngineFixture()
    }

    override func tearDown() {
        fixture.remove()
    }

    private func request(_ source: MediaPickSourceMsg, _ kinds: [MediaPickKindMsg], multiple: Bool = true) -> MediaPickRequestMsg {
        MediaPickRequestMsg(source: source, kinds: kinds, multiple: multiple)
    }

    // MARK: Photos

    func testPhotosConfigurationKeepsTheCurrentRepresentation() throws {
        let both = try MediaPicker.photosConfiguration(request(.photos, [.video, .image]))
        XCTAssertEqual(both.preferredAssetRepresentationMode, .current, "HEVC must not be transcoded")
        XCTAssertEqual(both.selectionLimit, 0, "multi-select")
        XCTAssertEqual(both.filter, PHPickerFilter.any(of: [.videos, .images]))

        let single = try MediaPicker.photosConfiguration(request(.photos, [.video], multiple: false))
        XCTAssertEqual(single.selectionLimit, 1)
        XCTAssertEqual(single.filter, PHPickerFilter.videos)
        XCTAssertEqual(try MediaPicker.photosConfiguration(request(.photos, [.image])).filter, PHPickerFilter.images)

        XCTAssertThrowsError(try MediaPicker.photosConfiguration(request(.photos, [.audio])))
    }

    func testProviderCopySurvivesTheHandlerAndOneSecondAndIsNotTranscoded() throws {
        let source = try ProbeFixtures.url("hlg_10bit_720p.mov")  // HEVC Main10
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        provider.suggestedName = "IMG_0042"
        let done = expectation(description: "loaded")
        var result: Result<[PickedMediaMsg], Error>?
        ItemProviderImport.load([provider], kinds: [.video, .image], into: fixture.paths.workPicks, origin: .photos) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        let items = try XCTUnwrap(result).get()
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertTrue(item.isTemporaryCopy)
        XCTAssertEqual(item.origin, .photos)
        XCTAssertNil(item.bookmark)
        XCTAssertEqual(item.displayName, "IMG_0042.mov")
        let copy = try XCTUnwrap(URL(string: item.uri))
        XCTAssertTrue(copy.isFileURL)
        // <cache>/vwish/editor/work/picks/<uuid>/<name>
        XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                       fixture.paths.workPicks.resolvingSymlinksInPath().path)
        XCTAssertNotNil(UUID(uuidString: copy.deletingLastPathComponent().lastPathComponent))

        // The provider deletes its own temp file when the handler returns; the clone stays.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source), "byte-identical: no transcode")
        XCTAssertEqual(item.sizeBytes, Int64(try Data(contentsOf: source).count))
    }

    func testProvidersKeepOrderAndSkipUnsupportedItems() throws {
        let image = try XCTUnwrap(NSItemProvider(contentsOf: try ProbeFixtures.url("still_4k.jpg")))
        let text = fixture.roots.base.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let unsupported = try XCTUnwrap(NSItemProvider(contentsOf: text))
        let video = try XCTUnwrap(NSItemProvider(contentsOf: try ProbeFixtures.url("frame_counter_720p24.mp4")))
        let done = expectation(description: "loaded")
        var items: [PickedMediaMsg] = []
        ItemProviderImport.load([image, unsupported, video], kinds: [.video, .image], into: fixture.paths.workPicks, origin: .photos) {
            items = (try? $0.get()) ?? []
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        // The system may hand the temp file over as `.jpeg`; any extension of the same type is fine.
        let extensions = items.map { ($0.displayName as NSString).pathExtension }
        XCTAssertEqual(extensions.count, 2)
        XCTAssertTrue(ItemProviderImport.sameFileType(extensions.first ?? "", "jpg"), "\(extensions)")
        XCTAssertTrue(ItemProviderImport.sameFileType(extensions.last ?? "", "mp4"), "\(extensions)")
    }

    func testClassifyKinds() throws {
        func provider(_ name: String) throws -> NSItemProvider {
            let url = fixture.roots.base.appendingPathComponent("classify/\(name)")
            try writePatternFile(url, size: 16)
            return try XCTUnwrap(NSItemProvider(contentsOf: url))
        }
        let all: Set<MediaPickKindMsg> = [.video, .audio, .image, .lut, .subtitle]
        XCTAssertEqual(ItemProviderImport.classify(try provider("a.mov"), kinds: all)?.kind, .video)
        XCTAssertEqual(ItemProviderImport.classify(try provider("a.m4a"), kinds: all)?.kind, .audio)
        XCTAssertEqual(ItemProviderImport.classify(try provider("a.png"), kinds: all)?.kind, .image)
        XCTAssertEqual(ItemProviderImport.classify(try provider("look.cube"), kinds: all)?.kind, .lut)
        XCTAssertEqual(ItemProviderImport.classify(try provider("subs.srt"), kinds: all)?.kind, .subtitle)
        XCTAssertNil(ItemProviderImport.classify(try provider("notes.txt"), kinds: all))
        XCTAssertNil(ItemProviderImport.classify(try provider("a.mov"), kinds: [.audio]), "kind not requested")
    }

    func testSanitizedNames() {
        XCTAssertEqual(ItemProviderImport.sanitize("../a/b.mov"), "_a_b.mov")
        XCTAssertEqual(ItemProviderImport.sanitize(".hidden"), "hidden")
        XCTAssertEqual(ItemProviderImport.sanitize(""), "media")
        let long = String(repeating: "é", count: 300) + ".mov"
        let cleaned = ItemProviderImport.sanitize(long)
        XCTAssertLessThanOrEqual(cleaned.utf8.count, 200)
        XCTAssertTrue(cleaned.hasSuffix(".mov"))
        XCTAssertEqual(ItemProviderImport.displayName(suggested: "IMG_1", file: URL(fileURLWithPath: "/t/x.MOV")), "IMG_1.MOV")
        XCTAssertEqual(ItemProviderImport.displayName(suggested: "a.mov", file: URL(fileURLWithPath: "/t/x.mov")), "a.mov")
        XCTAssertEqual(ItemProviderImport.displayName(suggested: nil, file: URL(fileURLWithPath: "/t/x.mov")), "x.mov")
        XCTAssertEqual(ItemProviderImport.displayName(suggested: "IMG_2.jpg", file: URL(fileURLWithPath: "/t/x.jpeg")), "IMG_2.jpg")
        XCTAssertEqual(ItemProviderImport.displayName(suggested: "IMG_3.png", file: URL(fileURLWithPath: "/t/x.jpeg")), "IMG_3.png.jpeg")
    }

    func testCloneIntoWorkMakesAnIndependentCopy() throws {
        let source = fixture.roots.base.appendingPathComponent("src.bin")
        try writePatternFile(source, size: 100_000)
        let copy = try ItemProviderImport.cloneIntoWork(source, directory: fixture.paths.workPicks, name: "src.bin")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: copy).count, 100_000)
    }

    // MARK: Files

    func testDocumentTypesPerKind() {
        XCTAssertEqual(MediaPicker.documentTypes([.video]), [.movie])
        XCTAssertEqual(Set(MediaPicker.documentTypes([.video, .audio, .image])), [.movie, .audio, .image])
        XCTAssertTrue(MediaPicker.documentTypes([.lut]).contains(.data), ".cube via public.data")
        XCTAssertTrue(MediaPicker.documentTypes([.subtitle]).contains(.data))
    }

    func testFilesItemsCarryBookmarksAndSkipWrongExtensions() throws {
        let cube = fixture.roots.base.appendingPathComponent("Files/look.cube")
        let pdf = fixture.roots.base.appendingPathComponent("Files/manual.pdf")
        let clip = fixture.roots.base.appendingPathComponent("Files/clip.mp4")
        for url in [cube, pdf, clip] { try writePatternFile(url, size: 64) }
        let items = MediaPicker.filesItems([cube, pdf, clip], kinds: [.lut, .video])
        XCTAssertEqual(items.map(\.displayName), ["look.cube", "clip.mp4"])
        for item in items {
            XCTAssertEqual(item.origin, .files)
            XCTAssertFalse(item.isTemporaryCopy)
            XCTAssertEqual(item.sizeBytes, 64)
            let bookmark = try XCTUnwrap(item.bookmark)
            let resolved = try MediaAccess(context: fixture.context).resolve(bookmark.data)
            XCTAssertEqual(resolved.url.lastPathComponent, item.displayName)
        }
    }

    func testPickWithoutPresenterFails() throws {
        let context = EngineContext(messenger: FakeMessenger(), textures: nil, presentingViewController: { nil })
        try context.configure(cacheRoot: fixture.roots.cache.path, supportRoot: fixture.roots.support.path)
        let picker = MediaPicker(context: context)
        let error = awaitFailure(self) { picker.pick(request(.files, [.video]), reply: $0) }
        XCTAssertEqual(error?.code, .internal)
    }
}
