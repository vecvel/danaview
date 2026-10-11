// OWNER: IOS-06
//
// Freeze-frame still (ARCH §15): a PNG of the exact source frame at `sourceTime`, decoded by
// AVAssetImageGenerator with zero tolerance, the preferred track transform applied and SDR output
// (`dynamicRangePolicy = .forceSDR` on iOS 18+), written to the Dart-supplied path
// (projects/<id>/assets/stills/...) through `<path>.part` + rename. A background interruption or a
// pre-emption simply restarts it (D-22); cancel deletes the partial file.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
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
enum FrameGrab {
    /// A generator for [asset]: zero tolerance, preferred transform, SDR.
    static func generator(for asset: AVAsset, maximumSize: CGSize?) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let size = maximumSize { generator.maximumSize = size }
        if #available(iOS 18.0, *) {
            generator.dynamicRangePolicy = .forceSDR
        }
        return generator
    }

    /// The request time for [sourceTimeUs]: +1 µs so a time rounded down from a rational frame
    /// start (k/fps) still lands on frame k, clamped inside the media.
    static func requestTime(sourceTimeUs: Int64, durationUs: Int64) -> CMTime {
        var us = max(0, sourceTimeUs) + 1
        if durationUs > 0 { us = min(us, durationUs - 1) }
        return CMTime(value: max(0, us), timescale: 1_000_000)
    }

    /// The frame displayed at [sourceTimeUs] of [url].
    static func exactFrame(url: URL, sourceTimeUs: Int64, maximumSize: CGSize?, control: JobControl?) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError(.mediaOffline, "media file missing") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, hasVideo) = try MediaBlocking.await { () -> (CMTime, Bool) in
            (try await asset.load(.duration), !(try await asset.loadTracks(withMediaType: .video)).isEmpty)
        }
        guard hasVideo else { throw EngineError(.unsupportedMedia, "no video track") }
        let generator = generator(for: asset, maximumSize: maximumSize)
        control?.onStop { _ in generator.cancelAllCGImageGeneration() }
        return try image(generator, at: requestTime(sourceTimeUs: sourceTimeUs, durationUs: Probe.microseconds(duration)))
    }

    /// Generates one image synchronously (call from a job queue).
    static func image(_ generator: AVAssetImageGenerator, at time: CMTime) throws -> CGImage {
        let done = DispatchSemaphore(value: 0)
        var result: Result<CGImage, Error> = .failure(EngineError(.decodeFailed, "no frame"))
        if #available(iOS 16.0, *) {
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image = image {
                    result = .success(image)
                } else if let error = error {
                    result = .failure(error)
                }
                done.signal()
            }
        } else {
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, status, error in
                switch status {
                case .succeeded:
                    if let image = image { result = .success(image) }
                case .cancelled:
                    result = .failure(EngineError.cancelled)
                default:
                    if let error = error { result = .failure(error) }
                }
                done.signal()
            }
        }
        done.wait()
        do {
            return try result.get()
        } catch {
            let ns = error as NSError
            if ns.domain == AVFoundationErrorDomain && ns.code == AVError.Code.operationCancelled.rawValue {
                throw EngineError.cancelled
            }
            throw EngineError.from(error)
        }
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
