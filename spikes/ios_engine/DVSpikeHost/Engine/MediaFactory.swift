import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Self-generated test media (the spike has no fixture dependency; ENG-05's fixtures replace these
/// later). Everything is written with AVAssetWriter / AVAudioFile into a per-run cache directory.
enum MediaFactory {
  enum Failure: Error, CustomStringConvertible {
    case writer(String)
    var description: String {
      switch self {
      case .writer(let s): return s
      }
    }
  }

  static var directory: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dvspike-media", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

  /// H.264 MP4 whose frame j (PTS = j/fps exactly) carries barcode (frame j, clip).
  @discardableResult
  static func barcodeVideo(
    name: String, width: Int, height: Int, fps: Int32, frames: Int, clip: Int,
    color: (r: UInt8, g: UInt8, b: UInt8) = (200, 90, 40), bitRate: Int? = nil
  ) async throws -> URL {
    let out = url(name)
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let tmp = url(name + ".partial.mp4")
    try? FileManager.default.removeItem(at: tmp)
    let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate ?? max(2_000_000, width * height * Int(fps) / 6),
        AVVideoMaxKeyFrameIntervalKey: Int(fps),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: Int(fps),
      ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    guard writer.startWriting() else {
      throw Failure.writer("startWriting: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)
    for j in 0..<frames {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      guard let buffer = pb else { throw Failure.writer("no pixel buffer") }
      Barcode.draw(into: buffer, frame: j, clip: clip, color: color)
      if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(j), timescale: fps)) {
        throw Failure.writer("append \(j): \(String(describing: writer.error))")
      }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw Failure.writer("finish: \(String(describing: writer.error))")
    }
    try FileManager.default.moveItem(at: tmp, to: out)
    return out
  }

  /// The runtime-generated 16×16 one-frame spacer video (ARCH §13.2; no bundled resource).
  ///
  /// IOS-01 finding: on the iOS 26 simulator a 16×16 H.264 frame fails with AVFoundation -11800 /
  /// VideoToolbox -12780 when compression properties (average bit rate 100 kbit/s, High
  /// AutoLevel, expected frame rate) are set, but encodes with the default settings; Photo-JPEG
  /// has no encoder there (-11834). The spacer is therefore H.264 with NO compression properties
  /// in a QuickTime movie (SpacerTests records the codec matrix per OS).
  static func spacer(fps: Int32 = 30) async throws -> URL {
    let out = url("spacer_16x16_v1.mov")
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let tmp = url("spacer_16x16_v1.partial.mov")
    try await writeSolid(to: tmp, codec: .h264, fileType: .mov, size: 16, fps: fps)
    try FileManager.default.moveItem(at: tmp, to: out)
    return out
  }

  /// Writes a one-frame black video of `size`×`size` (spacer probe).
  static func writeSolid(
    to out: URL, codec: AVVideoCodecType, fileType: AVFileType, size: Int, fps: Int32 = 30
  ) async throws {
    try? FileManager.default.removeItem(at: out)
    let writer = try AVAssetWriter(outputURL: out, fileType: fileType)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: size, AVVideoHeightKey: size])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size,
        kCVPixelBufferHeightKey as String: size,
      ])
    writer.add(input)
    guard writer.startWriting() else {
      throw Failure.writer("startWriting: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buffer = pb else { throw Failure.writer("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(
      CVPixelBufferGetBaseAddress(buffer), 0,
      CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: .zero) else {
      throw Failure.writer("append: \(String(describing: writer.error))")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: fps))
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw Failure.writer("finish: \(String(describing: writer.error))")
    }
  }

  /// Float32 stereo 48 kHz sine (WAV) at `dbfs`.
  @discardableResult
  /// `gaps`: source times (s) where the tone is silent for `gapSeconds` (timing markers for the
  /// V-N21 seam-alignment check).
  static func tone(
    name: String, hz: Double, dbfs: Double, seconds: Double, gaps: [Double] = [], gapSeconds: Double = 0.040
  ) throws -> URL {
    let out = url(name)
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let rate = 48_000.0
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    let file = try AVAudioFile(
      forWriting: out,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let total = Int(seconds * rate)
    let amp = Float(pow(10, dbfs / 20))
    let chunk = 4800
    var written = 0
    while written < total {
      let n = min(chunk, total - written)
      let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
      buf.frameLength = AVAudioFrameCount(n)
      for i in 0..<n {
        let t = Double(written + i) / rate
        let silent = gaps.contains { t >= $0 && t < $0 + gapSeconds }
        let v = silent ? 0 : amp * Float(sin(2 * Double.pi * hz * t))
        buf.floatChannelData![0][i] = v
        buf.floatChannelData![1][i] = v
      }
      try file.write(from: buf)
      written += n
    }
    return out
  }

  /// AAC-LC 48 kHz stereo copy of a PCM file (the common real-world audio source format).
  static func toneAAC(name: String, source: URL) throws -> URL {
    let out = url(name)
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let input = try AVAudioFile(forReading: source)
    let tmp = url(name + ".partial.m4a")
    try? FileManager.default.removeItem(at: tmp)
    let file = try AVAudioFile(
      forWriting: tmp,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4800)!
    while input.framePosition < input.length {
      try input.read(into: buf)
      if buf.frameLength == 0 { break }
      try file.write(from: buf)
    }
    try FileManager.default.moveItem(at: tmp, to: out)
    return out
  }

  /// HEVC Main10 HLG (BT.2020) clip: left half HLG signal 0.50, right half 0.75 (reference
  /// white), neutral chroma. Returns nil when no HEVC encoder is available (e.g. a simulator
  /// without one); the caller then falls back to the committed ffmpeg fixture.
  static func hlgClip(name: String, width: Int = 640, height: Int = 360, fps: Int32 = 30, frames: Int = 30)
    async throws -> URL?
  {
    let out = url(name)
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let tmp = url(name + ".partial.mov")
    try? FileManager.default.removeItem(at: tmp)
    let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
        AVVideoAverageBitRateKey: 4_000_000,
      ],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return nil }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    guard writer.startWriting() else { return nil }
    writer.startSession(atSourceTime: .zero)
    for j in 0..<frames {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      guard let buffer = pb else { return nil }
      fillHLG(buffer)
      if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(j), timescale: fps)) {
        writer.cancelWriting()
        return nil
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { return nil }
    try FileManager.default.moveItem(at: tmp, to: out)
    return out
  }

  /// 10-bit video-range code for an HLG signal level in [0, 1].
  static func hlgCode(_ signal: Double) -> UInt16 { UInt16((64 + signal * 876).rounded()) }

  private static func fillHLG(_ buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    let low = hlgCode(0.5) << 6
    let high = hlgCode(0.75) << 6
    for y in 0..<h {
      let row = (yBase + y * yStride).assumingMemoryBound(to: UInt16.self)
      for x in 0..<w { row[x] = x < w / 2 ? low : high }
    }
    let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
    let ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
    let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    for y in 0..<ch {
      let row = (cBase + y * cStride).assumingMemoryBound(to: UInt16.self)
      for x in 0..<(cw * 2) { row[x] = 512 << 6 }
    }
  }
}
