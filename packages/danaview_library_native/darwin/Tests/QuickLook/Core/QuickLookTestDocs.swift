// OWNER: HOM-26
//
// Locally generated documents for the Quick Look and document-thumbnail XCTests (nothing is
// downloaded): hand-written PDFs with a red marker in the top-left corner of the first page (any
// size, /Rotate, several pages), encrypted PDFs written by CoreGraphics (one that opens with the
// empty password, one that needs a password), a damaged PDF, Office files (docx, xlsx, pptx zipped
// with /usr/bin/zip), text, CSV and a file of an unknown type.

import CoreGraphics
import Foundation
import ImageIO

enum QuickLookTestDocs {
  /// A PDF of [pages] pages of [size] points, the first rotated by [rotate] degrees, each with a red
  /// 20×20 pt square in its top-left corner.
  static func pdf(at url: URL, size: CGSize = CGSize(width: 200, height: 100), rotate: Int = 0, pages: Int = 1) throws {
    var objects: [String] = []
    objects.append("<< /Type /Catalog /Pages 2 0 R >>")
    let kids = (0..<pages).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
    objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>")
    let w = Int(size.width), h = Int(size.height)
    for i in 0..<pages {
      let rotation = i == 0 && rotate != 0 ? " /Rotate \(rotate)" : ""
      objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)]\(rotation) /Contents \(4 + i * 2) 0 R >>")
      let stream = "1 0 0 rg 0 \(h - 20) 20 20 re f"
      objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (i, o) in objects.enumerated() {
      offsets.append(out.utf8.count)
      out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for o in offsets { out += String(format: "%010d 00000 n \n", o) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    try Data(out.utf8).write(to: url)
  }

  /// An encrypted one-page PDF; [userPassword] empty opens without a prompt.
  static func encryptedPdf(at url: URL, userPassword: String) throws {
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let info: [CFString: Any] = [kCGPDFContextOwnerPassword: "owner-secret", kCGPDFContextUserPassword: userPassword]
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 80, width: 20, height: 20))
    ctx.endPDFPage()
    ctx.closePDF()
  }

  /// A file that starts like a PDF and breaks off.
  static func damagedPdf(at url: URL) throws {
    try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R".utf8).write(to: url)
  }

  /// A small Office Open XML package of [kind] (`docx`, `xlsx`, `pptx`).
  static func office(at url: URL, kind: String) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent().appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    func put(_ path: String, _ text: String) throws {
      let f = dir.appendingPathComponent(path)
      try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: f)
    }
    let ns = "http://schemas.openxmlformats.org"
    switch kind {
    case "docx":
      try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """)
      try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
      try put("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="\(ns)/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Quarterly fixture</w:t></w:r></w:p></w:body></w:document>
        """)
    case "xlsx":
      try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """)
      try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
      try put("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
      try put("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="\(ns)/spreadsheetml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
      try put("xl/worksheets/sheet1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\(ns)/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>fixture</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>
        """)
    default:
      try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>
        """)
      try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """)
      try put("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:p="\(ns)/presentationml/2006/main"><p:sldSz cx="9144000" cy="6858000"/></p:presentation>
        """)
    }
    try? fm.removeItem(at: url)
    // zip appends ".zip" to a name without an extension, so write `<uuid>.zip` and move it.
    let archive = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = dir
    zip.arguments = ["-q", "-X", "-r", archive.path, "."]
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    try fm.moveItem(at: archive, to: url)
  }

  /// UTF-8 text.
  static func text(at url: URL, _ text: String = "Line one of the fixture\nLine two\n") throws {
    try Data(text.utf8).write(to: url)
  }

  /// Random bytes under an extension no app declares.
  static func unknown(at url: URL) throws {
    try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
  }

  /// The RGBA bytes of the pixel at ([x], [y]) from the top-left of the image file at [url].
  static func pixel(_ url: URL, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ok: Bool = data.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok, x >= 0, y >= 0, x < w, y < h else { return nil }
    let i = (y * w + x) * 4  // The bitmap's first row is the image's top row.
    return (data[i], data[i + 1], data[i + 2])
  }

  /// True when the pixel looks red (JPEG tolerant).
  static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
    guard let p = p else { return false }
    return p.r > 180 && p.g < 90 && p.b < 90
  }

  /// True when the pixel looks white (JPEG tolerant).
  static func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool {
    guard let p = p else { return false }
    return p.r > 220 && p.g > 220 && p.b > 220
  }
}
