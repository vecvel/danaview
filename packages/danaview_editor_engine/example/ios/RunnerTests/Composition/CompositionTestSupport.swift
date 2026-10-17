// OWNER: IOS-08
//
// Shared helpers of the IOS-08 tests: the contract corpus and vectors from the fixture trees
// (FixtureHarnessTests: core/ = packages/danaview_editor_core/test/fixtures, engine_api/ =
// packages/danaview_editor_engine_api/test_fixtures) and a synthetic long source written once per run
// (64 s, 64×64 H.264 at 30 fps, two mono 48 kHz PCM audio tracks), so every contract plan's source
// ranges and audio streams exist whatever the fixture URIs say.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

enum CompositionTestSupport {
    // MARK: Fixtures

    static func contractDir() throws -> URL {
        try XCTUnwrap(TestFixtures.url(.core, "render_plans/contract"), "contract corpus missing from the test bundle")
    }

    /// Contents of a fixture file as UTF-8 bytes without trailing whitespace.
    static func bytes(_ url: URL) throws -> Data {
        var text = try String(contentsOf: url, encoding: .utf8)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return Data(text.utf8)
    }

    /// The top-level JSON files of [dir], sorted (excluding `.expected_active.json`).
    static func jsonFiles(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".expected_active.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every valid plan fixture of the corpus (name, plan).
    static func contractPlans() throws -> [(String, RenderPlan)] {
        try jsonFiles(contractDir()).compactMap { url in
            let data = try bytes(url)
            guard case .object(let o) = try PlanJSONReader.parse(data), o["rev"] != nil else { return nil }
            return (url.lastPathComponent, try RenderPlanDecoder.decodePlan(data))
        }
    }

    static func plan(_ name: String) throws -> RenderPlan {
        try RenderPlanDecoder.decodePlan(bytes(contractDir().appendingPathComponent(name)))
    }

    /// A JSON object from a fixture tree.
    static func json(_ tree: TestFixtures.Tree, _ path: String) throws -> [String: Any] {
        let url = try XCTUnwrap(TestFixtures.url(tree, path), "\(path) missing")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Synthetic media

    private static let lock = NSLock()
    private static var cached: URL?

    static let syntheticSeconds = 64

    /// A 64 s 64×64 H.264 30 fps video with two mono PCM audio tracks (written once per run).
    static func syntheticMedia() async throws -> URL {
        if let url = lockedCached() { return url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ios08_media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("synthetic_av_64s_v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = dir.appendingPathComponent("synthetic_\(UUID().uuidString).mov")
            try await writeSynthetic(to: tmp)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        storeCached(url)
        return url
    }

    private static func lockedCached() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private static func storeCached(_ url: URL) {
        lock.lock()
        cached = url
        lock.unlock()
    }

    private static func writeSynthetic(to url: URL) async throws {
        let fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audio = [AVAssetWriterInput(mediaType: .audio, outputSettings: pcm), AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)]
        audio.forEach { $0.expectsMediaDataInRealTime = true }
        writer.add(video)
        audio.forEach { writer.add($0) }
        XCTAssertTrue(writer.startWriting(), "synthetic writer: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        var formats: [CMAudioFormatDescription] = []
        for _ in audio {
            var format: CMAudioFormatDescription?
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
                mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format)
            formats.append(try XCTUnwrap(format))
        }
        func waitReady(_ input: AVAssetWriterInput) async throws {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard waited < 5_000, writer.status == .writing else {
                    throw NSError(domain: "ios08.synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer stalled"])
                }
                try await Task.sleep(nanoseconds: 1_000_000)
                waited += 1
            }
        }
        // Interleaved in 100 ms steps: 3 video frames (flat grey level i % 256), then 100 ms of each tone.
        let chunk = 4_800
        for step in 0..<(syntheticSeconds * 10) {
            for f in 0..<3 {
                let i = step * 3 + f
                try await waitReady(video)
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                let buffer = try XCTUnwrap(pb)
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(i % 256), CVPixelBufferGetBytesPerRow(buffer) * 64)
                CVPixelBufferUnlockBaseAddress(buffer, [])
                XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
            }
            for (index, input) in audio.enumerated() {
                let hz = index == 0 ? 1_000.0 : 440.0
                try await waitReady(input)
                var samples = [Int16](repeating: 0, count: chunk)
                for n in 0..<chunk {
                    let t = Double(step * chunk + n) / 48_000
                    samples[n] = Int16(8_200 * sin(2 * Double.pi * hz * t))
                }
                var block: CMBlockBuffer?
                let bytes = samples.count * 2
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                    dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
                }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block!, formatDescription: formats[index], sampleCount: chunk,
                    presentationTimeStamp: CMTime(value: CMTimeValue(step * chunk), timescale: 48_000), packetDescriptions: nil,
                    sampleBufferOut: &sample)
                XCTAssertTrue(input.append(try XCTUnwrap(sample)))
            }
        }
        video.markAsFinished()
        audio.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "synthetic writer: \(String(describing: writer.error))")
    }

    // MARK: Building

    /// A scratch directory for the spacer (fresh per call when [fresh]).
    static func spacerDirectory(fresh: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            fresh ? "ios08_engine_\(UUID().uuidString)" : "ios08_engine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build options that read every video/audio asset from the synthetic source.
    static func options(validate: Bool = false) async throws -> CompositionBuildOptions {
        let media = try await syntheticMedia()
        var o = CompositionBuildOptions(spacerDirectory: try spacerDirectory())
        o.resolveURL = { _, _ in media }
        o.validate = validate
        return o
    }

    /// Whether [time] is exactly CMTime(k, fps) for an integer k; returns k.
    static func gridFrame(_ time: CMTime, fps: Int64) -> Int64? {
        guard time.isNumeric else { return nil }
        let k = FrameGrid(fps: fps).frameIndexNearest(time)
        return CMTimeCompare(time, CMTime(value: k, timescale: CMTimeScale(fps))) == 0 ? k : nil
    }
}
