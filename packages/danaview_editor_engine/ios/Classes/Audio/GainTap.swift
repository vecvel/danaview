// OWNER: IOS-18
//
// Per-sample audio gain on iOS (D-37, ARCH §13.2 'Audio', §14.2): an MTAudioProcessingTap on every
// AVMutableAudioMixInputParameters (`audioTapProcessor`) — the preview AVPlayerItem.audioMix and the
// export AVAssetReaderAudioMixOutput.audioMix — multiplies each sample by the track's TapEnvelope
// evaluated at that sample's composition time. AVFoundation mix volume and setVolumeRamp are never
// used (D-37). Values above 1 are not clipped here: the export pump clamps to [−1, 1] (§11.6).
//
// Tap rules from IOS-01 (V-N21):
// - the composition time of the first sample is the source range's `start` (composition time, also
//   inside scaleTimeRange'd segments); later samples advance by frames / sampleRate, NEVER by
//   `range.duration` (inside scaled ranges it is scaled by the rate again);
// - AVPlayer's first call can carry an invalid range: the tap continues from the last known time;
// - when MTAudioProcessingTapGetSourceAudio fails the tap zero-fills its buffers (never hands on
//   garbage or NaN; IOS-12 redoes a fully silent read);
// - in AVPlayer the tap runs 150–280 ms ahead of the item clock, so live envelope swaps are heard
//   with that delay.
//
// One GainTap controls one composition audio track and can produce several MTAudioProcessingTaps
// (one per AVMutableAudioMixInputParameters: preview item and export reader each get their own);
// each tap keeps its own render state and all of them follow the controller's envelope.
//
// Envelope swaps (gain-only patches, ARCH §11.5) are atomic: `swapEnvelope` replaces the reference
// under an unfair lock; each tap picks the new envelope up at its next render call and blends from the
// old to the new multiplier over 40 ms with a raised cosine, so a swap never produces a sample step
// (≤ −60 dBFS discontinuity for a full-scale input and a 1.0 gain change). A swap that arrives during
// a blend is picked up when that blend ends.

import AVFoundation
import MediaToolbox
import os

/// The gain tap controller of one composition audio track (D-37).
final class GainTap {
    /// Length of the old → new envelope blend after a swap.
    static let swapBlendSeconds = 0.040

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var _envelope: TapEnvelope
    /// Test-only measurement hook (nil in production).
    let meter: GainTapMeter?

    init(envelope: TapEnvelope = .unity, meter: GainTapMeter? = nil) {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        _envelope = envelope
        self.meter = meter
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The current envelope.
    var envelope: TapEnvelope {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return _envelope
    }

    /// How many render calls of this controller's taps were handed a range start more than 1 ms
    /// away from where the previous call ended (or an invalid range after the first call). In the
    /// export reader (no seeks) this marks the iOS 26 failure mode where the taps receive
    /// non-composition ranges and the read goes wrong; IOS-12 redoes such a read (ARCH §14.2). In
    /// AVPlayer every seek also counts, so preview ignores it.
    var rangeDiscontinuities: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return _rangeDiscontinuities
    }

    private var _rangeDiscontinuities = 0

    fileprivate func noteRangeDiscontinuity() {
        os_unfair_lock_lock(lock)
        _rangeDiscontinuities += 1
        os_unfair_lock_unlock(lock)
    }

    /// Atomically replaces the envelope (gain-only patch). Every tap of this controller blends to it
    /// over `swapBlendSeconds` from its next render call; the item is not rebuilt.
    func swapEnvelope(_ envelope: TapEnvelope) {
        os_unfair_lock_lock(lock)
        let old = _envelope
        _envelope = envelope
        os_unfair_lock_unlock(lock)
        withExtendedLifetime(old) {}
    }

    /// Creates a new MTAudioProcessingTap driven by this controller (post-effects, so it sees the
    /// time-pitch algorithm's output in composition time).
    func makeTap() throws -> MTAudioProcessingTap {
        let state = GainTapRenderState(controller: self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(state).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<GainTapRenderState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                Unmanaged<GainTapRenderState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<GainTapRenderState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let state = Unmanaged<GainTapRenderState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                var range = CMTimeRange()
                var provided: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &range, &provided)
                numberFramesOut.pointee = provided
                guard status == noErr else {
                    GainTapRenderState.zeroFill(bufferListInOut)
                    state.controller.meter?.recordFailure(status)
                    return
                }
                let startUs: Double? = range.start.isNumeric
                    ? Double(range.start.value) * 1_000_000 / Double(range.start.timescale) : nil
                state.process(bufferListInOut, frames: Int(provided), startUs: startUs)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let created = tap else {
            Unmanaged<GainTapRenderState>.fromOpaque(callbacks.clientInfo!).release()
            throw GainTapError.tapCreateFailed(status)
        }
        return created
    }

