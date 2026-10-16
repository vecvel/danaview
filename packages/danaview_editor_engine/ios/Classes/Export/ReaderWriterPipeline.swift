// OWNER: IOS-12
//
// The iOS export pipeline (ARCH §14.2, D-22, D-35, D-37, D-38): AVAssetReader over the export
// composition → IOS-17's SegmentedWriter → passthrough concat.
//
// Video. `AVAssetReader(asset: composition)` with `AVAssetReaderVideoCompositionOutput` (the
// export variant of IOS-08/IOS-10: renderSize = output, frameDuration = 1/export fps, DVCompositor
// stamping `danaview.frame = k`). The SegmentedWriter opens the source once per 10 s segment, so
// every segment re-creates its reader with that segment's `timeRange` (resume starts at the next
// segment). Every reader range and writer session end is clamped to the grid end CMTime(K, gridFps)
// (`ExportTime`, FIX-IOS-DURATION: the µs durUs = ceil(K·10⁶/fps) lies past it at 24/30/48/60 fps
// and a reader past the last instruction fails with −11841). IOS-08 lays the spacer without a
// fractionally scaled edit (FIX-IOS-SPACER), so a segment reader may start anywhere. Frames are
// BGRA IOSurface buffers; with the `.rotated` layout (ARCH §14.1) each frame
// is turned 90° counter-clockwise into a landscape buffer and the final file gets a 90° clockwise
// `preferredTransform`, set on the concat writer's video input (no extra remux copy).
//
// Audio. One whole-duration AAC-LC 48 kHz stereo file (IOS-17 `writeAudio`):
// - `plan.audio` empty (no audio, everything muted or soloed out, images/text only): silent LPCM
//   across [0, durUs); no AVAssetReaderAudioMixOutput is ever built over zero tracks (D-38: that
//   raises an uncatchable NSInvalidArgumentException).
// - otherwise `AVAssetReaderAudioMixOutput` (LPCM Float32 48 kHz stereo interleaved, `.timeDomain`
//   for keep-pitch tracks as set per track by IOS-08, IOS-18 gain taps carrying the plan
//   envelopes up to +6.02 dB). Samples are clamped to [−1, 1] (NaN → 0) before the AAC input
//   (§11.6 hard clip, D-37). The reader runs 0.01–0.10 s past the composition; the writer trims to
//   the duration (`endSession`). IOS-01 saw about one read in 70 come back silent or NaN, so a
//   read is validated (NaN, fully silent while the plan has audible audio, a tap range
//   discontinuity, a hung read, and a dropout or a seam step inside a speed-ramp or time-pitch
//   segment, see `TimePitchWatch`) and redone with a fresh composition, at most twice; the last attempt is
//   accepted (sanitised) unless it hangs or fails.
//
// Order: video segments (phase rendering; progress = last video PTS / duration), then the audio
// file and the concat (phase finishing). Pumps run on IOS-17's serial pump queue with
// requestMediaDataWhenReady; this class blocks the calling queue (the export work queue).
// Interruptions (background, AVFoundation −11847/−11819) return `.interrupted` with the checkpoint
// kept; `cancel` throws `cancelled` (the coordinator deletes the files).

import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Export composition

/// A composition built for export with the render session its compositor uses (kept alive).
final class ExportComposition {
    let built: BuiltComposition
    let session: DVRenderSession?

    init(built: BuiltComposition, session: DVRenderSession?) {
        self.built = built
        self.session = session
    }

    /// Decoder-backed composition video tracks (CORE-36 slots; the spacer is not counted).
    var decoderTracks: Int { built.trackIDBySeq.count }

    /// Audio tracks the mix output would read.
    var audioTracks: [AVAssetTrack] { built.composition.tracks(withMediaType: .audio) }

    func release() { built.releaseMedia() }
}

/// Builds the export composition of a plan (throws `decoderInitFailed` when a track cannot get a
/// decoder, `mediaOffline` for missing media, …).
typealias ExportCompositionFactory = (RenderPlan) throws -> ExportComposition

// MARK: - Grid end (D-35)

