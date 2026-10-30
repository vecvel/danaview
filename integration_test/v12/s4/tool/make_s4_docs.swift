// OWNER: S4-Q
//
// Real-world style PDFs for the S4 E2E (integration_test/v12/s4), written with the Mac's own
// Core Graphics, Core Text and PDFKit (nothing downloaded). Called by make_s4_docs.sh:
//
//   swift make_s4_docs.swift <out>
//
//   s4_report.pdf   6 A4 pages, two text columns per page in embedded system fonts (Georgia body,
//                   Helvetica Neue headings), a photo-like picture on page 1, a running header with
//                   the page token S4QR-P000n: an "Office export" with a picture
//   s4_form.pdf     2 pages of text (tokens S4QF-P000n) with AcroForm fields (a text field, a
//                   check box) and annotations (highlight, note, free text): forms and annotations
//   s4_locked.pdf   3 pages (tokens S4QL-P000n), user password "s4qa-open", owner password
//                   "s4qa-owner": the password PDF

import AppKit
import CoreText
import Foundation
import PDFKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

/// Deterministic words (a fixed linear congruential generator, so the files are reproducible).
struct Words {
  var state: UInt64 = 0x5EED_5401
  let pool = ["organise", "merge", "annotate", "signature", "compress", "quarterly", "revenue", "budget",
              "Kolkata", "Zürich", "São Paulo", "naïve", "façade", "café", "review", "contract", "appendix",
              "the", "a", "of", "and", "to", "in", "for", "with", "on", "by", "every", "page", "document",
              "summary", "figure", "table", "result", "measured", "device", "simulator", "library", "folder"]
  mutating func next() -> String {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return pool[Int((state >> 33) % UInt64(pool.count))]
  }
  mutating func sentence(_ n: Int) -> String {
    var s = (0..<n).map { _ in next() }.joined(separator: " ")
    s = s.prefix(1).uppercased() + s.dropFirst()
    return s + ". "
  }
}

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

func attributed(_ text: String, _ f: CTFont, color: CGColor = CGColor(gray: 0.1, alpha: 1)) -> NSAttributedString {
  NSAttributedString(string: text, attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): f,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
  ])
}

func drawLine(_ ctx: CGContext, _ text: String, _ f: CTFont, x: CGFloat, y: CGFloat) {
  let line = CTLineCreateWithAttributedString(attributed(text, f))
  ctx.textPosition = CGPoint(x: x, y: y)
  CTLineDraw(line, ctx)
}

/// A photo-like RGB picture (smooth gradients, a sun, some grain).
func photo(width: Int, height: Int) -> CGImage {
  let cs = CGColorSpaceCreateDeviceRGB()
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let data = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
  var seed: UInt32 = 12345
  for y in 0..<height {
    for x in 0..<width {
      seed = seed &* 1103515245 &+ 12345
      let grain = Int((seed >> 16) % 24) - 12
      let fy = Double(y) / Double(height), fx = Double(x) / Double(width)
      let dx = fx - 0.7, dy = fy - 0.3
      let sun = max(0, 1 - sqrt(dx * dx + dy * dy) * 6)
      let sky = fy < 0.55
      var r = sky ? 40 + fy * 160 : 30 + (1 - fy) * 90 + fx * 30
      var g = sky ? 90 + fy * 110 : 80 + (1 - fy) * 100
      var b = sky ? 170 + fy * 60 : 40 + fx * 30
      r += sun * 200; g += sun * 160; b += sun * 40
      let i = (y * width + x) * 4
      data[i] = UInt8(max(0, min(255, Int(r) + grain)))
      data[i + 1] = UInt8(max(0, min(255, Int(g) + grain)))
      data[i + 2] = UInt8(max(0, min(255, Int(b) + grain)))
      data[i + 3] = 255
    }
  }
  return ctx.makeImage()!
}

