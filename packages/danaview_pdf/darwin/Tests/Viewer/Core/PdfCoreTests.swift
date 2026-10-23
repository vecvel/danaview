// OWNER: HOM-24
//
// XCTests of the Flutter-free PDFKit core (BUILD_PLAN HOM-24): first page of a 200-page file
// within 500 ms, search finds the fixture strings, a password file opens after the password,
// outline, rotation-aware thumbnails, extraction ranges and limits, damaged and missing files,
// and sources unchanged after every read (rule 27).

import Foundation
import PDFKit
import XCTest

final class PdfCoreTests: XCTestCase {
  // MARK: Open and first page

  func testFirstPageOf200PageFileWithin500ms() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.fixture("text_200p.pdf")
      ?? TestPdfs.writeTextPdf(to: dir.appendingPathComponent("text_200p.pdf"), pages: 200, prefix: "HOM27T")
    let store = PdfDocumentStore()
    // Warm PDFKit once (framework load), as the app has by the time a user opens a file.
    _ = try store.open(path: TestPdfs.writeTextPdf(to: dir.appendingPathComponent("warm.pdf"), pages: 1).path, password: nil)

    let start = Date()
    let summary = try store.open(path: url.path, password: nil)
    let image = try PdfReader.render(try store.document(summary.handle), page: 0, maxWidth: 1170, maxHeight: 2532)
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertEqual(summary.pageCount, 200)
    XCTAssertEqual(summary.pages.count, 200)
    XCTAssertFalse(summary.locked)
    XCTAssertGreaterThan(image.png.count, 1000)
    XCTAssertLessThanOrEqual(elapsed, 0.5, "first page took \(Int(elapsed * 1000)) ms")
    print("HOM-24 first page of 200 pages: \(Int(elapsed * 1000)) ms")
  }

  func testSummaryAndRotationAwareThumbnail() throws {
    guard let url = TestPdfs.fixture("merge_partner_3p.pdf") else { throw XCTSkip("HOM-27 fixtures not found") }
    let store = PdfDocumentStore()
    let summary = try store.open(path: url.path, password: nil)
    XCTAssertEqual(summary.pageCount, 3)
    XCTAssertEqual(summary.pages.map(\.rotation), [0, 0, 90])
    XCTAssertGreaterThan(summary.pages[1].width, summary.pages[1].height, "landscape MediaBox")
    let doc = try store.document(summary.handle)
    let portrait = try PdfReader.render(doc, page: 0, maxWidth: 200, maxHeight: 200)
    XCTAssertLessThan(portrait.width, portrait.height)
    XCTAssertEqual(portrait.height, 200)
    let rotated = try PdfReader.render(doc, page: 2, maxWidth: 200, maxHeight: 200)
    XCTAssertGreaterThan(rotated.width, rotated.height, "a /Rotate 90 portrait page renders landscape")
    XCTAssertThrowsError(try PdfReader.render(doc, page: 3, maxWidth: 10, maxHeight: 10)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound)
    }
    XCTAssertThrowsError(try PdfReader.render(doc, page: 0, maxWidth: 0, maxHeight: 10)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument)
    }
  }

  // MARK: Search

  func testSearchFindsFixtureStrings() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.fixture("text_200p.pdf")
      ?? TestPdfs.writeTextPdf(to: dir.appendingPathComponent("text_200p.pdf"), pages: 200, prefix: "HOM27T")
    let doc = try PdfReader.open(path: url.path)

    let one = try PdfSearcher.search(doc, query: "HOM27T-P0150", caseSensitive: true, maxHits: 100)
    XCTAssertEqual(one.matches.count, 1)
    XCTAssertEqual(one.matches.first?.pageIndex, 149)
    XCTAssertFalse(one.truncated)
    let hit = try XCTUnwrap(one.matches.first)
    let snippet = hit.snippet as NSString
    XCTAssertEqual(snippet.substring(with: NSRange(location: hit.snippetMatchStart, length: hit.snippetMatchLength)), "HOM27T-P0150")
    XCTAssertFalse(hit.snippet.contains("\n"))
    XCTAssertGreaterThan(hit.bounds.width, 0)
    let pageText = try XCTUnwrap(doc.page(at: 149)?.string) as NSString
    XCTAssertEqual(pageText.substring(with: NSRange(location: hit.rangeStart, length: hit.rangeLength)), "HOM27T-P0150")

    let insensitive = try PdfSearcher.search(doc, query: "hom27t-p0001", caseSensitive: false, maxHits: 100)
    XCTAssertEqual(insensitive.matches.map(\.pageIndex), [0])
    XCTAssertTrue(try PdfSearcher.search(doc, query: "hom27t-p0001", caseSensitive: true, maxHits: 100).matches.isEmpty)
    XCTAssertTrue(try PdfSearcher.search(doc, query: "not-in-this-file", caseSensitive: false, maxHits: 100).matches.isEmpty)
    XCTAssertTrue(try PdfSearcher.search(doc, query: "   ", caseSensitive: false, maxHits: 100).matches.isEmpty)

    let capped = try PdfSearcher.search(doc, query: "HOM27T", caseSensitive: false, maxHits: 10)
    XCTAssertEqual(capped.matches.count, 10)
    XCTAssertTrue(capped.truncated)
    XCTAssertEqual(capped.matches.map(\.pageIndex), Array(0..<10))

    XCTAssertThrowsError(try PdfSearcher.search(doc, query: "HOM27T", caseSensitive: false, maxHits: 10, isCancelled: { true })) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .cancelled)
    }
  }

  func testSearchOnGeneratedFile() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("g.pdf"), pages: 5, prefix: "GEN")
    let doc = try PdfReader.open(path: url.path)
    XCTAssertEqual(try PdfSearcher.search(doc, query: "GEN-P0004", caseSensitive: true, maxHits: 5).matches.map(\.pageIndex), [3])
    XCTAssertEqual(try PdfSearcher.search(doc, query: "lazy DOG", caseSensitive: false, maxHits: 50).matches.count, 5)
  }

  // MARK: Passwords

  func testPasswordFileOpensAfterThePassword() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("locked.pdf"), pages: 4, prefix: "LOCK", userPassword: "s3cret")
    let store = PdfDocumentStore()

    let locked = try store.open(path: url.path, password: nil)
    XCTAssertTrue(locked.locked)
    XCTAssertTrue(locked.encrypted)
    XCTAssertEqual(locked.pageCount, 0)
    XCTAssertTrue(locked.pages.isEmpty)
    XCTAssertNil(locked.title)
    XCTAssertThrowsError(try store.twin(locked.handle)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .passwordRequired) }
    XCTAssertThrowsError(try PdfReader.render(try store.document(locked.handle), page: 0, maxWidth: 10, maxHeight: 10)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .passwordRequired)
    }
    XCTAssertEqual(try PdfReader.probe(path: url.path), PdfProbeResult(canOpen: true, encrypted: true, pageCount: -1))

    XCTAssertNil(try store.unlock(handle: locked.handle, password: "wrong"))
    XCTAssertNil(try store.unlock(handle: locked.handle, password: ""))
    let open = try XCTUnwrap(try store.unlock(handle: locked.handle, password: "s3cret"))
    XCTAssertFalse(open.locked)
    XCTAssertEqual(open.pageCount, 4)
    XCTAssertEqual(open.handle, locked.handle)

    // Search and thumbnails work after the prompt (the twin is unlocked with the same password).
    let twin = try store.twin(open.handle)
    XCTAssertEqual(try PdfSearcher.search(twin, query: "LOCK-P0003", caseSensitive: true, maxHits: 5).matches.map(\.pageIndex), [2])
    XCTAssertNoThrow(try PdfReader.render(try store.document(open.handle), page: 0, maxWidth: 100, maxHeight: 100))

    // Opening with the password straight away.
    XCTAssertFalse(try store.open(path: url.path, password: "s3cret").locked)
    XCTAssertTrue(try store.open(path: url.path, password: "nope").locked)

    // Text extraction needs it too.
    XCTAssertThrowsError(try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 0, pageCount: -1, maxChars: -1)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .passwordRequired)
    }
    let text = try PdfTextExtractor.extract(path: url.path, password: "s3cret", firstPage: 0, pageCount: -1, maxChars: -1)
    XCTAssertEqual(text.pages.count, 4)
  }

  // MARK: Outline, text, errors

  func testOutlineFlattenedDepthFirst() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeOutlinedPdf(in: dir)
    let doc = try PdfReader.open(path: url.path)
    XCTAssertEqual(PdfReader.outline(of: doc), [
      PdfOutlineEntry(title: "Chapter 1", pageIndex: 0, depth: 0),
      PdfOutlineEntry(title: "Section 1.1", pageIndex: 1, depth: 1),
      PdfOutlineEntry(title: "Chapter 2", pageIndex: 2, depth: 0),
    ])
    let plain = try PdfReader.open(path: TestPdfs.writeTextPdf(to: dir.appendingPathComponent("p.pdf"), pages: 1).path)
    XCTAssertEqual(PdfReader.outline(of: plain), [])
  }

  func testExtractTextRangesAndLimits() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("t.pdf"), pages: 6, prefix: "TXT")
    let all = try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 0, pageCount: -1, maxChars: -1)
    XCTAssertEqual(all.documentPageCount, 6)
    XCTAssertEqual(all.pages.map(\.index), Array(0..<6))
    for page in all.pages { XCTAssertTrue(page.text.contains(TestPdfs.token("TXT", page.index))) }
    XCTAssertFalse(all.truncated)

    let middle = try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 2, pageCount: 2, maxChars: -1)
    XCTAssertEqual(middle.pages.map(\.index), [2, 3])
    let past = try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 9, pageCount: 2, maxChars: -1)
    XCTAssertTrue(past.pages.isEmpty)

    let limited = try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 0, pageCount: -1, maxChars: 60)
    XCTAssertTrue(limited.truncated)
    XCTAssertEqual(limited.pages.reduce(0) { $0 + ($1.text as NSString).length }, 60)

    XCTAssertThrowsError(try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: -1, pageCount: 1, maxChars: -1)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument)
    }
  }

  func testImageOnlyFileHasNoText() throws {
    guard let url = TestPdfs.fixture("image_only_2p.pdf") else { throw XCTSkip("HOM-27 fixtures not found") }
    let text = try PdfTextExtractor.extract(path: url.path, password: nil, firstPage: 0, pageCount: -1, maxChars: -1)
    XCTAssertEqual(text.pages.count, 2)
    XCTAssertTrue(text.pages.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    XCTAssertTrue(try PdfSearcher.search(try PdfReader.open(path: url.path), query: "a", caseSensitive: false, maxHits: 5).matches.isEmpty)
  }

  func testDamagedAndMissingFiles() throws {
    let dir = TestPdfs.tempDir(self)
    let damaged = TestPdfs.writeDamagedPdf(in: dir)
    XCTAssertEqual(try PdfReader.probe(path: damaged.path), PdfProbeResult(canOpen: false, encrypted: false, pageCount: -1))
    XCTAssertThrowsError(try PdfDocumentStore().open(path: damaged.path, password: nil)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .damaged)
    }
    let missing = dir.appendingPathComponent("missing.pdf").path
    XCTAssertThrowsError(try PdfReader.probe(path: missing)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound) }
    XCTAssertThrowsError(try PdfReader.open(path: dir.path)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound) }
    let store = PdfDocumentStore()
    XCTAssertThrowsError(try store.document(42)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound) }
  }

  func testCloseReleasesHandles() throws {
    let dir = TestPdfs.tempDir(self)
    let url = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("c.pdf"), pages: 1)
    let store = PdfDocumentStore()
    let a = try store.open(path: url.path, password: nil)
    let b = try store.open(path: url.path, password: nil)
    XCTAssertNotEqual(a.handle, b.handle)
    XCTAssertEqual(store.count, 2)
    store.close(a.handle)
    store.close(a.handle)
    XCTAssertEqual(store.count, 1)
    XCTAssertThrowsError(try store.document(a.handle))
  }

  // MARK: Rule 27

  func testSourcesStayUnchanged() throws {
    let dir = TestPdfs.tempDir(self)
    var files = [
      TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 3),
      TestPdfs.writeTextPdf(to: dir.appendingPathComponent("b.pdf"), pages: 2, userPassword: "pw"),
      TestPdfs.writeOutlinedPdf(in: dir),
    ]
    if let fixture = TestPdfs.fixture("annotated_2p.pdf") { files.append(fixture) }
    let before = files.map(TestPdfs.fingerprint)
    Thread.sleep(forTimeInterval: 0.01)
    let store = PdfDocumentStore()
    for url in files {
      let s = try store.open(path: url.path, password: nil)
      _ = try store.unlock(handle: s.handle, password: "pw")
      let doc = try store.document(s.handle)
      _ = PdfReader.outline(of: doc)
      _ = try PdfReader.render(doc, page: 0, maxWidth: 64, maxHeight: 64)
      _ = try PdfSearcher.search(try store.twin(s.handle), query: "page", caseSensitive: false, maxHits: 10)
      _ = try PdfTextExtractor.extract(path: url.path, password: "pw", firstPage: 0, pageCount: -1, maxChars: -1)
      store.close(s.handle)
    }
    let after = files.map(TestPdfs.fingerprint)
    for (b, a) in zip(before, after) {
      XCTAssertEqual(b.0, a.0, "bytes changed")
      XCTAssertEqual(b.1, a.1, "modification date changed")
    }
  }
}