/// Export time ranges on the composition grid (FIX-IOS-DURATION, QA-03 finding 1).
///
/// The composition ends at `CMTime(K, gridFps)` (spacer, instructions; IOS-08), while the plan's
/// `durUs = timeOfFrame(K) = ceil(K·10⁶/gridFps)` lies up to 1 µs later whenever K·10⁶/gridFps is
/// fractional (24/30/48/60 fps). A reader whose µs time range ends past the last instruction fails
/// with AVFoundationErrorDomain −11841 (invalid video composition), so every reader range and
/// every writer session end is clamped to the grid end.
enum ExportTime {
    /// `CMTime(K, gridFps)` with K = frameIndexOf(durUs) on the plan's edit grid.
    static func gridEnd(_ plan: RenderPlan) -> CMTime {
        let grid = plan.canvas.editGrid
        return grid.cmTime(frame: grid.frameIndexOf(plan.durUs))
    }

    /// The µs time [us] clamped to [end] (never later than the grid end).
    static func clamp(us: Int64, to end: CMTime) -> CMTime {
        CMTimeMinimum(FrameGrid.cmTime(us: us), end)
    }

    /// The reader time range of the output range [startUs, endUs) of [plan]: starts stay µs (segment
    /// starts are whole 10 s), the end is clamped to the grid end.
    static func readerRange(startUs: Int64, endUs: Int64, plan: RenderPlan) -> CMTimeRange {
        let end = gridEnd(plan)
        let start = CMTimeMinimum(FrameGrid.cmTime(us: startUs), end)
        return CMTimeRange(start: start, end: clamp(us: endUs, to: end))
    }
}

// MARK: - Pipeline

final class ReaderWriterPipeline {
    struct Input {
        var jobId: String
        var plan: RenderPlan
        var planHash: String
        var settings: EncoderSettings
        var layout: EncodeLayout
        /// `work/export-<jobId>/`.
        var directory: URL
        var outputURL: URL
    }

    struct Result: Equatable {
        var path: String
        var bytes: Int64
        var durationUs: Int64
        var frames: Int
        var peakDiskBytes: Int64
        var reencodedSegments: [Int]
    }

    enum Outcome: Equatable {
        case completed(Result)
        /// Stopped by an interruption; the checkpoint keeps every finished segment.
        case interrupted
    }

    let input: Input
    let control: PipelineControl
    let makeComposition: ExportCompositionFactory
    var segmentDurationUs = SegmentedWriter.defaultSegmentDurationUs
    /// Audio reads per job (the first plus at most two redos).
    var maxAudioAttempts = 3
    /// Seconds one audio buffer may take before the read counts as hung.
    var audioWatchdog: TimeInterval = 30
    /// Encoder probe used to classify video encoder failures (`encoderSizeLimit` vs
    /// `encoderUnavailable`); decoder and media errors keep their codes (`decoderInitFailed` routes
    /// the job to the multi-pass hook).
    var probe: EncoderProbe = .system

    // Test hooks.
    /// Configures the segmented writer (fault injection, IOS-17 hooks).
    var configureWriter: ((SegmentedWriter) -> Void)?
    /// An error to throw when the video source opens the segment starting at the given µs.
    var videoOpenFault: ((Int64) -> Error?)?
    /// Called with every audio source before it is read (attempt 1, 2, …).
    var audioSourceHook: ((MixAudioSource, Int) -> Void)?

    /// Audio reads of the last run (tests).
    private(set) var audioAttempts = 0
    /// Whether the last run wrote silent audio (tests).
    private(set) var wroteSilentAudio = false

    init(input: Input, control: PipelineControl, makeComposition: @escaping ExportCompositionFactory) {
        self.input = input
        self.control = control
        self.makeComposition = makeComposition
    }

    /// Whether any audio segment of [plan] has a non-zero gain (a silent read is then suspicious).
    static func hasAudibleAudio(_ plan: RenderPlan) -> Bool {
        plan.audio.contains { seg in seg.gain.isEmpty || seg.gain.contains { $0.v > 1e-4 } }
    }

