// OWNER: IOS-06
//
// Freeze-frame still (ARCH §15): a PNG of the exact source frame at `sourceTime` (the last frame
// whose PTS is <= the request), decoded through an AVAssetReader with colour management off
// (ARCH §11.6: the still holds the decoded R'G'B' values of the preview and the exporter), the
// preferred track transform applied and SDR output (HLG/PQ tone-mapped to BT.709), written to the
// Dart-supplied path (projects/<id>/assets/stills/...) through `<path>.part` + rename. A
// background interruption or a pre-emption simply restarts it (D-22); cancel deletes the partial
// file.

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

final class FreezeFrameJob: MediaJobBody {
    let kind = JobKindMsg.freeze
    let mediaURL: URL
    let sourceTimeUs: Int64
    let output: URL

    init(mediaURL: URL, sourceTimeUs: Int64, output: URL) {
        self.mediaURL = mediaURL
        self.sourceTimeUs = sourceTimeUs
        self.output = output
    }

    var partialURL: URL { output.appendingPathExtension("part") }

    func run(_ control: JobControl) throws -> JobResultMsg {
        let image = try FrameGrab.exactFrame(url: mediaURL, sourceTimeUs: sourceTimeUs, maximumSize: nil, control: control)
        try control.check()
        control.progress(0.6)
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
        let partial = partialURL
        try? FileManager.default.removeItem(at: partial)
        try FrameGrab.writePNG(image, to: partial)
        try control.check()
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw EngineError.from(error)
        }
        control.progress(1)
        return JobResultMsg(kind: .freeze, asset: GeneratedAssetMsg(
            path: output.path, sizeBytes: SegmentedWriter.fileSize(output), durationUs: nil))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: partialURL)
    }
}

