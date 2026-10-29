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
// fractionally scaled edit (FIX-IOS-SPACER) but as ONE sample across the timeline, so before each
// segment reader opens, `ExportSpacer` re-lays it with a sample starting at the reader's start
// (FIX-IOS-EXPORT-STALL, QA-05 D1: a reader starting past every media track never delivered a
// frame). Frames are BGRA IOSurface buffers; with the `.rotated` layout (ARCH §14.1) each frame
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
//   segment, see `TimePitchWatch`) and redone with a fresh composition (so a fresh time-pitch unit),
//   at most four times, after a doubling back-off (0.25 s up to 2 s). The last attempt is accepted
//   (sanitised) unless it hangs or fails, or still has a time-pitch fault: then the export fails
//   with a typed, retryable `decodeFailed` (`timePitchFailure`) and no file is written; a dropout is
//   never shipped (CI round 6). A fault every witness read reproduces at the same place (at least
//   `minContentWitnesses` reads without another defect) is the content, not a fault
//   (`TimePitchFault.recurring`).
//
// Reader threading and hangs (FIX-IOS-D7, QA-05 D7, QA-01 FIX-IOS-12-1). AVAssetReaderAudioMixOutput
// over a keep-pitch scaled track sometimes blocks inside `copyNextSampleBuffer` for good
// (`remakerFamily_renderPipelineRanDry`; `ExportD7Tests` sees it in 0 to 3 of 8 fresh reads of the
// soak project on the iOS 26.5 simulator, the soak under load in every read). Rules:
// - every AVAssetReader is created, read, cancelled and released on ONE serial queue of its own
//   (`MixReadSession`, `CompositionVideoSource`), and its queue closures hold the reader, its output
//   and the composition, so nothing is cancelled or released while a call into it is outstanding;
// - the audio watchdog only signals: a hung read is left blocked on its queue and its reader is
//   never torn down (kept for the process, like IOS-17's abandoned pumps), and the read resumes on
//   a fresh composition and reader from the frame after the last delivered buffer
//   (`maxAudioResumes`), so the export completes; a stop request ends the wait at once (typed
//   interruption). A resumed reader starts inside the timeline, and such an
//   AVAssetReaderAudioMixOutput stops at the end of the audio there (10.0 s or 17.0 s of the soak's
//   39 s, CI round 6) instead of rendering the silence to its range end, so a resumed read that
//   ends early continues from the plan's audio layout (`continuation`): a fresh reader where audio
//   goes on, the silence up to the next audio segment, the silence after the last one. (Reading
//   the whole range again instead replays the same render and hangs at the same frame.) A read that
//   still ends more than `maxShortfallUs` early is rejected and never shipped (`shortRead`);
// - each export segment reads its own anchored copy of the composition (no composition is mutated
//   while a reader uses it), every audio read gets a fresh composition (never the video phase's),
//   and each phase's readers are torn down, and their compositions released, before the next phase
//   or the next export starts.
//
// Order: video segments (phase rendering; progress = last video PTS / duration), then the audio
// file and the concat (phase finishing). Pumps run on IOS-17's serial pump queue with
// requestMediaDataWhenReady and call into the readers through their own queues; this class blocks
// the calling queue (the export work queue).
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

// MARK: - Spacer anchor (FIX-IOS-EXPORT-STALL, QA-05 D1)

/// Puts a spacer sample start at a reader's start time.
///
/// IOS-08 lays the one-frame spacer as ONE edit scaled across n whole frames (FIX-IOS-SPACER), so
/// the spacer track holds one sample that starts at 0 and lasts the whole timeline. An
/// `AVAssetReaderVideoCompositionOutput` whose `timeRange` starts where no other video track has
/// a sample (past the end of every media track, or in a stretch of images, text or gaps) then
/// never delivers a frame: `copyNextSampleBuffer` blocks forever (iOS 26.5 simulator, measured by
/// `ExportStallTests`: [21 s, 25 s) and [30 s, 31.03 s) of a project whose video ends at 20 s
/// hang with 0 frames, [0, 31.03 s) reads all 931). That was the soak's stalled export: the
/// segment after the last media frame opened its reader and waited forever.
///
/// Before a reader opens at time T > 0, the spacer track is re-laid as [0, T) and [T, end), each
/// with the same integral-scale-plus-unscaled-remainder layout as IOS-08, so a spacer sample starts
/// exactly at T. Nothing visible changes (the spacer is black and never drawn: the compositor only
/// needs it to run for every output frame).
enum ExportSpacer {
    /// Test hook: false reproduces the soak's hang (the reader then opens inside the one sample).
    static var isEnabled = true

    /// Re-lays [built]'s spacer so that a sample starts at [start] (no-op at 0, past the end, or
    /// without a spacer). Call only while no reader of the composition is reading.
    static func anchor(_ built: BuiltComposition, at start: CMTime) throws {
        try anchor(built.composition, built: built, at: start)
    }

    /// Re-lays the spacer of [composition] (a copy of [built]'s composition, or that composition
    /// itself) so that a sample starts at [start] (FIX-IOS-D7: each export segment anchors its
    /// own copy, so no composition a reader still uses is ever mutated).
    static func anchor(_ composition: AVMutableComposition, built: BuiltComposition, at start: CMTime) throws {
        guard let id = built.spacerTrackID, let source = built.sources.spacerTrack, let unit = built.sources.spacerRange,
              let track = composition.track(withTrackID: id) else { return }
        let end = track.timeRange.end
        guard start.isNumeric, end.isNumeric, CMTimeCompare(start, .zero) > 0, CMTimeCompare(start, end) < 0 else { return }
        track.removeTimeRange(CMTimeRange(start: .zero, end: end))
        try lay(track, source: source, unit: unit, at: .zero, duration: start)
        try lay(track, source: source, unit: unit, at: start, duration: CMTimeSubtract(end, start))
    }

