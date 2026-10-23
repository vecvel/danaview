// OWNER: HOM-22
//
// XCTests of the file-out core (BUILD_PLAN HOM-22; ARCH v1.2 rule 26, V2-117, V2-118): safe names,
// create-new destinations, Save to Files copies that never move or change the library file,
// temporary read-only share copies and their cleanup, the stale sweep and the media kind used by
// Save to Photos. Every file is generated here (local test media only).

import Foundation
import XCTest

@testable import DanaviewFileOutCore

final class FileOutCoreTests: XCTestCase {
  private var dir: URL!
  private let fm = FileManager.default
  private let mtime = Date(timeIntervalSince1970: 1_577_934_245)

  override func setUpWithError() throws {
    dir = fm.temporaryDirectory.appendingPathComponent("hom22-core-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Read-only copies are removable (the directory is writable).
    try? fm.removeItem(at: dir)
  }

  private func libraryFile(_ name: String, _ text: String = "library bytes") throws -> OutFile {
    let entryDir = dir.appendingPathComponent("library/files/fe_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try fm.createDirectory(at: entryDir, withIntermediateDirectories: true)
    let url = entryDir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    return OutFile(path: url.path, displayName: name, uti: nil, mimeType: nil)
  }

  private func assertUnchanged(_ f: OutFile, _ text: String = "library bytes", file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertTrue(fm.fileExists(atPath: f.path), "the library file is still there", file: file, line: line)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.path)), Data(text.utf8), file: file, line: line)
    let attrs = try fm.attributesOfItem(atPath: f.path)
    XCTAssertEqual(attrs[.modificationDate] as? Date, mtime, "timestamps untouched", file: file, line: line)
  }

  func testSafeName() {
    XCTAssertEqual(FileOutCore.safeName("Report.pdf"), "Report.pdf")
    XCTAssertEqual(FileOutCore.safeName("a/b:c\\d.txt"), "a_b_c_d.txt")
    XCTAssertEqual(FileOutCore.safeName("..hidden"), "hidden")
    XCTAssertEqual(FileOutCore.safeName("  "), "file")
    XCTAssertEqual(FileOutCore.safeName("tab\there"), "tab_here")
    let long = String(repeating: "é", count: 200) + ".jpeg"
    let safe = FileOutCore.safeName(long)
    XCTAssertLessThanOrEqual(safe.utf8.count, 255)
    XCTAssertTrue(safe.hasSuffix(".jpeg"))
  }

  func testNumberedAndUniqueDestination() throws {
    XCTAssertEqual(FileOutCore.numbered("A.pdf", 1), "A.pdf")
    XCTAssertEqual(FileOutCore.numbered("A.pdf", 3), "A (3).pdf")
    XCTAssertEqual(FileOutCore.numbered("Notes", 2), "Notes (2)")
    let out = dir.appendingPathComponent("out", isDirectory: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    XCTAssertEqual(FileOutCore.uniqueDestination(in: out, name: "A.pdf").lastPathComponent, "A.pdf")
    try Data("x".utf8).write(to: out.appendingPathComponent("A.pdf"))
    try Data("x".utf8).write(to: out.appendingPathComponent("A (2).pdf"))
    XCTAssertEqual(FileOutCore.uniqueDestination(in: out, name: "A.pdf").lastPathComponent, "A (3).pdf")
  }

  func testValidate() throws {
    func code(_ files: [OutFile]) -> String? {
      do { try FileOutCore.validate(files); return nil } catch let f as OutFailure { return f.code } catch { return "other" }
    }
    XCTAssertEqual(code([]), "invalidArgument")
    XCTAssertEqual(code([OutFile(path: "relative.pdf", displayName: "a")]), "invalidArgument")
    XCTAssertEqual(code([OutFile(path: dir.appendingPathComponent("missing.pdf").path, displayName: "a")]), "notFound")
    XCTAssertEqual(code([OutFile(path: dir.path, displayName: "a")]), "notFound", "a directory is not a file")
    XCTAssertNil(code([try libraryFile("ok.pdf")]))
  }

  func testExportCopyIsCreateNewAndNeverMovesTheLibraryFile() throws {
    let src = try libraryFile("Report.pdf")
    let out = dir.appendingPathComponent("Files", isDirectory: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let existing = out.appendingPathComponent("Report.pdf")
    try Data("someone else's file".utf8).write(to: existing)

    let copy = try FileOutCore.exportCopy(src, toDirectory: out)
    XCTAssertEqual(copy.lastPathComponent, "Report (2).pdf")
    XCTAssertEqual(try Data(contentsOf: copy), Data("library bytes".utf8))
    XCTAssertEqual(try Data(contentsOf: existing), Data("someone else's file".utf8), "never writes over a file it didn't create")
    try assertUnchanged(src)

    var renamed = src
    renamed.displayName = "Chosen name.pdf"
    XCTAssertEqual(try FileOutCore.exportCopy(renamed, toDirectory: out).lastPathComponent, "Chosen name.pdf")
    try assertUnchanged(src)
  }

  func testTempBatchHoldsReadOnlyCopiesUnderDisplayNames() throws {
    let a = try libraryFile("Photo.heic", "a")
    var b = try libraryFile("Photo.heic", "b")
    b.displayName = "photo.HEIC" // the same name, case-insensitively
    let store = TempCopyStore(root: dir.appendingPathComponent("danaview-out", isDirectory: true))
    let batch = try store.makeBatch([a, b])

    XCTAssertEqual(batch.urls.map { $0.lastPathComponent }, ["Photo.heic", "photo (2).HEIC"])
    XCTAssertEqual(batch.directory.deletingLastPathComponent().standardizedFileURL, store.root.standardizedFileURL)
    for (url, text) in zip(batch.urls, ["a", "b"]) {
      XCTAssertNotEqual(url.path, a.path)
      XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
      let perms = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
      XCTAssertEqual(perms?.int16Value, 0o444, "the copy is read-only")
      XCTAssertFalse(fm.isWritableFile(atPath: url.path))
      XCTAssertThrowsError(try Data("changed".utf8).write(to: url), "a receiver can't change the copy")
    }
    try assertUnchanged(a, "a")
    try assertUnchanged(b, "b")

    store.remove(batch)
    XCTAssertFalse(fm.fileExists(atPath: batch.directory.path), "the batch is cleaned up")
    XCTAssertTrue(store.batches().isEmpty)
    try assertUnchanged(a, "a")
  }

  func testFailedBatchLeavesNothingBehind() throws {
    let ok = try libraryFile("ok.pdf")
    let store = TempCopyStore(root: dir.appendingPathComponent("danaview-out", isDirectory: true))
    XCTAssertThrowsError(try store.makeBatch([ok, OutFile(path: dir.appendingPathComponent("gone.pdf").path, displayName: "gone.pdf")])) { e in
      XCTAssertEqual((e as? OutFailure)?.code, "notFound")
    }
    XCTAssertTrue(store.batches().isEmpty)
  }

  func testRemoveRefusesDirectoriesOutsideTheRoot() throws {
    let store = TempCopyStore(root: dir.appendingPathComponent("danaview-out", isDirectory: true))
    let outside = dir.appendingPathComponent("library", isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    store.remove(TempBatch(directory: outside, urls: []))
    XCTAssertTrue(fm.fileExists(atPath: outside.path))
  }

  func testSweepRemovesOnlyStaleBatches() throws {
    let store = TempCopyStore(root: dir.appendingPathComponent("danaview-out", isDirectory: true))
    let old = try store.makeBatch([try libraryFile("old.pdf")])
    let fresh = try store.makeBatch([try libraryFile("fresh.pdf")])
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 3600)], ofItemAtPath: old.directory.path)
    XCTAssertEqual(store.sweepStale(), 1)
    XCTAssertFalse(fm.fileExists(atPath: old.directory.path))
    XCTAssertTrue(fm.fileExists(atPath: fresh.directory.path))
  }

  func testMediaKind() {
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "a", uti: "public.heic")), .photo)
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "a", uti: "com.apple.quicktime-movie")), .video)
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "a", mimeType: "video/mp4")), .video)
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "IMG_1.DNG")), .photo)
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "clip.m4v")), .video)
    XCTAssertEqual(FileOutCore.mediaKind(OutFile(path: "/a", displayName: "doc.pdf", uti: "com.adobe.pdf", mimeType: "application/pdf")), .other)
  }
}
