// OWNER: HOM-31
//
// XCTests of Compress/PdfCompressCore.swift (BUILD_PLAN HOM-31), run on the iOS Simulator and on
// macOS by Tests/Compress/run_compress_xctests.sh: an image-heavy file shrinks with every preset
// (High > Medium > Small) and still looks the same, a text-only file keeps its text selectable
// and searchable, the stage-2 rewriter handles Quartz's Flate images on its own (the path below
// iOS 16.4), an encrypted file stays encrypted, the estimate matches what a run writes, a
// cancelled run leaves no file and no temporary directory, and bad requests fail typed. Sizes are
// printed as `HOM31|…` lines for BUILD_STATE.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest

final class PdfCompressCoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom31_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

  private func compress(_ source: URL, _ preset: PdfCompressPreset, password: String? = nil) throws -> (URL, PdfCompressOutcome) {
    let out = url("\(source.deletingPathExtension().lastPathComponent)-\(preset).pdf")
    let outcome = try PdfCompressCore.compress(path: source.path, password: password, preset: preset, outPath: out.path)
    return (out, outcome)
  }

  private func platform() -> String {
    #if os(iOS)
    return "ios"
    #else
    return "macos"
    #endif
  }

  /// Mean absolute difference (0…255) of page 0 of [a] and [b] rendered at 200 × 260 px.
  private func pageDifference(_ a: URL, _ b: URL) throws -> Double {
    func pixels(_ url: URL) throws -> [UInt8] {
      let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
      let width = 200, height = 260
      let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let box = page.getBoxRect(.mediaBox)
      context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
      context.drawPDFPage(page)
      let data = try XCTUnwrap(context.data)
      return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
    let pa = try pixels(a), pb = try pixels(b)
    var total = 0
    for i in 0..<pa.count where i % 4 != 3 { total += abs(Int(pa[i]) - Int(pb[i])) }
    return Double(total) / Double(pa.count / 4 * 3)
  }

  func testImageHeavyPdfShrinksWithEveryPresetAndLooksTheSame() throws {
    for jpeg in [false, true] {
      let kind = jpeg ? "camera" : "scan"
      let source = CompressFixtures.writeImagePdf(to: url("\(kind).pdf"), pages: 3, jpeg: jpeg)
      let before = CompressFixtures.size(source)
      var sizes: [Int64] = []
      for preset in PdfCompressPreset.allCases {
        let (out, outcome) = try compress(source, preset)
        let after = CompressFixtures.size(out)
        XCTAssertEqual(after, outcome.sizeBytes)
        XCTAssertEqual(outcome.pageCount, 3)
        XCTAssertLessThan(after, before, "\(kind) \(preset) must shrink")
        let document = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 2)?.string?.contains(CompressFixtures.token("IMG", 2)) ?? false, "the text line survives")
        let difference = try pageDifference(source, out)
        XCTAssertLessThan(difference, 12, "\(kind) \(preset) still shows the same picture")
        print("HOM31|\(platform())|\(kind)|\(preset)|before=\(before)|after=\(after)|saving=\(String(format: "%.1f", 100 - Double(after) * 100 / Double(before)))%|replaced=\(outcome.imagesReplaced)/\(outcome.imagesSeen)|diff=\(String(format: "%.1f", difference))")
        sizes.append(after)
      }
      XCTAssertGreaterThan(sizes[0], sizes[1], "\(kind): High keeps more than Medium")
      XCTAssertGreaterThan(sizes[1], sizes[2], "\(kind): Medium keeps more than Small")
      XCTAssertLessThan(Double(sizes[1]), Double(before) * 0.5, "\(kind): Medium at least halves an image-heavy file")
    }
  }

  func testTextOnlyPdfKeepsSelectableSearchableText() throws {
    let source = CompressFixtures.writeTextPdf(to: url("text.pdf"), pages: 3)
    let before = CompressFixtures.size(source)
    for preset in PdfCompressPreset.allCases {
      let (out, outcome) = try compress(source, preset)
      let document = try XCTUnwrap(PDFDocument(url: out))
      XCTAssertEqual(document.pageCount, 3)
      for page in 0..<3 {
        let token = CompressFixtures.token("TXT", page)
        XCTAssertTrue(document.page(at: page)?.string?.contains(token) ?? false, "\(preset): page \(page) text extracts")
        XCTAssertEqual(document.findString(token, withOptions: []).count, 1, "\(preset): \(token) is found")
      }
      // Selectable: a selection over the first line returns its characters.
      let page = try XCTUnwrap(document.page(at: 0))
      let selection = page.selection(for: CGRect(x: 60, y: 710, width: 400, height: 24))
      XCTAssertTrue(selection?.string?.contains("TXT-P0001") ?? false, "\(preset): the first line selects as text")
      XCTAssertEqual(outcome.imagesSeen, 0)
      print("HOM31|\(platform())|text|\(preset)|before=\(before)|after=\(outcome.sizeBytes)|text=selectable,searchable")
    }
  }

  func testRewriterAloneRecompressesQuartzFlateImages() throws {
    // Below iOS 16.4 / macOS 13.4 stage 1 keeps Flate images; stage 2 must handle them itself.
    let source = CompressFixtures.writeImagePdf(to: url("flate.pdf"), pages: 2, jpeg: false, pixelsPerInch: 150)
    let data = try Data(contentsOf: source)
    let settings = PdfCompressSettings.of(.medium, pdfKitOptions: false)
    let result = try XCTUnwrap(PdfImageRewriter.rewrite(data, settings: settings, isCancelled: { false }, progress: { _ in }))
    XCTAssertEqual(result.seen, 2)
    XCTAssertEqual(result.replaced, 2)
    XCTAssertLessThan(Double(result.data.count), Double(data.count) * 0.2)
    let out = url("flate-rewritten.pdf")
    try result.data.write(to: out)
    let document = try XCTUnwrap(PDFDocument(url: out))
    XCTAssertEqual(document.pageCount, 2)
    XCTAssertTrue(document.page(at: 1)?.string?.contains(CompressFixtures.token("IMG", 1)) ?? false)
    XCTAssertLessThan(try pageDifference(source, out), 12)
    print("HOM31|\(platform())|rewriter-only-flate|medium-fallback|before=\(data.count)|after=\(result.data.count)")
  }

  func testRewriterLeavesFilesItCannotParse() throws {
    XCTAssertNil(try PdfImageRewriter.rewrite(Data("not a pdf".utf8), settings: .of(.small), isCancelled: { false }, progress: { _ in }))
  }

  func testEncryptedPdfStaysEncrypted() throws {
    let plain = CompressFixtures.writeImagePdf(to: url("plain.pdf"), pages: 1, jpeg: true, pixelsPerInch: 200)
    let document = try XCTUnwrap(PDFDocument(url: plain))
    let locked = url("locked.pdf")
    XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
    XCTAssertThrowsError(try compress(locked, .medium)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .passwordRequired) }
    let (out, outcome) = try compress(locked, .medium, password: "pw")
    XCTAssertLessThan(outcome.sizeBytes, CompressFixtures.size(locked))
    let reopened = try XCTUnwrap(PDFDocument(url: out))
    XCTAssertTrue(reopened.isEncrypted)
    XCTAssertTrue(reopened.isLocked)
    XCTAssertTrue(reopened.unlock(withPassword: "pw"))
    XCTAssertEqual(reopened.pageCount, 1)
    let estimate = try PdfCompressCore.estimate(path: locked.path, password: "pw")
    XCTAssertEqual(Double(estimate.presetBytes[1]), Double(outcome.sizeBytes), accuracy: Double(outcome.sizeBytes) * 0.05)
    XCTAssertThrowsError(try PdfCompressCore.estimate(path: locked.path, password: nil)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .passwordRequired)
    }
  }

  func testEstimateMatchesShortFilesAndScalesSampledOnes() throws {
    let short = CompressFixtures.writeImagePdf(to: url("short.pdf"), pages: 2, jpeg: true, pixelsPerInch: 150)
    let estimate = try PdfCompressCore.estimate(path: short.path, password: nil)
    XCTAssertFalse(estimate.sampled)
    XCTAssertEqual(estimate.sourceBytes, CompressFixtures.size(short))
    for preset in PdfCompressPreset.allCases {
      let (_, outcome) = try compress(short, preset)
      XCTAssertEqual(Double(estimate.presetBytes[preset.rawValue]), Double(outcome.sizeBytes), accuracy: Double(outcome.sizeBytes) * 0.02,
                     "an unsampled estimate is what the run writes (\(preset))")
    }
    let long = CompressFixtures.writeImagePdf(to: url("long.pdf"), pages: 9, jpeg: true, pixelsPerInch: 100)
    let sampled = try PdfCompressCore.estimate(path: long.path, password: nil)
    XCTAssertTrue(sampled.sampled)
    let (_, medium) = try compress(long, .medium)
    XCTAssertEqual(Double(sampled.presetBytes[1]), Double(medium.sizeBytes), accuracy: Double(medium.sizeBytes) * 0.35,
                   "a sampled estimate is within 35 % of the run")
    print("HOM31|\(platform())|estimate|long9|medium estimate=\(sampled.presetBytes[1])|actual=\(medium.sizeBytes)")
  }

  func testCancelLeavesNoFileAndNoTemporaryDirectory() throws {
    let source = CompressFixtures.writeImagePdf(to: url("cancel.pdf"), pages: 2, jpeg: false, pixelsPerInch: 150)
    let temp = FileManager.default.temporaryDirectory
    func scratch() -> Set<String> {
      Set(((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("dv_pdf_compress_") })
    }
    let scratchBefore = scratch()
    var total = 0
    let full = url("full.pdf")
    _ = try PdfCompressCore.compress(path: source.path, password: nil, preset: .small, outPath: full.path, isCancelled: {
      total += 1
      return false
    })
    XCTAssertGreaterThanOrEqual(total, 5, "polled before stage 1, between the stages, per image and before the write")
    // Cancel at every point the core polls.
    for cancelAfterPolls in 0..<total {
      let out = url("cancelled-\(cancelAfterPolls).pdf")
      var polls = 0
      XCTAssertThrowsError(try PdfCompressCore.compress(
        path: source.path, password: nil, preset: .small, outPath: out.path,
        isCancelled: {
          polls += 1
          return polls > cancelAfterPolls
        })) { error in
        XCTAssertEqual((error as? PdfFailure)?.code, .cancelled, "poll \(cancelAfterPolls)")
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial file after a cancel at poll \(cancelAfterPolls)")
    }
    XCTAssertEqual(scratch(), scratchBefore, "no temporary directory left behind")
  }

  func testBadRequestsFailTyped() throws {
    let source = CompressFixtures.writeTextPdf(to: url("bad.pdf"), pages: 1)
    XCTAssertThrowsError(try PdfCompressCore.compress(path: source.path, password: nil, preset: .high, outPath: source.path)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument, "an existing output is never overwritten")
    }
    XCTAssertThrowsError(try PdfCompressCore.compress(path: url("none.pdf").path, password: nil, preset: .high, outPath: url("o.pdf").path)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound)
    }
    let damaged = url("damaged.pdf")
    try Data("%PDF-1.4 garbage".utf8).write(to: damaged)
    XCTAssertThrowsError(try PdfCompressCore.compress(path: damaged.path, password: nil, preset: .high, outPath: url("o2.pdf").path)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .damaged)
    }
    XCTAssertThrowsError(try PdfCompressCore.compress(path: source.path, password: nil, preset: .high, outPath: url("no-dir/o.pdf").path)) {
      XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: url("o.pdf").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url("o2.pdf").path))
  }

  func testStripMetadataKeepsTheImage() throws {
    let image = CompressFixtures.photo(width: 64, height: 48, seed: 1)
    let jpeg = try XCTUnwrap(PdfImageRewriter.encodeJpeg(image, quality: 0.6))
    XCTAssertFalse(jpeg.indices.dropLast().contains { jpeg[$0] == 0xFF && (jpeg[$0 + 1] == 0xE1 || jpeg[$0 + 1] == 0xE2) && $0 < 64 })
    let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(decoded.width, 64)
    XCTAssertEqual(decoded.height, 48)
  }
}
