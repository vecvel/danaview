// OWNER: HOM-29
//
// XCTests of the HOM-28 open item fixed in HOM-29 (owner-approved): a page tool's output made from
// an encrypted PDF is written encrypted with the password the source was opened with (as HOM-31's
// compress does) — split and organise from their input, merge from its first encrypted input, also
// when an image or a plain PDF comes first. The outputs need the password, open with it, and keep
// their text. Run with the page tools' tests (run_xctests.sh macos | ios-sim).

import Foundation
import PDFKit
import XCTest

final class PdfPageToolsEncryptionTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = TestPdfs.tempDir(self)
  }

  private func out(_ name: String) -> String { dir.appendingPathComponent(name).path }

  private func assertEncrypted(_ path: String, password: String, tokens: [String], file: StaticString = #filePath, line: UInt = #line) throws {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)), file: file, line: line)
    XCTAssertTrue(document.isEncrypted, "encrypted", file: file, line: line)
    XCTAssertTrue(document.isLocked, "needs the password", file: file, line: line)
    XCTAssertFalse(document.unlock(withPassword: "wrong"), file: file, line: line)
    XCTAssertTrue(document.unlock(withPassword: password), file: file, line: line)
    XCTAssertEqual(document.pageCount, tokens.count, file: file, line: line)
    for (i, token) in tokens.enumerated() where !token.isEmpty {
      XCTAssertTrue(document.page(at: i)?.string?.contains(token) ?? false, "\(token) on page \(i + 1)", file: file, line: line)
    }
  }

  func testOrganiseAndSplitOfAnEncryptedFileStayEncrypted() throws {
    let locked = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("l.pdf"), pages: 4, prefix: "LCK", userPassword: "pw")
    let source = PdfToolSource(path: locked.path, password: "pw")
    let organised = try PdfPageToolsCore.organise(
      source, plan: [PdfPagePlanItem(2), PdfPagePlanItem(0, rotation: 90)], outPath: out("o.pdf"), control: RecordingControl())
    try assertEncrypted(organised.path, password: "pw", tokens: ["LCK-P0003", "LCK-P0001"])

    let parts = try PdfPageToolsCore.split(source, ranges: [0..<1, 1..<4], outPaths: [out("s1.pdf"), out("s2.pdf")], control: RecordingControl())
    try assertEncrypted(parts[0].path, password: "pw", tokens: ["LCK-P0001"])
    try assertEncrypted(parts[1].path, password: "pw", tokens: ["LCK-P0002", "LCK-P0003", "LCK-P0004"])
  }

  func testMergeTakesTheFirstEncryptedInputsPassword() throws {
    let plain = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("p.pdf"), pages: 1, prefix: "PLN")
    let locked = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("l.pdf"), pages: 1, prefix: "LCK", userPassword: "pw")
    let other = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("o.pdf"), pages: 1, prefix: "OTH", userPassword: "other")
    let image = TestImages.writeJpeg(to: dir.appendingPathComponent("i.jpg"), width: 120, height: 160)

    let a = try PdfPageToolsCore.merge(
      [PdfToolSource(path: locked.path, password: "pw"), PdfToolSource(path: plain.path)], outPath: out("a.pdf"), control: RecordingControl())
    try assertEncrypted(a.path, password: "pw", tokens: ["LCK-P0001", "PLN-P0001"])

    let b = try PdfPageToolsCore.merge(
      [PdfToolSource(path: plain.path), PdfToolSource(path: locked.path, password: "pw"), PdfToolSource(path: other.path, password: "other")],
      outPath: out("b.pdf"), control: RecordingControl())
    try assertEncrypted(b.path, password: "pw", tokens: ["PLN-P0001", "LCK-P0001", "OTH-P0001"])

    let c = try PdfPageToolsCore.merge(
      [PdfToolSource(path: image.path, isImage: true), PdfToolSource(path: locked.path, password: "pw")], outPath: out("c.pdf"), control: RecordingControl())
    try assertEncrypted(c.path, password: "pw", tokens: ["", "LCK-P0001"])
  }

  func testPlainInputsStayPlain() throws {
    let plain = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("p.pdf"), pages: 2, prefix: "PLN")
    let organised = try PdfPageToolsCore.organise(PdfToolSource(path: plain.path), plan: [PdfPagePlanItem(1)], outPath: out("o.pdf"), control: RecordingControl())
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: organised.path)))
    XCTAssertFalse(document.isEncrypted)
    XCTAssertFalse(document.isLocked)
  }
}
