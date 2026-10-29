// OWNER: HOM-30
//
// XCTests closing the plan's [VERIFY: HOM-30] (HOM plan §8.5 "Sign: stamp annotation with the
// signature image, burned into the page on save") on macOS and the iOS Simulator
// (Tests/Viewer/run_xctests.sh macos | ios-sim). A signed copy is the annotate save with image
// stamps and `burnIn: true` (Classes/Annotate/PdfAnnotateCore.swift; Sign/PdfSigner routes the
// frozen `PdfToolsHostApi.sign` to it):
//
// - the signature is in the page content: Quartz's own PDF renderer (CGPDFDocument, not PDFKit, as
//   another viewer would) draws it, and no page carries a Stamp annotation (read from the raw
//   page dictionaries);
// - page text stays text: selectable and searchable on every signed page;
// - the page's own annotations, crop box and rotation are kept; the outline still points at it;
// - an encrypted source gives an encrypted output with its password;
// - a cancel at any step, or a bad request, leaves no file; the source is never written;
// - the sign mode's move and resize geometry (Sign/PdfSignCore.swift).
//
// Uses TestPdfs, TestImages and RecordingControl (HOM-24 / HOM-28 helpers). No downloads.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest

final class PdfSignCoreTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = TestPdfs.tempDir(self)
  }

  private func out(_ name: String) -> String { dir.appendingPathComponent(name).path }

  private func code(_ body: () throws -> Any) -> PdfErrorCode? {
    do {
      _ = try body()
      return nil
    } catch let failure as PdfFailure {
      return failure.code
    } catch {
      return .internal
    }
  }

  /// A signature PNG: dark blue ink in its lower half, transparent above (TestImages' red half
  /// stands for the ink).
  private func signature() -> URL {
    TestImages.writePng(to: dir.appendingPathComponent("signature.png"), width: 240, height: 80)
  }

  private func sign(_ source: URL, password: String? = nil, stamps: [PdfStampSpec], to name: String, control: PdfToolControl = RecordingControl()) throws -> PdfWrittenFile {
    try PdfAnnotateCore.annotate(PdfToolSource(path: source.path, password: password), annotations: [], stamps: stamps, burnIn: true, outPath: out(name), control: control)
  }

  // ---------------------------------------------------------------------------------------------
  // Another viewer's view of the file: Quartz's CGPDFDocument, no PDFKit.

  private func quartz(_ path: String, password: String? = nil) throws -> CGPDFDocument {
    let document = try XCTUnwrap(CGPDFDocument(URL(fileURLWithPath: path) as CFURL))
    if let password, document.isEncrypted { XCTAssertTrue(document.unlockWithPassword(password)) }
    return document
  }

  /// The `/Subtype` names of page [index]'s `/Annots` (1-based Quartz pages inside).
  private func annotationSubtypes(_ path: String, page index: Int, password: String? = nil) throws -> [String] {
    let page = try XCTUnwrap(try quartz(path, password: password).page(at: index + 1))
    guard let dict = page.dictionary else { return [] }
    var annots: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, "Annots", &annots), let annots else { return [] }
    var names: [String] = []
    for i in 0..<CGPDFArrayGetCount(annots) {
      var a: CGPDFDictionaryRef?
      var subtype: UnsafePointer<Int8>?
      if CGPDFArrayGetDictionary(annots, i, &a), let a, CGPDFDictionaryGetName(a, "Subtype", &subtype), let subtype {
        names.append(String(cString: subtype))
      }
    }
    return names
  }

  /// RGB of page [index] of [path] drawn by Quartz without annotations at 1 px per point, at the
  /// point [p] of its media box.
  private func quartzPixel(_ path: String, page index: Int, at p: CGPoint, password: String? = nil) throws -> (r: Int, g: Int, b: Int) {
    let page = try XCTUnwrap(try quartz(path, password: password).page(at: index + 1))
    let box = page.getBoxRect(.mediaBox)
    let w = Int(box.width)
    let h = Int(box.height)
    let ctx = try XCTUnwrap(CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page) // the content stream only: annotations are not drawn
    let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
    let x = Int(p.x - box.minX)
    let y = h - 1 - Int(p.y - box.minY)
    let o = (y * w + x) * 4
    return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
  }

  private func assertSearchable(_ token: String, page: Int, in path: String, password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)), file: file, line: line)
    if let password { XCTAssertTrue(document.unlock(withPassword: password), file: file, line: line) }
    let hits = document.findString(token, withOptions: [])
    XCTAssertEqual(hits.count, 1, "\(token) found once", file: file, line: line)
    XCTAssertEqual(hits.first?.pages.first.map { document.index(for: $0) }, page, file: file, line: line)
    let p = try XCTUnwrap(document.page(at: page), file: file, line: line)
    let range = (p.string! as NSString).range(of: token)
    XCTAssertEqual(p.selection(for: range)?.string, token, "the token is selectable", file: file, line: line)
  }

  // ---------------------------------------------------------------------------------------------
  // [VERIFY: HOM-30]

  func testTheSignatureIsBurnedInOnEveryPageAndRendersInAnotherViewerWithoutAStampAnnotation() throws {
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("contract.pdf"), pages: 3, prefix: "SGN")
    let before = TestPdfs.fingerprint(source)
    let image = signature()
    // The same signature on two pages (several places), none on page 1.
    let stamps = [
      PdfStampSpec(pageIndex: 0, rect: CGRect(x: 300, y: 100, width: 240, height: 80), imagePath: image.path),
      PdfStampSpec(pageIndex: 2, rect: CGRect(x: 72, y: 150, width: 120, height: 40), imagePath: image.path),
    ]
    let written = try sign(source, stamps: stamps, to: "contract (signed).pdf")
    XCTAssertEqual(written.pageCount, 3)

    for page in 0..<3 {
      XCTAssertEqual(try annotationSubtypes(written.path, page: page), [], "page \(page) has no annotation (no Stamp left)")
    }
    // Quartz draws the signature from the page content: the ink half in, the transparent half out.
    let ink = try quartzPixel(written.path, page: 0, at: CGPoint(x: 480, y: 115))
    XCTAssertGreaterThan(ink.r, 140, "signature ink in page 0's content")
    XCTAssertLessThan(ink.g, 60)
    let clear = try quartzPixel(written.path, page: 0, at: CGPoint(x: 480, y: 170))
    XCTAssertGreaterThan(clear.g, 230, "the signature's transparency is kept")
    let small = try quartzPixel(written.path, page: 2, at: CGPoint(x: 160, y: 158))
    XCTAssertGreaterThan(small.r, 140, "the second placement is in page 2's content")
    XCTAssertLessThan(small.g, 60)
    let untouched = try quartzPixel(written.path, page: 1, at: CGPoint(x: 480, y: 115))
    XCTAssertGreaterThan(untouched.g, 230, "page 1 was not signed")

    // PDFKit agrees: no annotation objects on the signed pages.
    let reopened = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 0)
    XCTAssertEqual(reopened.page(at: 2)?.annotations.count, 0)

    // The source is never written.
    XCTAssertEqual(TestPdfs.fingerprint(source).0, before.0)
    XCTAssertEqual(TestPdfs.fingerprint(source).1, before.1)
  }

  func testPageTextStaysSelectableAndSearchableOnSignedPages() throws {
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("t.pdf"), pages: 2, prefix: "TXT")
    let image = signature()
    // The signature overlaps the token's line on page 0.
    let document = try XCTUnwrap(PDFDocument(url: source))
    let page0 = try XCTUnwrap(document.page(at: 0))
    let range = (page0.string! as NSString).range(of: "TXT-P0001")
    let bounds = try XCTUnwrap(page0.selection(for: range)).bounds(for: page0)
    let stamps = [
      PdfStampSpec(pageIndex: 0, rect: CGRect(x: bounds.minX, y: bounds.minY - 10, width: 150, height: 50), imagePath: image.path),
      PdfStampSpec(pageIndex: 1, rect: CGRect(x: 300, y: 300, width: 150, height: 50), imagePath: image.path),
    ]
    let written = try sign(source, stamps: stamps, to: "t (signed).pdf")
    try assertSearchable("TXT-P0001", page: 0, in: written.path)
    try assertSearchable("TXT-P0002", page: 1, in: written.path)
  }

  /// A 2-page text file with a crop box inset by 10 points and an outline (Chapter 1 → page 0).
  private func croppedOutlinedPdf() -> URL {
    let url = dir.appendingPathComponent("cropped.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    var crop = CGRect(x: 10, y: 10, width: 592, height: 772)
    let cropData = withUnsafeBytes(of: &crop) { Data($0) }
    for i in 0..<2 {
      context.beginPDFPage([kCGPDFContextCropBox as String: cropData] as CFDictionary)
      let attributed = NSAttributedString(string: TestPdfs.token("KEEP", i), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
      context.textPosition = CGPoint(x: 72, y: 700)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
      context.endPDFPage()
    }
    let outline: [String: Any] = [
      kCGPDFOutlineChildren as String: [[kCGPDFOutlineTitle as String: "Chapter 1", kCGPDFOutlineDestination as String: 1] as [String: Any]],
    ]
    CGPDFContextSetOutline(context, outline as CFDictionary)
    context.closePDF()
    return url
  }

  func testThePagesOwnAnnotationsCropBoxAndRotationAreKept() throws {
    // Prepared with the tools themselves (tests write PDFs only through the tools, rule 27): page 0
    // turned 90°, then a note and an ink mark of its own.
    let turned = try PdfPageToolsCore.organise(
      PdfToolSource(path: croppedOutlinedPdf().path), plan: [PdfPagePlanItem(0, rotation: 90), PdfPagePlanItem(1)],
      outPath: out("turned.pdf"), control: RecordingControl())
    let prepared = try PdfAnnotateCore.annotate(
      PdfToolSource(path: turned.path),
      annotations: [
        PdfAnnotationSpec(kind: .note, pageIndex: 0, rects: [CGRect(x: 30, y: 30, width: 0, height: 0)], text: "Own note"),
        PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: 40, y: 400), CGPoint(x: 140, y: 420)]], colorArgb: 0xFF00_00FF, lineWidth: 2),
      ],
      outPath: out("prepared.pdf"), control: RecordingControl())
    let source = URL(fileURLWithPath: prepared.path)
    // Pigeon page space starts at the crop box: (290, 190) is (300, 200) in PDF space.
    let stamp = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 290, y: 190, width: 240, height: 80), imagePath: signature().path)
    let written = try sign(source, stamps: [stamp], to: "signed.pdf")

    XCTAssertEqual(try annotationSubtypes(written.path, page: 0).filter { $0 != "Popup" }.sorted(), ["Ink", "Text"], "the page's own annotations (the note keeps its popup), and no Stamp")
    let result = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    let page = try XCTUnwrap(result.page(at: 0))
    XCTAssertEqual(page.annotations.first { $0.type == "Text" }?.contents, "Own note")
    XCTAssertEqual(page.rotation, 90)
    XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 10, y: 10, width: 592, height: 772))
    XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
    XCTAssertEqual(result.page(at: 1)?.rotation, 0)
    let ink = try quartzPixel(written.path, page: 0, at: CGPoint(x: 450, y: 215))
    XCTAssertGreaterThan(ink.r, 140, "the signature is in the rotated page's content")
    XCTAssertLessThan(ink.g, 60)
    try assertSearchable("KEEP-P0001", page: 0, in: written.path)
    let chapter = try XCTUnwrap(result.outlineRoot?.child(at: 0))
    XCTAssertEqual(chapter.destination?.page.map { result.index(for: $0) }, 0, "the outline still points at the signed page")
  }

  func testEncryptedInGivesEncryptedOut() throws {
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("locked.pdf"), pages: 2, prefix: "LCK", userPassword: "s3cret")
    let stamp = PdfStampSpec(pageIndex: 1, rect: CGRect(x: 300, y: 100, width: 240, height: 80), imagePath: signature().path)
    XCTAssertEqual(code { try self.sign(source, stamps: [stamp], to: "x.pdf") }, .passwordRequired)
    XCTAssertEqual(code { try self.sign(source, password: "wrong", stamps: [stamp], to: "x.pdf") }, .passwordRequired)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))

    let written = try sign(source, password: "s3cret", stamps: [stamp], to: "locked (signed).pdf")
    let reopened = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    XCTAssertTrue(reopened.isEncrypted, "the signed copy stays encrypted")
    XCTAssertTrue(reopened.isLocked, "it needs the password")
    XCTAssertFalse(reopened.unlock(withPassword: "wrong"))
    XCTAssertTrue(reopened.unlock(withPassword: "s3cret"))
    XCTAssertEqual(reopened.page(at: 1)?.annotations.count, 0)
    XCTAssertTrue(try XCTUnwrap(CGPDFDocument(URL(fileURLWithPath: written.path) as CFURL)).isEncrypted)
    let ink = try quartzPixel(written.path, page: 1, at: CGPoint(x: 480, y: 115), password: "s3cret")
    XCTAssertGreaterThan(ink.r, 140, "burned in under the encryption")
    try assertSearchable("LCK-P0002", page: 1, in: written.path, password: "s3cret")
  }

  func testCancelAtEveryStepAndBadRequestsLeaveNoFile() throws {
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("c.pdf"), pages: 3, prefix: "CNL")
    let image = signature()
    let stamps = (0..<3).map { PdfStampSpec(pageIndex: $0, rect: CGRect(x: 72, y: 72, width: 120, height: 40), imagePath: image.path) }
    let pre = RecordingControl()
    pre.cancel()
    XCTAssertEqual(code { try self.sign(source, stamps: stamps, to: "k0.pdf", control: pre) }, .cancelled)
    // Reports: the start, one per signed page (3), then the finished write.
    for n in 1...4 {
      XCTAssertEqual(code { try self.sign(source, stamps: stamps, to: "k\(n).pdf", control: RecordingControl(cancelAfter: n)) }, .cancelled, "cancel after \(n)")
    }
    // Bad requests write nothing and never overwrite.
    let missing = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 1, y: 1, width: 10, height: 10), imagePath: out("none.png"))
    XCTAssertEqual(code { try self.sign(source, stamps: [missing], to: "k5.pdf") }, .notFound)
    let off = PdfStampSpec(pageIndex: 3, rect: CGRect(x: 1, y: 1, width: 10, height: 10), imagePath: image.path)
    XCTAssertEqual(code { try self.sign(source, stamps: [off], to: "k6.pdf") }, .invalidArgument)
    let empty = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 1, y: 1, width: 0, height: 10), imagePath: image.path)
    XCTAssertEqual(code { try self.sign(source, stamps: [empty], to: "k7.pdf") }, .invalidArgument)
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [], stamps: stamps, burnIn: true, outPath: source.path, control: RecordingControl()) }, .invalidArgument)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("k") }
    XCTAssertEqual(leftovers, [])
  }

  func testAQuarterTurnedSignatureFillsItsRectUprightOnARotatedPage() throws {
    // The viewer places a signature upright on a page shown turned 90° clockwise: its rect is the
    // footprint in page space (tall), its image turned 270° clockwise (a quarter counter-clockwise).
    let turned = try PdfPageToolsCore.organise(
      PdfToolSource(path: TestPdfs.writeTextPdf(to: dir.appendingPathComponent("r.pdf"), pages: 1, prefix: "ROT").path),
      plan: [PdfPagePlanItem(0, rotation: 90)], outPath: out("turned.pdf"), control: RecordingControl())
    let stamp = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 300, y: 200, width: 80, height: 240), imagePath: signature().path, rotationDegrees: 270)
    let written = try sign(URL(fileURLWithPath: turned.path), stamps: [stamp], to: "r (signed).pdf")
    // The image's lower (ink) half now lies on the rect's right, its transparent half on the left,
    // and it reaches the rect's top and bottom: it fills the rect.
    let ink = try quartzPixel(written.path, page: 0, at: CGPoint(x: 362, y: 420))
    XCTAssertGreaterThan(ink.r, 140)
    XCTAssertLessThan(ink.g, 60)
    let clear = try quartzPixel(written.path, page: 0, at: CGPoint(x: 318, y: 420))
    XCTAssertGreaterThan(clear.g, 230)
    let low = try quartzPixel(written.path, page: 0, at: CGPoint(x: 362, y: 260))
    XCTAssertGreaterThan(low.r, 140, "the ink reaches the rect's lower part too")
    XCTAssertLessThan(low.g, 60)
    let outside = try quartzPixel(written.path, page: 0, at: CGPoint(x: 362, y: 450))
    XCTAssertGreaterThan(outside.g, 230, "nothing outside the rect")
  }

  // ---------------------------------------------------------------------------------------------
  // The sign mode's geometry

  func testMovingKeepsTheStampOnItsPage() {
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    let rect = CGRect(x: 100, y: 100, width: 200, height: 60)
    XCTAssertEqual(PdfSignGeometry.moved(rect, by: CGVector(dx: 50, dy: -20), within: page), CGRect(x: 150, y: 80, width: 200, height: 60))
    XCTAssertEqual(PdfSignGeometry.moved(rect, by: CGVector(dx: 1000, dy: 1000), within: page), CGRect(x: 400, y: 740, width: 200, height: 60))
    XCTAssertEqual(PdfSignGeometry.moved(rect, by: CGVector(dx: -1000, dy: -1000), within: page), CGRect(x: 0, y: 0, width: 200, height: 60))
  }

  func testResizingKeepsTheAspectTheAnchorAndTheLimits() {
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    let rect = CGRect(x: 100, y: 100, width: 200, height: 50)
    // The lower right corner (maxX, minY) dragged out: the upper left corner stays.
    let bigger = PdfSignGeometry.resized(rect, handle: CGPoint(x: 300, y: 100), to: CGPoint(x: 500, y: 90), within: page)
    XCTAssertEqual(bigger.minX, 100, accuracy: 0.001)
    XCTAssertEqual(bigger.maxY, 150, accuracy: 0.001)
    XCTAssertEqual(bigger.width, 400, accuracy: 0.001)
    XCTAssertEqual(bigger.width / bigger.height, 4, accuracy: 0.001, "aspect kept")
    // Dragged past the anchor: no smaller than the minimum side.
    let tiny = PdfSignGeometry.resized(rect, handle: CGPoint(x: 300, y: 100), to: CGPoint(x: 0, y: 800), within: page)
    XCTAssertEqual(tiny.height, PdfSignGeometry.minSide, accuracy: 0.001)
    XCTAssertEqual(tiny.width / tiny.height, 4, accuracy: 0.001)
    // Dragged off the page: it stops at the page edge.
    let edge = PdfSignGeometry.resized(rect, handle: CGPoint(x: 300, y: 100), to: CGPoint(x: 5000, y: -5000), within: page)
    XCTAssertEqual(edge.maxX, 600, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(edge.minY, 0)
    XCTAssertEqual(edge.width / edge.height, 4, accuracy: 0.001)
  }

  func testTheHandleIsTheLowestTrailingCornerOnScreen() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
    // Unrotated: screen y = -page y.
    XCTAssertEqual(PdfSignGeometry.handleCorner(of: rect, toScreen: { CGPoint(x: $0.x, y: -$0.y) }), CGPoint(x: 110, y: 20))
    // A page turned 90° clockwise: page x runs down the screen, page y to the right.
    XCTAssertEqual(PdfSignGeometry.handleCorner(of: rect, toScreen: { CGPoint(x: $0.y, y: $0.x) }), CGPoint(x: 110, y: 60))
  }
}
