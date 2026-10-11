import CoreGraphics
import CoreVideo
import Foundation

/// Frame barcode used by the spike's self-generated media (until ENG-05's fixtures land).
///
/// The bottom half of a source frame holds an 8 × 4 grid of black/white blocks: rows 0–1 the
/// source frame index (16 bits, LSB first), row 2 the clip id (8 bits), row 3 a check byte. The
/// top half is a solid clip colour. Decoding samples the inner half of each block, so it survives
/// H.264, scaling and Core Image resampling.
enum Barcode {
  static let columns = 8
  static let rows = 4
  static let white: UInt8 = 235
  static let black: UInt8 = 16

  struct Value: Equatable, CustomStringConvertible {
    var frame: Int
    var clip: Int

    var description: String { "clip \(clip) frame \(frame)" }
  }

  static func checkByte(frame: Int, clip: Int) -> Int {
    (frame & 0xFF) ^ ((frame >> 8) & 0xFF) ^ (clip & 0xFF) ^ 0x5A
  }

  static func bits(frame: Int, clip: Int) -> [Bool] {
    var out = [Bool]()
    for i in 0..<16 { out.append((frame >> i) & 1 == 1) }
    for i in 0..<8 { out.append((clip >> i) & 1 == 1) }
    let check = checkByte(frame: frame, clip: clip)
    for i in 0..<8 { out.append((check >> i) & 1 == 1) }
    return out
  }

  /// Fills a BGRA buffer: top half `color`, bottom half the barcode.
  static func draw(
    into buffer: CVPixelBuffer, frame: Int, clip: Int, color: (r: UInt8, g: UInt8, b: UInt8)
  ) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let code = bits(frame: frame, clip: clip)
    for y in 0..<h {
      let row = base + y * stride
      if y < h / 2 {
        for x in 0..<w {
          row[x * 4 + 0] = color.b
          row[x * 4 + 1] = color.g
          row[x * 4 + 2] = color.r
          row[x * 4 + 3] = 255
        }
      } else {
        let r = min(rows - 1, (y - h / 2) * rows / (h - h / 2))
        for x in 0..<w {
          let c = min(columns - 1, x * columns / w)
          let v = code[r * columns + c] ? white : black
          row[x * 4 + 0] = v
          row[x * 4 + 1] = v
          row[x * 4 + 2] = v
          row[x * 4 + 3] = 255
        }
      }
    }
  }

  /// Decodes the barcode of a source frame placed at `rect` (pixel coordinates, y-down) inside a
  /// BGRA buffer. Returns nil when the check byte fails (blended, missing or wrong content).
  static func decode(_ buffer: CVPixelBuffer, rect: CGRect? = nil) -> Value? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard let raw = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let base = raw.assumingMemoryBound(to: UInt8.self)
    let r = rect ?? CGRect(x: 0, y: 0, width: w, height: h)
    let codeTop = r.minY + r.height / 2
    let blockW = r.width / CGFloat(columns)
    let blockH = (r.height / 2) / CGFloat(rows)
    var bitsOut = [Bool]()
    for row in 0..<rows {
      for col in 0..<columns {
        let x0 = Int((r.minX + (CGFloat(col) + 0.25) * blockW).rounded())
        let x1 = Int((r.minX + (CGFloat(col) + 0.75) * blockW).rounded())
        let y0 = Int((codeTop + (CGFloat(row) + 0.25) * blockH).rounded())
        let y1 = Int((codeTop + (CGFloat(row) + 0.75) * blockH).rounded())
        var sum = 0
        var n = 0
        for y in max(0, y0)..<min(h, max(y0 + 1, y1)) {
          let line = base + y * stride
          for x in max(0, x0)..<min(w, max(x0 + 1, x1)) {
            sum += Int(line[x * 4 + 1])
            n += 1
          }
        }
        guard n > 0 else { return nil }
        bitsOut.append(sum / n > 128)
      }
    }
    var frame = 0
    var clip = 0
    var check = 0
    for i in 0..<16 where bitsOut[i] { frame |= 1 << i }
    for i in 0..<8 where bitsOut[16 + i] { clip |= 1 << i }
    for i in 0..<8 where bitsOut[24 + i] { check |= 1 << i }
    guard check == checkByte(frame: frame, clip: clip) else { return nil }
    return Value(frame: frame, clip: clip)
  }
}

/// Small pixel helpers for BGRA buffers.
enum Pixels {
  /// Mean (r, g, b) over `rect` (y-down) of a BGRA buffer, in 0…255.
  static func mean(_ buffer: CVPixelBuffer, rect: CGRect) -> (r: Double, g: Double, b: Double) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var sr = 0.0
    var sg = 0.0
    var sb = 0.0
    var n = 0.0
    let x0 = max(0, Int(rect.minX))
    let x1 = min(w, Int(rect.maxX))
    let y0 = max(0, Int(rect.minY))
    let y1 = min(h, Int(rect.maxY))
    for y in y0..<y1 {
      let line = base + y * stride
      for x in x0..<x1 {
        sb += Double(line[x * 4])
        sg += Double(line[x * 4 + 1])
        sr += Double(line[x * 4 + 2])
        n += 1
      }
    }
    guard n > 0 else { return (0, 0, 0) }
    return (sr / n, sg / n, sb / n)
  }

  static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
  }

  static func ioSurfaceID(_ buffer: CVPixelBuffer) -> UInt32? {
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
    return IOSurfaceGetID(surface)
  }

  static func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
  }
}
