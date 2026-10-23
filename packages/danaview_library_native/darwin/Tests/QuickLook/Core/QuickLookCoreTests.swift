// OWNER: HOM-26
//
// XCTests of QuickLook/QuickLookCore.swift without an app host (BUILD_PLAN HOM-26): which types Quick
// Look previews and which go to the file card (docx, xlsx, pptx, txt, csv, pdf vs an unknown type,
// an archive, a missing file), editing off, and document thumbnails: a PDF's first page at the
// caller's scale inside the box (marker in the right corner, /Rotate honoured, white page), an
// encrypted PDF that opens with the empty password, nil for a password PDF and a damaged one, Quick
// Look thumbnails of other types (or nil), validation, cancel, and the source left unchanged.

import CoreGraphics
import Foundation
import XCTest

@testable import DanaviewQuickLookCore

final class QuickLookCoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom26-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

  private func fixtures() throws -> [String: URL] {
    var out: [String: URL] = [:]
    for kind in ["docx", "xlsx", "pptx"] {
      let u = file("fixture.\(kind)")
      try QuickLookTestDocs.office(at: u, kind: kind)
      out[kind] = u
    }
    out["txt"] = file("notes.txt")
    try QuickLookTestDocs.text(at: out["txt"]!)
    out["csv"] = file("table.csv")
    try QuickLookTestDocs.text(at: out["csv"]!, "a,b\n1,2\n")
    out["pdf"] = file("doc.pdf")
    try QuickLookTestDocs.pdf(at: out["pdf"]!)
    out["unknown"] = file("blob.qqzz")
    try QuickLookTestDocs.unknown(at: out["unknown"]!)
    return out
  }

  // MARK: Policy

  func testOfficeTextCsvAndPdfArePreviewedAndAnUnknownTypeIsCarded() throws {
    let f = try fixtures()
    for kind in ["docx", "xlsx", "pptx", "txt", "csv", "pdf"] {
      let u = f[kind]!
      XCTAssertTrue(QuickLookPolicy.canPreview(path: u.path, displayName: u.lastPathComponent, uti: nil), kind)
    }
    let unknown = f["unknown"]!
    XCTAssertFalse(QuickLookPolicy.canPreview(path: unknown.path, displayName: unknown.lastPathComponent, uti: nil))
    let zip = file("bundle.zip")
    try QuickLookTestDocs.unknown(at: zip)
    XCTAssertFalse(QuickLookPolicy.canPreview(path: zip.path, displayName: "bundle.zip", uti: nil), "plain archives get the file card")
    let bare = file("noextension")
    try QuickLookTestDocs.unknown(at: bare)
    XCTAssertFalse(QuickLookPolicy.canPreview(path: bare.path, displayName: "", uti: nil))
  }

  func testTheDisplayNameOrUtiDecidesForAStoredFileWithoutExtension() throws {
    let stored = file("fe_stored_blob")
    try QuickLookTestDocs.office(at: stored, kind: "docx")
    XCTAssertTrue(QuickLookPolicy.canPreview(path: stored.path, displayName: "Report.docx", uti: nil))
    XCTAssertTrue(QuickLookPolicy.canPreview(path: stored.path, displayName: "Report", uti: "org.openxmlformats.wordprocessingml.document"))
    XCTAssertTrue(QuickLookPolicy.canPreview(path: stored.path, displayName: "Report", uti: "public.comma-separated-values-text"))
    XCTAssertFalse(QuickLookPolicy.canPreview(path: stored.path, displayName: "Report", uti: "public.data"))
    XCTAssertFalse(QuickLookPolicy.canPreview(path: stored.path, displayName: "Report", uti: nil))
  }

  func testMissingDirectoryAndRelativePathsAreNotPreviewable() throws {
    XCTAssertEqual(QuickLookPolicy.fileProblem(file("missing.docx").path)?.code, "notFound")
    XCTAssertEqual(QuickLookPolicy.fileProblem(dir.path)?.code, "notFound")
    XCTAssertEqual(QuickLookPolicy.fileProblem("relative/a.docx")?.code, "invalidArgument")
    XCTAssertFalse(QuickLookPolicy.canPreview(path: file("missing.docx").path, displayName: "missing.docx", uti: nil))
    let txt = file("a.txt")
    try QuickLookTestDocs.text(at: txt)
    XCTAssertNil(QuickLookPolicy.fileProblem(txt.path))
  }

  func testEditingIsOff() {
    XCTAssertFalse(QuickLookPolicy.editingAllowed)
  }

  // MARK: Thumbnails

  private func thumb(_ url: URL, box: Int = 512, scale: CGFloat = 2, quickLook: Bool = true, token: ThumbnailCancelToken = ThumbnailCancelToken()) throws -> ThumbnailOutput? {
    let t = DocumentThumbnailer()
    t.useQuickLook = quickLook
    t.timeout = 15
    return try t.generate(path: url.path, box: CGSize(width: box, height: box), scale: scale, format: .jpeg, quality: 0.9,
                          outputPath: file("out-\(UUID().uuidString).jpg").path, token: token)
  }

  func testPdfFirstPageAtTheScaleWithTheMarkerTopLeft() throws {
    let pdf = file("page.pdf")
    try QuickLookTestDocs.pdf(at: pdf, size: CGSize(width: 200, height: 100), pages: 3)
    let o = try XCTUnwrap(try thumb(pdf, box: 512, scale: 2))
    XCTAssertEqual(o.widthPx, 400)
    XCTAssertEqual(o.heightPx, 200)
    XCTAssertEqual(o.format, .jpeg)
    let out = URL(fileURLWithPath: o.path)
    XCTAssertTrue(QuickLookTestDocs.isRed(QuickLookTestDocs.pixel(out, x: 10, y: 10)), "marker top-left")
    XCTAssertTrue(QuickLookTestDocs.isWhite(QuickLookTestDocs.pixel(out, x: 390, y: 190)), "white page, not black")
  }

  func testTheBoxCapsTheScale() throws {
    let pdf = file("page.pdf")
    try QuickLookTestDocs.pdf(at: pdf, size: CGSize(width: 200, height: 100))
    let o = try XCTUnwrap(try thumb(pdf, box: 256, scale: 3))
    XCTAssertEqual(o.widthPx, 256)
    XCTAssertEqual(o.heightPx, 128)
    let one = try XCTUnwrap(try thumb(pdf, box: 512, scale: 1))
    XCTAssertEqual(one.widthPx, 200)
    XCTAssertEqual(one.heightPx, 100)
    XCTAssertEqual(DocumentThumbnailer.pageSize(points: CGSize(width: 612, height: 792), scale: 3, box: CGSize(width: 384, height: 384)),
                   CGSize(width: 297, height: 384))
  }

  func testRotatedPagesAreTurned() throws {
    let pdf90 = file("r90.pdf")
    try QuickLookTestDocs.pdf(at: pdf90, size: CGSize(width: 200, height: 100), rotate: 90)
    let o = try XCTUnwrap(try thumb(pdf90, box: 512, scale: 2))
    XCTAssertEqual(o.widthPx, 200)
    XCTAssertEqual(o.heightPx, 400)
    // Turned clockwise: the top-left marker is now top-right.
    let u = URL(fileURLWithPath: o.path)
    XCTAssertTrue(QuickLookTestDocs.isRed(QuickLookTestDocs.pixel(u, x: 190, y: 10)))
    XCTAssertTrue(QuickLookTestDocs.isWhite(QuickLookTestDocs.pixel(u, x: 10, y: 10)))

    let pdf270 = file("r270.pdf")
    try QuickLookTestDocs.pdf(at: pdf270, size: CGSize(width: 200, height: 100), rotate: 270)
    let o270 = try XCTUnwrap(try thumb(pdf270, box: 512, scale: 2))
    let u270 = URL(fileURLWithPath: o270.path)
    XCTAssertTrue(QuickLookTestDocs.isRed(QuickLookTestDocs.pixel(u270, x: 10, y: 390)), "top-left goes bottom-left")

    let pdf180 = file("r180.pdf")
    try QuickLookTestDocs.pdf(at: pdf180, size: CGSize(width: 200, height: 100), rotate: 180)
    let o180 = try XCTUnwrap(try thumb(pdf180, box: 512, scale: 2))
    XCTAssertEqual(o180.widthPx, 400)
    XCTAssertTrue(QuickLookTestDocs.isRed(QuickLookTestDocs.pixel(URL(fileURLWithPath: o180.path), x: 390, y: 190)))
  }

  func testEncryptedPdfThatOpensWithTheEmptyPasswordGetsAThumbnail() throws {
    let pdf = file("empty-pass.pdf")
    try QuickLookTestDocs.encryptedPdf(at: pdf, userPassword: "")
    XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.isEncrypted, true, "the fixture is encrypted")
    let o = try XCTUnwrap(try thumb(pdf, box: 512, scale: 2))
    XCTAssertEqual(o.widthPx, 400)
    XCTAssertTrue(QuickLookTestDocs.isRed(QuickLookTestDocs.pixel(URL(fileURLWithPath: o.path), x: 10, y: 10)))
  }

  func testPasswordPdfAndDamagedPdfHaveNoThumbnail() throws {
    let locked = file("locked.pdf")
    try QuickLookTestDocs.encryptedPdf(at: locked, userPassword: "open-sesame")
    XCTAssertEqual(CGPDFDocument(locked as CFURL)?.isUnlocked, false, "the fixture needs a password")
    XCTAssertNil(try thumb(locked))
    let damaged = file("damaged.pdf")
    try QuickLookTestDocs.damagedPdf(at: damaged)
    XCTAssertNil(try thumb(damaged))
  }

  func testAPdfWithoutExtensionIsFoundByItsHeader() throws {
    let stored = file("fe_pdf_blob")
    try QuickLookTestDocs.pdf(at: stored)
    XCTAssertTrue(DocumentThumbnailer.isPDF(stored))
    XCTAssertNotNil(try thumb(stored, quickLook: false))
    let txt = file("a.txt")
    try QuickLookTestDocs.text(at: txt)
    XCTAssertFalse(DocumentThumbnailer.isPDF(txt))
  }

  func testOtherDocumentsGoThroughQuickLookOrAnswerNil() throws {
    let f = try fixtures()
    for kind in ["docx", "xlsx", "pptx", "txt", "csv", "unknown"] {
      XCTAssertNil(try thumb(f[kind]!, quickLook: false), "\(kind) without Quick Look")
      // Quick Look's generators differ per machine: a thumbnail fits the box, or there is none.
      if let o = try thumb(f[kind]!, box: 256, scale: 2) {
        XCTAssertLessThanOrEqual(o.widthPx, 256, kind)
        XCTAssertLessThanOrEqual(o.heightPx, 256, kind)
        XCTAssertTrue(FileManager.default.fileExists(atPath: o.path), kind)
      }
    }
  }

  func testSourcesAreLeftByteForByte() throws {
    let f = try fixtures()
    for (kind, u) in f {
      let before = try Data(contentsOf: u)
      let modified = try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date
      _ = try thumb(u)
      XCTAssertEqual(try Data(contentsOf: u), before, kind)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date, modified, kind)
    }
  }

  func testMissingFileCancelAndValidation() throws {
    XCTAssertThrowsError(try thumb(file("missing.pdf"))) { XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "notFound") }
    let pdf = file("c.pdf")
    try QuickLookTestDocs.pdf(at: pdf)
    let token = ThumbnailCancelToken()
    token.cancel()
    XCTAssertThrowsError(try thumb(pdf, token: token)) { XCTAssertEqual(($0 as? ThumbnailFailure)?.code, "cancelled") }

    func check(id: String = "r", path: String = "/a.pdf", w: Int64 = 64, h: Int64 = 64, scale: Double = 2, q: Double = 0.8, out: String = "/o.jpg") -> String? {
      DocumentThumbnailer.validate(requestId: id, path: path, widthPx: w, heightPx: h, scale: scale, quality: q, outputPath: out)?.code
    }
    XCTAssertNil(check())
    XCTAssertEqual(check(id: ""), "invalidArgument")
    XCTAssertEqual(check(w: 0), "invalidArgument")
    XCTAssertEqual(check(h: 5000), "invalidArgument")
    XCTAssertEqual(check(scale: 0), "invalidArgument")
    XCTAssertEqual(check(scale: 9), "invalidArgument")
    XCTAssertEqual(check(scale: .nan), "invalidArgument")
    XCTAssertEqual(check(q: 1.5), "invalidArgument")
    XCTAssertEqual(check(path: "a.pdf"), "invalidArgument")
    XCTAssertEqual(check(out: "o.jpg"), "invalidArgument")
  }
}
