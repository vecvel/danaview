// OWNER: IOS-08
//
// The 16×16 one-frame spacer video (ARCH §13.2): generated at runtime with AVAssetWriter into
// `<cache>/danaview/editor/engine/spacer_16x16_v1.mov` when missing (no bundled resource) and
// scaled across `CMTime(0…K, gridFps)` so the compositor runs for every output frame, gaps
// included. IOS-01 §2.2: H.264 with NO compression properties (the simulator has no JPEG encoder,
// and compression properties make a 16×16 H.264 frame fail on the iOS 26 simulator).

import AVFoundation
import CoreVideo
import Foundation

enum SpacerVideo {
    static let fileName = "spacer_16x16_v1.mov"
    static let size = 16

    private static let lock = NSLock()

    /// The spacer in [directory], written first when missing (safe across concurrent callers).
    static func ensure(in directory: URL) async throws -> URL {
        let out = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent("spacer_16x16_v1.\(UUID().uuidString).partial.mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await write(to: tmp)
        try publish(tmp, to: out)
        return out
    }

    /// Moves [tmp] to [out] unless another caller got there first.
    private static func publish(_ tmp: URL, to out: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.moveItem(at: tmp, to: out)
        }
    }

    /// Writes one black 16×16 frame lasting 1/30 s.
    static func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw EngineError(.encodingFailed, "spacer: startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        } else {
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        }
        guard let buffer = pixelBuffer else {
            writer.cancelWriting()
            throw EngineError(.encodingFailed, "spacer: no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        guard adaptor.append(buffer, withPresentationTime: .zero) else {
            writer.cancelWriting()
            throw EngineError(.encodingFailed, "spacer: append failed")
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw EngineError(.encodingFailed, "spacer: finishWriting failed") }
    }
}
