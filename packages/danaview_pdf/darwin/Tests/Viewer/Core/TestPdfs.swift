// OWNER: HOM-24
//
// Locally generated PDFs for the viewer XCTests (no downloads): text pages with one token each
// (CoreText, real text, not outlines), the same encrypted with a user password, a file with an
// outline, a damaged file; plus the committed HOM-27 fixtures (spikes/android_pdf/fixtures, also
// generated) located through DV_PDF_FIXTURES or relative to this file.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest

enum TestPdfs {
  /// A fresh temporary directory, removed by the test case's teardown block.
  static func tempDir(_ test: XCTestCase) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dv_pdf_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// The token on page [index] (0-based) of a generated file.
  static func token(_ prefix: String, _ index: Int) -> String {
    String(format: "%@-P%04d", prefix, index + 1)
  }

  /// Writes [pages] US-letter pages, page i carrying `token(prefix, i)` and a sentence, to [url].
  /// With [userPassword], the file is encrypted (RC4/AES by Core Graphics) and needs it to open.
  @discardableResult
  static func writeTextPdf(to url: URL, pages: Int, prefix: String = "DVPDF", userPassword: String? = nil) -> URL {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [kCGPDFContextTitle: "Generated" as CFString]
    if let userPassword {
      info[kCGPDFContextUserPassword] = userPassword as CFString
      info[kCGPDFContextOwnerPassword] = (userPassword + "-owner") as CFString
    }
    let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for i in 0..<pages {
      context.beginPDFPage(nil)
      for (line, text) in ["\(token(prefix, i)) Danaview sample page", "The quick brown fox jumps over the lazy dog."].enumerated() {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(line) * 30)
        CTLineDraw(ctLine, context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  /// A 3-page text file with a two-level outline (Chapter 1 → page 0 with Section 1.1 → page 1,
  /// Chapter 2 → page 2), written by Core Graphics (`CGPDFContextSetOutline`).
  static func writeOutlinedPdf(in dir: URL) -> URL {
    let url = dir.appendingPathComponent("outlined.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for i in 0..<3 {
      context.beginPDFPage(nil)
      let attributed = NSAttributedString(string: token("OUTL", i), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
      context.textPosition = CGPoint(x: 72, y: 700)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
      context.endPDFPage()
    }
    func entry(_ title: String, _ page: Int, _ children: [[String: Any]] = []) -> [String: Any] {
      var e: [String: Any] = [kCGPDFOutlineTitle as String: title, kCGPDFOutlineDestination as String: page + 1]
      if !children.isEmpty { e[kCGPDFOutlineChildren as String] = children }
      return e
    }
    let outline: [String: Any] = [
      kCGPDFOutlineChildren as String: [entry("Chapter 1", 0, [entry("Section 1.1", 1)]), entry("Chapter 2", 2)],
    ]
    CGPDFContextSetOutline(context, outline as CFDictionary)
    context.closePDF()
    return url
  }

  /// A file that starts like a PDF but is garbage.
  static func writeDamagedPdf(in dir: URL) -> URL {
    let url = dir.appendingPathComponent("damaged.pdf")
    var bytes = Data("%PDF-1.7\n".utf8)
    bytes.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) }))
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: bytes))
    return url
  }

  /// The committed HOM-27 fixture [name], or nil when the directory isn't found.
  static func fixture(_ name: String) -> URL? {
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["DV_PDF_FIXTURES"] { candidates.append(URL(fileURLWithPath: env)) }
    var dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
      candidates.append(dir.appendingPathComponent("spikes/android_pdf/fixtures"))
      dir = dir.deletingLastPathComponent()
    }
    for c in candidates {
      let url = c.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  /// SHA-256-free fingerprint for the read-only checks: bytes and modification date.
  static func fingerprint(_ url: URL) -> (Data, Date?) {
    let data = (try? Data(contentsOf: url)) ?? Data()
    let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    return (data, date)
  }
}