    /// Installs a new tap of this controller on [parameters] (`audioTapProcessor`).
    func attach(to parameters: AVMutableAudioMixInputParameters) throws {
        parameters.audioTapProcessor = try makeTap()
    }
}

/// GainTap failures.
enum GainTapError: Error, Equatable {
    case tapCreateFailed(OSStatus)
}

/// Render state of one MTAudioProcessingTap (audio render thread only, apart from prepare).
final class GainTapRenderState {
    let controller: GainTap
    private(set) var sampleRate: Double = 48_000
    private(set) var isFloat = true
    private(set) var bitsPerChannel: UInt32 = 32
    /// Composition time (µs) of the next sample, from the previous call.
    private(set) var nextUs: Double?
    private var scratch: UnsafeMutablePointer<Float>
    private var scratchFrames: Int
    private var blendFrom: UnsafeMutablePointer<Float>
    private var current: TapEnvelope
    private var previous: TapEnvelope?
    private var blendDone = 0
    private var blendTotal = 0

    init(controller: GainTap) {
        self.controller = controller
        current = controller.envelope
        scratchFrames = 4_096
        scratch = .allocate(capacity: scratchFrames)
        blendFrom = .allocate(capacity: scratchFrames)
    }

    deinit {
        scratch.deallocate()
        blendFrom.deallocate()
    }

    /// Tap `prepare`: the processing format and the largest buffer (scratch is allocated here, not
    /// on the render path).
    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        bitsPerChannel = format.mBitsPerChannel
        if maxFrames > scratchFrames {
            scratch.deallocate()
            blendFrom.deallocate()
            scratchFrames = maxFrames
            scratch = .allocate(capacity: scratchFrames)
            blendFrom = .allocate(capacity: scratchFrames)
        }
        controller.meter?.recordFormat(format)
    }

    /// Tap `unprepare` (end of playback / reading): the next prepare starts afresh.
    func unprepare() {
        nextUs = nil
    }

    /// Multiplies [frames] frames of [bufferList] by the envelope; the first frame is at [startUs]
    /// composition µs (nil = continue from the previous call). Any interleaving; Float32 or Int16.
    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, startUs: Double?) {
        guard frames > 0 else { return }
        if let expected = nextUs, startUs.map({ abs($0 - expected) > 1_000 }) ?? true {
            controller.noteRangeDiscontinuity()
        }
        let t0 = startUs ?? nextUs ?? 0
        let step = 1_000_000 / sampleRate
        nextUs = t0 + Double(frames) * step
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let meter = controller.meter
        meter?.recordCall(startUs: startUs, frames: frames)
        let metering = meter?.accumulating == true
        var preSumSq = 0.0
        var postSumSq = 0.0
        var metered = 0
        var done = 0
        while done < frames {
            let n = min(scratchFrames, frames - done)
            gains(into: scratch, count: n, startUs: t0 + Double(done) * step)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(Int(buffer.mNumberChannels), 1)
                if isFloat && bitsPerChannel == 32 {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                    let count = min(n, available - done)
                    guard count > 0 else { continue }
                    for f in 0..<count {
                        let g = scratch[f]
                        let base = (done + f) * channels
                        for c in 0..<channels {
                            let v = samples[base + c]
                            let y = v * g
                            samples[base + c] = y
                            if metering {
                                preSumSq += Double(v) * Double(v)
                                postSumSq += Double(y) * Double(y)
                                metered += 1
                            }
                        }
                    }
                } else if !isFloat && bitsPerChannel == 16 {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    let available = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size / channels
                    let count = min(n, available - done)
                    guard count > 0 else { continue }
                    for f in 0..<count {
                        let g = scratch[f]
                        let base = (done + f) * channels
                        for c in 0..<channels {
                            let y = (Float(samples[base + c]) * g).rounded()
                            samples[base + c] = Int16(max(-32_768, min(32_767, y)))
                        }
                    }
                }
            }
            done += n
        }
        if metering { meter?.accumulate(preSumSq: preSumSq, postSumSq: postSumSq, samples: metered) }
        if let meter, meter.capturing, let first = buffers.first, let data = first.mData, isFloat, bitsPerChannel == 32 {
            let channels = max(Int(first.mNumberChannels), 1)
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = min(frames, Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels)
            meter.recordSamples(startUs: t0, (0..<count).map { samples[$0 * channels] })
        }
    }

    /// The multipliers of [count] samples from [startUs], including a pending swap blend.
    private func gains(into out: UnsafeMutablePointer<Float>, count: Int, startUs: Double) {
        if previous == nil {
            let latest = controller.envelope
            if latest !== current {
                previous = current
                current = latest
                blendDone = 0
                blendTotal = max(1, Int((GainTap.swapBlendSeconds * sampleRate).rounded()))
            }
        }
        current.fill(out, count: count, startUs: startUs, sampleRate: sampleRate)
        guard let from = previous else { return }
        from.fill(blendFrom, count: count, startUs: startUs, sampleRate: sampleRate)
        let total = Double(blendTotal)
        for i in 0..<count {
            let p = blendDone + i
            if p >= blendTotal { break }
            // Raised cosine: weight of the new envelope goes 0 → 1 with zero slope at both ends.
            let w = Float(0.5 - 0.5 * cos(Double.pi * Double(p) / total))
            out[i] = blendFrom[i] + (out[i] - blendFrom[i]) * w
        }
        blendDone += count
        if blendDone >= blendTotal { previous = nil }
    }

    /// Zero-fills every buffer of [bufferList] (GetSourceAudio failed).
    static func zeroFill(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}

