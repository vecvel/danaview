// OWNER: IOS-19
//
// RenderPreviewJob (ARCH D-45(A), §12.3 `renderPreview`, §13.2): renders one range plan of the
// render-preview cache into a preview-quality intermediate. Registered with IOS-05's JobRegistry by
// RenderPreviewJobService, so cancel, priorities, export pre-emption, background pauses and the
// job events (progress ≤ 4 Hz, done, failed) work as for every media job.
//
// Pipeline: the range plan (a preview plan cut to the range, times relative to its start) goes
// through the same CompositionBuilder (IOS-08) and DVCompositor (IOS-10) as the live preview, with
// the compositor's render size = the preview render size (the canvas fitted to the tier's
// `maxPreviewLongSide`, QualityGovernor full level, even sides) and the originals (no proxies).
// `AVAssetReaderVideoCompositionOutput` → `AVAssetWriter`: H.264, every frame a sync sample
// (`AVVideoMaxKeyFrameIntervalKey` 1, no frame reordering), BT.709, video only, frames on the
// project frame grid (output frame k is written at `CMTime(k, fps)`, k read from the compositor's
// `danaview.frame` stamp, D-35). The playback swap (RenderedRangeSwap) maps output frame k0 + i of
// the session to frame i of this file.
//
// Files: the encoder writes `<name>.partial.<ext>` next to the output and renames it on success, so
// a file under the final name is always complete. Cancel, a failure or a pause (pre-emption,
// background: the registry restarts the job) delete the partial file (`cleanUp`).
//
// Thermal (D-45): while the thermal state is `serious` or worse, the job waits before the next
// frame (it keeps its place; cancel still stops it at once).

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// How a render-preview job builds and encodes (production defaults; tests inject resolvers,
/// thermal states and sizes).
struct RenderPreviewOptions {
    /// Directory of the spacer video (`Paths.engineAssets`).
    var spacerDirectory: URL
    /// Longest side of the preview render size (`TierLimits.maxPreviewLongSide`).
    var maxPreviewLongSide: Int
    /// Asset → URL (nil: MediaURLResolver).
    var resolveURL: ((String, PlanAsset) throws -> URL)?
    /// The device's thermal state (polled before every frame).
    var thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    /// Poll interval while thermally paused.
    var thermalPollInterval: TimeInterval = 0.25
    /// Encoder bits per pixel and frame (intra-only needs more than a long-GOP stream).
    var bitsPerPixel: Double = 0.5

    init(spacerDirectory: URL, maxPreviewLongSide: Int) {
        self.spacerDirectory = spacerDirectory
        self.maxPreviewLongSide = maxPreviewLongSide
    }
}

final class RenderPreviewJob: MediaJobBody {
    let kind = JobKindMsg.renderPreview
    let plan: RenderPlan
    let outputURL: URL
    let options: RenderPreviewOptions

    static let minBitrate = 2_000_000
    static let maxBitrate = 60_000_000

    /// Frames written by the last run (tests).
    private(set) var framesWritten = 0
    /// Times the job waited for the thermal state to drop below `serious` (tests).
    private(set) var thermalPauses = 0
    /// Wall time of the last completed run in ms (render-time numbers).
    private(set) var renderMs: Double = 0
    /// Called after every written frame with its index (tests: cancel or fault mid-render).
    var onFrame: ((Int) -> Void)?

    /// [plan] must be a valid preview plan (RenderPreviewJob.decode checks it).
    init(plan: RenderPlan, outputURL: URL, options: RenderPreviewOptions) {
        self.plan = plan
        self.outputURL = outputURL
        self.options = options
    }

    /// Two jobs never write the same file at once.
    var exclusiveKey: String? { "render-preview-\(outputURL.standardizedFileURL.path)" }

    /// The partial file the encoder writes (`<name>.partial.<ext>`).
    var partialURL: URL {
        let ext = outputURL.pathExtension.isEmpty ? "mp4" : outputURL.pathExtension
        let name = outputURL.deletingPathExtension().lastPathComponent
        return outputURL.deletingLastPathComponent().appendingPathComponent("\(name).partial.\(ext)")
    }

    /// The output frames of the range plan.
    var frameCount: Int64 { max(0, plan.canvas.outputGrid.frameIndexOf(plan.durUs)) }

    /// The compositor render size of the range: the canvas at the preview's full quality.
    var renderSize: CGSize {
        QualityGovernor.renderSize(
            canvasWidth: plan.canvas.w, canvasHeight: plan.canvas.h, level: .full, maxLongSide: options.maxPreviewLongSide)
    }

    // MARK: Plan checks

