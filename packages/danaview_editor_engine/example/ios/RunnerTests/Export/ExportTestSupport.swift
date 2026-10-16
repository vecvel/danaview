// OWNER: IOS-12
//
// Helpers of the IOS-12 export tests: export plans written as RenderPlan v1 JSON over the engine
// media corpus (assets resolve by the file name of their URI), a coordinator with injected device
// facts, synchronous wrappers of the coordinator's async replies, and the §14.4 conformance
// inspection of an output file (container brand, codec tag, size, transform, fps, frame count,
// AAC format, bitrate, decoded PCM and frames).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

// MARK: - Plans

enum ExportPlans {
    /// A video asset entry of the media corpus.
    static func video(_ id: String, file: String, w: Int, h: Int, durUs: Int64, hasAudio: Bool) -> String {
        "\"\(id)\":{\"kind\":\"video\",\"uri\":\"file:///fixtures/\(file)\",\"fp\":\"fp_\(id)\",\"w\":\(w),\"h\":\(h),\"durUs\":\(durUs),\"hasAudio\":\(hasAudio)}"
    }

    static func audio(_ id: String, file: String, durUs: Int64) -> String {
        "\"\(id)\":{\"kind\":\"audio\",\"uri\":\"file:///fixtures/\(file)\",\"fp\":\"fp_\(id)\",\"durUs\":\(durUs),\"hasAudio\":true}"
    }

    static func image(_ id: String, file: String, w: Int, h: Int) -> String {
        "\"\(id)\":{\"kind\":\"image\",\"uri\":\"file:///fixtures/\(file)\",\"fp\":\"fp_\(id)\",\"w\":\(w),\"h\":\(h)}"
    }

    static func mediaLayer(_ id: String, asset: String, seq: Int, t0: Int64, t1: Int64, s0: Int64 = -1, w: Double, h: Double,
                           z: Int = 10, cx: Double? = nil, cy: Double? = nil) -> String {
        let source = s0 < 0 ? t0 : s0
        let xf = (cx != nil || cy != nil) ? ",\"xf\":{\"cx\":\(cx ?? w / 2),\"cy\":\(cy ?? h / 2)}" : ""
        return "{\"id\":\"\(id)\",\"z\":\(z),\"seq\":\(seq),\"t\":[\(t0),\(t1)],\"kind\":\"media\",\"asset\":\"\(asset)\",\"map\":[[\(t0),\(t1),\(source),\(source + t1 - t0)]],\"base\":[\(w),\(h)]\(xf)}"
    }

    static func imageLayer(_ id: String, asset: String, t0: Int64, t1: Int64, w: Double, h: Double, z: Int = 10) -> String {
        "{\"id\":\"\(id)\",\"z\":\(z),\"t\":[\(t0),\(t1)],\"kind\":\"image\",\"asset\":\"\(asset)\",\"base\":[\(w),\(h)]}"
    }

    static func solid(_ id: String, t0: Int64, t1: Int64, color: String, w: Double, h: Double, cx: Double, cy: Double, z: Int = 10) -> String {
        "{\"id\":\"\(id)\",\"z\":\(z),\"t\":[\(t0),\(t1)],\"kind\":\"solid\",\"color\":\"\(color)\",\"base\":[\(w),\(h)],\"xf\":{\"cx\":\(cx),\"cy\":\(cy)}}"
    }

    static func audioSeg(_ id: String, asset: String, t0: Int64, t1: Int64, s0: Int64 = -1, gain: [(Int64, Double)] = [(0, 1)]) -> String {
        let source = s0 < 0 ? t0 : s0
        let keys = gain.map { "[\($0.0),\($0.1)]" }.joined(separator: ",")
        return "{\"id\":\"\(id)\",\"asset\":\"\(asset)\",\"t\":[\(t0),\(t1)],\"map\":[[\(t0),\(t1),\(source),\(source + t1 - t0)]],\"gain\":[\(keys)]}"
    }

