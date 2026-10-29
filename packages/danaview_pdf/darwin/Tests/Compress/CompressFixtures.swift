// OWNER: HOM-31
//
// Locally generated PDFs for the compress XCTests (no downloads): a scanner-style file (one
// 300 dpi photo-like bitmap per page, Flate-encoded by Quartz, with a line of real text), a
// camera-style file (the same pictures as high-quality JPEGs, passed through by Quartz) and a
// text-only file (CoreText lines, real text). Every page carries `token(prefix, page)` so tests
// can check text survives.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum CompressFixtures {
  /// The token on page [index] (0-based).
  static func token(_ prefix: String, _ index: Int) -> String {
    String(format: "%@-P%04d", prefix, index + 1)
  }

  /// A photo-like RGB bitmap: smooth gradients, soft discs and a little sensor noise (what
  /// scanned photos and camera pictures look like to a JPEG encoder), different per [seed].
  static func photo(width: Int, height: Int, seed: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
    var state = UInt32(truncatingIfNeeded: 2_654_435_761 &* (seed + 1))
    let fx = Double(seed % 5 + 2), fy = Double(seed % 3 + 2)
    for y in 0..<height {
      let v = Double(y) / Double(height)
      for x in 0..<width {
        let u = Double(x) / Double(width)
        state = state &* 1_664_525 &+ 1_013_904_223
        let noise = Double(Int(state >> 29)) - 3.5
        let o = y * width * 4 + x * 4
        let wave = sin(u * .pi * fx) * cos(v * .pi * fy)
        let dx = u - 0.5, dy = v - 0.45
        let disc = max(0, 1 - (dx * dx + dy * dy) * 9)
        buffer[o] = UInt8(clamping: Int(40 + 150 * u + 50 * wave + 40 * disc + noise))
        buffer[o + 1] = UInt8(clamping: Int(60 + 120 * v + 40 * wave * disc + noise))
        buffer[o + 2] = UInt8(clamping: Int(90 + 80 * (1 - u) * v + 70 * disc - 30 * wave + noise))
      }
    }
    return context.makeImage()!
  }

  /// [image] round-tripped through a JPEG at [quality] (Quartz then embeds the JPEG bytes).
  static func jpegImage(_ image: CGImage, quality: Double) -> CGImage {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data, nil)!, 0, nil)!
  }

  /// [pages] US-letter pages, each a 7.5 × 9 in picture at 300 dpi above one line of text.
  /// [jpeg] stores the pictures as JPEG (camera style), else Quartz Flate-encodes the bitmap
  /// (scanner style).
  /// With [userPassword] the file is encrypted by Core Graphics and needs it to open.
  @discardableResult
  static func writeImagePdf(
    to url: URL, pages: Int, jpeg: Bool, prefix: String = "IMG", pixelsPerInch: Int = 300, userPassword: String? = nil
  ) -> URL {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [:]
    if let userPassword {
      info[kCGPDFContextUserPassword] = userPassword as CFString
      info[kCGPDFContextOwnerPassword] = userPassword as CFString
    }
    let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
    for i in 0..<pages {
      context.beginPDFPage(nil)
      var image = photo(width: 15 * pixelsPerInch / 2, height: 9 * pixelsPerInch, seed: i)
      if jpeg { image = jpegImage(image, quality: 0.92) }
      context.draw(image, in: CGRect(x: 36, y: 90, width: 540, height: 648))
      drawLine("\(token(prefix, i)) scanned page", in: context, at: CGPoint(x: 36, y: 50))
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  /// [pages] pages of text only (40 lines each), page i carrying `token(prefix, i)`.
  @discardableResult
  static func writeTextPdf(to url: URL, pages: Int, prefix: String = "TXT") -> URL {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for i in 0..<pages {
      context.beginPDFPage(nil)
      drawLine("\(token(prefix, i)) Danaview compress fixture", in: context, at: CGPoint(x: 72, y: 720))
      for line in 1..<40 {
        drawLine("Line \(line): the quick brown fox jumps over the lazy dog.", in: context, at: CGPoint(x: 72, y: 720 - CGFloat(line) * 16))
      }
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  static func drawLine(_ text: String, in context: CGContext, at point: CGPoint) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
  }

  static func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
  }
}