    /// Runs the job to completion or interruption.
    func run() throws -> Outcome {
        let plan = input.plan
        guard plan.durUs > 0 else { throw EngineError(.planInvalid, "empty export plan") }
        let segmentSettings = input.settings.segmentSettings(layout: input.layout)
        let writer = try SegmentedWriter(
            directory: input.directory, jobKind: ExportJob.jobKind, inputHash: input.planHash, settings: segmentSettings,
            startUs: 0, endUs: plan.durUs, segmentDurationUs: segmentDurationUs)
        // D-35: the last segment, the audio file and the concat end on the composition's grid end
        // CMTime(K, gridFps), not on durUs (up to 1 µs later at 24/30/48/60 fps).
        writer.exactEnd = ExportTime.gridEnd(plan)
        configureWriter?(writer)
        control.attach(writer)
        defer { control.attach(nil) }
        if control.isCancelled { throw EngineError.cancelled }
        if let job = control as? ExportJob { job.restoreProgress(doneUs: writer.checkpoint.resumeTimeUs) }

        var composition: ExportComposition?
        defer { composition?.release() }

        // Video segments.
        if !writer.checkpoint.isVideoComplete {
            control.enter(.preparing)
            let built = try makeComposition(plan)
            composition = built
            let rotator = input.layout == .rotated
                ? FrameRotator(sourceWidth: input.settings.width, sourceHeight: input.settings.height) : nil
            let source = CompositionVideoSource(composition: built, control: control, rotator: rotator)
            source.openFault = videoOpenFault
            control.enter(.rendering)
            let outcome: SegmentedWriter.Outcome
            do {
                outcome = try writer.writeVideo(source: source)
            } catch {
                if control.isCancelled { throw EngineError.cancelled }
                throw EncoderErrors.map(error, settings: input.settings, probe: probe)
            }
            if outcome == .interrupted {
                if control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
        } else if let job = control as? ExportJob {
            job.videoProgress(lastPtsUs: plan.durUs - 1)
        }

        // Audio and concat.
        control.enter(.finishing)
        if !writer.checkpoint.audioComplete {
            if try writeAudio(writer, composition: &composition) == .interrupted {
                if control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
        }
        if control.isCancelled { throw EngineError.cancelled }
        composition?.release()
        composition = nil

        // The rotated layout's preferredTransform is set by the concat writer itself (one copy).
        let transform = input.layout == .rotated
            ? EncodeLayout.rotatedTransform(encodedHeight: segmentSettings.height) : .identity
        let concat: SegmentConcat.Result
        do {
            concat = try writer.concat(to: input.outputURL, transform: transform)
        } catch {
            try? FileManager.default.removeItem(at: input.outputURL)
            if control.isCancelled { throw EngineError.cancelled }
            throw error
        }
        if control.isCancelled {
            try? FileManager.default.removeItem(at: input.outputURL)
            throw EngineError.cancelled
        }
        return .completed(Result(
            path: input.outputURL.path, bytes: SegmentedWriter.fileSize(input.outputURL), durationUs: plan.durUs,
            frames: concat.frames, peakDiskBytes: concat.peakDiskBytes, reencodedSegments: concat.reencodedSegments))
    }

    private func writeAudio(_ writer: SegmentedWriter, composition: inout ExportComposition?) throws -> SegmentedWriter.Outcome {
        let plan = input.plan
        if plan.audio.isEmpty {
            wroteSilentAudio = true
            return try writer.writeAudio(source: SilentAudioSource(control: control))
        }
        let audible = ReaderWriterPipeline.hasAudibleAudio(plan)
        var attempt = 0
        while true {
            attempt += 1
            audioAttempts = attempt
            if composition == nil || attempt > 1 {
                composition?.release()
                composition = nil
                composition = try makeComposition(plan)
            }
            guard let built = composition else { throw EngineError(.internal, "no export composition") }
            guard built.built.audioMix != nil, !built.audioTracks.isEmpty else {
                // Every segment was skipped (missing streams): silence, never a mix over zero tracks.
                wroteSilentAudio = true
                return try writer.writeAudio(source: SilentAudioSource(control: control))
            }
            let source = MixAudioSource(composition: built, expectAudible: audible, control: control)
            source.timePitchWatch = TimePitchWatch.of(plan)
            source.validates = attempt < maxAudioAttempts
            source.watchdog = audioWatchdog
            audioSourceHook?(source, attempt)
            do {
                return try writer.writeAudio(source: source)
            } catch {
                if control.isCancelled { throw EngineError.cancelled }
                guard let reason = source.rejection, attempt < maxAudioAttempts else { throw error }
                Log.info(.export, "audio read \(attempt) rejected (\(reason)); reading again")
            }
        }
    }
}

// MARK: - Video source

/// Frames of the export composition per segment (AVAssetReaderVideoCompositionOutput).
final class CompositionVideoSource: SegmentVideoSource {
    private let composition: ExportComposition
    private let control: PipelineControl
    private let rotator: FrameRotator?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderVideoCompositionOutput?
    /// Test hook: an error to throw when opening the segment that starts at the given µs.
    var openFault: ((Int64) -> Error?)?
    /// Frames delivered (all segments).
    private(set) var framesRead = 0

    static let videoSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    init(composition: ExportComposition, control: PipelineControl, rotator: FrameRotator?) {
        self.composition = composition
        self.control = control
        self.rotator = rotator
    }

    func openSegment(startUs: Int64, endUs: Int64) throws {
        closeSegment()
        if let fault = openFault?(startUs) { throw fault }
        let built = composition.built
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: built.composition)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = ExportTime.readerRange(startUs: startUs, endUs: endUs, plan: built.plan)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.decoderInitFailed, "video composition output refused") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "export reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    func nextFrame() throws -> SegmentFrame? {
        control.waitWhileThermalCritical()
        guard let output = output, let reader = reader else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let frame = try rotator?.rotate(image) ?? image
            framesRead += 1
            control.videoProgress(lastPtsUs: FrameGrid.us(pts))
            return SegmentFrame(pixelBuffer: frame, pts: pts)
        }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "export reader failed")
        }
        return nil
    }

    func closeSegment() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
    }
}