/// Exact-frame decoding shared by FreezeFrameJob and SourceFrameCache.
///
/// Colour management is off (ARCH §11.6, §13): the frame is decoded by an AVAssetReaderTrackOutput
/// to BGRA (VideoToolbox applies the YCbCr matrix only, exactly as for the compositor's source
/// buffers) and oriented / scaled by a Core Image context whose working and output colour spaces
/// are NSNull, so a still holds the same R'G'B' values the preview and the exporter decode.
/// AVAssetImageGenerator is not used: it converts its output to a display colour space (BT.709
/// transfer to sRGB lifted mid-grey 128 to 139, QA-03 finding 3). HDR sources (HLG/PQ) are the one
/// exception: they are tone-mapped to BT.709 SDR, which needs a colour-managed pass.
enum FrameGrab {
    /// Core Image with colour management off (SDR frames).
    private static let unmanagedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
            .name: "danaview.framegrab",
        ]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// Colour-managed Core Image for the HDR -> BT.709 SDR tone map.
    private static let toneMapContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "danaview.framegrab.hdr"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// The tag written on stills. The pixel values are the decoded R'G'B' unchanged; sRGB is the
    /// conventional still tag and keeps CGContext draws into sRGB contexts conversion free.
    static let stillColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The request time for [sourceTimeUs]: +1 µs so a time rounded down from a rational frame
    /// start (k/fps) still lands on frame k, clamped inside the media.
    static func requestTime(sourceTimeUs: Int64, durationUs: Int64) -> CMTime {
        var us = max(0, sourceTimeUs) + 1
        if durationUs > 0 { us = min(us, durationUs - 1) }
        return CMTime(value: max(0, us), timescale: 1_000_000)
    }

    /// The frame displayed at [sourceTimeUs] of [url] (preferred transform applied), scaled to fit
    /// [maximumSize] when given (aspect kept, never enlarged).
    static func exactFrame(url: URL, sourceTimeUs: Int64, maximumSize: CGSize?, control: JobControl?) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError(.mediaOffline, "media file missing") }
        try control?.check()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, track) = try MediaBlocking.await { () -> (CMTime, AVAssetTrack?) in
            (try await asset.load(.duration), try await asset.loadTracks(withMediaType: .video).first)
        }
        guard let track = track else { throw EngineError(.unsupportedMedia, "no video track") }
        let (transform, descriptions, range) = try MediaBlocking.await { () -> (CGAffineTransform, [CMFormatDescription], CMTimeRange) in
            (try await track.load(.preferredTransform), try await track.load(.formatDescriptions), try await track.load(.timeRange))
        }
        let hdr = descriptions.first.map(isHDR) ?? false
        let end = range.end.isValid && !range.end.isIndefinite && range.end > .zero ? range.end : duration
        let time = requestTime(sourceTimeUs: sourceTimeUs, durationUs: Probe.microseconds(end))
        let buffer = try decode(asset: asset, track: track, at: time, control: control)
        try control?.check()
        return try render(buffer, transform: transform, maximumSize: maximumSize, toneMap: hdr)
    }

    /// Whether [description] carries an HDR transfer function (HLG or PQ).
    static func isHDR(_ description: CMFormatDescription) -> Bool {
        guard let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return false }
        return transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    /// Decodes the frame displayed at [time]: the last sample whose PTS is <= [time] (the reader
    /// starts with the sample whose display interval holds the range start).
    static func decode(asset: AVAsset, track: AVAssetTrack, at time: CMTime, control: JobControl?) throws -> CVPixelBuffer {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 1_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError(.decoderInitFailed, "reader output refused") }
        reader.add(output)
        control?.onStop { _ in reader.cancelReading() }
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "reader did not start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var chosen: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            try control?.check()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if chosen != nil && pts.isValid && pts > time { break }
            chosen = image
            if pts.isValid && pts > time { break }
        }
        try control?.check()
        if let chosen = chosen { return chosen }
        if reader.status == .failed, let error = reader.error { throw EngineError.from(error) }
        throw EngineError(.decodeFailed, "no frame")
    }

    /// The display-oriented, optionally scaled 8-bit still of [buffer]. [transform] is the track's
    /// preferred transform (top-left origin coordinates).
    static func render(_ buffer: CVPixelBuffer, transform: CGAffineTransform, maximumSize: CGSize?, toneMap: Bool) throws -> CGImage {
        var options: [CIImageOption: Any] = [:]
        if toneMap {
            options[.toneMapHDRtoSDR] = true
        } else {
            options[.colorSpace] = NSNull()
        }
        var image = CIImage(cvPixelBuffer: buffer, options: options)
        image = oriented(image, by: transform)
        let w = image.extent.width, h = image.extent.height
        if let size = maximumSize, size.width > 0, size.height > 0, w > 0, h > 0 {
            let scale = min(1, size.width / w, size.height / h)
            if scale < 1 {
                let outW = max(1, (w * scale).rounded()), outH = max(1, (h * scale).rounded())
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: outH / h, kCIInputAspectRatioKey: (outW / w) / (outH / h),
                ]).cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: image.extent.width.rounded(), height: image.extent.height.rounded())
        let context = toneMap ? toneMapContext : unmanagedContext
        let space = toneMap ? CGColorSpace(name: CGColorSpace.itur_709)! : stillColorSpace
        guard let cg = context.createCGImage(image, from: bounds, format: .BGRA8, colorSpace: space) else {
            throw EngineError(.internal, "still render failed")
        }
        return toneMap ? retagged(cg) : cg
    }

    /// [image] with its preferred transform applied: [transform] maps top-left-origin pixel
    /// coordinates; Core Image works bottom-left, so the transform is conjugated by a y flip. The
    /// result sits at the origin (rotations and flips are exact pixel moves).
    static func oriented(_ image: CIImage, by transform: CGAffineTransform) -> CIImage {
        if transform.isIdentity { return image }
        let h = image.extent.height
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let full = toTopLeft.concatenating(transform).concatenating(CGAffineTransform(scaleX: 1, y: -1))
        let moved = image.transformed(by: full)
        let origin = moved.extent.origin
        return moved.transformed(by: CGAffineTransform(translationX: -origin.x.rounded(), y: -origin.y.rounded()))
    }

    /// An HDR still converted to BT.709 R'G'B' carries those values under the sRGB tag, like SDR
    /// stills (the values are what counts; colour management is off downstream).
    private static func retagged(_ image: CGImage) -> CGImage {
        image.copy(colorSpace: stillColorSpace) ?? image
    }

    /// Writes [image] as PNG.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError(.io, "png destination failed", retryable: true)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw EngineError(.io, "png write failed", retryable: true)
        }
    }
}
