// OWNER: HOM-22
//
// Shared support of the HOM-22 glue XCTests (ExportOut, Share, OpenIn): a temp directory with
// generated "library" files and a helper to wait for a Pigeon reply on the main thread.

import Foundation
import XCTest

@testable import danaview_library_native

class FileOutTestCase: XCTestCase {
  var dir: URL!
  let fm = FileManager.default
  let mtime = Date(timeIntervalSince1970: 1_577_934_245)

  override func setUpWithError() throws {
    dir = fm.temporaryDirectory.appendingPathComponent("hom22-glue-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: dir)
  }

  /// A temp-copy store under the test directory.
  func tempStore() -> TempCopyStore {
    TempCopyStore(root: dir.appendingPathComponent("danaview-out", isDirectory: true))
  }

  /// A generated library file `files/<id>/<name>` holding [text].
  func libraryItem(_ name: String, _ text: String = "library bytes", uti: String? = nil, mime: String? = nil) throws -> FileItemMsg {
    let entry = dir.appendingPathComponent("DanaviewLibrary/files/fe_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try fm.createDirectory(at: entry, withIntermediateDirectories: true)
    let url = entry.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    return FileItemMsg(path: url.path, displayName: name, mimeType: mime, uti: uti)
  }

  /// Asserts the library file is where it was, with its bytes and timestamp.
  func assertUnchanged(_ item: FileItemMsg, _ text: String = "library bytes", file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertTrue(fm.fileExists(atPath: item.path), "never moves the library file", file: file, line: line)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.path)), Data(text.utf8), file: file, line: line)
    XCTAssertEqual(try fm.attributesOfItem(atPath: item.path)[.modificationDate] as? Date, mtime, file: file, line: line)
  }

  /// Runs [call] and waits for its reply, asserting it arrives on the main thread.
  func replyOf<T>(_ call: (@escaping (Result<T, Error>) -> Void) -> Void, file: StaticString = #filePath, line: UInt = #line) -> Result<T, Error> {
    let done = expectation(description: "reply")
    var out: Result<T, Error>?
    call { result in
      XCTAssertTrue(Thread.isMainThread, "replies on the main thread", file: file, line: line)
      out = result
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return out!
  }

  /// The Pigeon error code of [result], or nil on success.
  func code<T>(_ result: Result<T, Error>) -> String? {
    if case .failure(let e) = result { return (e as? LibraryPigeonError)?.code ?? "other" }
    return nil
  }
}