/// Writes [pages] pages of [columns]-column text with the header token "<prefix>-P000n".
func textPDF(_ path: String, pages: Int, prefix: String, title: String, columns: Int, picture: Bool, info extra: [CFString: Any] = [:]) {
  var box = a4
  var info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Danaview S4-Q fixtures"]
  for (k, v) in extra { info[k] = v }
  guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, info as CFDictionary) else { fatalError("cannot write \(path)") }
  var words = Words()
  let body = NSMutableAttributedString()
  let bodyFont = font("Georgia", 10.5), headFont = font("HelveticaNeue-Bold", 14)
  for section in 1...(pages * columns * 2) {
    body.append(attributed("\(section). \(words.sentence(3))\n", headFont))
    var para = ""
    for _ in 0..<9 { para += words.sentence(12) }
    body.append(attributed(para + "\n\n", bodyFont))
  }
  let setter = CTFramesetterCreateWithAttributedString(body as CFAttributedString)
  var at = 0
  let pic = picture ? photo(width: 1600, height: 1000) : nil
  for p in 1...pages {
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(a4)
    drawLine(ctx, "\(title) · \(prefix)-P\(String(format: "%04d", p))", font("HelveticaNeue-Medium", 9), x: 48, y: 805)
    drawLine(ctx, "Page \(p) of \(pages)", font("HelveticaNeue", 9), x: 480, y: 30)
    var top: CGFloat = 790
    if let pic, p == 1 {
      ctx.draw(pic, in: CGRect(x: 48, y: 470, width: 499, height: 312))
      top = 460
    }
    let gap: CGFloat = 18
    let colWidth = (499 - gap * CGFloat(columns - 1)) / CGFloat(columns)
    for c in 0..<columns {
      let rect = CGRect(x: 48 + CGFloat(c) * (colWidth + gap), y: 48, width: colWidth, height: top - 48)
      let frame = CTFramesetterCreateFrame(setter, CFRange(location: at, length: 0), CGPath(rect: rect, transform: nil), nil)
      CTFrameDraw(frame, ctx)
      at += CTFrameGetVisibleStringRange(frame).length
    }
    ctx.endPDFPage()
  }
  ctx.closePDF()
}

let report = "\(out)/s4_report.pdf"
textPDF(report, pages: 6, prefix: "S4QR", title: "S4 QA quarterly report", columns: 2, picture: true)

// Forms and annotations: a two-page text file, then PDFKit adds the fields and the marks.
let formBase = "\(out)/s4_form_base.pdf"
textPDF(formBase, pages: 2, prefix: "S4QF", title: "S4 QA application form", columns: 1, picture: false)
guard let form = PDFDocument(url: URL(fileURLWithPath: formBase)), let first = form.page(at: 0) else { fatalError("form base") }
let name = PDFAnnotation(bounds: CGRect(x: 360, y: 760, width: 180, height: 22), forType: .widget, withProperties: nil)
name.widgetFieldType = .text
name.fieldName = "applicant"
name.widgetStringValue = "Masud Q."
name.backgroundColor = NSColor(white: 0.95, alpha: 1)
first.addAnnotation(name)
let agree = PDFAnnotation(bounds: CGRect(x: 360, y: 730, width: 18, height: 18), forType: .widget, withProperties: nil)
agree.widgetFieldType = .button
agree.widgetControlType = .checkBoxControl
agree.fieldName = "agree"
agree.buttonWidgetState = .onState
first.addAnnotation(agree)
let highlight = PDFAnnotation(bounds: CGRect(x: 48, y: 700, width: 220, height: 14), forType: .highlight, withProperties: nil)
highlight.color = NSColor.systemYellow.withAlphaComponent(0.5)
first.addAnnotation(highlight)
let note = PDFAnnotation(bounds: CGRect(x: 520, y: 640, width: 20, height: 20), forType: .text, withProperties: nil)
note.contents = "Reviewer note S4QF-NOTE"
first.addAnnotation(note)
let free = PDFAnnotation(bounds: CGRect(x: 300, y: 60, width: 240, height: 30), forType: .freeText, withProperties: nil)
free.contents = "Approved for QA S4QF-FREE"
free.font = NSFont(name: "Helvetica", size: 12)
free.fontColor = .systemRed
first.addAnnotation(free)
guard form.write(to: URL(fileURLWithPath: "\(out)/s4_form.pdf")) else { fatalError("form write") }
try? FileManager.default.removeItem(atPath: formBase)

// The password PDF.
textPDF("\(out)/s4_locked.pdf", pages: 3, prefix: "S4QL", title: "S4 QA locked statement", columns: 1, picture: false,
        info: [kCGPDFContextUserPassword: "s4qa-open", kCGPDFContextOwnerPassword: "s4qa-owner"])
print("swift fixtures written to \(out)")
