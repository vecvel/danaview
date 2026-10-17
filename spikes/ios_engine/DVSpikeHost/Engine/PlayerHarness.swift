import AVFoundation
import QuartzCore

/// The shape of Flutter's `FlutterTexture` protocol (`copyPixelBuffer` returns a +1 buffer that the
/// engine wraps zero-copy as a Metal texture). The spike host has no Flutter engine; the latency
/// measurement through a real Flutter texture lives in flutter_texture_latency/.
protocol FlutterTextureLike: AnyObject {
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
}

/// ARCH §12.7 TextureBridge: pulls the compositor's BGRA IOSurface buffers out of
/// `AVPlayerItemVideoOutput` and hands the very same buffers to the texture registry.
final class TextureBridge: NSObject, FlutterTextureLike {
  /// Same attributes as the compositor output, so the video output never converts (copies).
  static let outputAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: TextureBridge.outputAttributes)
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private(set) var framesAvailable = 0
  /// Called whenever a new buffer is available (production: `textureFrameAvailable`).
  var onFrameAvailable: (() -> Void)?

  /// Display-link step: copies the buffer for `itemTime` if there is a new one.
  @discardableResult
  func pull(itemTime: CMTime) -> CVPixelBuffer? {
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else { return nil }
    push(buffer)
    return buffer
  }

  /// Redraw-from-cache path: a compositor buffer rendered while paused.
  func push(_ buffer: CVPixelBuffer) {
    lock.lock()
    latest = buffer
    framesAvailable += 1
    lock.unlock()
    onFrameAvailable?()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let b = latest else { return nil }
    return Unmanaged.passRetained(b)
  }
}

/// AVPlayer session per ARCH §13.2 (no display link; tests poll the output).
final class PlayerHarness {
  let player: AVPlayer
  let item: AVPlayerItem
  let bridge = TextureBridge()
  private(set) var lastStamp: Int64?

  init(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix? = nil) {
    item = AVPlayerItem(asset: asset)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    item.seekingWaitsForVideoCompositionRendering = true
    item.add(bridge.output)
    player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.actionAtItemEnd = .pause
  }

  convenience init(built: BuiltComposition, audioMix: AVAudioMix? = nil) {
    self.init(asset: built.composition, videoComposition: built.videoComposition, audioMix: audioMix)
  }

  enum Failure: Error { case notReady(String) }

  /// Which item time the paused exact-seek ack asks the video output for.
  enum Query {
    /// `item.currentTime()` after the seek completed (what a display link sees while paused).
    case itemTime
    /// The seek target `CMTime(k, fps)` itself (the TextureBridge knows the pending seek).
    case seekTarget
  }

  /// Production default per the IOS-01 finding (see exactSeek).
  var query: Query = .seekTarget
  /// Time from readyToPlay to the first composited buffer in the output (ms).
  private(set) var firstFrameMs: Double?
  /// True when the first frame only arrived after an explicit seek to zero.
  private(set) var firstFrameNeededSeek = false

  /// Waits for readyToPlay AND the first composited frame (production: the session reports ready
  /// after the first `textureFrameAvailable`, so the first user seek does not pay decoder and
  /// kernel start-up inside its 500 ms ack budget).
  func waitReady(timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while item.status != .readyToPlay {
      if item.status == .failed { throw Failure.notReady("\(String(describing: item.error))") }
      if Date() > deadline { throw Failure.notReady("timeout") }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let started = CACurrentMediaTime()
    var seeked = false
    while Date() < deadline.addingTimeInterval(10) {
      if bridge.output.hasNewPixelBuffer(forItemTime: .zero),
        let b = bridge.output.copyPixelBuffer(forItemTime: .zero, itemTimeForDisplay: nil)
      {
        lastStamp = SpikeCompositor.frameStamp(b)
        firstFrameMs = (CACurrentMediaTime() - started) * 1000
        firstFrameNeededSeek = seeked
        return
      }
      if !seeked, CACurrentMediaTime() - started > 1 {
        seeked = true
        _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
      }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw Failure.notReady("no first frame")
  }

  struct SeekAck {
    var k: Int64
    var acked: Bool
    var stamp: Int64?
    var ms: Double
    var buffer: CVPixelBuffer?
    /// item.currentTime() right after the seek completion handler, and whether it equals the
    /// seek target exactly.
    var itemTimeAfterSeek: CMTime
    var itemTimeIsTarget: Bool
    /// Stamps of every buffer pulled while waiting (stale ones first).
    var seen: [Int64?]
  }

  /// Exact seek (ARCH §13.2): seek(to: CMTime(k, fps), tolerance .zero), then wait for the output
  /// buffer whose `danaview.frame` == k (timeout 500 ms) and ack.
  func exactSeek(k: Int64, fps: Int64, timeoutMs: Double = 500) async -> SeekAck {
    let started = CACurrentMediaTime()
    let target = Grid.cm(frame: k, fps: fps)
    _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    let after = item.currentTime()
    var stamp: Int64?
    var buffer: CVPixelBuffer?
    var seen: [Int64?] = []
    while (CACurrentMediaTime() - started) * 1000 < timeoutMs {
      let t = query == .seekTarget ? target : item.currentTime()
      if bridge.output.hasNewPixelBuffer(forItemTime: t),
        let b = bridge.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
      {
        stamp = SpikeCompositor.frameStamp(b)
        seen.append(stamp)
        buffer = b
        lastStamp = stamp
        if stamp == k { break }
      } else if lastStamp == k, buffer == nil {
        // Same frame as the one already on screen: nothing new will arrive.
        break
      }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    let ms = (CACurrentMediaTime() - started) * 1000
    return SeekAck(
      k: k, acked: lastStamp == k, stamp: stamp ?? lastStamp, ms: ms, buffer: buffer,
      itemTimeAfterSeek: after, itemTimeIsTarget: CMTimeCompare(after, target) == 0, seen: seen)
  }

  struct Captured {
    var itemTime: CMTime
    var stamp: Int64?
    var buffer: CVPixelBuffer
    var hostTime: CFTimeInterval
  }

  /// Plays at `rate` until `end` and returns every buffer the output delivered (polled at 2 ms,
  /// the way a 120 Hz display link would see them).
  func capturePlayback(rate: Float, end: CMTime, timeout: TimeInterval, keepBuffers: Bool,
                       onFrame: ((Captured) -> Void)? = nil) async -> [Captured] {
    var frames: [Captured] = []
    player.playImmediately(atRate: rate)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let t = item.currentTime()
      if bridge.output.hasNewPixelBuffer(forItemTime: t) {
        var display = CMTime.invalid
        if let b = bridge.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) {
          let c = Captured(
            itemTime: display, stamp: SpikeCompositor.frameStamp(b), buffer: b,
            hostTime: CACurrentMediaTime())
          onFrame?(c)
          if keepBuffers { frames.append(c) } else {
            frames.append(Captured(itemTime: display, stamp: c.stamp, buffer: Self.placeholder, hostTime: c.hostTime))
          }
        }
      }
      if CMTimeCompare(t, end) >= 0 || (player.rate == 0 && CMTimeCompare(t, .zero) > 0) { break }
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    player.pause()
    return frames
  }

  private static let placeholder = Pixels.makeBGRA(width: 2, height: 2)
}
