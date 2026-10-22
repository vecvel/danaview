// OWNER: HOM-22
//
// XCTests of ExportOutHostApiImpl linked against FlutterMacOS (BUILD_PLAN HOM-22; ARCH v1.2 rule
// 26, V2-117): Save to Files writes create-new copies and never moves the library file, the
// temporary copies handed to the system picker are cleaned up whatever the user does, a cancel is
// reported, Save to Photos receives only photos and videos (add-only saver), Save to Downloads is
// Android only, bad requests and a second export are refused. The panels and pickers themselves
// need a person (device check); a fake presenter stands in for them.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class ExportOutGlueTests: FileOutTestCase {
  private final class FakePresenter: ExportPresenter {
    var answer: Result<ExportPick, OutFailure> = .success(.cancelled)
    var hold = false
    var seen: [TempBatch] = []
    var held: ((Result<ExportPick, OutFailure>) -> Void)?
    var copiesWhilePresented: [Data] = []

    func presentExport(files: [OutFile], batch: TempBatch, anchor: CGRect?, completion: @escaping (Result<ExportPick, OutFailure>) -> Void) {
      seen.append(batch)
      copiesWhilePresented = batch.urls.compactMap { try? Data(contentsOf: $0) }
      if hold { held = completion } else { completion(answer) }
    }
  }

  private final class FakeSaver: PhotoSaver {
    var received: [(file: OutFile, kind: OutMediaKind)] = []
    var answer: Result<[String?], OutFailure>?

    func save(_ items: [(file: OutFile, kind: OutMediaKind)], completion: @escaping (Result<[String?], OutFailure>) -> Void) {
      received = items
      DispatchQueue.global().async { [answer] in
        completion(answer ?? .success(items.enumerated().map { "asset-\($0.offset)" }))
      }
    }
  }

  private var presenter: FakePresenter!
  private var saver: FakeSaver!
  private var api: ExportOutHostApiImpl!

  override func setUpWithError() throws {
    try super.setUpWithError()
    presenter = FakePresenter()
    saver = FakeSaver()
    api = ExportOutHostApiImpl(presenter: presenter, photoSaver: saver, temp: tempStore())
  }

  private func save(_ items: [FileItemMsg], _ destination: SaveOutDestinationMsg = .files) -> Result<SaveOutResultMsg, Error> {
    replyOf { api.saveOut(request: SaveOutRequestMsg(items: items, destination: destination), completion: $0) }
  }

  func testSaveToFilesWritesNewCopiesAndNeverMovesTheLibraryFile() throws {
    let a = try libraryItem("Report.pdf")
    let b = try libraryItem("Scan.png", "png bytes")
    let out = dir.appendingPathComponent("Chosen folder", isDirectory: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    try Data("already here".utf8).write(to: out.appendingPathComponent("Report.pdf"))
    presenter.answer = .success(.directory(out, names: nil))

    let r = try save([a, b]).get()
    XCTAssertFalse(r.cancelled)
    XCTAssertEqual(r.failedCount, 0)
    XCTAssertEqual(r.savedUris.map { URL(string: $0)!.lastPathComponent }, ["Report (2).pdf", "Scan.png"])
    XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Report (2).pdf")), Data("library bytes".utf8))
    XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Report.pdf")), Data("already here".utf8), "create-new only")
    try assertUnchanged(a)
    try assertUnchanged(b, "png bytes")
    XCTAssertEqual(presenter.copiesWhilePresented, [Data("library bytes".utf8), Data("png bytes".utf8)])
    XCTAssertFalse(fm.fileExists(atPath: presenter.seen[0].directory.path), "temporary copies are cleaned up")
  }

  func testSavePanelNameIsUsedAndAnExistingFileIsNotReplaced() throws {
    let a = try libraryItem("Report.pdf")
    let out = dir.appendingPathComponent("Desktop", isDirectory: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    try Data("theirs".utf8).write(to: out.appendingPathComponent("Final.pdf"))
    presenter.answer = .success(.directory(out, names: ["Final.pdf"]))
    let r = try save([a]).get()
    XCTAssertEqual(URL(string: r.savedUris[0])!.lastPathComponent, "Final (2).pdf")
    XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Final.pdf")), Data("theirs".utf8))
    try assertUnchanged(a)
  }

  func testSystemExportedAndCancelledAreReportedAndCleanedUp() throws {
    let a = try libraryItem("A.txt")
    presenter.answer = .success(.exported([URL(fileURLWithPath: "/Users/x/Documents/A.txt")]))
    let exported = try save([a]).get()
    XCTAssertEqual(exported.savedUris, ["file:///Users/x/Documents/A.txt"])
    XCTAssertFalse(exported.cancelled)

    presenter.answer = .success(.cancelled)
    let cancelled = try save([a]).get()
    XCTAssertTrue(cancelled.cancelled)
    XCTAssertTrue(cancelled.savedUris.isEmpty)
    XCTAssertTrue(tempStore().batches().isEmpty, "every batch removed")
    try assertUnchanged(a)
  }

  func testPresenterFailureMapsToItsCode() throws {
    presenter.answer = .failure(.io("no window"))
    XCTAssertEqual(code(save([try libraryItem("A.txt")])), "ioError")
    XCTAssertTrue(tempStore().batches().isEmpty)
  }

  func testBadRequestsAreRefusedBeforeAnyUI() throws {
    XCTAssertEqual(code(save([])), "invalidArgument")
    XCTAssertEqual(code(save([FileItemMsg(path: dir.appendingPathComponent("gone.pdf").path, displayName: "gone.pdf")])), "notFound")
    XCTAssertEqual(code(save([try libraryItem("A.txt")], .downloads)), "notSupportedOnDevice", "Save to Downloads is Android only")
    XCTAssertTrue(presenter.seen.isEmpty)
  }

  func testASecondExportWhileOneIsOpenIsBusy() throws {
    let a = try libraryItem("A.txt")
    presenter.hold = true
    var first: Result<SaveOutResultMsg, Error>?
    api.saveOut(request: SaveOutRequestMsg(items: [a], destination: .files)) { first = $0 }
    XCTAssertEqual(code(save([a])), "busy")
    presenter.held?(.success(.cancelled))
    XCTAssertEqual(try first?.get().cancelled, true)
    presenter.hold = false
    XCTAssertNil(code(save([a])), "free again after the first finished")
  }

  func testSaveToPhotosHandsOnlyMediaToTheAddOnlySaver() throws {
    let photo = try libraryItem("IMG_1.HEIC", "heic", uti: "public.heic")
    let video = try libraryItem("clip.mov", "mov", mime: "video/quicktime")
    let pdf = try libraryItem("doc.pdf", "pdf", uti: "com.adobe.pdf")
    let r = try save([photo, pdf, video], .photos).get()
    XCTAssertEqual(saver.received.map { $0.file.displayName }, ["IMG_1.HEIC", "clip.mov"])
    XCTAssertEqual(saver.received.map { $0.kind }, [.photo, .video])
    XCTAssertEqual(saver.received[0].file.path, photo.path, "the saver copies (shouldMoveFile = false); no temp copy needed")
    XCTAssertEqual(r.savedUris, ["asset-0", "asset-1"])
    XCTAssertEqual(r.failedCount, 1, "the PDF can't go to Photos")
    try assertUnchanged(photo, "heic")
    try assertUnchanged(video, "mov")

    saver.answer = .success(["asset-0", nil])
    XCTAssertEqual(try save([photo, video], .photos).get().failedCount, 1)
    saver.answer = .failure(.denied("no"))
    XCTAssertEqual(code(save([photo], .photos)), "permissionDenied")
    XCTAssertEqual(try save([pdf], .photos).get().failedCount, 1)
  }
}