/// Turns BGRA frames 90° counter-clockwise into landscape buffers (ARCH §14.1 `.rotated` layout).
final class FrameRotator {
    /// Size of the rotated (encoded) buffer.
    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?

    init(sourceWidth: Int, sourceHeight: Int) {
        width = sourceHeight
        height = sourceWidth
    }

    func rotate(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw EngineError(.internal, "rotation expects BGRA frames")
        }
        let destination = try makeBuffer()
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        var src = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source), height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source))
        var dst = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(destination), height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination))
        guard Int(src.width) == height, Int(src.height) == width else {
            throw EngineError(.internal, "rotation size mismatch")
        }
        var background: [UInt8] = [0, 0, 0, 255]
        let status = vImageRotate90_ARGB8888(
            &src, &dst, UInt8(kRotate90DegreesCounterClockwise), &background, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw EngineError(.internal, "frame rotation failed (\(status))") }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool = pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let out = buffer else {
            throw EngineError(.internal, "no rotation buffer")
        }
        return out
    }
}

// MARK: - Audio

/// LPCM Float32 48 kHz stereo interleaved buffers (the AAC writer's input format).
enum ExportPCM {
    static let sampleRate = EncoderSettings.audioSampleRate
    static let channels = EncoderSettings.audioChannels

    /// Reader output settings of the mix (ARCH §14.2).
    static var readerSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    static let format: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        return description
    }()

    /// A sample buffer of [frames] interleaved frames at [pts]; [fill] writes the samples (zeroed).
    static func makeBuffer(frames: Int, pts: CMTime, fill: (UnsafeMutableBufferPointer<Float>) -> Void) throws -> CMSampleBuffer {
        guard let format = format, frames > 0 else { throw EngineError(.internal, "no PCM format") }
        let bytes = frames * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let blockBuffer = block else { throw EngineError(.internal, "PCM block (\(status))") }
        var pointer: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let raw = pointer else { throw EngineError(.internal, "PCM pointer (\(status))") }
        raw.withMemoryRebound(to: Float.self, capacity: frames * channels) { floats in
            let samples = UnsafeMutableBufferPointer(start: floats, count: frames * channels)
            samples.initialize(repeating: 0)
            fill(samples)
        }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let out = sample else { throw EngineError(.internal, "PCM sample (\(status))") }
        return out
    }
}

/// Digital silence across the output range (plans without audio segments, D-38).
final class SilentAudioSource: SegmentAudioSource {
    static let chunkFrames = 4_096
    private let control: PipelineControl?
    private var startUs: Int64 = 0
    private var total: Int64 = 0
    private var next: Int64 = 0

