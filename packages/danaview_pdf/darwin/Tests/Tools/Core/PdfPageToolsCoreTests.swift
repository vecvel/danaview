// OWNER: HOM-28
//
// XCTests of the PDFKit page tools (Classes/Tools/PdfPageToolsCore.swift; HOM plan §8.5) on macOS
// and the iOS Simulator (run_xctests.sh macos | ios-sim): merge of PDFs and images, split by ranges
// and every N pages, reorder, rotate, delete and extract through organise; text stays text after
// every tool (PDFKit finds and selects each page's token in the output); sources keep their bytes
// and dates; outputs are new files only, and a cancel or failure leaves none; progress is monotonic.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest

/// A cancel flag and progress recorder; cancels itself after [cancelAfter] progress reports.
final class RecordingControl: PdfToolControl {
  private let lock = NSLock()
  private var cancelled = false
  private(set) var reports: [(done: Int, total: Int)] = []
  let cancelAfter: Int?

  init(cancelAfter: Int? = nil) {
    self.cancelAfter = cancelAfter
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func progress(done: Int, total: Int) {
    lock.lock()
    reports.append((done, total))
    if let cancelAfter, reports.count >= cancelAfter { cancelled = true }
    lock.unlock()
  }
}

enum TestImages {
  /// A [width] × [height] JPEG (a gradient, opaque) tagged with EXIF [orientation] (1 = up,
  /// 6 = rotate 90° clockwise to display).
  static func writeJpeg(to url: URL, width: Int, height: Int, orientation: Int = 1) -> URL {
    let image = makeImage(width: width, height: height, alpha: false)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return url
  }

