// OWNER: HOM-22
//
// XCTests of ShareHostApiImpl linked against FlutterMacOS (BUILD_PLAN HOM-22; V2-118, HOM plan
// §8.3): the share sheet receives temporary read-only copies, never the library file; the copies
// are cleaned up when the system releases them (at once on iOS, after the service finished on
// macOS); failures clean up and map to their code; a second sheet is busy. The sheet itself needs
// a person (device check); a fake presenter stands in for it.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class ShareGlueTests: FileOutTestCase {
  private final class FakePresenter: SharePresenter {
    var urls: [URL] = []
    var subject: String?
    var chosen: ((Result<ShareOutcome, OutFailure>) -> Void)?
    var released: (() -> Void)?

    func presentShare(urls: [URL], subject: String?, anchor: CGRect?, chosen: @escaping (Result<ShareOutcome, OutFailure>) -> Void, released: @escaping () -> Void) {
      self.urls = urls
      self.subject = subject
      self.chosen = chosen
      self.released = released
    }
  }

  private var presenter: FakePresenter!
  private var api: ShareHostApiImpl!

  override func setUpWithError() throws {
    try super.setUpWithError()
    presenter = FakePresenter()
    api = ShareHostApiImpl(presenter: presenter, temp: tempStore())
  }

  /// Waits for the main queue to run what is queued on it.
  private func drainMain() {
    let e = expectation(description: "main")
    DispatchQueue.main.async { e.fulfill() }
    wait(for: [e], timeout: 5)
  }

  func testTheSheetGetsReadOnlyTemporaryCopiesThatAreCleanedUp() throws {
    let a = try libraryItem("Holiday.jpg", "jpeg")
    let b = try libraryItem("Notes.txt", "notes")
    var reply: Result<ShareResultMsg, Error>?
    api.share(request: ShareRequestMsg(items: [a, b], subject: "Two files")) { reply = $0 }

    XCTAssertEqual(presenter.urls.map { $0.lastPathComponent }, ["Holiday.jpg", "Notes.txt"])
    XCTAssertEqual(presenter.subject, "Two files")
    for (url, item) in zip(presenter.urls, [a, b]) {
      XCTAssertNotEqual(url.path, item.path, "never the library file")
      XCTAssertTrue(url.path.hasPrefix(tempStore().root.path))
      XCTAssertFalse(fm.isWritableFile(atPath: url.path), "read-only")
    }
    XCTAssertEqual(try Data(contentsOf: presenter.urls[0]), Data("jpeg".utf8))

    presenter.chosen?(.success(ShareOutcome(completed: true, activityType: "com.apple.UIKit.activity.AirDrop")))
    let r = try XCTUnwrap(reply).get()
    XCTAssertTrue(r.completed)
    XCTAssertEqual(r.activityType, "com.apple.UIKit.activity.AirDrop")
    XCTAssertTrue(fm.fileExists(atPath: presenter.urls[0].path), "kept until the system releases them (macOS services read later)")

    presenter.released?()
    drainMain()
    XCTAssertFalse(fm.fileExists(atPath: presenter.urls[0].deletingLastPathComponent().path), "the temporary copies are cleaned up")
    XCTAssertTrue(tempStore().batches().isEmpty)
    try assertUnchanged(a, "jpeg")
    try assertUnchanged(b, "notes")
  }

  func testCancelledSheetReportsNotCompleted() throws {
    let a = try libraryItem("A.pdf")
    let r = replyOf { (done: @escaping (Result<ShareResultMsg, Error>) -> Void) in
      self.api.share(request: ShareRequestMsg(items: [a]), completion: done)
      self.presenter.chosen?(.success(ShareOutcome(completed: false, activityType: nil)))
      self.presenter.released?()
    }
    XCTAssertFalse(try r.get().completed)
    drainMain()
    XCTAssertTrue(tempStore().batches().isEmpty)
  }

  func testFailureCleansUpAndMapsItsCode() throws {
    let a = try libraryItem("A.pdf")
    let r = replyOf { (done: @escaping (Result<ShareResultMsg, Error>) -> Void) in
      self.api.share(request: ShareRequestMsg(items: [a]), completion: done)
      self.presenter.chosen?(.failure(.io("no window")))
    }
    XCTAssertEqual(code(r), "ioError")
    XCTAssertTrue(tempStore().batches().isEmpty)
  }

  func testBadRequestsAndBusy() throws {
    XCTAssertEqual(code(replyOf { api.share(request: ShareRequestMsg(items: []), completion: $0) }), "invalidArgument")
    let missing = FileItemMsg(path: dir.appendingPathComponent("gone.jpg").path, displayName: "gone.jpg")
    XCTAssertEqual(code(replyOf { api.share(request: ShareRequestMsg(items: [missing]), completion: $0) }), "notFound")
    XCTAssertTrue(presenter.urls.isEmpty)

    let a = try libraryItem("A.pdf")
    api.share(request: ShareRequestMsg(items: [a])) { _ in }
    XCTAssertEqual(code(replyOf { api.share(request: ShareRequestMsg(items: [a]), completion: $0) }), "busy")
    presenter.chosen?(.success(ShareOutcome(completed: true)))
    presenter.released?()
    drainMain()
    XCTAssertTrue(tempStore().batches().isEmpty)
  }
}
