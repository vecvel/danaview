// OWNER: IOS-13
//
// IOS-13 acceptance for the destinations (ARCH §14.1, §14.2): Photos add-only saves work without
// full library access (fake library: authorized / prompt / denied / failure; a real add-only save
// runs when the simulator has granted add-only access, e.g. `xcrun simctl privacy <udid> grant
// photos-add com.vecvel.danaview.editor.engine.danaviewEditorEngineExample`, and is skipped otherwise); the Files
// export and the share sheet return their results (the system sheets are driven through their
// delegate and completion handler); the source file is never moved or deleted (Dart deletes it
// via OwnedFileDeleter).

import Photos
import UIKit
import XCTest

@testable import danaview_editor_engine

final class HandoffTests: XCTestCase {
    private var roots: TempRoots!
    private var source: URL!

    override func setUpWithError() throws {
        roots = try TempRoots()
        source = roots.cache.appendingPathComponent("work/export-ex_test.mp4")
        try writePatternFile(source, size: 4096)
    }

    override func tearDown() {
        roots.remove()
    }

    private func sourceUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source kept for OwnedFileDeleter", file: file, line: line)
        XCTAssertEqual((try? Data(contentsOf: source))?.count, 4096, file: file, line: line)
    }

    // MARK: Photos (add-only)

    func testPhotosSaveWithAddOnlyAccess() throws {
        let library = FakePhotoLibrary(status: .authorized)
        let saver = PhotosSaver(context: nil, library: library)
        let result = try awaitReply(self) { saver.saveToPhotos(fileURL: source, reply: $0) }
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(result.savedUri, "FAKE-ASSET-1/L0/001")
        XCTAssertEqual(library.added, [source])
        XCTAssertEqual(library.requests, 0)
        sourceUntouched()
    }

    func testPhotosPromptsOnceWhenUndetermined() throws {
        let library = FakePhotoLibrary(status: .notDetermined)
        let saver = PhotosSaver(context: nil, library: library)
        XCTAssertFalse(saver.isAuthorized)
        let result = try awaitReply(self) { saver.saveToPhotos(fileURL: source, reply: $0) }
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(library.requests, 1)
        XCTAssertTrue(saver.isAuthorized)
        _ = try awaitReply(self) { saver.saveToPhotos(fileURL: source, reply: $0) }
        XCTAssertEqual(library.requests, 1, "asked once")
    }

    func testPhotosDeniedIsPermissionDenied() {
        for status in [PHAuthorizationStatus.denied, .restricted] {
            let library = FakePhotoLibrary(status: status)
            let saver = PhotosSaver(context: nil, library: library)
            XCTAssertEqual(awaitFailure(self) { saver.saveToPhotos(fileURL: source, reply: $0) }?.code, .permissionDenied)
            XCTAssertTrue(library.added.isEmpty)
        }
        let refused = FakePhotoLibrary(status: .notDetermined)
        refused.answer = .denied
        XCTAssertEqual(awaitFailure(self) { PhotosSaver(context: nil, library: refused).saveToPhotos(fileURL: source, reply: $0) }?.code,
                       .permissionDenied)
        let revoked = FakePhotoLibrary(status: .authorized)
        revoked.failure = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue)
        XCTAssertEqual(awaitFailure(self) { PhotosSaver(context: nil, library: revoked).saveToPhotos(fileURL: source, reply: $0) }?.code,
                       .permissionDenied)
        sourceUntouched()
    }

    func testPhotosFailuresAndMissingFile() {
        let library = FakePhotoLibrary(status: .authorized)
        library.failure = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.invalidResource.rawValue)
        let failure = awaitFailure(self) { PhotosSaver(context: nil, library: library).saveToPhotos(fileURL: source, reply: $0) }
        XCTAssertNotNil(failure)
        XCTAssertNotEqual(failure?.code, .permissionDenied)
        let missing = roots.cache.appendingPathComponent("work/none.mp4")
        XCTAssertEqual(awaitFailure(self) {
            PhotosSaver(context: nil, library: FakePhotoLibrary(status: .authorized)).saveToPhotos(fileURL: missing, reply: $0)
        }?.code, .mediaOffline)
    }

    func testDetachedSaveNeverPrompts() {
        let library = FakePhotoLibrary(status: .notDetermined)
        let saver = PhotosSaver(context: nil, library: library)
        let done = expectation(description: "detached")
        saver.saveDetached(fileURL: source) { saved, identifier in
            XCTAssertFalse(saved)
            XCTAssertNil(identifier)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(library.requests, 0)
    }

    /// A real add-only save on the simulator (needs `simctl privacy grant photos-add`).
    func testRealAddOnlySaveWhenGranted() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("add-only Photos access not granted on this simulator")
        }
        // Full library access is never needed.
        let video = try XCTUnwrap(TestFixtures.url(.engine, "media/frame_counter_720p25.mp4"))
        let copy = roots.cache.appendingPathComponent("work/export-ex_real.mp4")
        try FileManager.default.copyItem(at: video, to: copy)
        let saver = PhotosSaver(context: nil, library: SystemPhotoLibrary())
        let result = try awaitReply(self, timeout: 30) { saver.saveToPhotos(fileURL: copy, reply: $0) }
        XCTAssertEqual(result.outcome, .done)
        XCTAssertNotNil(result.savedUri)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    // MARK: Files

    private func handoff(_ presented: @escaping (UIViewController) -> Void = { _ in }) -> FileHandoff {
        FileHandoff(context: nil, stagingRoot: roots.cache.appendingPathComponent("work")) { controller in
            presented(controller)
            return true
        }
    }

    private func stagingDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: roots.cache.appendingPathComponent("work").path)) ?? [])
            .filter { $0.hasPrefix("handoff-") }
    }

    func testSaveToFilesExportsACopyUnderTheSuggestedName() throws {
        var shown: UIViewController?
        let files = handoff { shown = $0 }
        var result: Result<FileHandoffResultMsg, Error>?
        files.saveToFiles(fileURL: source, suggestedName: "Holiday 2026") { result = $0 }
        let picker = try XCTUnwrap(shown as? UIDocumentPickerViewController)
        XCTAssertTrue(picker.delegate === files)
        XCTAssertEqual(picker.documentPickerMode, .exportToService, "asCopy: true")
        XCTAssertEqual(stagingDirectories().count, 1, "staged under the suggested name")
        let staged = roots.cache.appendingPathComponent("work").appendingPathComponent(stagingDirectories()[0])
            .appendingPathComponent("Holiday 2026.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(result)
        let destination = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/Holiday 2026.mp4")
        files.documentPicker(picker, didPickDocumentsAt: [destination])
        let answer = try XCTUnwrap(result).get()
        XCTAssertEqual(answer.outcome, .done)
        XCTAssertEqual(answer.savedUri, destination.absoluteString)
        XCTAssertTrue(stagingDirectories().isEmpty, "staging copy removed")
        XCTAssertNil(files.presentedController)
        sourceUntouched()
        // A late second answer is ignored.
        files.documentPickerWasCancelled(picker)
    }

    func testSaveToFilesCancelledAndBusy() throws {
        var shown: UIViewController?
        let files = handoff { shown = $0 }
        var result: Result<FileHandoffResultMsg, Error>?
        files.saveToFiles(fileURL: source, suggestedName: "export-ex_test.mp4") { result = $0 }
        XCTAssertTrue(stagingDirectories().isEmpty, "same name: no staging copy")
        XCTAssertEqual(awaitFailure(self) { files.share(fileURL: source, reply: $0) }?.code, .busy)
        files.documentPickerWasCancelled(try XCTUnwrap(shown as? UIDocumentPickerViewController))
        XCTAssertEqual(try XCTUnwrap(result).get().outcome, .cancelled)
        sourceUntouched()
    }

    func testExportNameKeepsTheExtensionAndDropsSeparators() {
        XCTAssertEqual(FileHandoff.exportName("My/Film", source: source), "My-Film.mp4")
        XCTAssertEqual(FileHandoff.exportName("clip.mov", source: source), "clip.mov")
        XCTAssertEqual(FileHandoff.exportName("  ", source: source), "export-ex_test.mp4")
    }

    func testNoPresenterIsNotSupportedAndMissingFileIsOffline() {
        let files = FileHandoff(context: nil, stagingRoot: roots.cache.appendingPathComponent("work")) { _ in false }
        XCTAssertEqual(awaitFailure(self) { files.saveToFiles(fileURL: source, suggestedName: "x", reply: $0) }?.code, .notSupportedOnDevice)
        XCTAssertTrue(stagingDirectories().isEmpty)
        XCTAssertEqual(awaitFailure(self) { files.share(fileURL: source, reply: $0) }?.code, .notSupportedOnDevice)
        let missing = roots.cache.appendingPathComponent("work/none.mp4")
        XCTAssertEqual(awaitFailure(self) { handoff().share(fileURL: missing, reply: $0) }?.code, .mediaOffline)
        sourceUntouched()
    }

    // MARK: Share

    func testShareSheetReturnsDoneCancelledAndFailure() throws {
        var shown: UIViewController?
        let files = handoff { shown = $0 }

        var result: Result<FileHandoffResultMsg, Error>?
        files.share(fileURL: source) { result = $0 }
        var sheet = try XCTUnwrap(shown as? UIActivityViewController)
        sheet.completionWithItemsHandler?(.airDrop, true, nil, nil)
        XCTAssertEqual(try XCTUnwrap(result).get().outcome, .done)
        XCTAssertEqual(try XCTUnwrap(result).get().savedUri, UIActivity.ActivityType.airDrop.rawValue)

        result = nil
        files.share(fileURL: source) { result = $0 }
        sheet = try XCTUnwrap(shown as? UIActivityViewController)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertEqual(try XCTUnwrap(result).get().outcome, .cancelled)

        result = nil
        files.share(fileURL: source) { result = $0 }
        sheet = try XCTUnwrap(shown as? UIActivityViewController)
        sheet.completionWithItemsHandler?(.mail, false, nil, NSError(domain: "test", code: 7))
        XCTAssertThrowsError(try XCTUnwrap(result).get()) { XCTAssertEqual(EngineError.from($0).code, .io) }
        XCTAssertNil(files.presentedController)
        sourceUntouched()
    }

    func testPopoverAnchorOnIPad() {
        let presenter = UIViewController()
        presenter.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sheet = UIActivityViewController(activityItems: [source!], applicationActivities: nil)
        sheet.modalPresentationStyle = .popover
        FileHandoff.anchor(sheet, in: presenter)
        XCTAssertTrue(sheet.popoverPresentationController?.sourceView === presenter.view)
        XCTAssertEqual(sheet.popoverPresentationController?.sourceRect.origin, CGPoint(x: 400, y: 300))
    }
}
