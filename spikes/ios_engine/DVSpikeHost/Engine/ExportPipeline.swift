import AVFoundation
import Foundation

/// ARCH §14.2 reduced: AVAssetReader(composition) + AVAssetReaderVideoCompositionOutput with the
/// same custom compositor → AVAssetWriter (H.264), plus the IOS-17 segmented/resumable variant
/// and passthrough concat, so the spike can check that a segmented writer resumes after an
/// interruption (V-N20).
enum ExportPipeline {
  struct Failure: Error, CustomStringConvertible {
    var stage: String
    var error: Error?
    var description: String { "\(stage): \(error.map { "\($0)" } ?? "unknown")" }

    var nsError: NSError? { error as NSError? }
  }

  struct Result {
    var url: URL
    var frames: Int
    var stamps: [Int64?]
    var ms: Double
    var writerStatus: AVAssetWriter.Status
  }

  static func videoSettings(size: CGSize, fps: Int64, bitRate: Int = 8_000_000) -> [String: Any] {
    [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: Int(fps),
        AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
        AVVideoAllowFrameReorderingKey: false,
      ],
    ]
  }

  /// Exports `range` (default: everything) of the composition. `shouldStop` is polled per frame;
  /// returning true cancels reader and writer (the simulated background encoder loss).
  static func export(
    built: BuiltComposition, to url: URL, range: CMTimeRange? = nil,
    shouldStop: ((Int) -> Bool)? = nil, onFrame: ((CVPixelBuffer, CMTime) -> Void)? = nil
  ) async throws -> Result {
    let started = CFAbsoluteTimeGetCurrent()
    try? FileManager.default.removeItem(at: url)
    let comp = built.composition
    let reader = try AVAssetReader(asset: comp)
    if let range = range { reader.timeRange = range }
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: comp.tracks(withMediaType: .video),
      videoSettings: TextureBridge.outputAttributes)
    output.videoComposition = built.videoComposition
    output.alwaysCopiesSampleData = false
    reader.add(output)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let fps = built.state.plan.canvas.fps
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: videoSettings(size: built.videoComposition.renderSize, fps: fps))
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    guard reader.startReading() else { throw Failure(stage: "reader.start", error: reader.error) }
    guard writer.startWriting() else { throw Failure(stage: "writer.start", error: writer.error) }
    writer.startSession(atSourceTime: range?.start ?? .zero)

    let queue = DispatchQueue(label: "dv.spike.export.video")
    var stamps: [Int64?] = []
    var stopped = false
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      var resumed = false
      func finish(_ error: Error?) {
        guard !resumed else { return }
        resumed = true
        if let e = error { cont.resume(throwing: e) } else { cont.resume() }
      }
      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData {
          if let stop = shouldStop, stop(stamps.count) {
            stopped = true
            reader.cancelReading()
            input.markAsFinished()
            finish(nil)
            return
          }
          guard let sample = output.copyNextSampleBuffer() else {
            input.markAsFinished()
            if reader.status == .failed {
              finish(Failure(stage: "reader", error: reader.error))
            } else {
              finish(nil)
            }
            return
          }
          if let pb = CMSampleBufferGetImageBuffer(sample) {
            stamps.append(SpikeCompositor.frameStamp(pb))
            onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sample))
          }
          if !input.append(sample) {
            reader.cancelReading()
            finish(Failure(stage: "writer.append", error: writer.error))
            return
          }
        }
      }
    }
    if stopped {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      throw Failure(
        stage: "interrupted",
        error: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.operationInterrupted.rawValue))
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure(stage: "writer.finish", error: writer.error) }
    return Result(
      url: url, frames: stamps.count, stamps: stamps,
      ms: (CFAbsoluteTimeGetCurrent() - started) * 1000, writerStatus: writer.status)
  }

  /// Decodes every frame of an exported file and returns the barcode read at `rect` per frame
  /// together with its PTS.
  static func readBack(_ url: URL, rect: ((CVPixelBuffer) -> CGRect)? = nil) throws -> [(pts: CMTime, value: Barcode.Value?)] {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let reader = try AVAssetReader(asset: asset)
    let track = asset.tracks(withMediaType: .video).first!
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var out: [(CMTime, Barcode.Value?)] = []
    while let s = output.copyNextSampleBuffer() {
      guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
      out.append((CMSampleBufferGetPresentationTimeStamp(s), Barcode.decode(pb, rect: rect?(pb))))
    }
    return out
  }
}

