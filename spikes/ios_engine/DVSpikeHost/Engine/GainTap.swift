import AVFoundation
import MediaToolbox

/// D-37 / V-N21 probe: an `MTAudioProcessingTap` that records the time ranges it is handed and
/// multiplies every sample by `gain` (the production `GainTap` evaluates the plan's envelope at
/// composition time; the spike uses a constant so the measured level is unambiguous).
final class GainTapProbe {
  struct Call {
    var start: CMTime
    var duration: CMTime
    var requested: Int
    var provided: Int
    var preSumSq: Double
    var postSumSq: Double
    var samples: Int
    var hostTime: UInt64
    /// MTAudioProcessingTapFlags returned by GetSourceAudio (start/end of stream).
    var flags: UInt32
    var status: OSStatus
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var _gain: Float
  private(set) var format = AudioStreamBasicDescription()
  private(set) var maxFrames = 0
  let flags: MTAudioProcessingTapCreationFlags

  init(gain: Float, preEffects: Bool = false) {
    _gain = gain
    flags = preEffects ? kMTAudioProcessingTapCreationFlag_PreEffects : kMTAudioProcessingTapCreationFlag_PostEffects
  }

  var gain: Float {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _gain
    }
    set {
      lock.lock()
      _gain = newValue
      lock.unlock()
    }
  }

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  fileprivate func record(_ c: Call) {
    lock.lock()
    _calls.append(c)
    lock.unlock()
  }

  fileprivate func prepared(maxFrames: Int, format: AudioStreamBasicDescription) {
    self.maxFrames = maxFrames
    self.format = format
  }

  /// Creates the tap; the tap retains the probe until it is finalized.
  func makeTap() -> MTAudioProcessingTap? {
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
      init: { _, clientInfo, storageOut in
        storageOut.pointee = clientInfo
      },
      finalize: { tap in
        Unmanaged<GainTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
      },
      prepare: { tap, maxFrames, format in
        let probe = Unmanaged<GainTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
        probe.prepared(maxFrames: Int(maxFrames), format: format.pointee)
      },
      unprepare: nil,
      process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
        let probe = Unmanaged<GainTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
        var range = CMTimeRange()
        var provided: CMItemCount = 0
        let status = MTAudioProcessingTapGetSourceAudio(
          tap, numberFrames, bufferListInOut, flagsOut, &range, &provided)
        numberFramesOut.pointee = provided
        guard status == noErr else {
          // Production rule: never hand on an unfilled buffer (it would be garbage or NaN).
          for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
          }
          probe.record(
            Call(
              start: .invalid, duration: .invalid, requested: Int(numberFrames), provided: 0,
              preSumSq: 0, postSumSq: 0, samples: 0, hostTime: mach_absolute_time(),
              flags: flagsOut.pointee, status: status))
          return
        }
        let gain = probe.gain
        var pre = 0.0
        var post = 0.0
        var n = 0
        let isFloat = probe.format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
          guard isFloat, let data = buffer.mData else { continue }
          let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
          let samples = data.assumingMemoryBound(to: Float.self)
          for i in 0..<count {
            let v = samples[i]
            pre += Double(v * v)
            let g = v * gain
            samples[i] = g
            post += Double(g * g)
          }
          n += count
        }
        probe.record(
          Call(
            start: range.start, duration: range.duration, requested: Int(numberFrames),
            provided: Int(provided), preSumSq: pre, postSumSq: post, samples: n,
            hostTime: mach_absolute_time(), flags: flagsOut.pointee, status: noErr))
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, flags, &tap)
    guard status == noErr else {
      Unmanaged<GainTapProbe>.fromOpaque(callbacks.clientInfo!).release()
      return nil
    }
    return tap
  }
}

/// Audio composition for V-N21: three segments of one tone file with jumps in source time and
/// different speeds, so composition-time and source-time ranges are distinguishable.
struct AudioCompositionSpec {
  struct Segment {
    var sourceStart: Double
    var sourceDuration: Double
    var compositionStart: Double
    var compositionDuration: Double
  }

