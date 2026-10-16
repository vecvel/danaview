// OWNER: IOS-20
//
// One intermediate pass of the multi-pass precompose (ARCH D-45(B), §14.2): the pass plan (the
// background plus the bottom layers, or the previous intermediate plus the next layers) through
// the same export composition factory as a single pass (DVCompositor, export variant, the same
// Core Image working space), read with IOS-12's CompositionVideoSource on the export frame grid,
// written by IOS-17's SegmentedWriter as closed-GOP segments in `pre-<n>.work/` (its own
// checkpoint: an interrupted pass resumes from its next segment), then joined with a passthrough
// concat into the opaque, video-only intermediate `pre-<n>.mov` (written as `.partial` and
// renamed, so a file under the final name is always complete).
//
// Encoding: the job's codec (HEVC or H.264, whichever the job uses), the export size, the export
// fps, ≥ 4× the export bitrate (at least 0.2 bit per pixel and frame, capped at 240 Mbit/s), a
// keyframe every second, no B-frames, BT.709, no audio. With the `.rotated` layout (ARCH §14.1)
// frames are turned into landscape buffers like the final pass does (the planner marks the
// intermediate `rot: 90`).
//
// Stop semantics follow the pipeline: the job's background interruption stops the running segment
// (`.interrupted`, checkpoint kept), cancel throws `cancelled`.

import AVFoundation
import Foundation

final class PrecomposePass {
    struct Input {
        var index: Int
        /// The pass plan with real intermediate uris.
        var plan: RenderPlan
        var hash: String
        var settings: EncoderSettings
        var layout: EncodeLayout
        /// `work/export-<jobId>/pre-<n>.work/`.
        var workDirectory: URL
        /// `work/export-<jobId>/pre-<n>.mov`.
        var outputURL: URL
        var segmentDurationUs: Int64
    }

    enum Outcome: Equatable {
        case completed(frames: Int, bytes: Int64)
        case interrupted
    }

    static let jobKind = "export-precompose"
    /// Bitrate multiple of the export (D-45: ≥ 4×).
    static let bitrateFactor = 4
    static let minBitsPerPixel = 0.2
    static let maxBitrate = 240_000_000

    let input: Input
    let control: PipelineControl
    let makeComposition: ExportCompositionFactory

    // Test hooks.
    /// Configures the segmented writer (fault injection).
    var configureWriter: ((SegmentedWriter) -> Void)?
    /// An error to throw when the video source opens the segment starting at the given µs.
    var videoOpenFault: ((Int64) -> Error?)?
    /// Output-time fraction 0...1 of this pass (pump queue or the calling queue).
    var onProgress: ((Double) -> Void)?

    /// The segment the pass started from (0 = from the beginning; tests).
    private(set) var startSegment = 0

    init(input: Input, control: PipelineControl, makeComposition: @escaping ExportCompositionFactory) {
        self.input = input
        self.control = control
        self.makeComposition = makeComposition
    }

    /// The intermediate's video bitrate for an export of [settings].
    static func bitrate(for settings: EncoderSettings) -> Int {
        let floor = Double(settings.width * settings.height * settings.fps) * minBitsPerPixel
        let wanted = max(Double(settings.videoBitrate) * Double(bitrateFactor), floor)
        return Int(min(Double(maxBitrate), wanted))
    }

    /// Writer settings of every intermediate segment.
    static func segmentSettings(_ settings: EncoderSettings, layout: EncodeLayout) -> SegmentEncodeSettings {
        let rotated = layout == .rotated
        return SegmentEncodeSettings(
            codec: settings.codec == .hevc ? .hevc : .h264,
            width: rotated ? settings.height : settings.width,
            height: rotated ? settings.width : settings.height,
            fps: settings.fps,
            averageBitRate: bitrate(for: settings),
            maxKeyFrameIntervalFrames: nil,
            maxKeyFrameIntervalSeconds: 1,
            allowFrameReordering: false,
            container: .mov,
            profileLevel: nil,
            audio: nil)
    }

    /// Bytes one intermediate of [settings] over [durationUs] takes, plus one segment while it is
    /// being joined.
    static func estimatedBytes(_ settings: EncoderSettings, durationUs: Int64) -> Int64 {
        let bps = Double(bitrate(for: settings))
        let seconds = Double(max(0, durationUs)) / 1_000_000
        let segment = bps * Double(SegmentedWriter.defaultSegmentDurationUs) / 1_000_000 / 8
        return Int64(bps * seconds / 8 * 1.02 + segment)
    }

    /// Runs the pass to completion or interruption.
    func run() throws -> Outcome {
        let plan = input.plan
        guard plan.durUs > 0 else { throw EngineError(.planInvalid, "empty export plan") }
        let writer = try SegmentedWriter(
            directory: input.workDirectory, jobKind: PrecomposePass.jobKind, inputHash: input.hash,
            settings: PrecomposePass.segmentSettings(input.settings, layout: input.layout),
            startUs: 0, endUs: plan.durUs, segmentDurationUs: input.segmentDurationUs)
        // D-35 (FIX-IOS-SPACER): the last segment and the concat end on the composition's grid end
        // CMTime(K, gridFps), not on durUs (up to 1 µs later at 24/30/48/60 fps).
        writer.exactEnd = ExportTime.gridEnd(plan)
        startSegment = writer.checkpoint.nextSegment
        if let progress = onProgress { writer.onProgress = progress }
        configureWriter?(writer)
        control.attach(writer)
        defer { control.attach(nil) }
        if control.isCancelled { throw EngineError.cancelled }
        if let job = control as? ExportJob { job.restoreProgress(doneUs: writer.checkpoint.resumeTimeUs) }

        if !writer.checkpoint.isVideoComplete {
            control.enter(.preparing)
            let built = try makeComposition(plan)
            defer { built.release() }
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
                throw EngineError.from(error)
            }
            if outcome == .interrupted {
                if control.isCancelled { throw EngineError.cancelled }
                return .interrupted
            }
        }
        if control.isCancelled { throw EngineError.cancelled }

        let partial = input.outputURL.deletingPathExtension().appendingPathExtension("partial.mov")
        let concat: SegmentConcat.Result
        do {
            concat = try writer.concat(to: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if control.isCancelled { throw EngineError.cancelled }
            throw EngineError.from(error)
        }
        do {
            try? FileManager.default.removeItem(at: input.outputURL)
            try FileManager.default.moveItem(at: partial, to: input.outputURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw EngineError.from(error)
        }
        try? FileManager.default.removeItem(at: input.workDirectory)
        if control.isCancelled { throw EngineError.cancelled }
        return .completed(frames: concat.frames, bytes: SegmentedWriter.fileSize(input.outputURL))
    }
}