    init(control: PipelineControl?) {
        self.control = control
    }

    func openAudio(startUs: Int64, endUs: Int64) throws {
        self.startUs = startUs
        let rate = Int64(ExportPCM.sampleRate)
        total = max(1, ((endUs - startUs) * rate + 500_000) / 1_000_000)
        next = 0
    }

    func nextAudio() throws -> CMSampleBuffer? {
        control?.waitWhileThermalCritical()
        guard next < total else { return nil }
        let frames = Int(min(Int64(SilentAudioSource.chunkFrames), total - next))
        let pts = CMTimeAdd(
            FrameGrid.cmTime(us: startUs), CMTime(value: next, timescale: CMTimeScale(ExportPCM.sampleRate)))
        next += Int64(frames)
        return try ExportPCM.makeBuffer(frames: frames, pts: pts) { _ in }
    }

    func closeAudio() {}
}

/// Checks of an export audio read inside speed-ramp and time-pitch segments (FIX-IOS-MEDIA,
/// QA-11 (d) ramp-seam click test).
///
/// The time-pitch unit of a speed-ramp pair or of a scaled keep-pitch track sometimes renders a
/// stretch of exact zeros inside a piece. FIX-IOS-MEDIA measured, for QA-11's 7-point ramp on the
/// iOS 26.5 simulator, bad reads in up to a third of the reads under load (≈ 1 in 70 in QA-11):
/// - 95 %: a DROPOUT, the mix steps between the signal and digital silence for 6–300 ms;
/// - 5 %: one track of a ramp-seam pair drops out inside its 5 ms crossfade while the other
///   track still plays, a SEAM STEP (the mix level falls abruptly at the seam).
/// A read is rejected (and redone, see the file comment) for either:
/// - an exact-zero run (both channels) of at least `minRunFrames` with an abrupt edge (a frame at
///   or above `abruptEdge` within `edgeFrames` of the run) inside a watched span where the plan
///   gain is audible.
///   `.timeDomain` overlap-add cannot give content that shape except from digitally gated
///   sources;
/// - at an inner seam of a ramp (a change of rate between map pieces) with audible gain, a peak
///   second difference of the mono mix within ±`seamWindowUs` that exceeds `seamStepRatio` times
///   the peak in the reference windows 10–40 ms on either side (and `abruptEdge` in absolute
///   terms). A steady tone's good seams measure ≤ 1.4, the dropped crossfade 7.6.
/// A false positive (a transient of the content right on a seam) only costs a redo: the last
/// attempt is accepted.
struct TimePitchWatch: Equatable {
    struct Span: Equatable {
        /// Composition µs, already shrunk by `edgeMarginUs` at both ends.
        let startUs: Int64
        let endUs: Int64
        let gain: [AnimKey]
    }

    /// Spans watched for dropouts.
    let spans: [Span]
    /// Inner ramp seams (composition µs, sorted) watched for steps.
    let seamsUs: [Int64]

    /// 2 ms at 48 kHz.
    static let minRunFrames = 96
    /// ≈ −50 dBFS.
    static let abruptEdge: Float = 0.003
    /// 2 ms at 48 kHz: how close to a run the signal must reach `abruptEdge` (a dropout can end in
    /// the other track's crossfade, a few ms of low level before the step back).
    static let edgeFrames: Int64 = 96
    /// Segment edges (ramp-seam extensions, keep-pitch latency trims, fades) are not watched.
    static let edgeMarginUs: Int64 = 10_000
    /// Gain below which a span or a seam is treated as silent.
    static let audibleGain = 1e-4
    /// Half width of the window around a seam (the seam crossfade is 5 ms).
    static let seamWindowUs: Int64 = 8_000
    /// Reference windows: from 10 ms to 40 ms before and after the seam.
    static let seamReferenceUs: (near: Int64, far: Int64) = (10_000, 40_000)
    static let seamStepRatio: Float = 4

    static let none = TimePitchWatch(spans: [], seamsUs: [])