/// IOS-17-style segmented writer (reduced): closed-GOP segments of `segmentFrames` output frames,
/// an atomic JSON checkpoint after each finished segment, resume from the first incomplete
/// segment, passthrough concat.
final class SegmentedExporter {
  struct Checkpoint: Codable {
    var completed: [Int]
  }

  let built: BuiltComposition
  let directory: URL
  let segmentFrames: Int64
  private(set) var log: [String] = []

  init(built: BuiltComposition, directory: URL, segmentFrames: Int64) {
    self.built = built
    self.directory = directory
    self.segmentFrames = segmentFrames
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var fps: Int64 { built.state.plan.canvas.fps }
  var totalFrames: Int64 { built.state.plan.frameCount }
  var segmentCount: Int { Int((totalFrames + segmentFrames - 1) / segmentFrames) }
  var checkpointURL: URL { directory.appendingPathComponent("checkpoint.json") }

  func segmentURL(_ i: Int) -> URL { directory.appendingPathComponent("v-\(i).mp4") }

  func loadCheckpoint() -> Checkpoint {
    guard let data = try? Data(contentsOf: checkpointURL),
      let c = try? JSONDecoder().decode(Checkpoint.self, from: data)
    else { return Checkpoint(completed: []) }
    return c
  }

  private func save(_ c: Checkpoint) throws {
    try JSONEncoder().encode(c).write(to: checkpointURL, options: .atomic)
  }

  func range(of segment: Int) -> CMTimeRange {
    let k0 = Int64(segment) * segmentFrames
    let k1 = min(totalFrames, k0 + segmentFrames)
    return CMTimeRange(start: Grid.cm(frame: k0, fps: fps), end: Grid.cm(frame: k1, fps: fps))
  }

  /// Runs (or resumes) the export. `interrupt(segment, frameInSegment)` returning true simulates
  /// the background encoder loss: the in-progress segment is discarded, the checkpoint kept.
  /// Returns true when every segment is complete.
  func run(interrupt: ((Int, Int) -> Bool)? = nil) async throws -> Bool {
    var cp = loadCheckpoint()
    for i in 0..<segmentCount where !cp.completed.contains(i) {
      do {
        _ = try await ExportPipeline.export(
          built: built, to: segmentURL(i), range: range(of: i),
          shouldStop: interrupt.map { f in { n in f(i, n) } })
      } catch let e as ExportPipeline.Failure where e.stage == "interrupted" {
        log.append("segment \(i) interrupted; checkpoint keeps \(cp.completed)")
        return false
      }
      cp.completed.append(i)
      try save(cp)
      log.append("segment \(i) complete")
    }
    return true
  }

  /// Passthrough concat: compressed samples of every segment, retimed onto one timeline, into one
  /// writer input whose format hint is the first segment's format description.
  func concat(to url: URL) async throws -> Int {
    try? FileManager.default.removeItem(at: url)
    let first = AVURLAsset(url: segmentURL(0))
    let firstTrack = try await first.loadTracks(withMediaType: .video).first!
    let hint = try await firstTrack.load(.formatDescriptions).first
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var count = 0
    for i in 0..<segmentCount {
      let asset = AVURLAsset(url: segmentURL(i), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      let track = try await asset.loadTracks(withMediaType: .video).first!
      let desc = try await track.load(.formatDescriptions).first
      if let d = desc, let h = hint, !CMFormatDescriptionEqual(d, otherFormatDescription: h) {
        log.append("segment \(i) format description differs from segment 0 (SPS/PPS)")
      }
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(output)
      reader.startReading()
      let offset = range(of: i).start
      while let s = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(s, at: 0, timingInfoOut: &timing)
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, offset)
        if timing.decodeTimeStamp.isValid {
          timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, offset)
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: nil, sampleBuffer: s, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
          sampleBufferOut: &retimed)
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let r = retimed, input.append(r) else {
          throw ExportPipeline.Failure(stage: "concat.append", error: writer.error)
        }
        count += 1
      }
      try? FileManager.default.removeItem(at: segmentURL(i))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw ExportPipeline.Failure(stage: "concat.finish", error: writer.error)
    }
    return count
  }
}