    /// An export plan document.
    static func plan(w: Int, h: Int, fps: Int, gridFps: Int? = nil, durUs: Int64, bg: String = "#000000FF",
                     assets: [String], layers: [String], audio: [String] = []) -> Data {
        let grid = gridFps.map { ",\"gridFps\":\($0)" } ?? ""
        let json = "{\"v\":1,\"rev\":1,\"target\":\"export\",\"canvas\":{\"w\":\(w),\"h\":\(h),\"fps\":\(fps)\(grid),\"bg\":\"\(bg)\"},"
            + "\"durUs\":\(durUs),\"assets\":{\(assets.joined(separator: ","))},\"layers\":[\(layers.joined(separator: ","))],"
            + "\"audio\":[\(audio.joined(separator: ","))]}"
        return Data(json.utf8)
    }

    /// The frame_counter-with-tone clip (1280×720 30 fps, 8 s, AAC 1 kHz) fitted to the canvas.
    static func toneVideo(w: Int, h: Int, fps: Int, gridFps: Int? = nil, durUs: Int64, withAudio: Bool, gain: Double = 1) -> Data {
        plan(
            w: w, h: h, fps: fps, gridFps: gridFps, durUs: durUs,
            assets: [video("md_tone00000001", file: "tone_under_video.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: true)],
            layers: [mediaLayer("it_tone0000001#v", asset: "md_tone00000001", seq: 0, t0: 0, t1: durUs, w: Double(w), h: Double(h))],
            audio: withAudio ? [audioSeg("it_tone0000001#a", asset: "md_tone00000001", t0: 0, t1: durUs, gain: [(0, gain)])] : [])
    }

    /// tone_1khz.wav (10 s, −12 dBFS) as one audio segment over [map] pieces (t0, t1, s0, s1) on a
    /// grey backdrop: a speed ramp when the map has several pieces (QA-11 (d), FIX-IOS-MEDIA).
    static func toneAudio(map: [(Int64, Int64, Int64, Int64)], pitch: Bool = true, w: Int = 320, h: Int = 180, fps: Int = 30) -> Data {
        let durUs = map.map(\.1).max() ?? 0
        let pieces = map.map { "[\($0.0),\($0.1),\($0.2),\($0.3)]" }.joined(separator: ",")
        let pitchKey = pitch ? "" : ",\"pitch\":false"
        let seg = "{\"id\":\"it_tonea000001#a\",\"asset\":\"md_tone1k00001\",\"t\":[\(map.first?.0 ?? 0),\(durUs)],"
            + "\"map\":[\(pieces)],\"gain\":[[0,1]]\(pitchKey)}"
        return plan(
            w: w, h: h, fps: fps, durUs: durUs,
            assets: [audio("md_tone1k00001", file: "tone_1khz.wav", durUs: 10_000_000)],
            layers: [solid("it_backdrop0001", t0: 0, t1: durUs, color: "#202020FF", w: Double(w), h: Double(h), cx: Double(w) / 2, cy: Double(h) / 2)],
            audio: [seg])
    }

    /// QA-11 (d)'s 7-point speed ramp (1, 1.25, 1.6, 2, 1.6, 1.25, 1×; 300 ms each; source from 0.5 s).
    static let rampSpeeds: [Double] = [1, 1.25, 1.6, 2, 1.6, 1.25, 1]
    static let rampPieceUs: Int64 = 300_000

    static var rampMap: [(Int64, Int64, Int64, Int64)] {
        var s0: Int64 = 500_000
        return rampSpeeds.enumerated().map { k, speed in
            let s1 = s0 + Int64((speed * Double(rampPieceUs)).rounded())
            defer { s0 = s1 }
            return (Int64(k) * rampPieceUs, Int64(k + 1) * rampPieceUs, s0, s1)
        }
    }

    /// A silent clip (frame_counter 720p25 has no audio) on its own.
    static func noAudioVideo(w: Int, h: Int, fps: Int, durUs: Int64) -> Data {
        plan(
            w: w, h: h, fps: fps, durUs: durUs,
            assets: [video("md_fc0000000001", file: "frame_counter_720p25.mp4", w: 1280, h: 720, durUs: 8_000_000, hasAudio: false)],
            layers: [mediaLayer("it_fc000000001#v", asset: "md_fc0000000001", seq: 0, t0: 0, t1: durUs, w: Double(w), h: Double(h))])
    }

    static func settings(_ w: Int, _ h: Int, fps: Int, container: ExportContainerMsg = .mp4, codec: VideoCodecMsg = .h264,
                         videoBitrate: Int64 = 1_500_000, audioBitrate: Int64 = 192_000) -> EncodeSettingsMsg {
        EncodeSettingsMsg(
            container: container, codec: codec, width: Int64(w), height: Int64(h), fps: Int64(fps), videoBitrate: videoBitrate,
            audioBitrate: audioBitrate, audioSampleRate: 48_000, audioChannels: 2, keyframeIntervalMs: 1_000, stripLocation: true)
    }
}

// MARK: - Coordinator harness

final class ExportHarness {
    let roots: TempRoots
    let recorder: JobEventRecorder
    let context: EngineContext
    let coordinator: ExportCoordinator
    let interruption: JobInterruption

    struct Options {
        var probe: EncoderProbe = .system
        var tier: DeviceTierMsg = .high
        var decoderLimit = 16
        var listenerAttached = true
        var segmentDurationUs: Int64 = 1_000_000
        var thermal: () -> ProcessInfo.ThermalState = { .nominal }
        var encoders: EncoderSupport? = nil
    }

    init(_ options: Options = Options(), roots: TempRoots? = nil) throws {
        self.roots = try roots ?? TempRoots()
        recorder = JobEventRecorder()
        context = try MediaJobTestSupport.context(self.roots, events: recorder.hub)
        interruption = JobInterruption(center: NotificationCenter())
        var env = ExportEnvironment.production(context: context)
        env.tier = { options.tier }
        env.probe = options.probe
        if let encoders = options.encoders { env.encoders = { encoders } }
        env.decoderLimit = options.decoderLimit
        env.listenerAttached = { $0(options.listenerAttached) }
        env.segmentDurationUs = options.segmentDurationUs
        env.thermalState = options.thermal
        env.backgroundKind = { .paused }
        env.resolveURL = { _, asset in
            let name = URL(string: asset.uri)?.lastPathComponent ?? ""
            guard let url = TestFixtures.url(.engine, "media/\(name)") else { throw EngineError(.mediaOffline, "fixture missing") }
            return url
        }
        coordinator = ExportCoordinator(context: context, environment: env, interruption: interruption, startInterruption: false)
        coordinator.previewSuspender = CountingSuspender()
    }

    var paths: Paths { try! context.requirePaths() }

    func outputURL(_ ext: String = "mp4") -> URL {
        paths.work.appendingPathComponent("export-test-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    /// Waits for an async coordinator reply.
    func call<T>(_ test: XCTestCase, timeout: TimeInterval = 60, _ body: (@escaping EngineReply<T>) -> Void) throws -> T {
        let done = test.expectation(description: "reply")
        let box = ReplyBox<T>()
        body { result in
            box.set(result)
            done.fulfill()
        }
        test.wait(for: [done], timeout: timeout)
        return try XCTUnwrap(box.result, "no reply").get()
    }

    func start(_ test: XCTestCase, plan: Data, settings: EncodeSettingsMsg, output: URL,
               whenDetached: DetachedHandoffMsg = .saveToGallery) throws -> String {
        try call(test) { coordinator.start(plan: plan, settings: settings, outputURL: output, title: "Test", whenDetached: whenDetached, reply: $0) }
    }

    /// Starts and waits for the end; returns the job id.
    @discardableResult
    func export(_ test: XCTestCase, plan: Data, settings: EncodeSettingsMsg, output: URL, timeout: TimeInterval = 180) throws -> String {
        let id = try start(test, plan: plan, settings: settings, output: output)
        recorder.waitForEnd(id, test: test, timeout: timeout)
        return id
    }

    func preflight(_ test: XCTestCase, plan: Data, settings: EncodeSettingsMsg) throws -> ExportPreflightMsg {
        try call(test) { coordinator.preflight(plan: plan, settings: settings, reply: $0) }
    }

    func activeJobs(_ test: XCTestCase) throws -> [ExportJobRecordMsg] {
        try call(test) { coordinator.activeJobs(reply: $0) }
    }

    func cancel(_ test: XCTestCase, _ jobId: String) throws {
        try call(test) { coordinator.cancel(jobId: jobId, reply: $0) }
    }

    /// Runs [body] on the export queue and returns its value.
    func onExportQueue<T>(_ body: () -> T) -> T { context.queues.export.sync(execute: body) }

    /// Export progress events of [jobId].
    func progress(_ jobId: String) -> [ExportProgressMsg] {
        recorder.events.filter { $0.jobId == jobId }.compactMap(\.exportProgress)
    }

    func remove() { roots.remove() }
}

final class ReplyBox<T> {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    var result: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }
}

final class CountingSuspender: ExportPreviewSuspending {
    private let lock = NSLock()
    private(set) var suspends = 0
    private(set) var resumes = 0

    func suspendPreviewForExport() {
        lock.lock()
        suspends += 1
        lock.unlock()
    }

    func resumePreviewAfterExport() {
        lock.lock()
        resumes += 1
        lock.unlock()
    }

    var counts: (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (suspends, resumes)
    }
}

// MARK: - Conformance (ARCH §14.4)

enum ExportConformance {
    struct Facts {
        var brand: String
        var codec: String
        var width: Int
        var height: Int
        var transform: CGAffineTransform
        var nominalFps: Float
        var frames: Int
        var videoDurationUs: Int64
        var videoBitrate: Double
        var audioFormat: AudioFormatID
        var sampleRate: Double
        var channels: Int
        var audioDurationUs: Int64
        var hasLocation: Bool
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// The `ftyp` major brand of [url].
    static func brand(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 12)
        guard head.count == 12, String(data: head[4..<8], encoding: .ascii) == "ftyp" else { return "" }
        return String(data: head[8..<12], encoding: .ascii) ?? ""
    }

    static func inspect(_ url: URL) throws -> Facts {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (videos, audios, metadata) = try MediaBlocking.await {
            (try await asset.loadTracks(withMediaType: .video), try await asset.loadTracks(withMediaType: .audio),
             try await asset.load(.metadata))
        }
        let video = try XCTUnwrap(videos.first, "no video track")
        let audio = try XCTUnwrap(audios.first, "no audio track")
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(audios.count, 1)
        let (size, transform, fps, vDesc, vRange) = try MediaBlocking.await {
            (try await video.load(.naturalSize), try await video.load(.preferredTransform), try await video.load(.nominalFrameRate),
             try await video.load(.formatDescriptions), try await video.load(.timeRange))
        }
        let (aDesc, aRange) = try MediaBlocking.await { (try await audio.load(.formatDescriptions), try await audio.load(.timeRange)) }
        let vd = try XCTUnwrap(vDesc.first)
        let ad = try XCTUnwrap(aDesc.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(ad)?.pointee)

        // Frames and compressed bytes (passthrough read).
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        var bytes = 0
        while let sample = output.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sample)
            frames += n
            bytes += CMSampleBufferGetTotalSampleSize(sample)
        }
        let durationUs = FrameGrid.us(vRange.duration)
        let location = metadata.contains { ($0.identifier?.rawValue ?? "").lowercased().contains("location") }
        return Facts(
            brand: try brand(url), codec: fourCC(CMFormatDescriptionGetMediaSubType(vd)), width: Int(size.width),
            height: Int(size.height), transform: transform, nominalFps: fps, frames: frames, videoDurationUs: durationUs,
            videoBitrate: durationUs > 0 ? Double(bytes * 8) / (Double(durationUs) / 1_000_000) : 0,
            audioFormat: asbd.mFormatID, sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
            audioDurationUs: FrameGrid.us(aRange.duration), hasLocation: location)
    }

    /// Asserts the §14.4 conformance rules for an export of [settings] over [durUs].
    @discardableResult
    static func check(_ url: URL, settings: EncodeSettingsMsg, durUs: Int64, brand: String, codec: String,
                      checkBitrate: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> Facts {
        let f = try inspect(url)
        XCTAssertEqual(f.brand, brand, "container brand", file: file, line: line)
        XCTAssertEqual(f.codec, codec, "codec tag", file: file, line: line)
        XCTAssertEqual(f.width, Int(settings.width), "width", file: file, line: line)
        XCTAssertEqual(f.height, Int(settings.height), "height", file: file, line: line)
        XCTAssertEqual(Double(f.nominalFps), Double(settings.fps), accuracy: 0.5, "fps", file: file, line: line)
        let expected = Int(ExportJob.frameCount(durUs: durUs, fps: Int(settings.fps)))
        XCTAssertLessThanOrEqual(abs(f.frames - expected), 1, "frame count \(f.frames) vs \(expected)", file: file, line: line)
        XCTAssertEqual(f.audioFormat, kAudioFormatMPEG4AAC, "AAC", file: file, line: line)
        XCTAssertEqual(f.sampleRate, 48_000, "48 kHz", file: file, line: line)
        XCTAssertEqual(f.channels, 2, "stereo", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(f.audioDurationUs - durUs), 50_000, "audio duration \(f.audioDurationUs)", file: file, line: line)
        XCTAssertFalse(f.hasLocation, "no location metadata", file: file, line: line)
        if checkBitrate {
            let ratio = f.videoBitrate / Double(settings.videoBitrate)
            XCTAssertTrue(ratio >= 0.75 && ratio <= 1.25, "bitrate \(Int(f.videoBitrate)) vs \(settings.videoBitrate)", file: file, line: line)
        }
        return f
    }

    /// Decoded interleaved stereo Float32 48 kHz PCM of the audio track.
    static func pcm(_ url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .audio).first })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var out: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            floats.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            out.append(contentsOf: floats)
        }
        return out
    }

    /// RMS (dB) of channel [channel] over frames [a, b) of interleaved stereo [pcm].
    static func rmsDb(_ pcm: [Float], channel: Int, _ a: Int, _ b: Int) -> Double {
        var s = 0.0
        var n = 0
        var i = a
        while i < b, 2 * i + channel < pcm.count {
            let v = Double(pcm[2 * i + channel])
            s += v * v
            n += 1
            i += 1
        }
        return n == 0 ? -.infinity : 10 * log10(max(s / Double(n), 1e-20))
    }

    static func peak(_ pcm: [Float]) -> Float { pcm.reduce(0) { max($0, abs($1)) } }

    /// Every decoded frame of the video track (BGRA, display orientation not applied): PTS and buffer.
    static func frames(_ url: URL, each: (CMTime, CVPixelBuffer) -> Void) throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) { each(CMSampleBufferGetPresentationTimeStamp(sample), pb) }
        }
        XCTAssertEqual(reader.status, .completed)
    }

    /// Mean BGRA colour of a rectangle of [pb].
    static func meanColor(_ pb: CVPixelBuffer, x0: Int, y0: Int, x1: Int, y1: Int) -> (r: Double, g: Double, b: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = base + y * row + x * 4
                b += Double(p[0])
                g += Double(p[1])
                r += Double(p[2])
                n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    /// Mean RGB of a rectangle (top-left origin) of [image], drawn upright into an RGBA bitmap.
    static func meanColor(_ image: CGImage, x0: Int, y0: Int, x1: Int, y1: Int) -> (r: Double, g: Double, b: Double) {
        let w = image.width
        let h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * w + x) * 4
                r += Double(px[o])
                g += Double(px[o + 1])
                b += Double(px[o + 2])
                n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    /// Mean luma (0–255) of [pb].
    static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        let c = meanColor(pb, x0: 0, y0: 0, x1: CVPixelBufferGetWidth(pb), y1: CVPixelBufferGetHeight(pb))
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }
}