    /// Decodes and checks a range plan: a valid preview plan with at least one output frame.
    static func decode(_ data: Data) throws -> RenderPlan {
        let plan: RenderPlan
        do {
            plan = try RenderPlanDecoder.decodePlan(data)
        } catch {
            throw PreviewSession.planError(error)
        }
        guard plan.target == .preview else { throw EngineError(.planInvalid, "render previews take a preview plan") }
        if let first = PlanValidator.validate(plan).first {
            throw EngineError(.planInvalid, first.description, itemId: first.id)
        }
        guard plan.canvas.outputGrid.frameIndexOf(plan.durUs) > 0 else {
            throw EngineError(.planInvalid, "the range plan has no frame")
        }
        return plan
    }

    // MARK: Encoding

    /// The writer's video settings for [size] at [fps].
    static func videoSettings(size: CGSize, fps: Int, bitsPerPixel: Double) -> [String: Any] {
        let w = Int(size.width)
        let h = Int(size.height)
        let wanted = Double(w * h * max(1, fps)) * bitsPerPixel
        let bitrate = Int(min(Double(maxBitrate), max(Double(minBitrate), wanted)))
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

    // MARK: MediaJobBody

    func run(_ control: JobControl) throws -> JobResultMsg {
        let start = CFAbsoluteTimeGetCurrent()
        framesWritten = 0
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL)
        do {
            try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try control.check()
            try render(control)
            try control.check()
            try? fm.removeItem(at: outputURL)
            try fm.moveItem(at: partialURL, to: outputURL)
        } catch {
            try? fm.removeItem(at: partialURL)
            try control.check()
            throw EngineError.from(error)
        }
        renderMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let bytes = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return JobResultMsg(
            kind: .renderPreview,
            asset: GeneratedAssetMsg(path: outputURL.path, sizeBytes: bytes, durationUs: plan.durUs))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: partialURL)
    }

    /// Builds the composition and encodes every output frame into the partial file.
    private func render(_ control: JobControl) throws {
        let size = renderSize
        let fps = plan.canvas.fps
        let total = frameCount
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .utility)
        var build = CompositionBuildOptions(spacerDirectory: options.spacerDirectory)
        build.renderSize = size
        build.useProxies = false
        build.access = SessionMediaAccess()
        build.validate = false
        build.resolveURL = options.resolveURL
        session.configure(&build)
        let input = UncheckedSendable((plan, build))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        defer { built.releaseMedia() }
        try control.check()

        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: plan.canvas.editGrid.cmTime(frame: plan.canvas.editGrid.frameIndexOf(plan.durUs)))
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.decoderInitFailed, "video composition output refused") }
        reader.add(output)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partialURL, fileType: RenderPreviewJob.fileType(for: outputURL))
        } catch {
            throw EngineError.from(error)
        }
        let settings = RenderPreviewJob.videoSettings(size: size, fps: fps, bitsPerPixel: options.bitsPerPixel)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw EngineError(.encoderUnavailable, "H.264 at \(Int(size.width))×\(Int(size.height)) is not available")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw EngineError(.encoderUnavailable, "video input refused") }
        writer.add(videoInput)

        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "render reader did not start")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error.map(EngineError.from) ?? EngineError(.encoderUnavailable, "render writer did not start")
        }
        writer.startSession(atSourceTime: .zero)
        let cancelReading = { if reader.status == .reading { reader.cancelReading() } }
        control.onStop { _ in cancelReading() }

        var next: Int64 = 0
        var lastK: Int64 = -1
        do {
            while next < total {
                try waitWhileThermallyLimited(control)
                try control.check()
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let k = DVRenderSession.frameIndex(of: pb) ?? next
                guard k > lastK, k < total else { continue }
                while !videoInput.isReadyForMoreMediaData {
                    try control.check()
                    if writer.status == .failed { break }
                    usleep(2_000)
                }
                guard writer.status == .writing,
                      adaptor.append(pb, withPresentationTime: CMTime(value: k, timescale: CMTimeScale(fps))) else {
                    throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "render frame \(k) was not written")
                }
                lastK = k
                next = k + 1
                framesWritten += 1
                control.progress(Double(next) / Double(total))
                onFrame?(framesWritten)
            }
            try control.check()
            if reader.status == .failed {
                throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "render reader failed")
            }
            guard framesWritten > 0 else { throw EngineError(.decodeFailed, "the range rendered no frame") }
        } catch {
            cancelReading()
            writer.cancelWriting()
            throw error
        }
        cancelReading()
        videoInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: lastK + 1, timescale: CMTimeScale(fps)))
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "render file was not finished")
        }
    }

    /// Waits while the device is at `serious` or worse (D-45); a stop ends the wait.
    private func waitWhileThermallyLimited(_ control: JobControl) throws {
        var counted = false
        while options.thermalState().rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            if !counted {
                counted = true
                thermalPauses += 1
                Log.info(.jobs, "render preview paused (thermal)")
            }
            try control.check()
            Thread.sleep(forTimeInterval: options.thermalPollInterval)
        }
    }
}
