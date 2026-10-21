// OWNER: HOM-02
//
// Test media generated on the fly with CoreGraphics and ImageIO (no downloads).

import CoreGraphics
import Foundation
import ImageIO

enum TestMedia {
  struct Failure: Error {}

  /// A solid-colour image of [width] × [height].
  static func image(width: Int, height: Int, red: CGFloat = 0.2) throws -> CGImage {
    guard let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure() }
    ctx.setFillColor(CGColor(red: red, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage() else { throw Failure() }
    return image
  }

  /// A JPEG with the given EXIF, TIFF and GPS dictionaries.
  static func jpeg(width: Int, height: Int, red: CGFloat = 0.2, exif: [String: Any] = [:], tiff: [String: Any] = [:], gps: [String: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw Failure() }
    var props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.8]
    if !exif.isEmpty { props[kCGImagePropertyExifDictionary as String] = exif }
    if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }
    if !gps.isEmpty { props[kCGImagePropertyGPSDictionary as String] = gps }
    CGImageDestinationAddImage(dest, try image(width: width, height: height, red: red), props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw Failure() }
    return data as Data
  }
}
