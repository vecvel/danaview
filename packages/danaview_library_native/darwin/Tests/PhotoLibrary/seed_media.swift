// OWNER: HOM-02
//
// Writes the seed media of the PhotoLibrary XCTests into the directory given as the first argument
// (generated locally with CoreGraphics, ImageIO and AVFoundation; nothing is downloaded):
// dv_seed_exif.jpg (EXIF: Fixture Cam, ISO 400), dv_seed_plain.jpg, dv_seed_heic.heic,
// dv_seed_png.png and dv_seed_movie.mov (1 s H.264). run_xctests.sh adds them to the simulator
// with `xcrun simctl addmedia`.
//
//   xcrun swift seed_media.swift <out-dir>

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

func image(_ w: Int, _ h: Int, _ r: CGFloat) -> CGImage {
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: r, green: 0.4, blue: 0.7, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
  return ctx.makeImage()!
}

func write(_ url: URL, _ type: String, _ img: CGImage, _ props: [String: Any]) {
  let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, props as CFDictionary)
  precondition(CGImageDestinationFinalize(dest), "could not write \(url.lastPathComponent)")
}

func movie(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
  let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
  ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320,
    kCVPixelBufferHeightKey as String: 240,
  ])
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  for frame in 0..<30 {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 320, height: 240, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.draw(image(320, 240, CGFloat(frame) / 30), in: CGRect(x: 0, y: 0, width: 320, height: 240))
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  precondition(writer.status == .completed, "movie failed")
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let now = DateFormatter()
now.locale = Locale(identifier: "en_US_POSIX")
now.dateFormat = "yyyy:MM:dd HH:mm:ss"
write(out.appendingPathComponent("dv_seed_exif.jpg"), "public.jpeg", image(640, 480, 0.1), [
  kCGImagePropertyExifDictionary as String: [
    kCGImagePropertyExifISOSpeedRatings as String: [400],
    kCGImagePropertyExifFNumber as String: 2.2,
    kCGImagePropertyExifDateTimeOriginal as String: now.string(from: Date()),
  ],
  kCGImagePropertyTIFFDictionary as String: [
    kCGImagePropertyTIFFMake as String: "Danaview",
    kCGImagePropertyTIFFModel as String: "Fixture Cam",
  ],
])
write(out.appendingPathComponent("dv_seed_plain.jpg"), "public.jpeg", image(480, 640, 0.5), [:])
write(out.appendingPathComponent("dv_seed_heic.heic"), "public.heic", image(800, 600, 0.7), [:])
write(out.appendingPathComponent("dv_seed_png.png"), "public.png", image(300, 300, 0.9), [:])
movie(out.appendingPathComponent("dv_seed_movie.mov"))
print("seeded \(out.path)")