    /// Speed ramps (more than one map piece) and keep-pitch segments with a scaled piece.
    static func of(_ plan: RenderPlan) -> TimePitchWatch {
        var spans: [Span] = []
        var seams: [Int64] = []
        for seg in plan.audio {
            let scaled = seg.map.contains { $0.t1 > $0.t0 && abs($0.rate - 1) > 1e-6 }
            guard seg.map.count > 1 || (seg.pitch && scaled) else { continue }
            let start = seg.t0 + edgeMarginUs, end = seg.t1 - edgeMarginUs
            if end > start { spans.append(Span(startUs: start, endUs: end, gain: seg.gain)) }
            let pieces = seg.map.sorted { $0.t0 < $1.t0 }
            for (a, b) in zip(pieces, pieces.dropFirst()) where abs(a.rate - b.rate) > 1e-6 {
                let seam = b.t0
                guard seam - seamReferenceUs.far >= seg.t0, seam + seamReferenceUs.far <= seg.t1 else { continue }
                guard Keyframes.evaluate(seg.gain, at: seam, fallback: 1) > audibleGain else { continue }
                seams.append(seam)
            }
        }
        return TimePitchWatch(spans: spans, seamsUs: Array(Set(seams)).sorted())
    }

    var isEmpty: Bool { spans.isEmpty && seamsUs.isEmpty }

    /// Whether the composition interval [startUs, endUs) lies inside a watched span whose gain is
    /// audible across it.
    func watches(startUs: Int64, endUs: Int64) -> Bool {
        spans.contains { span in
            guard startUs >= span.startUs, endUs <= span.endUs else { return false }
            let mid = startUs + (endUs - startUs) / 2
            return [startUs, mid, endUs].allSatisfy { Keyframes.evaluate(span.gain, at: $0, fallback: 1) > TimePitchWatch.audibleGain }
        }
    }
}

/// The audio mix of the export composition (AVAssetReaderAudioMixOutput with IOS-18 gain taps),
/// clamped to [−1, 1] and validated (see the file comment).
final class MixAudioSource: SegmentAudioSource {
    private let composition: ExportComposition
    private let expectAudible: Bool
    private let control: PipelineControl?
    private let readQueue = DispatchQueue(label: "com.vecvel.danaview.editor.export.audioread", qos: .userInitiated)
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?

    /// Reject bad reads (false on the last attempt: the read is accepted, sanitised).
    var validates = true
    /// Seconds one buffer may take.
    var watchdog: TimeInterval = 30
    /// Test hook: rewrites the floats of buffer n (0-based) before validation.
    var corrupt: ((Int, UnsafeMutableBufferPointer<Float>) -> Void)?

    /// Why the read was rejected (nil = accepted or not finished).
    private(set) var rejection: String?
    private(set) var frames = 0
    private(set) var nanSamples = 0
    private(set) var clippedSamples = 0
    private(set) var peak: Float = 0
    private var buffers = 0

    /// Dropout and seam-step checks (none = not checked).
    var timePitchWatch = TimePitchWatch.none {
        didSet { seamStats = timePitchWatch.seamsUs.map { SeamStats(seamUs: $0) } }
    }
    /// Dropouts and seam steps found (the first one described in `firstTimePitchFault`).
    private(set) var dropouts = 0
    private(set) var seamSteps = 0
    private(set) var firstTimePitchFault: String?
    /// Scan state: absolute frame of the next expected frame, the current exact-zero run and the
    /// magnitude of the frame before it, the last two mono samples (second difference).
    private var scanNext: Int64?
    private var runStart: Int64?
    /// Last frame at or above `abruptEdge`.
    private var lastLoud: Int64?
    /// A finished run waiting for a loud frame after it (start, end).
    private var pendingRun: (start: Int64, end: Int64)?
    private var mono1: Float?
    private var mono2: Float?
    private var seamStats: [SeamStats] = []
    private var seamCursor = 0

    /// Peak second differences around one seam.
    private struct SeamStats {
        let seamUs: Int64
        var window: Float = 0
        var reference: Float = 0
        /// Whether the read reached the end of the far reference window.
        var complete = false
    }

    /// Peak below which a whole read counts as silent.
    static let silencePeak: Float = 1e-5

