// OWNER: HOM-04
//
// Test media for the thumbnail XCTests, generated on the fly with CoreGraphics, ImageIO and
// AVFoundation (nothing is downloaded): solid images with a white centre square in JPEG, HEIC and
// PNG (optionally with an EXIF orientation), a short H.264 movie, and a corrupt file.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

enum ThumbnailTestMedia {
  struct Failure: Error {}

  static func image(width: Int, height: Int, red: CGFloat = 0.9) throws -> CGImage {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure() }
    ctx.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    guard let img = ctx.makeImage() else { throw Failure() }
    return img
  }

  /// Writes an image file of [type] (`public.jpeg`, `public.heic`, `public.png`).
  @discardableResult
  static func write(_ url: URL, type: String, width: Int, height: Int, orientation: Int = 1) throws -> URL {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw Failure() }
    let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(dest, try image(width: width, height: height), props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw Failure() }
    return url
  }

  /// Writes [bytes] of garbage with an image extension.
  @discardableResult
  static func corrupt(_ url: URL) throws -> URL {
    var bytes = [UInt8](repeating: 0, count: 4096)
    for i in bytes.indices { bytes[i] = UInt8((i * 31 + 7) & 0xFF) }
    try Data(bytes).write(to: url)
    return url
  }

  /// Writes a 1 s, 15 fps H.264 movie of [width] × [height].
  @discardableResult
  static func movie(_ url: URL, width: Int, height: Int) throws -> URL {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw Failure() }
    writer.startSession(atSourceTime: .zero)
    let frame = try image(width: width, height: height, red: 0.2)
    for i in 0..<15 {
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
      guard let pool = adaptor.pixelBufferPool else { throw Failure() }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      guard let pb = buffer else { throw Failure() }
      CVPixelBufferLockBaseAddress(pb, [])
      let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      ctx?.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
      CVPixelBufferUnlockBaseAddress(pb, [])
      adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 15))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw Failure() }
    return url
  }

  /// Pixel size and type identifier of an encoded file.
  static func probe(_ path: String) -> (width: Int, height: Int, type: String)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let type = CGImageSourceGetType(src) as String?,
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h, type)
  }

  /// RGBA of the pixel at ([x], [y]) (top-left origin) of an encoded file.
  static func pixel(_ path: String, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return (px[0], px[1], px[2])
  }
}