    /// The spacer across [at, at + duration): n whole units as one integrally scaled edit, then an
    /// unscaled remainder shorter than one unit (`CompositionBuilder.spacerLayout`).
    private static func lay(_ track: AVMutableCompositionTrack, source: AVAssetTrack, unit: CMTimeRange, at: CMTime, duration: CMTime) throws {
        guard let layout = CompositionBuilder.spacerLayout(end: duration, unit: unit.duration) else {
            try track.insertTimeRange(unit, of: source, at: at)
            track.scaleTimeRange(CMTimeRange(start: at, duration: unit.duration), toDuration: duration)
            return
        }
        if layout.n > 0 {
            try track.insertTimeRange(unit, of: source, at: at)
            if layout.n > 1 {
                track.scaleTimeRange(CMTimeRange(start: at, duration: unit.duration), toDuration: layout.whole)
            }
        }
        if layout.remainder > .zero {
            try track.insertTimeRange(
                CMTimeRange(start: unit.start, duration: layout.remainder), of: source, at: CMTimeAdd(at, layout.whole))
        }
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
    /// Audio reads per job (the first plus at most four redos). Every read is a fresh composition,
    /// reader and so a fresh time-pitch unit.
    var maxAudioAttempts = 5
    /// Seconds before the first redo; doubled for each further redo, at most `audioRetryDelayCap`
    /// (0.25 + 0.5 + 1 + 2 s over five reads: a loaded device gets time to settle).
    var audioRetryDelay: TimeInterval = 0.25
    var audioRetryDelayCap: TimeInterval = 2
    // A time-pitch fault counts as the content only when every witness read of the job has it at
    // the same place, the last read included, and there were at least `minContentWitnesses`:
    // AVFoundation's faults recur near ramp seams (seen 2.5 ms after a seam in two reads running)
    // but not in four or five reads running, while a fresh unit renders digitally gated content
    // identically every time. A read rejected for another defect (NaN, silence, a tap range jump,
    // an early end) is no witness: its scan saw a broken render (CI round 6: a read with a tap
    // range jump missed the content's dropout and so no fault was ever kept as content).
    /// Witness reads (the last one included) a recurring time-pitch fault needs to count as content.
    var minContentWitnesses = 4
    /// Seconds one audio buffer may take before the read counts as hung (FIX-IOS-D7: the
    /// watchdog only signals; the read resumes on a fresh reader, see `MixAudioSource`).
    var audioWatchdog: TimeInterval = 8
    /// Resumes per audio read after hung reads.
    var maxAudioResumes = 3
    /// Seconds the pipeline waits for a reader's teardown at the end of a phase (a reader blocked
    /// inside AVFoundation is not waited for: it is left behind, untouched).
    var teardownTimeout: TimeInterval = 2
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

        // Video segments.
        if !writer.checkpoint.isVideoComplete {
            control.enter(.preparing)
            let built = try makeComposition(plan)
            let rotator = input.layout == .rotated
                ? FrameRotator(sourceWidth: input.settings.width, sourceHeight: input.settings.height) : nil
            let source = CompositionVideoSource(composition: built, control: control, rotator: rotator)
            source.openFault = videoOpenFault
            // FIX-IOS-D7: the video phase's reader, compositor session and composition are gone
            // before the audio read (and before the next export) starts. A reader still blocked
            // inside AVFoundation is never touched: its teardown runs on its queue once it returns.
            defer { ReaderWriterPipeline.retire(source, built, timeout: teardownTimeout) }
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
            if try writeAudio(writer) == .interrupted {
                if control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
        }
        if control.isCancelled { throw EngineError.cancelled }

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

    private func writeAudio(_ writer: SegmentedWriter) throws -> SegmentedWriter.Outcome {
        let plan = input.plan
        if plan.audio.isEmpty {
            wroteSilentAudio = true
            return try writer.writeAudio(source: SilentAudioSource(control: control))
        }
        let audible = ReaderWriterPipeline.hasAudibleAudio(plan)
        let factory = makeComposition
        var attempt = 0
        // Time-pitch faults every witness read so far had (`MixAudioSource.isTimePitchWitness`: a
        // read rejected for NaN, silence, a tap range jump or an early end is no evidence of the
        // content), and how many witnesses there were.
        var recurring: [TimePitchFault]?
        var witnesses = 0
        while true {
            attempt += 1
            audioAttempts = attempt
            if attempt > 1, try backOff(redo: attempt - 1) == .interrupted { return .interrupted }
            control.enter(.finishing) // a heartbeat per attempt
            // FIX-IOS-D7: every read gets its own fresh composition (never the video phase's, never
            // the one a hung read still holds).
            let built = try factory(plan)
            guard built.built.audioMix != nil, !built.audioTracks.isEmpty else {
                // Every segment was skipped (missing streams): silence, never a mix over zero tracks.
                built.release()
                wroteSilentAudio = true
                return try writer.writeAudio(source: SilentAudioSource(control: control))
            }
            let source = MixAudioSource(composition: built, expectAudible: audible, control: control)
            source.timePitchWatch = TimePitchWatch.of(plan)
            source.validates = attempt < maxAudioAttempts
            source.watchdog = audioWatchdog
            source.maxResumes = maxAudioResumes
            source.reopen = { try factory(plan) }
            if attempt == maxAudioAttempts, witnesses + 1 >= minContentWitnesses { source.contentFaults = recurring ?? [] }
            audioSourceHook?(source, attempt)
            defer { ReaderWriterPipeline.retire(source, timeout: teardownTimeout) }
            do {
                return try writer.writeAudio(source: source)
            } catch {
                if control.isCancelled { throw EngineError.cancelled }
                if source.isTimePitchWitness {
                    witnesses += 1
                    recurring = TimePitchFault.recurring(recurring, source.timePitchFaults)
                }
                if source.timePitchFailed {
                    throw ReaderWriterPipeline.timePitchFailure(reads: attempt, first: source.firstTimePitchFault)
                }
                guard let reason = source.rejection, attempt < maxAudioAttempts else { throw error }
                Log.info(.export, "audio read \(attempt) rejected (\(reason)); reading again")
            }
        }
    }

    /// The export's failure when AVFoundation's time-pitch unit spoiled every audio read: typed
    /// `decodeFailed` (the UI's generic "The export didn't finish / Try again"), retryable (the
    /// faults are random), never a file with the dropout in it.
    static func timePitchFailure(reads: Int, first: String?) -> EngineError {
        EngineError(.decodeFailed, "\(timePitchFailurePrefix) in all \(reads) audio reads (last: \(first ?? "?"))", retryable: true)
    }

    static let timePitchFailurePrefix = "audio time-pitch fault"

    /// Waits before redo [redo] (1-based): `audioRetryDelay`·2^(redo−1), capped, in short slices
    /// that end at once on a stop request.
    private func backOff(redo: Int) throws -> SegmentedWriter.Outcome {
        let delay = min(audioRetryDelayCap, audioRetryDelay * pow(2, Double(redo - 1)))
        let deadline = Date().addingTimeInterval(delay)
        while Date() < deadline {
            if control.shouldStop {
                if control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.timeIntervalSinceNow)))
        }
        control.enter(.finishing) // a heartbeat after the wait
        return .completed
    }