    init(composition: ExportComposition, expectAudible: Bool, control: PipelineControl?) {
        self.composition = composition
        self.expectAudible = expectAudible
        self.control = control
    }

    func openAudio(startUs: Int64, endUs: Int64) throws {
        closeAudio()
        let built = composition.built
        let tracks = composition.audioTracks
        guard let mix = built.audioMix, !tracks.isEmpty else {
            // D-38: never construct a mix output over zero tracks.
            throw EngineError(.internal, "audio mix without tracks")
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: built.composition)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = ExportTime.readerRange(startUs: startUs, endUs: endUs, plan: built.plan)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExportPCM.readerSettings)
        output.audioMix = mix
        output.audioTimePitchAlgorithm = .timeDomain
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.decodeFailed, "audio mix output refused") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "audio reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    func nextAudio() throws -> CMSampleBuffer? {
        control?.waitWhileThermalCritical()
        guard let output = output, let reader = reader else { return nil }
        let box = SampleBox()
        let done = DispatchSemaphore(value: 0)
        readQueue.async {
            box.sample = output.copyNextSampleBuffer()
            done.signal()
        }
        if done.wait(timeout: .now() + watchdog) == .timedOut {
            rejection = "hung"
            reader.cancelReading()
            _ = done.wait(timeout: .now() + 5)
            throw EngineError(.decodeFailed, "audio read hung", retryable: true)
        }
        guard let sample = box.sample else {
            if reader.status == .failed {
                rejection = "failed"
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio reader failed")
            }
            try finishValidation()
            return nil
        }
        return try sanitized(sample)
    }

    private final class SampleBox {
        var sample: CMSampleBuffer?
    }

    private func finishValidation() throws {
        var reason: String?
        let jumps = composition.built.gainTaps.map(\.rangeDiscontinuities).reduce(0, +)
        if nanSamples > 0 {
            reason = "NaN"
        } else if expectAudible && peak < MixAudioSource.silencePeak {
            reason = "silent"
        } else if jumps > 0 {
            reason = "tap range discontinuity"
        } else {
            evaluateSeams()
            if dropouts + seamSteps > 0 {
                reason = "time-pitch fault (\(dropouts) dropout(s), \(seamSteps) seam step(s); first: \(firstTimePitchFault ?? "?"))"
            }
        }
        guard let reason = reason else { return }
        guard validates else {
            Log.info(.export, "audio read accepted on the last attempt despite: \(reason)")
            return
        }
        rejection = reason
        throw EngineError(.decodeFailed, "audio read rejected: \(reason)", retryable: true)
    }

    /// A copy of [sample] with NaN → 0 and every sample clamped to [−1, 1].
    private func sanitized(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw EngineError(.decodeFailed, "audio buffer without data") }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        let frameCount = count / ExportPCM.channels
        guard frameCount > 0 else { return try ExportPCM.makeBuffer(frames: 1, pts: CMSampleBufferGetPresentationTimeStamp(sample)) { _ in } }
        let index = buffers
        buffers += 1
        var nan = 0
        var clipped = 0
        var localPeak: Float = 0
        let out = try ExportPCM.makeBuffer(frames: frameCount, pts: CMSampleBufferGetPresentationTimeStamp(sample)) { dst in
            _ = dst.withMemoryRebound(to: UInt8.self) { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frameCount * ExportPCM.channels * 4, destination: bytes.baseAddress!)
            }
            corrupt?(index, dst)
            for i in 0..<dst.count {
                var v = dst[i]
                if v.isNaN {
                    nan += 1
                    v = 0
                } else if v > 1 {
                    clipped += 1
                    v = 1
                } else if v < -1 {
                    clipped += 1
                    v = -1
                }
                dst[i] = v
                let a = abs(v)
                if a > localPeak { localPeak = a }
            }
        }
        frames += frameCount
        nanSamples += nan
        clippedSamples += clipped
        peak = max(peak, localPeak)
        if !timePitchWatch.isEmpty { scanTimePitch(out, frames: frameCount) }
        return out
    }

    /// Scans one sanitised buffer for `TimePitchWatch` faults: exact-zero runs (across buffer
    /// boundaries; a PTS gap between buffers resets the scan) and the second-difference peaks
    /// around the watched seams.
    private func scanTimePitch(_ sample: CMSampleBuffer, frames frameCount: Int) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let rate = Double(ExportPCM.sampleRate)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        let first = Int64((pts.seconds * rate).rounded())
        if let expected = scanNext, abs(first - expected) > 1 {
            runStart = nil
            lastLoud = nil
            pendingRun = nil
            mono1 = nil
            mono2 = nil
        }
        scanNext = first + Int64(frameCount)
        var pointer: UnsafeMutablePointer<Int8>?
        var length = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let base = pointer else { return }
        let channels = ExportPCM.channels
        let count = min(frameCount, length / (4 * channels))
        let framesPerUs = rate / 1_000_000
        func frame(_ us: Int64) -> Int64 { Int64((Double(us) * framesPerUs).rounded()) }
        base.withMemoryRebound(to: Float.self, capacity: count * channels) { samples in
            for f in 0..<count {
                var magnitude: Float = 0
                var sum: Float = 0
                for c in 0..<channels {
                    let v = samples[f * channels + c]
                    magnitude = max(magnitude, abs(v))
                    sum += v
                }
                let index = first + Int64(f)
                // Dropouts.
                if !timePitchWatch.spans.isEmpty {
                    let loud = magnitude >= TimePitchWatch.abruptEdge
                    if let pending = pendingRun {
                        if index >= pending.end + TimePitchWatch.edgeFrames {
                            pendingRun = nil
                        } else if loud {
                            flagDropout(start: pending.start, end: pending.end, rate: rate)
                            pendingRun = nil
                        }
                    }
                    if magnitude == 0 {
                        if runStart == nil { runStart = index }
                    } else if let start = runStart {
                        runStart = nil
                        if index - start >= Int64(TimePitchWatch.minRunFrames) {
                            if loud || lastLoud.map({ start - $0 <= TimePitchWatch.edgeFrames }) == true {
                                flagDropout(start: start, end: index, rate: rate)
                            } else {
                                pendingRun = (start, index)
                            }
                        }
                    }
                    if loud { lastLoud = index }
                }
                // Seam steps.
                let mono = sum / Float(channels)
                defer {
                    mono2 = mono1
                    mono1 = mono
                }
                guard !seamStats.isEmpty, let m1 = mono1, let m2 = mono2 else { continue }
                let d2 = abs(mono - 2 * m1 + m2)
                while seamCursor < seamStats.count,
                      index >= frame(seamStats[seamCursor].seamUs + TimePitchWatch.seamReferenceUs.far) {
                    seamStats[seamCursor].complete = true
                    seamCursor += 1
                }
                var k = seamCursor
                while k < seamStats.count {
                    let seam = seamStats[k].seamUs
                    let lo = frame(seam - TimePitchWatch.seamReferenceUs.far)
                    if index < lo { break }
                    let offset = abs(index - frame(seam))
                    if offset <= frame(TimePitchWatch.seamWindowUs) {
                        seamStats[k].window = max(seamStats[k].window, d2)
                    } else if offset >= frame(TimePitchWatch.seamReferenceUs.near) {
                        seamStats[k].reference = max(seamStats[k].reference, d2)
                    }
                    k += 1
                }
            }
        }
    }

    private func flagDropout(start: Int64, end: Int64, rate: Double) {
        let startUs = Int64((Double(start) * 1_000_000 / rate).rounded(.down))
        let endUs = Int64((Double(end) * 1_000_000 / rate).rounded(.up))
        guard timePitchWatch.watches(startUs: startUs, endUs: endUs) else { return }
        dropouts += 1
        if firstTimePitchFault == nil {
            firstTimePitchFault = "dropout of \(end - start) frames at \(startUs) µs"
        }
    }

    /// Counts the seam steps of the seams the read covered completely.
    private func evaluateSeams() {
        for stats in seamStats where stats.complete {
            guard stats.window >= TimePitchWatch.abruptEdge,
                  stats.window > TimePitchWatch.seamStepRatio * stats.reference else { continue }
            seamSteps += 1
            if firstTimePitchFault == nil {
                firstTimePitchFault = "seam step at \(stats.seamUs) µs, peak \(stats.window) vs \(stats.reference)"
            }
        }
    }

    func closeAudio() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
    }
}
