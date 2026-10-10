import AVFoundation
import Flutter
import QuartzCore
import UIKit

/// IOS-01 / V-N23: preview A/V latency through a real Flutter texture.
///
/// An AVPlayer plays a generated 640×360 30 fps clip with a 1 kHz tone (the item clock is the
/// audio clock). A CADisplayLink asks `AVPlayerItemVideoOutput` for
/// `itemTime(forHostTime: targetTimestamp + compensation)` (ARCH §12.7), copies the buffer and
/// marks the Flutter texture available; the raster thread pulls it with `copyPixelBuffer`. Dart
/// sends back `FrameTiming`s; for every texture frame the display time is the first vsync after
/// the raster that sampled it, and the A/V offset is the audio item time at that display time
/// minus the video buffer's item time.
final class LatencyProbe: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private(set) var textureId: Int64 = -1
  private var player: AVPlayer?
  private var output: AVPlayerItemVideoOutput?
  private var link: CADisplayLink?
  private let lock = NSLock()
  private var latest: (buffer: CVPixelBuffer, item: Double, target: Double, seq: Int)?
  private var seq = 0
  private var compensation: Double = 0

  // Records (host times in seconds, CACurrentMediaTime base).
  private var ticks: [(timestamp: Double, target: Double)] = []
  private var copies: [(host: Double, item: Double, target: Double, seq: Int)] = []

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let now = CACurrentMediaTime()
    lock.lock()
    defer { lock.unlock() }
    guard let l = latest else { return nil }
    copies.append((now, l.item, l.target, l.seq))
    return Unmanaged.passRetained(l.buffer)
  }

  func start(completion: @escaping (Int64) -> Void) {
    Task { @MainActor in
      do {
        let item = try await Self.makeItem()
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
          kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        p.volume = 0.05
        self.output = out
        self.player = p
        self.textureId = self.registry.register(self)
        while item.status != .readyToPlay { try await Task.sleep(nanoseconds: 10_000_000) }
        let l = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
        l.add(to: .main, forMode: .common)
        self.link = l
        p.play()
        completion(self.textureId)
      } catch {
        print("VWSPIKE-LATENCY error \(error)")
        completion(-1)
      }
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let out = output else { return }
    let target = link.targetTimestamp + compensation
    ticks.append((link.timestamp, link.targetTimestamp))
    let t = out.itemTime(forHostTime: target)
    guard out.hasNewPixelBuffer(forItemTime: t) else { return }
    var display = CMTime.invalid
    guard let b = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) else { return }
    lock.lock()
    seq += 1
    latest = (b, display.seconds, link.targetTimestamp, seq)
    lock.unlock()
    registry.textureFrameAvailable(textureId)
  }

  /// Computes the phase report from Dart's frame timings ([vsyncStart, rasterStart, rasterFinish]
  /// in µs) and resets the records; `nextCompensation` (s) applies to the next phase.
  func report(phase: String, timings: [[Int]], nextCompensation: Double?) -> [String: Any] {
    guard let out = output else { return ["error": "not started"] }
    lock.lock()
    let copies = self.copies
    self.copies.removeAll()
    lock.unlock()
    let ticks = self.ticks
    self.ticks.removeAll()
    let frames = timings.map { (vsync: Double($0[0]) / 1e6, rs: Double($0[1]) / 1e6, rf: Double($0[2]) / 1e6) }
    let period = median(zip(ticks, ticks.dropFirst()).map { $1.timestamp - $0.timestamp })
    // Clock check: Dart vsyncStart vs the nearest native vsync timestamp.
    let vsyncs = ticks.map(\.timestamp)
    let clockDiffs = frames.prefix(200).compactMap { f -> Double? in
      guard let n = vsyncs.min(by: { abs($0 - f.vsync) < abs($1 - f.vsync) }) else { return nil }
      return (f.vsync - n) * 1000
    }
    let targets = ticks.map(\.target).sorted()
    var offsets: [Double] = []
    var textureLatency: [Double] = []
    var unmatched = 0
    for c in copies {
      guard let f = frames.first(where: { $0.rs - 0.0005 <= c.host && c.host <= $0.rf + 0.0005 }),
        let display = targets.first(where: { $0 >= f.rf })
      else {
        unmatched += 1
        continue
      }
      let audio = out.itemTime(forHostTime: display).seconds
      offsets.append((audio - c.item) * 1000)
      textureLatency.append((display - c.target) * 1000)
    }
    let result: [String: Any] = [
      "test": "V-N23.flutterTexture.\(phase)",
      "compensationMs": round2(compensation * 1000),
      "textureFrames": copies.count, "matched": offsets.count, "unmatched": unmatched,
      "displayPeriodMs": round2(period * 1000),
      "clockDiffMsP50": round2(median(clockDiffs)),
      "avOffsetMsP50": round2(median(offsets)), "avOffsetMsP95abs": round2(percentile(offsets.map(abs), 95)),
      "avOffsetMsMin": round2(offsets.min() ?? .nan), "avOffsetMsMax": round2(offsets.max() ?? .nan),
      "textureLatencyMsP50": round2(median(textureLatency)),
      "textureLatencyMsP95": round2(percentile(textureLatency, 95)),
      "destination": Self.destination,
      // AVPlayer's item clock already includes the route's output latency (the item time mapped
      // to a host time is what is audible then); recorded to show its size on this route.
      "audioSessionOutputLatencyMs": round2(AVAudioSession.sharedInstance().outputLatency * 1000),
    ]
    if let c = nextCompensation { compensation = c }
    return result
  }

  private static var destination: String {
    #if targetEnvironment(simulator)
      return "simulator \(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "?") iOS \(UIDevice.current.systemVersion)"
    #else
      return "device iOS \(UIDevice.current.systemVersion)"
    #endif
  }

  private func median(_ xs: [Double]) -> Double { percentile(xs, 50) }

  private func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, max(0, Int((p / 100 * Double(s.count - 1)).rounded())))]
  }

  private func round2(_ x: Double) -> Double { x.isFinite ? (x * 100).rounded() / 100 : -1 }

  // MARK: Generated media (no downloads, no bundled files)

  private static func makeItem() async throws -> AVPlayerItem {
    let dir = FileManager.default.temporaryDirectory
    let video = dir.appendingPathComponent("latency_640x360_30.mp4")
    let audio = dir.appendingPathComponent("latency_tone.caf")
    if !FileManager.default.fileExists(atPath: video.path) { try await writeVideo(video) }
    if !FileManager.default.fileExists(atPath: audio.path) { try writeTone(audio) }
    let comp = AVMutableComposition()
    let va = AVURLAsset(url: video)
    let aa = AVURLAsset(url: audio)
    let vt = try await va.loadTracks(withMediaType: .video).first!
    let at = try await aa.loadTracks(withMediaType: .audio).first!
    let range = CMTimeRange(start: .zero, duration: CMTime(value: 20, timescale: 1))
    try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
      .insertTimeRange(range, of: vt, at: .zero)
    try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
      .insertTimeRange(range, of: at, at: .zero)
    return AVPlayerItem(asset: comp)
  }

  private static func writeVideo(_ url: URL) async throws {
    let tmp = url.appendingPathExtension("partial.mp4")
    try? FileManager.default.removeItem(at: tmp)
    let w = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
    let ad = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
      ])
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    for j in 0..<600 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
      let b = pb!
      CVPixelBufferLockBaseAddress(b, [])
      let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(b)
      let x0 = (j * 7) % 600
      for y in 0..<360 {
        for x in 0..<640 {
          let o = y * stride + x * 4
          let bar = x >= x0 && x < x0 + 40
          base[o] = bar ? 255 : 40
          base[o + 1] = bar ? 255 : UInt8(j % 256)
          base[o + 2] = bar ? 255 : 90
          base[o + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(b, [])
      ad.append(b, withPresentationTime: CMTime(value: Int64(j), timescale: 30))
    }
    input.markAsFinished()
    await w.finishWriting()
    try FileManager.default.moveItem(at: tmp, to: url)
  }

  private static func writeTone(_ url: URL) throws {
    let rate = 48_000.0
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
    let n = Int(rate) * 20
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n {
      let v = Float(0.1 * sin(2 * Double.pi * 1000 * Double(i) / rate))
      buf.floatChannelData![0][i] = v
      buf.floatChannelData![1][i] = v
    }
    try file.write(from: buf)
  }
}
