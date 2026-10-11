import AVFoundation
import Foundation
import DVSpikeKernels

/// Per-frame diagnostics written by the compositor.
struct FrameRecord {
  var k: Int64
  var compositionTime: CMTime
  var active: [String]
  var missing: [String]
  var surfaceID: UInt32?
  var renderMs: Double
  var sourceFormats: [String: OSType]
  var sourceTransfer: [String: String]
}

/// Thread-safe log of compositor requests.
final class FrameLog {
  private let lock = NSLock()
  private var records: [FrameRecord] = []

  func add(_ r: FrameRecord) {
    lock.lock()
    records.append(r)
    lock.unlock()
  }

  var all: [FrameRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  func reset() {
    lock.lock()
    records.removeAll()
    lock.unlock()
  }
}

/// What the compositor renders: the plan, the composition track per packing slot and the live
/// parameters (the spike's `ParamSnapshot`, swapped atomically, never locked during a render).
final class CompositorState {
  let plan: SpikePlan
  let trackIDBySeq: [Int: CMPersistentTrackID]
  let log = FrameLog()
  private let lock = NSLock()
  private var _look = SpikeLook.identity
  private var _blurSigma: Float = 0
  private weak var _compositor: SpikeCompositor?
  /// When true the compositor stamps `danaview.frame` (always on; switchable for the negative test).
  var stampFrames = true

  init(plan: SpikePlan, trackIDBySeq: [Int: CMPersistentTrackID]) {
    self.plan = plan
    self.trackIDBySeq = trackIDBySeq
  }

  var params: (look: SpikeLook, blur: Float) {
    lock.lock()
    defer { lock.unlock() }
    return (_look, _blurSigma)
  }

  func setParams(look: SpikeLook, blur: Float) {
    lock.lock()
    _look = look
    _blurSigma = blur
    lock.unlock()
  }

  /// The compositor instance AVFoundation created for this composition (registered on its first
  /// request), so tests can drive redraw-from-cache.
  var compositor: SpikeCompositor? {
    lock.lock()
    defer { lock.unlock() }
    return _compositor
  }

  func register(_ c: SpikeCompositor) {
    lock.lock()
    _compositor = c
    lock.unlock()
  }
}

/// Custom instruction: a time range on the grid plus the shared state.
final class SpikeInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  let state: CompositorState
  let layerIDs: [String]

  init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], layerIDs: [String], state: CompositorState) {
    self.timeRange = timeRange
    self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
    self.layerIDs = layerIDs
    self.state = state
  }
}

struct BuiltComposition {
  let composition: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  let state: CompositorState
  let spacerTrackID: CMPersistentTrackID
  let buildMs: Double
}

/// ARCH §13.2 CompositionBuilder + InstructionBuilder, reduced to what the spike proves.
enum CompositionBuilder {
  /// `.rational`: D-35 rule 2 (every grid time is CMTime(k, gridFps)). `.microseconds`: the
  /// pre-D-35 behaviour (plan µs as CMTime(t, 1e6)), kept as a negative control.
  enum GridMode { case rational, microseconds }

  enum Failure: Error { case missingTrack(String) }

  static let epsilonUs: Int64 = 500

  static func build(
    plan: SpikePlan, media: [String: URL], spacer: URL, mode: GridMode = .rational,
    renderScale: Double = 1
  ) async throws -> BuiltComposition {
    let start = CFAbsoluteTimeGetCurrent()
    let comp = AVMutableComposition()
    let fps = plan.canvas.editFps
    func grid(_ t: Int64) -> CMTime {
      switch mode {
      case .rational: return Grid.cm(frame: Grid.frameIndexOf(t, fps: fps), fps: fps)
      case .microseconds: return Grid.cm(us: t)
      }
    }

    // IOS-01 finding: the AVURLAsset must stay alive while its tracks are inserted. Holding only
    // the AVAssetTrack makes every insertTimeRange fail with AVFoundation -11800 / Fig -12780.
    var assets: [String: AVURLAsset] = [:]
    var sourceTracks: [String: AVAssetTrack] = [:]
    for (id, url) in media {
      let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      assets[id] = asset
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw Failure.missingTrack(id)
      }
      sourceTracks[id] = track
    }

    var tracks: [Int: AVMutableCompositionTrack] = [:]
    let ordered = plan.layers.sorted { ($0.seq, $0.t0) < ($1.seq, $1.t0) }
    for layer in ordered {
      guard let src = sourceTracks[layer.asset] else { throw Failure.missingTrack(layer.asset) }
      let track =
        tracks[layer.seq]
        ?? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
      tracks[layer.seq] = track
      for seg in layer.segments {
        let at = grid(seg.t0)
        let source = CMTimeRange(
          start: Grid.cm(us: seg.s0 + epsilonUs), duration: Grid.cm(us: seg.s1 - seg.s0))
        try track.insertTimeRange(source, of: src, at: at)
        let target: CMTime
        switch mode {
        case .rational:
          target = Grid.cm(
            frame: Grid.frameIndexOf(seg.t1, fps: fps) - Grid.frameIndexOf(seg.t0, fps: fps), fps: fps)
        case .microseconds:
          target = Grid.cm(us: seg.t1 - seg.t0)
        }
        track.scaleTimeRange(CMTimeRange(start: at, duration: source.duration), toDuration: target)
      }
    }

    // Runtime-generated spacer scaled across the whole duration so the compositor runs for every
    // output frame, gaps included.
    let spacerAsset = AVURLAsset(url: spacer)
    guard let spacerSource = try await spacerAsset.loadTracks(withMediaType: .video).first else {
      throw Failure.missingTrack("spacer")
    }
    let spacerRange = try await spacerSource.load(.timeRange)
    let spacerTrack = comp.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try spacerTrack.insertTimeRange(spacerRange, of: spacerSource, at: .zero)
    spacerTrack.scaleTimeRange(
      CMTimeRange(start: .zero, duration: spacerRange.duration), toDuration: grid(plan.durUs))

    withExtendedLifetime(assets) {}
    let state = CompositorState(
      plan: plan, trackIDBySeq: tracks.mapValues { $0.trackID })

    var bounds = Set<Int64>([0, plan.durUs])
    for l in plan.layers {
      bounds.insert(max(0, min(plan.durUs, l.t0)))
      bounds.insert(max(0, min(plan.durUs, l.t1)))
    }
    let sorted = bounds.sorted()
    var instructions: [SpikeInstruction] = []
    for i in 0..<(sorted.count - 1) {
      let a = sorted[i]
      let b = sorted[i + 1]
      let active = plan.activeLayers(at: a)
      let ids = Array(Set(active.compactMap { state.trackIDBySeq[$0.seq] })).sorted()
      instructions.append(
        SpikeInstruction(
          timeRange: CMTimeRange(start: grid(a), end: grid(b)), trackIDs: ids,
          layerIDs: active.map(\.id), state: state))
    }

    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = SpikeCompositor.self
    vc.frameDuration = CMTime(value: 1, timescale: Int32(plan.canvas.fps))
    vc.renderSize = CGSize(
      width: (Double(plan.canvas.w) * renderScale).rounded(),
      height: (Double(plan.canvas.h) * renderScale).rounded())
    vc.instructions = instructions
    vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

    return BuiltComposition(
      composition: comp, videoComposition: vc, state: state, spacerTrackID: spacerTrack.trackID,
      buildMs: (CFAbsoluteTimeGetCurrent() - start) * 1000)
  }
}
