// OWNER: HOM-22
//
// XCTests of OpenInHostApiImpl linked against FlutterMacOS (BUILD_PLAN HOM-22; V2-117, HOM plan
// §8.3): the other app receives a temporary read-only copy, never the library file; the copy goes
// when the menu closes without a choice, when the chosen app has it (iOS), or is left to the start
// sweep when the release can't be known (macOS); failures clean up; a second menu is busy. The
// system menu itself needs a person (device check); a fake presenter stands in for it.

import FlutterMacOS
import XCTest

@testable import danaview_library_native

final class OpenInGlueTests: FileOutTestCase {
  private final class FakePresenter: OpenInPresenter {
    var reportsRelease = true
    var url: URL?
    var uti: String?
    var shown: ((Result<Bool, OutFailure>) -> Void)?
    var released: (() -> Void)?

    func presentOpenIn(url: URL, uti: String?, anchor: CGRect?, shown: @escaping (Result<Bool, OutFailure>) -> Void, released: @escaping () -> Void) {
      self.url = url
      self.uti = uti
      self.shown = shown
      self.released = released
    }
  }

  private var presenter: FakePresenter!
  private var api: OpenInHostApiImpl!

  override func setUpWithError() throws {
    try super.setUpWithError()
    presenter = FakePresenter()
    api = OpenInHostApiImpl(presenter: presenter, temp: tempStore())
  }

  private func drainMain() {
    let e = expectation(description: "main")
    DispatchQueue.main.async { e.fulfill() }
    wait(for: [e], timeout: 5)
  }

  private func open(_ item: FileItemMsg, then: @escaping () -> Void) -> Result<Bool, Error> {
    replyOf { (done: @escaping (Result<Bool, Error>) -> Void) in
      self.api.openIn(request: OpenInRequestMsg(item: item), completion: done)
      then()
    }
  }

  func testTheOtherAppGetsAReadOnlyCopyRemovedWhenItHasIt() throws {
    let doc = try libraryItem("Budget.xlsx", "cells", uti: "org.openxmlformats.spreadsheetml.sheet")
    let r = open(doc) { self.presenter.shown?(.success(true)) }
    XCTAssertTrue(try r.get())
    let url = try XCTUnwrap(presenter.url)
    XCTAssertNotEqual(url.path, doc.path)
    XCTAssertEqual(url.lastPathComponent, "Budget.xlsx")
    XCTAssertEqual(presenter.uti, "org.openxmlformats.spreadsheetml.sheet")
    XCTAssertFalse(fm.isWritableFile(atPath: url.path), "read-only grant")
    XCTAssertTrue(fm.fileExists(atPath: url.path), "kept while the menu is open")
    XCTAssertEqual(code(open(doc) {}), "busy", "one menu at a time")

    presenter.released?()
    drainMain()
    XCTAssertFalse(fm.fileExists(atPath: url.path), "cleaned up once the app has it")
    try assertUnchanged(doc, "cells")
    XCTAssertNil(code(open(doc) { self.presenter.shown?(.success(false)) }), "free again")
  }

  func testNoAppForTheFileRemovesTheCopyAtOnce() throws {
    let doc = try libraryItem("Odd.xyz")
    XCTAssertFalse(try open(doc) { self.presenter.shown?(.success(false)) }.get())
    XCTAssertTrue(tempStore().batches().isEmpty)
  }

  func testWhenReleaseIsUnknownTheCopyWaitsForTheSweepButTheApiIsFree() throws {
    presenter.reportsRelease = false
    let doc = try libraryItem("Deck.key")
    XCTAssertTrue(try open(doc) { self.presenter.shown?(.success(true)) }.get())
    XCTAssertEqual(tempStore().batches().count, 1, "the app may still be reading it")
    XCTAssertNil(code(open(doc) { self.presenter.shown?(.success(true)) }), "not busy")
    for b in tempStore().batches() {
      try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 24 * 3600)], ofItemAtPath: b.path)
    }
    XCTAssertEqual(tempStore().sweepStale(), 2)
  }

  func testFailuresCleanUpAndMapTheirCode() throws {
    let doc = try libraryItem("A.pdf")
    XCTAssertEqual(code(open(doc) { self.presenter.shown?(.failure(.io("no window"))) }), "ioError")
    XCTAssertTrue(tempStore().batches().isEmpty)
    let missing = FileItemMsg(path: dir.appendingPathComponent("gone.pdf").path, displayName: "gone.pdf")
    XCTAssertEqual(code(open(missing) {}), "notFound")
  }
}