    // MARK: Teardown (FIX-IOS-D7)

    /// Releases the video phase: closes the segment reader (queued behind any outstanding call)
    /// and releases [composition] once the reader is gone, waiting up to [timeout] for that.
    static func retire(_ source: CompositionVideoSource, _ composition: ExportComposition, timeout: TimeInterval) {
        source.closeSegment()
        if source.waitForTeardown(timeout: timeout) {
            composition.release()
        } else {
            Log.error(.export, "video reader still blocked at teardown; left behind")
            source.afterTeardown { composition.release() }
        }
    }

    /// Releases an audio read: every reader of [source] is closed (queued behind any outstanding
    /// call) and each composition is released once its reader is gone.
    static func retire(_ source: MixAudioSource, timeout: TimeInterval) {
        source.closeAudio()
        if !source.retireReaders(timeout: timeout) {
            Log.error(.export, "audio reader still blocked at teardown; left behind")
        }
    }
}

// MARK: - Video source

/// Frames of the export composition per segment (AVAssetReaderVideoCompositionOutput).
///
/// FIX-IOS-D7 / FIX-IOS-12-1: every call into a segment's reader and output (creation, the
/// spacer anchor, `startReading`, `copyNextSampleBuffer`, `status`, `cancelReading`, release) runs
/// on this source's serial reader queue, so a reader is never cancelled or released while a call
/// into it is outstanding (`closeSegment` queues the teardown behind it). Each segment reads its
/// own copy of the composition with the spacer anchored at the segment start, so the composition
/// a previous (cancelled, still tearing down) reader used is never mutated under it.
final class CompositionVideoSource: SegmentVideoSource {
    private let composition: ExportComposition
    private let control: PipelineControl
    private let rotator: FrameRotator?
    private let readerQueue = DispatchQueue(label: "com.vecvel.danaview.editor.export.videoread", qos: .userInitiated)
    // Reader-queue state.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderVideoCompositionOutput?
    private var segmentAsset: AVComposition?
    private var after: [() -> Void] = []
    // Caller-side state (lock-protected: the work queue opens and closes, the pump reads).
    private let lock = NSLock()
    private var outstanding = 0
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
        try call { try self.open(startUs: startUs, endUs: endUs) }
    }

    /// Reader queue: the segment's reader over its own anchored copy of the composition.
    private func open(startUs: Int64, endUs: Int64) throws {
        let built = composition.built
        let range = ExportTime.readerRange(startUs: startUs, endUs: endUs, plan: built.plan)
        let asset: AVComposition
        if ExportSpacer.isEnabled {
            // QA-05 D1: a spacer sample must start where the reader starts (see `ExportSpacer`).
            guard let copy = built.composition.mutableCopy() as? AVMutableComposition else {
                throw EngineError(.internal, "composition copy failed")
            }
            try ExportSpacer.anchor(copy, built: built, at: range.start)
            asset = copy
        } else {
            asset = built.composition
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = range
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: asset.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.decoderInitFailed, "video composition output refused") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "export reader did not start")
        }
        self.reader = reader
        self.output = output
        segmentAsset = asset
    }

    func nextFrame() throws -> SegmentFrame? {
        control.waitWhileThermalCritical()
        let read: (CVPixelBuffer, CMTime)? = try call {
            guard let output = self.output, let reader = self.reader else { return nil }
            while let sample = output.copyNextSampleBuffer() {
                guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                return (image, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            if reader.status == .failed {
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "export reader failed")
            }
            return nil
        }
        guard let (image, pts) = read else { return nil }
        let frame = try rotator?.rotate(image) ?? image
        framesRead += 1
        control.videoProgress(lastPtsUs: FrameGrid.us(pts))
        return SegmentFrame(pixelBuffer: frame, pts: pts)
    }

    /// Queues the teardown of the current segment's reader behind any outstanding call.
    func closeSegment() {
        readerQueue.async { [self] in
            if reader?.status == .reading { reader?.cancelReading() }
            reader = nil
            output = nil
            segmentAsset = nil
            let work = after
            after = []
            work.forEach { $0() }
        }
    }

    /// Waits up to [timeout] for the queued teardown; false at once when a call into the reader is
    /// still outstanding (blocked inside AVFoundation: it is left alone).
    func waitForTeardown(timeout: TimeInterval) -> Bool {
        if isCalling { return false }
        let done = DispatchSemaphore(value: 0)
        readerQueue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Runs [body] on the reader queue once the queued work (a teardown included) is done.
    func afterTeardown(_ body: @escaping () -> Void) {
        readerQueue.async { [self] in
            if reader == nil { body() } else { after.append(body) }
        }
    }

    private var isCalling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outstanding > 0
    }

    /// Runs [body] on the reader queue (counted as an outstanding call while it runs).
    private func call<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        outstanding += 1
        lock.unlock()
        defer {
            lock.lock()
            outstanding -= 1
            lock.unlock()
        }
        return try readerQueue.sync(execute: body)
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
/// A false positive (a transient of the content right on a seam, digitally gated content) shows up
/// at the same place in every read, a real fault mostly elsewhere: `TimePitchFault.recurring`
/// keeps the faults every witness read so far had, and on the last attempt a fault every witness
/// reproduced is treated as content (accepted). Any other fault left after the last attempt fails the export
/// (`ReaderWriterPipeline.timePitchFailure`); a dropout is never shipped.
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

/// One `TimePitchWatch` fault of a read (composition frame at 48 kHz).
struct TimePitchFault: Equatable {
    enum Kind: Equatable { case dropout, seamStep }
    let kind: Kind
    /// Dropout: first zero frame; seam step: the seam's frame.
    let frame: Int64

    /// Frames two reads' dropouts may differ by and still be the same fault (1 ms).
    static let matchFrames: Int64 = 48

    func matches(_ other: TimePitchFault) -> Bool {
        kind == other.kind && abs(frame - other.frame) <= TimePitchFault.matchFrames
    }

    /// The faults of [previous] (nil: no read yet) that [read] has too.
    static func recurring(_ previous: [TimePitchFault]?, _ read: [TimePitchFault]) -> [TimePitchFault] {
        guard let previous = previous else { return read }
        return previous.filter { p in read.contains { $0.matches(p) } }
    }
}

/// The `TimePitchWatch` scan of one audio read (FIX-IOS-MEDIA): the export's MixAudioSource feeds
/// it every sanitised buffer, and the RunnerTests mix reads run the same scan, so both redo the
/// reads AVFoundation's time-pitch unit spoils (dropouts, dropped seam crossfades).
struct TimePitchScan {
    let watch: TimePitchWatch
    /// Dropouts and seam steps found (the first one described in `firstFault`).
    private(set) var dropouts = 0
    private(set) var seamSteps = 0
    private(set) var firstFault: String?
    /// Every fault found, in the order found.
    private(set) var faults: [TimePitchFault] = []
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
    private var seamStats: [SeamStats]
    private var seamCursor = 0
    private var seamsEvaluated = false

    /// Peak second differences around one seam.
    private struct SeamStats {
        let seamUs: Int64
        var window: Float = 0
        var reference: Float = 0
        /// Whether the read reached the end of the far reference window.
        var complete = false
    }

    init(watch: TimePitchWatch) {
        self.watch = watch
        seamStats = watch.seamsUs.map { SeamStats(seamUs: $0) }
    }

    /// Scans one sanitised buffer for `TimePitchWatch` faults: exact-zero runs (across buffer
    /// boundaries; a PTS gap between buffers resets the scan) and the second-difference peaks
    /// around the watched seams.
    mutating func scan(_ sample: CMSampleBuffer, frames frameCount: Int) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        let first = Int64((pts.seconds * Double(ExportPCM.sampleRate)).rounded())
        var pointer: UnsafeMutablePointer<Int8>?
        var length = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let base = pointer else { return }
        let channels = ExportPCM.channels
        let count = min(frameCount, length / (4 * channels))
        base.withMemoryRebound(to: Float.self, capacity: count * channels) { samples in
            scan(UnsafeBufferPointer(start: samples, count: count * channels), firstFrame: first, channels: channels)
        }
    }

    /// Scans [samples] (interleaved Float32, [channels] per frame, 48 kHz) whose first frame is
    /// composition frame [first]; consecutive calls continue the scan.
    mutating func scan(_ samples: UnsafeBufferPointer<Float>, firstFrame first: Int64, channels: Int) {
        let rate = Double(ExportPCM.sampleRate)
        let count = samples.count / channels
        if let expected = scanNext, abs(first - expected) > 1 {
            runStart = nil
            lastLoud = nil
            pendingRun = nil
            mono1 = nil
            mono2 = nil
        }
        scanNext = first + Int64(count)
        let framesPerUs = rate / 1_000_000
        func frame(_ us: Int64) -> Int64 { Int64((Double(us) * framesPerUs).rounded()) }
        do {
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
                if !watch.spans.isEmpty {
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

    private mutating func flagDropout(start: Int64, end: Int64, rate: Double) {
        let startUs = Int64((Double(start) * 1_000_000 / rate).rounded(.down))
        let endUs = Int64((Double(end) * 1_000_000 / rate).rounded(.up))
        guard watch.watches(startUs: startUs, endUs: endUs) else { return }
        dropouts += 1
        faults.append(TimePitchFault(kind: .dropout, frame: start))
        if firstFault == nil {
            firstFault = "dropout of \(end - start) frames at \(startUs) µs"
        }
    }

    /// Counts the seam steps of the seams the read covered completely.
    mutating func evaluateSeams() {
        guard !seamsEvaluated else { return }
        seamsEvaluated = true
        for stats in seamStats where stats.complete {
            guard stats.window >= TimePitchWatch.abruptEdge,
                  stats.window > TimePitchWatch.seamStepRatio * stats.reference else { continue }
            seamSteps += 1
            faults.append(TimePitchFault(kind: .seamStep, frame: Int64((Double(stats.seamUs) * Double(ExportPCM.sampleRate) / 1_000_000).rounded())))
            if firstFault == nil {
                firstFault = "seam step at \(stats.seamUs) µs, peak \(stats.window) vs \(stats.reference)"
            }
        }
    }
}

/// The audio mix of the export composition (AVAssetReaderAudioMixOutput with IOS-18 gain taps),
/// clamped to [−1, 1] and validated (see the file comment).
final class MixAudioSource: SegmentAudioSource {
    private let composition: ExportComposition
    private let expectAudible: Bool
    private let control: PipelineControl?
    /// The reader in use; its AVAssetReader lives on the session's own queue. `session`,
    /// `sessions` and `hung` are lock-protected: the pump reads, the work queue closes and retires
    /// (also when IOS-17 abandoned a pump that is still inside `nextAudio`).
    private var _session: MixReadSession?
    /// Sessions opened by this source (the first plus resumes), for validation and teardown.
    private var _sessions: [MixReadSession] = []
    private let lock = NSLock()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var session: MixReadSession? { locked { _session } }
    private var sessions: [MixReadSession] { locked { _sessions } }

    /// Takes the current session out (nil afterwards) and marks it as left behind when [hung].
    private func takeSession(hung leftBehind: Bool) -> MixReadSession? {
        locked {
            let s = _session
            _session = nil
            if leftBehind, let s = s { _hung.append(s) }
            return s
        }
    }
    /// Reader range end (resumes read to it).
    private var rangeEnd: CMTime = .invalid
    /// Continuations of resumed sessions that ended early, and whether the rest of the range is
    /// silence the source renders itself (no audio segment after the last delivered frame).
    private(set) var continuations = 0
    private var padsToEnd = false
    /// Absolute 48 kHz frame of the next frame the writer gets (continuity across a resume).
    private var nextFrame: Int64 = 0
    /// A real buffer held back while the silence of a resume gap goes first.
    private var pending: CMSampleBuffer?

    /// Reject bad reads (false on the last attempt: a NaN, silent or tap-discontinuity read is
    /// accepted, sanitised; a time-pitch fault still fails the read, `timePitchFailed`).
    var validates = true
    /// Faults every earlier read of the job reproduced (set on the last attempt only): the content,
    /// not a time-pitch fault; ignored.
    var contentFaults: [TimePitchFault] = []
    /// Seconds one buffer may take before the read counts as hung (the watchdog only signals: the
    /// blocked reader is never cancelled or released while its call is outstanding).
    var watchdog: TimeInterval = 8
    /// A fresh export composition for a resume after a hung read (nil: a hung read fails the read).
    var reopen: (() throws -> ExportComposition)?
    /// Resumes per read after hung reads (each on a fresh composition and reader from the frame
    /// after the last delivered buffer).
    var maxResumes = 3
    /// Test hook: rewrites the floats of buffer n (0-based) before validation.
    var corrupt: ((Int, UnsafeMutableBufferPointer<Float>) -> Void)?
    /// Test hook: runs on the reader's queue right before read n (0-based, over all sessions)
    /// calls copyNextSampleBuffer (block it to simulate AVFoundation's hung read).
    var readGate: ((Int) -> Void)?
    /// Test hook: called on a session's queue once its reader is cancelled and released.
    var onTeardown: (() -> Void)?
    /// Test hook: called when the watchdog gives up on a read (the pump queue).
    var onHung: (() -> Void)?
    private var reads = 0

    /// Resumes done after hung reads.
    private(set) var resumes = 0
    /// Hung reads seen (each one left alone on its own queue).
    private(set) var hungReads = 0
    private var _hung: [MixReadSession] = []

    /// Why the read was rejected (nil = accepted or not finished).
    private(set) var rejection: String?
    private(set) var frames = 0
    private(set) var nanSamples = 0
    private(set) var clippedSamples = 0
    private(set) var peak: Float = 0
    private var buffers = 0

    /// Dropout and seam-step checks (none = not checked).
    var timePitchWatch = TimePitchWatch.none {
        didSet { timePitchScan = TimePitchScan(watch: timePitchWatch) }
    }
    private var timePitchScan = TimePitchScan(watch: .none)
    /// Dropouts and seam steps found (the first one described in `firstTimePitchFault`).
    var dropouts: Int { timePitchScan.dropouts }
    var seamSteps: Int { timePitchScan.seamSteps }
    var firstTimePitchFault: String? { timePitchScan.firstFault }
    /// Every time-pitch fault of the read (content faults included).
    var timePitchFaults: [TimePitchFault] { timePitchScan.faults }
    /// The faults that are not `contentFaults`.
    var unexplainedFaults: [TimePitchFault] {
        timePitchFaults.filter { f in !contentFaults.contains { $0.matches(f) } }
    }
    /// Whether the read reached its end and was scanned (validation ran).
    private(set) var scanned = false
    /// The read's defect other than a time-pitch fault (NaN, silent, tap range discontinuity,
    /// ended early), nil when it had none. Such a read's time-pitch scan is no evidence of the
    /// content (`isTimePitchWitness`).
    private(set) var otherDefect: String?
    /// Whether the read ended more than `maxShortfallUs` before its range end (never shipped).
    private(set) var shortRead = false
    /// A scanned read without another defect: its time-pitch faults count for
    /// `TimePitchFault.recurring`.
    var isTimePitchWitness: Bool { scanned && otherDefect == nil }
    /// How far before the range end a read may stop (the mix output ends a few ms early).
    static let maxShortfallUs: Int64 = 50_000
    /// Whether the read was refused for a time-pitch fault while not validating (the last attempt):
    /// the export fails rather than ship the dropout.
    private(set) var timePitchFailed = false

    /// Peak below which a whole read counts as silent.
    static let silencePeak: Float = 1e-5

    init(composition: ExportComposition, expectAudible: Bool, control: PipelineControl?) {
        self.composition = composition
        self.expectAudible = expectAudible
        self.control = control
    }

    func openAudio(startUs: Int64, endUs: Int64) throws {
        closeAudio()
        guard composition.built.audioMix != nil, !composition.audioTracks.isEmpty else {
            // D-38: never construct a mix output over zero tracks.
            throw EngineError(.internal, "audio mix without tracks")
        }
        let range = ExportTime.readerRange(startUs: startUs, endUs: endUs, plan: composition.built.plan)
        rangeEnd = range.end
        nextFrame = MixAudioSource.frame(range.start)
        try open(composition, range: range)
    }

    private func open(_ composition: ExportComposition, range: CMTimeRange) throws {
        let s = try MixReadSession(composition: composition, range: range, onTeardown: onTeardown)
        locked {
            _session = s
            _sessions.append(s)
        }
    }

    static func frame(_ time: CMTime) -> Int64 {
        Int64((time.seconds * Double(ExportPCM.sampleRate)).rounded())
    }

    func nextAudio() throws -> CMSampleBuffer? {
        control?.waitWhileThermalCritical()
        if let held = pending {
            pending = nil
            return try sanitized(held, skip: 0)
        }
        if padsToEnd {
            let left = MixAudioSource.frame(rangeEnd) - nextFrame
            guard left > 0 else {
                padsToEnd = false
                try finishValidation()
                return nil
            }
            let silence = try ExportPCM.makeBuffer(
                frames: Int(min(Int64(SilentAudioSource.chunkFrames), left)),
                pts: CMTime(value: nextFrame, timescale: CMTimeScale(ExportPCM.sampleRate))) { _ in }
            return try sanitized(silence, skip: 0, real: false)
        }
        while true {
            guard let current = session else { return nil }
            let n = reads
            reads += 1
            switch try waitFor(current.read(gate: readGate, index: n)) {
            case .sample(let sample):
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric else { return try sanitized(sample, skip: 0) }
                let first = MixAudioSource.frame(pts)
                let count = Int64(CMSampleBufferGetNumSamples(sample))
                if first + count <= nextFrame && sessions.count > 1 { continue } // read again after a resume
                if first > nextFrame && sessions.count > 1 {
                    // A resumed reader started late: silence for the gap, then the buffer.
                    pending = sample
                    let gap = Int(first - nextFrame)
                    let silence = try ExportPCM.makeBuffer(
                        frames: gap, pts: CMTime(value: nextFrame, timescale: CMTimeScale(ExportPCM.sampleRate))) { _ in }
                    return try sanitized(silence, skip: 0, real: false)
                }
                let skip = sessions.count > 1 ? Int(max(0, nextFrame - first)) : 0
                return try sanitized(sample, skip: skip)
            case .end:
                if sessions.count > 1, let reopen = reopen, let next = continuation() {
                    // A resumed reader stopped at the end of the audio around it (see the header).
                    continuations += 1
                    takeSession(hung: false)?.close()
                    guard let startUs = next else {
                        Log.info(.export, "resumed audio read ended at \(resumeTime.seconds) s; silence to the end")
                        padsToEnd = true
                        return try nextAudio()
                    }
                    Log.info(.export, "resumed audio read ended at \(resumeTime.seconds) s; continuing from \(Double(startUs) / 1e6) s")
                    continuationFrom = nextFrame
                    try open(try reopen(), range: CMTimeRange(start: FrameGrid.cmTime(us: startUs), end: rangeEnd))
                    continue
                }
                try finishValidation()
                return nil
            case .failed(let error):
                rejection = "failed"
                throw error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio reader failed")
            case .hung:
                hungReads += 1
                onHung?()
                // The watchdog only signals: the blocked call keeps its reader, and the reader is
                // never cancelled or released, not even once the call returns (tearing down an
                // audio mix reader whose render threads got stuck crashed inside AudioToolbox under
                // Thread Sanitizer). It is left behind with its composition, like IOS-17's
                // abandoned pumps.
                takeSession(hung: true)?.abandon()
                guard let reopen = reopen, resumes < maxResumes, CMTimeCompare(resumeTime, rangeEnd) < 0 else {
                    rejection = "hung"
                    throw EngineError(.decodeFailed, "audio read hung", retryable: true)
                }
                resumes += 1
                Log.info(.export, "audio read hung at \(resumeTime.seconds) s; resuming on a fresh reader (\(resumes))")
                try open(try reopen(), range: CMTimeRange(start: resumeTime, end: rangeEnd))
            }
        }
    }

    private var resumeTime: CMTime { CMTime(value: nextFrame, timescale: CMTimeScale(ExportPCM.sampleRate)) }

    /// Frame the last continuation started from (a continuation that delivered nothing is not
    /// continued again).
    private var continuationFrom: Int64?

    /// Where a resumed session that ended at `nextFrame` (short of the range end) continues: `.some(t)`
    /// opens a fresh reader at composition µs t (the frame itself when an audio segment still plays
    /// there, else the next segment's start, the gap delivered as silence), `.some(nil)` renders
    /// silence to the end (no audio segment after it), nil ends the read (at the range end, no
    /// progress since the last continuation, or out of continuations; validation then judges it).
    private func continuation() -> Int64?? {
        let endFrame = MixAudioSource.frame(rangeEnd)
        guard nextFrame < endFrame, continuationFrom != nextFrame else { return nil }
        let plan = composition.built.plan
        guard continuations < plan.audio.count + 2 else { return nil }
        let nowUs = Int64((Double(nextFrame) * 1_000_000 / Double(ExportPCM.sampleRate)).rounded())
        // A segment still playing (more than 1 ms of it left) continues right here.
        if plan.audio.contains(where: { $0.t0 <= nowUs && $0.t1 - nowUs > 1_000 }) { return .some(nowUs) }
        let nextStart = plan.audio.map(\.t0).filter { $0 > nowUs }.min()
        guard let start = nextStart, MixAudioSource.frame(FrameGrid.cmTime(us: start)) < endFrame else { return .some(nil) }
        return .some(start)
    }

    /// Waits for [ticket] in short slices: at most `watchdog` seconds (then `.hung`), and never
    /// past a stop request (a cancel or background interruption ends the read at once, typed as
    /// an interruption; the blocked call is left to its queue).
    private func waitFor(_ ticket: MixReadSession.Ticket) throws -> MixReadSession.Outcome {
        let deadline = Date().addingTimeInterval(watchdog)
        while true {
            if let outcome = ticket.wait(SegmentedWriter.waitSlice) { return outcome }
            if control?.shouldStop == true {
                // Left behind like a hung read: its call may still be inside AVFoundation.
                takeSession(hung: true)?.close()
                throw EngineError(.interrupted, "audio read stopped", retryable: true)
            }
            if Date() >= deadline { return .hung }
        }
    }

    /// Closes every reader of this source (each teardown queued behind any outstanding call) and
    /// releases each reader's composition once that reader is gone: at once for the readers that
    /// tear down within [timeout], later (on the reader's queue) for one still blocked inside
    /// AVFoundation, which is never waited for. Returns whether every reader was torn down.
    @discardableResult
    func retireReaders(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var all = true
        let (opened, leftBehind) = locked { (_sessions, _hung) }
        for s in opened {
            s.close()
            // A hung reader is not waited for (its call may never return).
            if !leftBehind.contains(where: { $0 === s }), s.waitClosed(until: deadline) {
                s.composition.release()
            } else {
                all = false
                s.afterTeardown { s.composition.release() }
            }
        }
        return all
    }

    /// The compositions this source read (the first plus one per resume).
    var compositions: [ExportComposition] { sessions.map(\.composition) }

    private func finishValidation() throws {
        scanned = true
        timePitchScan.evaluateSeams()
        let unexplained = unexplainedFaults
        let timePitchReason = unexplained.isEmpty ? nil
            : "time-pitch fault (\(dropouts) dropout(s), \(seamSteps) seam step(s), \(unexplained.count) not content; first: \(firstTimePitchFault ?? "?"))"
        if timePitchFaults.count > unexplained.count {
            Log.info(.export, "audio read: \(timePitchFaults.count - unexplained.count) time-pitch fault(s) reproduced by every read; kept as content")
        }
        var reason: String?
        // A resumed session's taps start at its own range start (no discontinuity there).
        let jumps = sessions.flatMap { $0.composition.built.gainTaps }.map(\.rangeDiscontinuities).reduce(0, +)
        let shortfall = MixAudioSource.frame(rangeEnd) - nextFrame
        if shortfall * 1_000_000 > MixAudioSource.maxShortfallUs * Int64(ExportPCM.sampleRate) {
            shortRead = true
            otherDefect = "ended early at \(Double(nextFrame) / Double(ExportPCM.sampleRate)) s of \(rangeEnd.seconds) s"
        } else if nanSamples > 0 {
            otherDefect = "NaN"
        } else if expectAudible && peak < MixAudioSource.silencePeak {
            otherDefect = "silent"
        } else if jumps > 0 {
            otherDefect = "tap range discontinuity"
        }
        reason = otherDefect ?? timePitchReason
        guard let reason = reason else { return }
        if shortRead {
            // Never ship audio that stops early, not even on the last attempt.
            rejection = reason
            throw EngineError(.decodeFailed, "audio read rejected: \(reason)", retryable: true)
        }
        if !validates, let timePitchReason = timePitchReason {
            // Never ship a dropout: the last attempt fails instead (the pipeline types the error).
            rejection = timePitchReason
            timePitchFailed = true
            throw EngineError(.decodeFailed, "audio read rejected: \(timePitchReason)", retryable: true)
        }
        guard validates else {
            Log.info(.export, "audio read accepted on the last attempt despite: \(reason)")
            return
        }
        rejection = reason
        throw EngineError(.decodeFailed, "audio read rejected: \(reason)", retryable: true)
    }

    /// A copy of [sample] without its first [skip] frames, NaN → 0 and every sample clamped to
    /// [−1, 1]. [real] false: generated silence (not counted as a read buffer for `corrupt`).
    private func sanitized(_ sample: CMSampleBuffer, skip: Int, real: Bool = true) throws -> CMSampleBuffer {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw EngineError(.decodeFailed, "audio buffer without data") }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        let total = count / ExportPCM.channels
        let frameCount = total - skip
        var pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if skip > 0 { pts = CMTimeAdd(pts, CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(ExportPCM.sampleRate))) }
        guard frameCount > 0 else { return try ExportPCM.makeBuffer(frames: 1, pts: pts) { _ in } }
        let index = buffers
        if real { buffers += 1 }
        var nan = 0
        var clipped = 0
        var localPeak: Float = 0
        let offset = skip * ExportPCM.channels * 4
        let out = try ExportPCM.makeBuffer(frames: frameCount, pts: pts) { dst in
            _ = dst.withMemoryRebound(to: UInt8.self) { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: frameCount * ExportPCM.channels * 4, destination: bytes.baseAddress!)
            }
            if real { corrupt?(index, dst) }
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
        if pts.isNumeric { nextFrame = MixAudioSource.frame(pts) + Int64(frameCount) }
        nanSamples += nan
        clippedSamples += clipped
        peak = max(peak, localPeak)
        if !timePitchWatch.isEmpty { timePitchScan.scan(out, frames: frameCount) }
        return out
    }

    func closeAudio() {
        takeSession(hung: false)?.close()
    }
}

/// One AVAssetReader over an export composition's audio mix (FIX-IOS-D7, QA-05 D7).
///
/// Every call into the reader and its output (creation, `startReading`, `copyNextSampleBuffer`,
/// `status`, `error`, `cancelReading`, release) runs on the session's own serial queue, so nothing
/// ever cancels or releases the reader while a call into it is outstanding. The queue's closures
/// hold the reader, its output and the composition (taps, compositor session), so a read that
/// AVFoundation leaves blocked keeps them all alive; `close()` is queued behind it and runs only
/// once that call returned. Before this, the 30 s watchdog called `cancelReading()` on the blocked
/// reader and the source then released it while `copyNextSampleBuffer` was still inside it (the
/// closure held only the output, which does not keep its reader alive): run b's SIGSEGV in
/// `assetReader_ExtractAndRetainNextSampleBuffer`, reproduced by `ExportD7Tests` as
/// "cannot copy next sample buffer before adding this output to an instance of AVAssetReader".
final class MixReadSession {
    enum Outcome {
        case sample(CMSampleBuffer)
        case end
        case failed(Error?)
        case hung
    }

    /// One read handed to the session's queue.
    final class Ticket {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Outcome?

        fileprivate func complete(_ value: Outcome) {
            lock.lock()
            outcome = value
            lock.unlock()
            done.signal()
        }

        /// The outcome, or nil when the read is still running after [seconds].
        func wait(_ seconds: TimeInterval) -> Outcome? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    let composition: ExportComposition
    private let queue = DispatchQueue(label: "com.vecvel.danaview.editor.export.audioread", qos: .userInitiated)
    private let onTeardown: (() -> Void)?
    private let closed = DispatchSemaphore(value: 0)
    // Queue-only state.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private var isClosed = false
    private var after: [() -> Void] = []
    private let flagLock = NSLock()
    private var _closeRequested = false

    /// Marks the close as requested; false when it already was.
    private func requestClose() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        guard !_closeRequested else { return false }
        _closeRequested = true
        return true
    }

    private var closeRequested: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return _closeRequested
    }

    init(composition: ExportComposition, range: CMTimeRange, onTeardown: (() -> Void)?) throws {
        self.composition = composition
        self.onTeardown = onTeardown
        try queue.sync { try self.start(range) }
    }

    /// Queue: builds and starts the reader.
    private func start(_ range: CMTimeRange) throws {
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
        reader.timeRange = range
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

    /// Queues one `copyNextSampleBuffer` (and the status check of an end) on the session's queue.
    func read(gate: ((Int) -> Void)?, index: Int) -> Ticket {
        let ticket = Ticket()
        queue.async { [self] in
            gate?(index)
            guard let output = output, let reader = reader else { return ticket.complete(.end) }
            if let sample = output.copyNextSampleBuffer() { return ticket.complete(.sample(sample)) }
            ticket.complete(reader.status == .failed ? .failed(reader.error) : .end)
        }
        return ticket
    }

    /// Queues the teardown behind any outstanding call: cancel (if still reading), release, then
    /// the `afterTeardown` work. Idempotent; never blocks the caller.
    func close() {
        guard requestClose() else { return }
        queue.async { [self] in
            if reader?.status == .reading { reader?.cancelReading() }
            reader = nil
            output = nil
            isClosed = true
            onTeardown?()
            let work = after
            after = []
            closed.signal()
            work.forEach { $0() }
        }
    }

    /// Leaves the session behind for good: no teardown is ever queued, and the session (its
    /// reader, output and composition) is kept alive for the rest of the process.
    func abandon() {
        guard requestClose() else { return }
        SegmentedWriter.keepAbandoned([self])
    }

    /// Runs [body] after the teardown (at once on the queue when it already happened).
    func afterTeardown(_ body: @escaping () -> Void) {
        queue.async { [self] in
            if isClosed { body() } else { after.append(body) }
        }
    }

    /// Waits for the teardown until [deadline] (false: still blocked or never closed).
    func waitClosed(until deadline: Date) -> Bool {
        guard closeRequested else { return false }
        let seconds = max(0, deadline.timeIntervalSinceNow)
        guard closed.wait(timeout: .now() + seconds) == .success else { return false }
        closed.signal()
        return true
    }
}
