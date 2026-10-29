// OWNER: HOM-29
//
// XCTests of annotate and highlight (Classes/Annotate/PdfAnnotateCore.swift; HOM plan §8.5) on
// macOS and the iOS Simulator (Tests/Viewer/run_xctests.sh macos | ios-sim): every annotation kind
// is written as a real PDF annotation, read back with its geometry, colour and text, and is still
// editable (changed and written again by PDFKit); text stays selectable and searchable; the file's
// own annotations stay intact; an encrypted source gives an encrypted output with its password;
// a cancel at any step or a bad request leaves no file; image stamps are kept as Stamp
// annotations or burned into the page (HOM-30's hooks) with text, rotation, boxes and the outline
// kept. Uses the HOM-28 helpers (RecordingControl, TestImages) and TestPdfs.

import CoreGraphics
import Foundation
import PDFKit
import XCTest

final class PdfAnnotateCoreTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = TestPdfs.tempDir(self)
  }

  private func pdf(_ name: String, pages: Int, prefix: String, password: String? = nil) -> URL {
    TestPdfs.writeTextPdf(to: dir.appendingPathComponent(name), pages: pages, prefix: prefix, userPassword: password)
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

  /// The line rects (Pigeon page space) of [token] on page [index] of [url].
  private func lineRects(of token: String, page index: Int, in url: URL, password: String? = nil) throws -> [CGRect] {
    let document = try XCTUnwrap(PDFDocument(url: url))
    if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
    let page = try XCTUnwrap(document.page(at: index))
    let range = (page.string! as NSString).range(of: token)
    let selection = try XCTUnwrap(page.selection(for: range))
    let lines = PdfAnnotateCore.lineRects(selection, in: document)
    XCTAssertEqual(lines.map(\.pageIndex), [index])
    return lines.first?.rects ?? []
  }

  private func annotations(_ path: String, page: Int, password: String? = nil) throws -> [PDFAnnotation] {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
    if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
    return try XCTUnwrap(document.page(at: page)).annotations.filter { $0.type != "Popup" }
  }

  /// RGBA of page [index] of [path] rendered at 1 px per point (annotations included), at the
  /// page-space point [p].
  private func pixel(_ path: String, page index: Int, at p: CGPoint) throws -> (r: Int, g: Int, b: Int) {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
    let page = try XCTUnwrap(document.page(at: index))
    let box = page.bounds(for: .mediaBox)
    let w = Int(box.width)
    let h = Int(box.height)
    let ctx = try XCTUnwrap(CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: -box.minX, y: -box.minY)
    let rotation = page.rotation
    page.rotation = 0
    page.draw(with: .mediaBox, to: ctx)
    page.rotation = rotation
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

  private func specs(rects: [CGRect]) -> [PdfAnnotationSpec] {
    [
      PdfAnnotationSpec(kind: .highlight, pageIndex: 0, rects: rects, colorArgb: 0x80FF_D60A),
      PdfAnnotationSpec(kind: .underline, pageIndex: 0, rects: rects, colorArgb: 0xFF1E_88E5),
      PdfAnnotationSpec(kind: .strikeOut, pageIndex: 0, rects: rects, colorArgb: 0xFFE5_3935),
      PdfAnnotationSpec(kind: .ink, pageIndex: 1, strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160), CGPoint(x: 260, y: 120)], [CGPoint(x: 300, y: 300)]],
                        colorArgb: 0xFF00_0000, lineWidth: 4),
      PdfAnnotationSpec(kind: .freeText, pageIndex: 1, rects: [CGRect(x: 72, y: 400, width: 220, height: 0)], colorArgb: 0xFF1E_88E5, text: "Check this figure"),
      PdfAnnotationSpec(kind: .note, pageIndex: 1, rects: [CGRect(x: 500, y: 700, width: 0, height: 0)], colorArgb: 0xFFFF_D60A, text: "A note"),
    ]
  }

  // ---------------------------------------------------------------------------------------------

  func testEveryKindRoundTripsAsAnEditableAnnotation() throws {
    let source = pdf("a.pdf", pages: 2, prefix: "ANN")
    let before = TestPdfs.fingerprint(source)
    let rects = try lineRects(of: "ANN-P0001", page: 0, in: source)
    XCTAssertEqual(rects.count, 1)
    let control = RecordingControl()
    let written = try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: specs(rects: rects), outPath: out("o.pdf"), control: control)
    XCTAssertEqual(written.pageCount, 2)
    XCTAssertGreaterThan(written.sizeBytes, 0)
    XCTAssertEqual(control.reports.last?.done, control.reports.last?.total)
    // The source is untouched.
    XCTAssertEqual(TestPdfs.fingerprint(source).0, before.0)
    XCTAssertEqual(TestPdfs.fingerprint(source).1, before.1)
    XCTAssertTrue(try annotations(source.path, page: 0).isEmpty)

    let first = try annotations(written.path, page: 0)
    XCTAssertEqual(first.map(\.type), ["Highlight", "Underline", "StrikeOut"])
    for a in first {
      XCTAssertEqual(a.quadrilateralPoints?.count, 4, "one quadrilateral per line")
      XCTAssertEqual(a.bounds.minX, rects[0].minX, accuracy: 0.5)
      XCTAssertEqual(a.bounds.width, rects[0].width, accuracy: 0.5)
    }
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    first[1].color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    XCTAssertEqual(red, 0x1E / 255, accuracy: 0.02)
    XCTAssertEqual(blue, 0xE5 / 255, accuracy: 0.02)

    let second = try annotations(written.path, page: 1)
    XCTAssertEqual(second.map(\.type), ["Ink", "FreeText", "Text"])
    XCTAssertEqual(second[0].paths?.count, 2, "one path per stroke")
    XCTAssertEqual(second[0].border?.lineWidth ?? 0, 4, accuracy: 0.01)
    XCTAssertTrue(second[0].bounds.contains(CGPoint(x: 200, y: 160)))
    XCTAssertEqual(second[1].contents, "Check this figure")
    XCTAssertEqual(second[1].bounds.minX, 72, accuracy: 0.5)
    XCTAssertEqual(second[1].bounds.maxY, 400, accuracy: 0.5, "the box hangs from its top edge")
    XCTAssertGreaterThan(second[1].bounds.height, PdfAnnotateCore.freeTextFontSize)
    XCTAssertEqual(second[2].contents, "A note")

    // Still editable: another app (here PDFKit) changes, removes and writes them again.
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    let page1 = try XCTUnwrap(document.page(at: 1))
    let text = try XCTUnwrap(page1.annotations.first { $0.type == "FreeText" })
    text.contents = "Edited"
    let page0 = try XCTUnwrap(document.page(at: 0))
    page0.removeAnnotation(try XCTUnwrap(page0.annotations.first { $0.type == "StrikeOut" }))
    XCTAssertTrue(document.write(to: URL(fileURLWithPath: out("edited.pdf"))))
    XCTAssertEqual(try annotations(out("edited.pdf"), page: 0).map(\.type), ["Highlight", "Underline"])
    XCTAssertEqual(try annotations(out("edited.pdf"), page: 1).first { $0.type == "FreeText" }?.contents, "Edited")
  }

  func testMarkupIsVisibleAndTextStaysSelectableAndSearchable() throws {
    let source = pdf("a.pdf", pages: 3, prefix: "TXT")
    let rects = try lineRects(of: "TXT-P0002", page: 1, in: source)
    let spec = PdfAnnotationSpec(kind: .highlight, pageIndex: 1, rects: rects, colorArgb: 0xFFFF_D60A)
    let ink = PdfAnnotationSpec(kind: .ink, pageIndex: 2, strokes: [[CGPoint(x: 72, y: 600), CGPoint(x: 72, y: 720)]], colorArgb: 0xFF00_00FF, lineWidth: 6)
    let written = try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [spec, ink], outPath: out("o.pdf"), control: RecordingControl())
    for i in 0..<3 { try assertSearchable(TestPdfs.token("TXT", i), page: i, in: written.path) }
    // The highlight shows: a yellow-ish pixel in a gap of the highlighted line.
    let r = rects[0]
    let shown = try pixel(written.path, page: 1, at: CGPoint(x: r.midX, y: r.minY + 1.5))
    XCTAssertGreaterThan(shown.r, 200)
    // PDFKit paints highlights translucent (multiplied over the page): clearly yellow, not white.
    XCTAssertLessThan(shown.b, 220, "highlighted")
    XCTAssertGreaterThan(shown.r - shown.b, 40, "highlighted")
    let ink2 = try pixel(written.path, page: 2, at: CGPoint(x: 72, y: 660))
    XCTAssertGreaterThan(ink2.b, 150)
    XCTAssertLessThan(ink2.r, 80, "the ink stroke is drawn")
  }

  func testTheFilesOwnAnnotationsStayIntact() throws {
    // A source that already has a link-free square and a note.
    let plain = pdf("plain.pdf", pages: 1, prefix: "OWN")
    let document = try XCTUnwrap(PDFDocument(url: plain))
    let page = try XCTUnwrap(document.page(at: 0))
    let square = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 80, height: 40), forType: .square, withProperties: nil)
    square.color = PdfAnnotateCore.color(0xFF00_AA00)
    page.addAnnotation(square)
    let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "Original"
    page.addAnnotation(note)
    let source = dir.appendingPathComponent("owned.pdf")
    XCTAssertTrue(document.write(to: source))
    var sources = [source]
    if let fixture = TestPdfs.fixture("annotated_2p.pdf") { sources.append(fixture) }
    for (n, url) in sources.enumerated() {
      let original = try XCTUnwrap(PDFDocument(url: url)).page(at: 0)!.annotations.filter { $0.type != "Popup" }
      XCTAssertFalse(original.isEmpty)
      let ink = PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)]], colorArgb: 0xFF00_0000, lineWidth: 2)
      let written = try PdfAnnotateCore.annotate(PdfToolSource(path: url.path), annotations: [ink], outPath: out("o\(n).pdf"), control: RecordingControl())
      let after = try annotations(written.path, page: 0)
      XCTAssertEqual(after.count, original.count + 1)
      for (a, b) in zip(original, after) {
        XCTAssertEqual(a.type, b.type)
        XCTAssertEqual(a.bounds.minX, b.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(a.bounds.minY, b.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(a.contents ?? "", b.contents ?? "")
      }
      XCTAssertEqual(after.last?.type, "Ink")
    }
  }

  func testEncryptedInGivesEncryptedOut() throws {
    let source = pdf("locked.pdf", pages: 2, prefix: "ENC", password: "s3cret")
    let rects = try lineRects(of: "ENC-P0001", page: 0, in: source, password: "s3cret")
    let spec = PdfAnnotationSpec(kind: .highlight, pageIndex: 0, rects: rects)
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [spec], outPath: self.out("x.pdf"), control: RecordingControl()) }, .passwordRequired)
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path, password: "wrong"), annotations: [spec], outPath: self.out("x.pdf"), control: RecordingControl()) }, .passwordRequired)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))

    let written = try PdfAnnotateCore.annotate(PdfToolSource(path: source.path, password: "s3cret"), annotations: [spec], outPath: out("o.pdf"), control: RecordingControl())
    let reopened = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    XCTAssertTrue(reopened.isEncrypted, "the output stays encrypted")
    XCTAssertTrue(reopened.isLocked, "it needs the password")
    XCTAssertFalse(reopened.unlock(withPassword: "wrong"))
    XCTAssertTrue(reopened.unlock(withPassword: "s3cret"))
    XCTAssertEqual(reopened.page(at: 0)?.annotations.map(\.type), ["Highlight"])
    try assertSearchable("ENC-P0002", page: 1, in: written.path, password: "s3cret")
  }

  func testCancelAtEveryStepLeavesNoFile() throws {
    let source = pdf("a.pdf", pages: 3, prefix: "CNL")
    let specs = (0..<3).map {
      PdfAnnotationSpec(kind: .ink, pageIndex: $0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)]], colorArgb: 0xFF00_0000, lineWidth: 2)
    }
    let pre = RecordingControl()
    pre.cancel()
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: specs, outPath: self.out("c0.pdf"), control: pre) }, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("c0.pdf")))
    // Reports: the start, then one per page (3); the 5th comes after the write, when the file is
    // complete, so a cancel can land after any of the first 4.
    for n in 1...4 {
      let path = out("c\(n).pdf")
      XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: specs, outPath: path, control: RecordingControl(cancelAfter: n)) },
                     .cancelled, "cancel after \(n) reports")
      XCTAssertFalse(FileManager.default.fileExists(atPath: path), "no file after cancel \(n)")
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("c") }
    XCTAssertEqual(leftovers, [])
  }

  func testBadRequestsAreRejectedWithoutWriting() throws {
    let source = pdf("a.pdf", pages: 1, prefix: "BAD")
    let ok = PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: 1, y: 1)]])
    let cases: [(String, [PdfAnnotationSpec], String, PdfErrorCode)] = [
      ("page", [PdfAnnotationSpec(kind: .ink, pageIndex: 1, strokes: [[CGPoint(x: 1, y: 1)]])], out("x1.pdf"), .invalidArgument),
      ("markup without rects", [PdfAnnotationSpec(kind: .highlight, pageIndex: 0)], out("x2.pdf"), .invalidArgument),
      ("empty text", [PdfAnnotationSpec(kind: .freeText, pageIndex: 0, rects: [CGRect(x: 1, y: 1, width: 10, height: 10)], text: "  ")], out("x3.pdf"), .invalidArgument),
      ("ink without points", [PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[]])], out("x4.pdf"), .invalidArgument),
      ("not finite", [PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: CGFloat.nan, y: 1)]])], out("x5.pdf"), .invalidArgument),
      ("output is the input", [ok], source.path, .invalidArgument),
      ("output folder missing", [ok], dir.appendingPathComponent("none/x.pdf").path, .notFound),
    ]
    for (name, specs, path, expected) in cases {
      XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: specs, outPath: path, control: RecordingControl()) }, expected, name)
      if path != source.path { XCTAssertFalse(FileManager.default.fileExists(atPath: path), name) }
    }
    FileManager.default.createFile(atPath: out("exists.pdf"), contents: Data("x".utf8))
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [ok], outPath: self.out("exists.pdf"), control: RecordingControl()) }, .invalidArgument)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out("exists.pdf"))), Data("x".utf8), "an existing file is never overwritten")
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: self.out("none.pdf")), annotations: [ok], outPath: self.out("y.pdf"), control: RecordingControl()) }, .notFound)
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: TestPdfs.writeDamagedPdf(in: self.dir).path), annotations: [ok], outPath: self.out("y.pdf"), control: RecordingControl()) }, .damaged)
  }

  // ---------------------------------------------------------------------------------------------
  // HOM-30's hooks: image stamps, kept or burned in.

  func testStampsAreKeptAsStampAnnotationsWithTheImage() throws {
    let source = pdf("a.pdf", pages: 1, prefix: "STP")
    let image = TestImages.writePng(to: dir.appendingPathComponent("sig.png"), width: 200, height: 100)
    let stamp = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 300, y: 200, width: 200, height: 100), imagePath: image.path)
    let written = try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [], stamps: [stamp], outPath: out("o.pdf"), control: RecordingControl())
    let after = try annotations(written.path, page: 0)
    XCTAssertEqual(after.map(\.type), ["Stamp"])
    XCTAssertEqual(after[0].bounds.minX, 300, accuracy: 0.5)
    // The image's opaque (lower) half is red; its upper half is transparent.
    let red = try pixel(written.path, page: 0, at: CGPoint(x: 450, y: 220))
    XCTAssertGreaterThan(red.r, 140)
    XCTAssertLessThan(red.g, 60)
    let clear = try pixel(written.path, page: 0, at: CGPoint(x: 450, y: 290))
    XCTAssertGreaterThan(clear.g, 230, "transparency is kept")
    try assertSearchable("STP-P0001", page: 0, in: written.path)
    XCTAssertEqual(code { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [], stamps: [PdfStampSpec(pageIndex: 0, rect: stamp.rect, imagePath: self.out("none.png"))], outPath: self.out("x.pdf"), control: RecordingControl()) }, .notFound)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))
  }

  func testBurnInDrawsIntoThePageAndKeepsTextBoxesRotationOutlineAndOwnAnnotations() throws {
    let outlined = TestPdfs.writeOutlinedPdf(in: dir)
    let document = try XCTUnwrap(PDFDocument(url: outlined))
    let page0 = try XCTUnwrap(document.page(at: 0))
    page0.rotation = 90
    page0.setBounds(CGRect(x: 10, y: 10, width: 592, height: 772), for: .cropBox)
    let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "Kept"
    page0.addAnnotation(note)
    let source = dir.appendingPathComponent("prepared.pdf")
    XCTAssertTrue(document.write(to: source))

    let image = TestImages.writePng(to: dir.appendingPathComponent("sig.png"), width: 200, height: 100)
    // Pigeon page space starts at the crop box: (290, 190) is (300, 200) in PDF space.
    let stamp = PdfStampSpec(pageIndex: 0, rect: CGRect(x: 290, y: 190, width: 200, height: 100), imagePath: image.path)
    let ink = PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: 90, y: 490), CGPoint(x: 90, y: 590)]], colorArgb: 0xFF00_00FF, lineWidth: 6)
    let written = try PdfAnnotateCore.annotate(
      PdfToolSource(path: source.path), annotations: [ink], stamps: [stamp], burnIn: true, outPath: out("burned.pdf"), control: RecordingControl())
    let result = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: written.path)))
    let page = try XCTUnwrap(result.page(at: 0))
    XCTAssertEqual(page.annotations.filter { $0.type != "Popup" }.map(\.type), ["Text"], "only the page's own annotation is an annotation")
    XCTAssertEqual(page.annotations.first { $0.type == "Text" }?.contents, "Kept")
    XCTAssertEqual(page.rotation, 90)
    XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 10, y: 10, width: 592, height: 772))
    let red = try pixel(written.path, page: 0, at: CGPoint(x: 450, y: 220))
    XCTAssertGreaterThan(red.r, 140, "the stamp is in the page content")
    XCTAssertLessThan(red.g, 60)
    let blue = try pixel(written.path, page: 0, at: CGPoint(x: 100, y: 550))
    XCTAssertGreaterThan(blue.b, 150, "the ink is in the page content")
    try assertSearchable("OUTL-P0001", page: 0, in: written.path)
    // The outline still points at the burned page.
    let chapter = try XCTUnwrap(result.outlineRoot?.child(at: 0))
    XCTAssertEqual(chapter.label, "Chapter 1")
    XCTAssertEqual(chapter.destination?.page.map { result.index(for: $0) }, 0)
    XCTAssertEqual(result.pageCount, 3)
  }

  // ---------------------------------------------------------------------------------------------
  // The viewer's helpers

  func testHitTestFindsTheTopmostItem() {
    let items: [(id: String, kind: PdfAnnotationKind?, bounds: CGRect, rects: [CGRect], strokes: [[CGPoint]], lineWidth: CGFloat)] = [
      ("mark", .highlight, CGRect(x: 0, y: 0, width: 100, height: 40), [CGRect(x: 0, y: 0, width: 100, height: 15), CGRect(x: 0, y: 25, width: 60, height: 15)], [], 0),
      ("ink", .ink, CGRect(x: 0, y: 0, width: 200, height: 200), [], [[CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)]], 2),
      ("box", .freeText, CGRect(x: 150, y: 150, width: 40, height: 20), [], [], 0),
    ]
    XCTAssertEqual(PdfAnnotateCore.hitTest(items, at: CGPoint(x: 50, y: 5), tolerance: 4), "mark")
    XCTAssertNil(PdfAnnotateCore.hitTest(items, at: CGPoint(x: 80, y: 32), tolerance: 4), "between the lines' rects, past the second line")
    XCTAssertEqual(PdfAnnotateCore.hitTest(items, at: CGPoint(x: 120, y: 103), tolerance: 4), "ink")
    XCTAssertNil(PdfAnnotateCore.hitTest(items, at: CGPoint(x: 120, y: 120), tolerance: 4), "away from the stroke")
    XCTAssertEqual(PdfAnnotateCore.hitTest(items, at: CGPoint(x: 160, y: 160), tolerance: 4), "box")
    XCTAssertEqual(PdfAnnotateCore.distance(CGPoint(x: 5, y: 5), CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 5, accuracy: 0.001)
  }

  func testLineRectsGroupASelectionByPage() throws {
    let source = pdf("a.pdf", pages: 2, prefix: "SEL")
    let document = try XCTUnwrap(PDFDocument(url: source))
    let p0 = try XCTUnwrap(document.page(at: 0))
    let p1 = try XCTUnwrap(document.page(at: 1))
    let a = try XCTUnwrap(p0.selection(for: NSRange(location: 0, length: (p0.string! as NSString).length)))
    let b = try XCTUnwrap(p1.selection(for: NSRange(location: 0, length: 9)))
    a.add(b)
    let lines = PdfAnnotateCore.lineRects(a, in: document)
    XCTAssertEqual(lines.map(\.pageIndex), [0, 1])
    XCTAssertEqual(lines[0].rects.count, 2, "two text lines on page 1")
    XCTAssertEqual(lines[1].rects.count, 1)
  }
}