/// Test measurement hook of a GainTap: level in and out of the tap, the ranges it was handed and
/// GetSourceAudio failures. Only tests create one (it records from the render thread).
final class GainTapMeter {
    struct Call {
        /// Composition start µs handed to the tap (nil = invalid range).
        let startUs: Double?
        let frames: Int
    }

    private let lock = NSLock()
    private var _preSumSq = 0.0
    private var _postSumSq = 0.0
    private var _samples = 0
    private var _calls: [Call] = []
    private var _failures: [OSStatus] = []
    private var _format: AudioStreamBasicDescription?
    private var _captured: [(startUs: Double, samples: [Float])] = []
    /// Level accumulation only counts while this is true (tests skip the ramp-up).
    var accumulating = true
    /// When true, the tap's output samples (first channel, Float32 formats) are kept with the
    /// composition time of their first sample (FIX-IOS-PITCH-SYNC: click timing in AVPlayer).
    var capturing = false

    init() {}

    fileprivate func accumulate(preSumSq: Double, postSumSq: Double, samples: Int) {
        lock.lock()
        _preSumSq += preSumSq
        _postSumSq += postSumSq
        _samples += samples
        lock.unlock()
    }

    fileprivate func recordCall(startUs: Double?, frames: Int) {
        lock.lock()
        _calls.append(Call(startUs: startUs, frames: frames))
        lock.unlock()
    }

    fileprivate func recordSamples(startUs: Double, _ samples: [Float]) {
        lock.lock()
        _captured.append((startUs, samples))
        lock.unlock()
    }

    /// Captured output blocks (see `capturing`), in render order.
    var captured: [(startUs: Double, samples: [Float])] {
        lock.lock()
        defer { lock.unlock() }
        return _captured
    }

    fileprivate func recordFailure(_ status: OSStatus) {
        lock.lock()
        _failures.append(status)
        lock.unlock()
    }

    fileprivate func recordFormat(_ format: AudioStreamBasicDescription) {
        lock.lock()
        _format = format
        lock.unlock()
    }

    /// Resets the level sums.
    func resetLevels() {
        lock.lock()
        _preSumSq = 0
        _postSumSq = 0
        _samples = 0
        lock.unlock()
    }

    /// (input dB, output dB, samples) since the last reset.
    var levels: (preDb: Double, postDb: Double, samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = Double(max(_samples, 1))
        return (10 * log10(_preSumSq / n), 10 * log10(_postSumSq / n), _samples)
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var failures: [OSStatus] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    var format: AudioStreamBasicDescription? {
        lock.lock()
        defer { lock.unlock() }
        return _format
    }
}