  /// A [width] × [height] PNG with a transparent half.
  static func writePng(to url: URL, width: Int, height: Int) -> URL {
    let image = makeImage(width: width, height: height, alpha: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return url
  }

  static func makeImage(width: Int, height: Int, alpha: Bool) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    if alpha { context.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
    context.setFillColor(CGColor(red: 0.7, green: 0.03, blue: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: alpha ? height / 2 : height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
    return context.makeImage()!
  }
}

final class PdfPageToolsCoreTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = TestPdfs.tempDir(self)
  }

  private func pdf(_ name: String, pages: Int, prefix: String, password: String? = nil) -> URL {
    TestPdfs.writeTextPdf(to: dir.appendingPathComponent(name), pages: pages, prefix: prefix, userPassword: password)
  }

  private func out(_ name: String) -> String { dir.appendingPathComponent(name).path }

  private func src(_ url: URL, password: String? = nil, image: Bool = false) -> PdfToolSource {
    PdfToolSource(path: url.path, password: password, isImage: image)
  }

  /// The token each page of [path] starts with ("" for a page without one), read back by PDFKit.
  private func tokens(_ path: String, password: String? = nil) throws -> [String] {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
    if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
    return (0..<document.pageCount).map { i in
      let text = document.page(at: i)?.string ?? ""
      return text.split(separator: " ").first.map(String.init) ?? ""
    }
  }

  /// Text stays text: PDFKit finds [token] as a selection on page [page] of [path].
  private func assertSelectable(_ token: String, onPage page: Int, of path: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)), file: file, line: line)
    let hits = document.findString(token, withOptions: [])
    XCTAssertEqual(hits.count, 1, "\(token) found once", file: file, line: line)
    guard let hit = hits.first, let hitPage = hit.pages.first else { return XCTFail("no selection", file: file, line: line) }
    XCTAssertEqual(document.index(for: hitPage), page, file: file, line: line)
    XCTAssertEqual(hit.string, token, file: file, line: line)
    // A selection across the whole page reads the token too (copy works).
    let all = document.page(at: page)?.selection(for: document.page(at: page)!.bounds(for: .cropBox))?.string ?? ""
    XCTAssertTrue(all.contains(token), file: file, line: line)
  }

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

  // ---------------------------------------------------------------------------------------------
  // Merge

  func testMergeKeepsOrderAndTextAndLeavesTheSourcesAlone() throws {
    let a = pdf("a.pdf", pages: 2, prefix: "AAA")
    let b = pdf("b.pdf", pages: 3, prefix: "BBB")
    let before = (TestPdfs.fingerprint(a), TestPdfs.fingerprint(b))
    let control = RecordingControl()
    let result = try PdfPageToolsCore.merge([src(a), src(b)], outPath: out("m.pdf"), control: control)
    XCTAssertEqual(result.pageCount, 5)
    XCTAssertGreaterThan(result.sizeBytes, 0)
    XCTAssertEqual(try tokens(result.path), ["AAA-P0001", "AAA-P0002", "BBB-P0001", "BBB-P0002", "BBB-P0003"])
    try assertSelectable("AAA-P0002", onPage: 1, of: result.path)
    try assertSelectable("BBB-P0003", onPage: 4, of: result.path)
    XCTAssertEqual(TestPdfs.fingerprint(a).0, before.0.0)
    XCTAssertEqual(TestPdfs.fingerprint(a).1, before.0.1)
    XCTAssertEqual(TestPdfs.fingerprint(b).0, before.1.0)
    XCTAssertEqual(TestPdfs.fingerprint(b).1, before.1.1)
    // Progress: monotonic, same total, ends complete.
    XCTAssertFalse(control.reports.isEmpty)
    XCTAssertTrue(zip(control.reports, control.reports.dropFirst()).allSatisfy { $0.done <= $1.done })
    XCTAssertEqual(Set(control.reports.map(\.total)), [5])
    XCTAssertEqual(control.reports.last?.done, 5)
  }

  func testMergeTheSameFileTwice() throws {
    let a = pdf("a.pdf", pages: 2, prefix: "AAA")
    let result = try PdfPageToolsCore.merge([src(a), src(a)], outPath: out("m.pdf"), control: RecordingControl())
    XCTAssertEqual(try tokens(result.path), ["AAA-P0001", "AAA-P0002", "AAA-P0001", "AAA-P0002"])
  }

  func testMergeImagesAsPagesWithOrientationApplied() throws {
    let a = pdf("a.pdf", pages: 1, prefix: "AAA")
    // Stored landscape 400×200, EXIF orientation 6: shown portrait.
    let jpeg = TestImages.writeJpeg(to: dir.appendingPathComponent("p.jpg"), width: 400, height: 200, orientation: 6)
    let png = TestImages.writePng(to: dir.appendingPathComponent("t.png"), width: 300, height: 150)
    let result = try PdfPageToolsCore.merge([src(jpeg, image: true), src(a), src(png, image: true)], outPath: out("m.pdf"), control: RecordingControl())
    XCTAssertEqual(result.pageCount, 3)
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.path)))
    let first = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
    XCTAssertEqual(first.height, 842, accuracy: 0.5, "the longer side is A4's")
    XCTAssertEqual(first.width, 421, accuracy: 0.5, "orientation 6 makes the page portrait")
    let last = try XCTUnwrap(document.page(at: 2)).bounds(for: .mediaBox)
    XCTAssertEqual(last.width, 842, accuracy: 0.5)
    XCTAssertEqual(last.height, 421, accuracy: 0.5)
    try assertSelectable("AAA-P0001", onPage: 1, of: result.path)
  }

  func testMergeTwoImagesOnly() throws {
    let a = TestImages.writeJpeg(to: dir.appendingPathComponent("a.jpg"), width: 120, height: 160)
    let b = TestImages.writePng(to: dir.appendingPathComponent("b.png"), width: 160, height: 120)
    let result = try PdfPageToolsCore.merge([src(a, image: true), src(b, image: true)], outPath: out("m.pdf"), control: RecordingControl())
    XCTAssertEqual(result.pageCount, 2)
  }

  func testMergeOpensPasswordFilesOnlyWithTheirPassword() throws {
    let locked = pdf("l.pdf", pages: 2, prefix: "LCK", password: "pw")
    let a = pdf("a.pdf", pages: 1, prefix: "AAA")
    XCTAssertEqual(code { try PdfPageToolsCore.merge([src(a), src(locked)], outPath: self.out("x.pdf"), control: RecordingControl()) }, .passwordRequired)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))
    let result = try PdfPageToolsCore.merge([src(a), src(locked, password: "pw")], outPath: out("m.pdf"), control: RecordingControl())
    // HOM-29: the output of an encrypted input is encrypted with its password.
    XCTAssertTrue(PDFDocument(url: URL(fileURLWithPath: result.path))?.isLocked ?? false)
    XCTAssertEqual(try tokens(result.path, password: "pw"), ["AAA-P0001", "LCK-P0001", "LCK-P0002"])
  }

  func testMergeRejectsBadInputsWithoutWriting() throws {
    let a = pdf("a.pdf", pages: 1, prefix: "AAA")
    let control = RecordingControl()
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a)], outPath: self.out("x.pdf"), control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a), PdfToolSource(path: self.out("none.pdf"))], outPath: self.out("x.pdf"), control: control) }, .notFound)
    let damaged = TestPdfs.writeDamagedPdf(in: dir)
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a), self.src(damaged)], outPath: self.out("x.pdf"), control: control) }, .damaged)
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a), self.src(damaged, image: true)], outPath: self.out("x.pdf"), control: control) }, .damaged)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))
  }

  func testOutputsAreNewFilesOnly() throws {
    let a = pdf("a.pdf", pages: 2, prefix: "AAA")
    let existing = pdf("existing.pdf", pages: 1, prefix: "OLD")
    let before = TestPdfs.fingerprint(existing)
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a), self.src(a)], outPath: existing.path, control: RecordingControl()) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [PdfPagePlanItem(1)], outPath: a.path, control: RecordingControl()) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [PdfPagePlanItem(1)], outPath: self.out("no/such/dir.pdf"), control: RecordingControl()) }, .notFound)
    XCTAssertEqual(TestPdfs.fingerprint(existing).0, before.0)
  }

  func testCancelLeavesNoFile() throws {
    let a = pdf("a.pdf", pages: 20, prefix: "AAA")
    let b = pdf("b.pdf", pages: 20, prefix: "BBB")
    let control = RecordingControl(cancelAfter: 5)
    XCTAssertEqual(code { try PdfPageToolsCore.merge([self.src(a), self.src(b)], outPath: self.out("m.pdf"), control: control) }, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("m.pdf")))

    let early = RecordingControl()
    early.cancel()
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [PdfPagePlanItem(3)], outPath: self.out("o.pdf"), control: early) }, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("o.pdf")))

    let splitCancel = RecordingControl(cancelAfter: 8)
    XCTAssertEqual(code {
      try PdfPageToolsCore.split(self.src(a), ranges: PdfPageToolsCore.rangesEvery(5, pageCount: 20), outPaths: (1...4).map { self.out("s\($0).pdf") }, control: splitCancel)
    }, .cancelled)
    for i in 1...4 { XCTAssertFalse(FileManager.default.fileExists(atPath: out("s\(i).pdf")), "split part \(i) removed") }
  }

  // ---------------------------------------------------------------------------------------------
  // Split

  func testSplitByRanges() throws {
    let a = pdf("a.pdf", pages: 5, prefix: "SPL")
    let before = TestPdfs.fingerprint(a)
    let files = try PdfPageToolsCore.split(src(a), ranges: [0..<2, 2..<5, 1..<2], outPaths: [out("1.pdf"), out("2.pdf"), out("3.pdf")], control: RecordingControl())
    XCTAssertEqual(files.map(\.pageCount), [2, 3, 1])
    XCTAssertEqual(try tokens(files[0].path), ["SPL-P0001", "SPL-P0002"])
    XCTAssertEqual(try tokens(files[1].path), ["SPL-P0003", "SPL-P0004", "SPL-P0005"])
    XCTAssertEqual(try tokens(files[2].path), ["SPL-P0002"], "overlapping ranges still find their pages")
    try assertSelectable("SPL-P0004", onPage: 1, of: files[1].path)
    XCTAssertEqual(TestPdfs.fingerprint(a).0, before.0)
    XCTAssertEqual(TestPdfs.fingerprint(a).1, before.1)
  }

  func testSplitEveryNPages() throws {
    XCTAssertEqual(PdfPageToolsCore.rangesEvery(2, pageCount: 5), [0..<2, 2..<4, 4..<5])
    XCTAssertEqual(PdfPageToolsCore.rangesEvery(5, pageCount: 5), [0..<5])
    XCTAssertEqual(PdfPageToolsCore.rangesEvery(0, pageCount: 5), [])
    let a = pdf("a.pdf", pages: 5, prefix: "EVR")
    let ranges = PdfPageToolsCore.rangesEvery(2, pageCount: 5)
    let files = try PdfPageToolsCore.split(src(a), ranges: ranges, outPaths: (0..<3).map { out("e\($0).pdf") }, control: RecordingControl())
    XCTAssertEqual(files.map(\.pageCount), [2, 2, 1])
    XCTAssertEqual(try tokens(files[2].path), ["EVR-P0005"])
  }

  func testSplitRejectsBadRangesWithoutWriting() throws {
    let a = pdf("a.pdf", pages: 3, prefix: "AAA")
    let control = RecordingControl()
    XCTAssertEqual(code { try PdfPageToolsCore.split(self.src(a), ranges: [0..<4], outPaths: [self.out("x.pdf")], control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.split(self.src(a), ranges: [1..<1], outPaths: [self.out("x.pdf")], control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.split(self.src(a), ranges: [0..<1, 1..<2], outPaths: [self.out("x.pdf")], control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.split(self.src(a), ranges: [0..<1, 1..<2], outPaths: [self.out("x.pdf"), self.out("x.pdf")], control: control) }, .invalidArgument)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("x.pdf")))
  }

  // ---------------------------------------------------------------------------------------------
  // Organise: reorder, rotate, delete, extract

  func testReorder() throws {
    let a = pdf("a.pdf", pages: 4, prefix: "ORD")
    let plan = try PdfPageToolsCore.reorderPlan([2, 0, 3, 1], pageCount: 4)
    let result = try PdfPageToolsCore.organise(src(a), plan: plan, outPath: out("o.pdf"), control: RecordingControl())
    XCTAssertEqual(try tokens(result.path), ["ORD-P0003", "ORD-P0001", "ORD-P0004", "ORD-P0002"])
    try assertSelectable("ORD-P0004", onPage: 2, of: result.path)
    XCTAssertEqual(code { try PdfPageToolsCore.reorderPlan([0, 0, 1, 2], pageCount: 4) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.reorderPlan([0, 1, 2], pageCount: 4) }, .invalidArgument)
  }

  func testReorderEveryPermutationOfFourPages() throws {
    let a = pdf("a.pdf", pages: 4, prefix: "PRM")
    func permutations(_ xs: [Int]) -> [[Int]] {
      xs.count <= 1 ? [xs] : xs.flatMap { x in permutations(xs.filter { $0 != x }).map { [x] + $0 } }
    }
    for (i, order) in permutations([0, 1, 2, 3]).enumerated() {
      let result = try PdfPageToolsCore.organise(src(a), plan: order.map { PdfPagePlanItem($0) }, outPath: out("p\(i).pdf"), control: RecordingControl())
      XCTAssertEqual(try tokens(result.path), order.map { TestPdfs.token("PRM", $0) }, "\(order)")
    }
  }

  func testRotateSelectedPages() throws {
    let a = pdf("a.pdf", pages: 3, prefix: "ROT")
    let plan = try PdfPageToolsCore.rotatePlan([0, 2], degrees: 90, pageCount: 3)
    let once = try PdfPageToolsCore.organise(src(a), plan: plan, outPath: out("r.pdf"), control: RecordingControl())
    var document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: once.path)))
    XCTAssertEqual((0..<3).map { document.page(at: $0)!.rotation }, [90, 0, 90])
    try assertSelectable("ROT-P0001", onPage: 0, of: once.path)
    // Rotating again adds up; a negative turn wraps.
    let twice = try PdfPageToolsCore.organise(
      PdfToolSource(path: once.path), plan: [PdfPagePlanItem(0, rotation: 90), PdfPagePlanItem(1, rotation: -90), PdfPagePlanItem(2, rotation: 270)],
      outPath: out("r2.pdf"), control: RecordingControl())
    document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: twice.path)))
    XCTAssertEqual((0..<3).map { document.page(at: $0)!.rotation }, [180, 270, 0])
    XCTAssertEqual(code { try PdfPageToolsCore.rotatePlan([0], degrees: 45, pageCount: 3) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.rotatePlan([3], degrees: 90, pageCount: 3) }, .invalidArgument)
  }

  func testDeletePages() throws {
    let a = pdf("a.pdf", pages: 5, prefix: "DEL")
    let plan = try PdfPageToolsCore.deletePlan([1, 3], pageCount: 5)
    let result = try PdfPageToolsCore.organise(src(a), plan: plan, outPath: out("d.pdf"), control: RecordingControl())
    XCTAssertEqual(try tokens(result.path), ["DEL-P0001", "DEL-P0003", "DEL-P0005"])
    try assertSelectable("DEL-P0005", onPage: 2, of: result.path)
    XCTAssertEqual(code { try PdfPageToolsCore.deletePlan([0, 1, 2, 3, 4], pageCount: 5) }, .invalidArgument, "one page must remain")
    XCTAssertEqual(code { try PdfPageToolsCore.deletePlan([], pageCount: 5) }, .invalidArgument)
  }

  func testOrganiseCombinesReorderRotateDeleteAndExtract() throws {
    let a = pdf("a.pdf", pages: 6, prefix: "ORG")
    // Extract pages 5, 1 and 3 in that order, the first turned a quarter.
    let plan = [PdfPagePlanItem(4, rotation: 90), PdfPagePlanItem(0), PdfPagePlanItem(2)]
    let control = RecordingControl()
    let result = try PdfPageToolsCore.organise(src(a), plan: plan, outPath: out("x.pdf"), control: control)
    XCTAssertEqual(try tokens(result.path), ["ORG-P0005", "ORG-P0001", "ORG-P0003"])
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.path)))
    XCTAssertEqual((0..<3).map { document.page(at: $0)!.rotation }, [90, 0, 0])
    XCTAssertEqual(control.reports.last.map { [$0.done, $0.total] }, [6, 6])
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [], outPath: self.out("y.pdf"), control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [PdfPagePlanItem(1), PdfPagePlanItem(1)], outPath: self.out("y.pdf"), control: control) }, .invalidArgument)
    XCTAssertEqual(code { try PdfPageToolsCore.organise(self.src(a), plan: [PdfPagePlanItem(9)], outPath: self.out("y.pdf"), control: control) }, .invalidArgument)
    XCTAssertFalse(FileManager.default.fileExists(atPath: out("y.pdf")))
  }

  func testOrganiseKeepsTheOutline() throws {
    let outlined = TestPdfs.writeOutlinedPdf(in: dir)
    let result = try PdfPageToolsCore.organise(src(outlined), plan: [PdfPagePlanItem(2), PdfPagePlanItem(0), PdfPagePlanItem(1)], outPath: out("o.pdf"), control: RecordingControl())
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.path)))
    let outline = PdfReader.outline(of: document)
    XCTAssertEqual(outline.map(\.title), ["Chapter 1", "Section 1.1", "Chapter 2"])
    XCTAssertEqual(outline.map(\.pageIndex), [1, 2, 0], "entries follow their pages")
  }

  func testLargeFileMergeAndOrganiseFinish() throws {
    let a = pdf("a.pdf", pages: 300, prefix: "BIG")
    let b = pdf("b.pdf", pages: 200, prefix: "BIH")
    let merged = try PdfPageToolsCore.merge([src(a), src(b)], outPath: out("m.pdf"), control: RecordingControl())
    XCTAssertEqual(merged.pageCount, 500)
    try assertSelectable("BIH-P0200", onPage: 499, of: merged.path)
    let reversed = try PdfPageToolsCore.organise(
      PdfToolSource(path: merged.path), plan: (0..<500).reversed().map { PdfPagePlanItem($0) }, outPath: out("r.pdf"), control: RecordingControl())
    XCTAssertEqual(reversed.pageCount, 500)
    try assertSelectable("BIG-P0001", onPage: 499, of: reversed.path)
  }

  func testHom27FixturesKeepTheirTextThroughMergeAndOrganise() throws {
    guard let big = TestPdfs.fixture("text_200p.pdf"), let partner = TestPdfs.fixture("merge_partner_3p.pdf") else {
      throw XCTSkip("HOM-27 fixtures not found")
    }
    let originals = [try XCTUnwrap(PDFDocument(url: big)), try XCTUnwrap(PDFDocument(url: partner))]
    let texts = originals.flatMap { d in (0..<d.pageCount).map { d.page(at: $0)?.string ?? "" } }
    let rotations = originals.flatMap { d in (0..<d.pageCount).map { d.page(at: $0)?.rotation ?? 0 } }
    let merged = try PdfPageToolsCore.merge([src(big), src(partner)], outPath: out("m.pdf"), control: RecordingControl())
    XCTAssertEqual(merged.pageCount, texts.count)
    let count = texts.count
    let reversed = try PdfPageToolsCore.organise(
      PdfToolSource(path: merged.path), plan: (0..<count).reversed().map { PdfPagePlanItem($0) }, outPath: out("r.pdf"), control: RecordingControl())
    let output = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: reversed.path)))
    for i in 0..<count {
      XCTAssertEqual(output.page(at: count - 1 - i)?.string, texts[i], "page \(i) text")
      XCTAssertEqual(output.page(at: count - 1 - i)?.rotation, rotations[i], "page \(i) keeps its /Rotate")
    }
  }
}