  /// [0,1) ← src [0,1) at 1×; [1,2) ← src [3,5) at 2×; [2,4) ← src [6,7) at 0.5×.
  static let standard: [Segment] = [
    Segment(sourceStart: 0, sourceDuration: 1, compositionStart: 0, compositionDuration: 1),
    Segment(sourceStart: 3, sourceDuration: 2, compositionStart: 1, compositionDuration: 1),
    Segment(sourceStart: 6, sourceDuration: 1, compositionStart: 2, compositionDuration: 2),
  ]

  static func cm(_ seconds: Double) -> CMTime {
    CMTime(value: Int64((seconds * 48_000).rounded()), timescale: 48_000)
  }

  static func build(tone: URL, segments: [Segment], tap: MTAudioProcessingTap?, keepPitch: Bool = true)
    async throws -> (AVMutableComposition, AVMutableAudioMix)
  {
    let comp = AVMutableComposition()
    let asset = AVURLAsset(url: tone, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let source = try await asset.loadTracks(withMediaType: .audio).first!
    let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    for s in segments {
      let src = CMTimeRange(start: cm(s.sourceStart), duration: cm(s.sourceDuration))
      try track.insertTimeRange(src, of: source, at: cm(s.compositionStart))
      if s.sourceDuration != s.compositionDuration {
        track.scaleTimeRange(
          CMTimeRange(start: cm(s.compositionStart), duration: src.duration),
          toDuration: cm(s.compositionDuration))
      }
    }
    let params = AVMutableAudioMixInputParameters(track: track)
    params.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
    params.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [params]
    return (comp, mix)
  }

  struct MixRead {
    var left: [Float]
    var status: AVAssetReader.Status
    var error: Error?
    /// True when `copyNextSampleBuffer` stopped returning within the watchdog timeout (the read
    /// was cancelled; `left` holds what had arrived).
    var hung = false
  }

  private final class Accumulator {
    let lock = NSLock()
    var left: [Float] = []
    func append(_ xs: [Float]) {
      lock.lock()
      left += xs
      lock.unlock()
    }
    var snapshot: [Float] {
      lock.lock()
      defer { lock.unlock() }
      return left
    }
  }

  /// Reads the mixed composition through AVAssetReaderAudioMixOutput as interleaved Float32
  /// 48 kHz stereo and returns the left-channel samples with the reader's final status. The read
  /// runs on a worker queue under a watchdog: iOS 26 can block in `copyNextSampleBuffer` forever
  /// on scaled ranges (IOS-01 finding), which would otherwise hang the whole test run.
  static func readMix(
    _ comp: AVComposition, mix: AVAudioMix, algorithm: AVAudioTimePitchAlgorithm = .spectral,
    timeout: TimeInterval = 20
  ) throws -> MixRead {
    let reader = try AVAssetReader(asset: comp)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: comp.tracks(withMediaType: .audio),
      audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    output.audioMix = mix
    output.audioTimePitchAlgorithm = algorithm
    reader.add(output)
    reader.startReading()
    let acc = Accumulator()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { raw in
          _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        var left: [Float] = []
        left.reserveCapacity(floats.count / 2)
        var i = 0
        while i < floats.count {
          left.append(floats[i])
          i += 2
        }
        acc.append(left)
      }
      // Keep the reader alive until copyNextSampleBuffer has returned: releasing it while this
      // thread is still blocked inside a cancelled read crashed the test host.
      withExtendedLifetime(reader) { done.signal() }
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      reader.cancelReading()
      _ = done.wait(timeout: .now() + 5)
      return MixRead(left: acc.snapshot, status: reader.status, error: reader.error, hung: true)
    }
    return MixRead(left: acc.snapshot, status: reader.status, error: reader.error)
  }

  /// RMS level (dB) of `x[a s, b s)` at 48 kHz; nil when the range is not inside `x`.
  static func rmsDb(_ x: [Float], _ a: Double, _ b: Double) -> Double? {
    let i = Int(a * 48_000)
    let j = Int(b * 48_000)
    guard i >= 0, j <= x.count, i < j else { return nil }
    return rmsDb(x[i..<j])
  }

  static func rmsDb(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return -.infinity }
    var s = 0.0
    for v in x { s += Double(v) * Double(v) }
    return 10 * log10(s / Double(x.count))
  }
}
