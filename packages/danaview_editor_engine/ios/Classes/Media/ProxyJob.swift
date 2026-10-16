// OWNER: IOS-05
//
// 540p proxy transcode (ARCH §9.5, §15, D-22): H.264 3 Mbps, short side 540, GOP 10 frames, SDR
// (HDR tone-mapped by Core Image), AAC 128 kbit/s 48 kHz stereo, and the SAME presentation
// timestamps as the source (VFR preserved: every decoded frame is written at its own PTS). The
// video goes through the IOS-17 SegmentedWriter (closed-GOP segments + checkpoint in
// `work/proxy-<quickHash>/`), so a background interruption or a pre-emption resumes from the last
// complete segment, also after a relaunch. The segments are concatenated into
// `proxies/<quickHash>-540.mp4.part` and renamed. The encoded orientation is kept: a rotated source
// gets the same `preferredTransform` on the proxy track (a passthrough remux after the concat), so
// the proxy is a drop-in replacement of the source in every plan.
//
// Shared with IOS-07 (ReverseJob): `VideoTrackInfo`, `FrameRenderer`, `AssetAudioSource` and
// `PassthroughRemux`.

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

final class ProxyJob: MediaJobBody {
    static let shortSide = 540
    static let videoBitRate = 3_000_000
    static let gopFrames = 10
    static let audioBitRate = 128_000
    static let jobKind = "proxy"
    /// Settings version folded into the checkpoint input hash.
    static let settingsVersion = "540v1"

    let kind = JobKindMsg.proxy
    let mediaURL: URL
    let fingerprint: String
    private let paths: Paths
    private let segmentDurationUs: Int64
    /// Test hook: called with the writer before every run (fault injection).
    var configureWriter: ((SegmentedWriter) -> Void)?

    init(mediaURL: URL, fingerprint: String, paths: Paths,
         segmentDurationUs: Int64 = SegmentedWriter.defaultSegmentDurationUs) {
        self.mediaURL = mediaURL
        self.fingerprint = fingerprint
        self.paths = paths
        self.segmentDurationUs = segmentDurationUs
    }

    var exclusiveKey: String? { "proxy-\(fingerprint)" }

    var outputURL: URL { ProxyRegistry.proxyURL(fingerprint: fingerprint, paths: paths) }
    var partialURL: URL { outputURL.appendingPathExtension("part") }
    var workDirectory: URL { paths.work.appendingPathComponent("proxy-\(CacheStore.fileName(fingerprint))", isDirectory: true) }

    /// Proxy size for a source of [width]x[height] (encoded orientation): short side 540 (never
    /// upscaled), even dimensions.
    static func proxySize(width: Int, height: Int) -> (width: Int, height: Int) {
        let short = min(width, height), long = max(width, height)
        guard short > 0 else { return (2, 2) }
        let targetShort = min(shortSide, short)
        let targetLong = Int((Double(long) * Double(targetShort) / Double(short)).rounded())
        func even(_ v: Int) -> Int { max(2, v - v % 2) }
        return width <= height ? (even(targetShort), even(targetLong)) : (even(targetLong), even(targetShort))
    }

    func run(_ control: JobControl) throws -> JobResultMsg {
        if let ready = ProxyRegistry.readyProxy(fingerprint: fingerprint, paths: paths) {
            return result(ready, durationUs: nil)
        }
        let info = try VideoTrackInfo.load(mediaURL)
        let size = ProxyJob.proxySize(width: info.width, height: info.height)
        let durationUs = info.endUs
        guard durationUs > 0 else { throw EngineError(.unsupportedMedia, "empty video") }

        // Disk: segments + concat output (network-optimised rewrite) + slack.
        let estimate = Int64(Double(ProxyJob.videoBitRate + ProxyJob.audioBitRate) / 8 * Double(durationUs) / 1_000_000)
        let free = try Paths.freeBytes(at: paths.cacheRoot.path)
        if free < 3 * estimate + 64 * 1_048_576 { throw EngineError(.diskFull, "not enough space for the proxy") }

        ProxyRegistry.pruneStaleWork(paths: paths)
        try paths.ensureDirectory(paths.proxies)
        let directory = workDirectory
        DiskCache.markActive(directory)
        defer { DiskCache.unmarkActive(directory) }

        let settings = SegmentEncodeSettings(
            codec: .h264, width: size.width, height: size.height, fps: max(1, Int(info.nominalFps.rounded())),
            averageBitRate: ProxyJob.videoBitRate, maxKeyFrameIntervalFrames: ProxyJob.gopFrames,
            maxKeyFrameIntervalSeconds: nil, allowFrameReordering: false, container: .mp4,
            audio: info.hasAudio ? SegmentEncodeSettings.Audio(sampleRate: 48_000, channels: 2, bitRate: ProxyJob.audioBitRate) : nil)
        let writer = try SegmentedWriter(
            directory: directory, jobKind: ProxyJob.jobKind, inputHash: "\(fingerprint)-\(ProxyJob.settingsVersion)",
            settings: settings, startUs: 0, endUs: durationUs, segmentDurationUs: segmentDurationUs)
        configureWriter?(writer)
        control.onStop { reason in
            if reason == .cancel { writer.cancel() } else { writer.interrupt() }
        }
        writer.onProgress = { control.progress($0 * 0.85) }

        let source = ProxyFrameSource(info: info, width: size.width, height: size.height, control: control)
        if try writer.writeVideo(source: source) == .interrupted {
            try control.check()
            throw EngineError(.interrupted, "proxy interrupted", retryable: true)
        }
        try control.check()
        if settings.audio != nil {
            let audio = AssetAudioSource(url: mediaURL, sampleRate: 48_000, channels: 2)
            if try writer.writeAudio(source: audio) == .interrupted {
                try control.check()
                throw EngineError(.interrupted, "proxy audio interrupted", retryable: true)
            }
        }
        control.progress(0.9)
        try control.check()

        let partial = partialURL
        ProxyRegistry.store(paths).pin(partial)
        defer { ProxyRegistry.store(paths).unpin(partial) }
        try? FileManager.default.removeItem(at: partial)
        if info.transform.isIdentity {
            _ = try writer.concat(to: partial)
        } else {
            let joined = directory.appendingPathComponent("joined.mp4")
            _ = try writer.concat(to: joined)
            try PassthroughRemux.remux(from: joined, to: partial, fileType: .mp4, transform: info.transform)
            try? FileManager.default.removeItem(at: joined)
        }
        try control.check()
        let final = outputURL
        do {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            throw EngineError.from(error)
        }
        try? FileManager.default.removeItem(at: directory)
        ProxyRegistry.enforceCap(paths: paths, keep: final)
        control.progress(1)
        return result(final, durationUs: durationUs)
    }

    private func result(_ url: URL, durationUs: Int64?) -> JobResultMsg {
        let duration = durationUs ?? (try? VideoTrackInfo.load(url).endUs)
        return JobResultMsg(kind: .proxy, asset: GeneratedAssetMsg(
            path: url.path, sizeBytes: SegmentedWriter.fileSize(url), durationUs: duration))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

// MARK: - Source facts

/// The facts of a file's first video track the media jobs need.
struct VideoTrackInfo {
    let asset: AVURLAsset
    let track: AVAssetTrack
    /// Encoded size.
    let width: Int
    let height: Int
    let transform: CGAffineTransform
    let nominalFps: Double
    let estimatedDataRate: Double
    /// End of the video track (µs).
    let endUs: Int64
    let isHDR: Bool
    let bitDepth: Int
    let hasAudio: Bool
    let sampleTimescale: CMTimeScale
    /// The track's edit list (media → track time). Passthrough readers return media times.
    let edits: TrackEdits

    static func load(_ url: URL) throws -> VideoTrackInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError(.mediaOffline, "media file missing") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let loaded = try MediaBlocking.await { () -> (AVAssetTrack?, Bool, CMTime) in
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            return (video, !audio.isEmpty, duration)
        }
        guard let track = loaded.0 else { throw EngineError(.unsupportedMedia, "no video track") }
        let facts = try MediaBlocking.await { () -> (CGSize, CGAffineTransform, Float, Float, CMTimeRange, [CMFormatDescription], CMTimeScale) in
            (try await track.load(.naturalSize), try await track.load(.preferredTransform),
             try await track.load(.nominalFrameRate), try await track.load(.estimatedDataRate),
             try await track.load(.timeRange), try await track.load(.formatDescriptions),
             try await track.load(.naturalTimeScale))
        }
        let edits = try TrackEdits.load(track)
        var hdr = false
        var depth = 8
        if let description = facts.5.first {
            if let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
            if let bits = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber {
                depth = bits.intValue
            } else if hdr {
                depth = 10
            }
        }
        let rangeEnd = facts.4.end
        let end = rangeEnd.isValid && !rangeEnd.isIndefinite ? rangeEnd : loaded.2
        return VideoTrackInfo(
            asset: asset, track: track, width: Int(abs(facts.0.width).rounded()), height: Int(abs(facts.0.height).rounded()),
            transform: facts.1, nominalFps: facts.2 > 0 ? Double(facts.2) : 30, estimatedDataRate: Double(facts.3),
            endUs: Probe.microseconds(end), isHDR: hdr, bitDepth: depth, hasAudio: loaded.1, sampleTimescale: facts.6,
            edits: edits)
    }

    /// The reader pixel format: 10-bit for HDR / high bit depth sources (tone-mapped later), 420v
    /// otherwise.
    var decodePixelFormat: OSType {
        isHDR || bitDepth > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

// MARK: - Edit list

/// A track's edit list: maps MEDIA time (what a passthrough `AVAssetReaderTrackOutput` with nil
/// output settings returns) to TRACK time (what decoded outputs, reader time ranges and
/// compositions use). Encoders that reorder frames (B-frames) usually write an edit that starts
/// the media at the first composition offset (e.g. media 0.108 s → track 0), so the two differ
/// (FIX-IOS-MEDIA).
struct TrackEdits: Equatable {
    struct Edit: Equatable {
        let source: CMTimeRange
        let target: CMTimeRange
    }

    /// Non-empty edits in track order; empty = identity.
    let edits: [Edit]

    static let identity = TrackEdits(edits: [])

    static func load(_ track: AVAssetTrack) throws -> TrackEdits {
        let segments = try MediaBlocking.await { try await track.load(.segments) }
        return TrackEdits(edits: segments.compactMap { segment in
            guard !segment.isEmpty, segment.timeMapping.source.start.isNumeric,
                  segment.timeMapping.source.duration.isNumeric, segment.timeMapping.target.duration.isNumeric else { return nil }
            return Edit(source: segment.timeMapping.source, target: segment.timeMapping.target)
        })
    }

    /// Track time of the media interval [mediaStart, mediaEnd) for every edit that presents part of
    /// it (a frame straddling an edit's start is shown from that edit's target start).
    func trackTimes(mediaStart: CMTime, mediaEnd: CMTime) -> [CMTime] {
        guard !edits.isEmpty else { return [mediaStart] }
        var times: [CMTime] = []
        for edit in edits {
            let sourceEnd = edit.source.end
            guard CMTimeCompare(mediaStart, sourceEnd) < 0, CMTimeCompare(mediaEnd, edit.source.start) > 0 else { continue }
            let offset = CMTimeSubtract(CMTimeMaximum(mediaStart, edit.source.start), edit.source.start)
            let scaled: CMTime
            if CMTimeCompare(edit.source.duration, edit.target.duration) == 0 || edit.source.duration.seconds <= 0 {
                scaled = offset
            } else {
                scaled = CMTimeMultiplyByFloat64(offset, multiplier: edit.target.duration.seconds / edit.source.duration.seconds)
            }
            times.append(CMTimeAdd(edit.target.start, scaled))
        }
        return times
    }

    /// Track times of a list of media sample PTS (any order): each sample covers up to the next
    /// media PTS ([mediaEnd] for the last); samples no edit presents are dropped. Sorted, unique.
    func trackTimes(ofMediaPts pts: [CMTime], mediaEnd: CMTime) -> [CMTime] {
        let sorted = pts.sorted { CMTimeCompare($0, $1) < 0 }
        guard !edits.isEmpty else { return TrackEdits.unique(sorted) }
        var result: [CMTime] = []
        for (i, p) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : CMTimeMaximum(mediaEnd, CMTimeAdd(p, CMTime(value: 1, timescale: 1_000_000)))
            result.append(contentsOf: trackTimes(mediaStart: p, mediaEnd: next))
        }
        return TrackEdits.unique(result.sorted { CMTimeCompare($0, $1) < 0 })
    }

    /// End of the media covered by the edits (the last sample's end), or nil without edits.
    var mediaEnd: CMTime? {
        edits.map(\.source.end).max { CMTimeCompare($0, $1) < 0 }
    }

    private static func unique(_ sorted: [CMTime]) -> [CMTime] {
        var out: [CMTime] = []
        for t in sorted where out.last.map({ CMTimeCompare($0, t) != 0 }) ?? true { out.append(t) }
        return out
    }
}

// MARK: - Frame renderer

/// Scales a decoded frame into a pooled 420v BT.709 buffer with Core Image; HDR frames are
/// tone-mapped to SDR (`kCIImageToneMapHDRtoSDR`). Orientation is not changed.
final class FrameRenderer {
    let width: Int
    let height: Int
    private let toneMap: Bool
    private var pool: CVPixelBufferPool?
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "danaview.jobs"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    init(width: Int, height: Int, toneMap: Bool) {
        self.width = width
        self.height = height
        self.toneMap = toneMap
    }

    /// Whether [source] can be used as is (same size, 8-bit, no tone mapping).
    func isPassthrough(_ source: CVPixelBuffer) -> Bool {
        !toneMap && CVPixelBufferGetWidth(source) == width && CVPixelBufferGetHeight(source) == height
            && CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    func render(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if isPassthrough(source) { return source }
        let output = try makeBuffer()
        var options: [CIImageOption: Any] = [:]
        if toneMap { options[.toneMapHDRtoSDR] = true }
        var image = CIImage(cvPixelBuffer: source, options: options)
        let sx = Double(width) / Double(max(1, CVPixelBufferGetWidth(source)))
        let sy = Double(height) / Double(max(1, CVPixelBufferGetHeight(source)))
        if abs(sx - 1) > 1e-6 || abs(sy - 1) > 1e-6 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy,
            ])
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        FrameRenderer.sharedContext.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        return output
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                    attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool = pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer = buffer else {
            throw EngineError(.internal, "pixel buffer allocation failed")
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}

// MARK: - Proxy frame source

/// Source frames at their own PTS (output time = source time), scaled and tone-mapped. Re-creates
/// its reader for each segment's time range.
final class ProxyFrameSource: SegmentVideoSource {
    private let info: VideoTrackInfo
    private let renderer: FrameRenderer
    private let control: JobControl?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var segmentStart = CMTime.zero

    /// How far before a segment's start its reader begins. A decoding reader returns the frame that
    /// straddles its range start re-stamped to that start (a VFR frame at 1.983 s comes back at
    /// 2.000 s for a range starting at 2 s, a duplicate of the previous segment's last frame); with
    /// the range opened earlier that copy lands before the segment and is skipped (FIX-IOS-MEDIA).
    static let readerLeadUs: Int64 = 100_000

    init(info: VideoTrackInfo, width: Int, height: Int, control: JobControl?) {
        self.info = info
        renderer = FrameRenderer(width: width, height: height, toneMap: info.isHDR)
        self.control = control
    }

    func openSegment(startUs: Int64, endUs: Int64) throws {
        closeSegment()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: info.asset)
        } catch {
            throw EngineError.from(error)
        }
        segmentStart = CMTime(value: startUs, timescale: 1_000_000)
        reader.timeRange = CMTimeRange(start: CMTime(value: max(0, startUs - ProxyFrameSource.readerLeadUs), timescale: 1_000_000),
                                       end: CMTime(value: endUs, timescale: 1_000_000))
        let output = AVAssetReaderTrackOutput(
            track: info.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: info.decodePixelFormat])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    func nextFrame() throws -> SegmentFrame? {
        guard let output = output, let reader = reader else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            if control?.isStopped == true { throw EngineError(.interrupted, "stopped", retryable: true) }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            // Frames of the lead-in belong to the previous segment: skipped before rendering.
            if CMTimeCompare(pts, segmentStart) < 0 { continue }
            return SegmentFrame(pixelBuffer: try renderer.render(image), pts: pts)
        }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "reader failed")
        }
        return nil
    }

    func closeSegment() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
    }
}

// MARK: - Audio source

/// LPCM Float32 of a file's audio tracks mixed to [channels] at [sampleRate], in source time.
final class AssetAudioSource: SegmentAudioSource {
    private let url: URL
    private let sampleRate: Int
    private let channels: Int
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?

    init(url: URL, sampleRate: Int, channels: Int) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func openAudio(startUs: Int64, endUs: Int64) throws {
        closeAudio()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try MediaBlocking.await { try await asset.loadTracks(withMediaType: .audio) }
        guard let first = tracks.first else { throw EngineError(.unsupportedMedia, "no audio track") }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw EngineError.from(error)
        }
        reader.timeRange = CMTimeRange(start: CMTime(value: startUs, timescale: 1_000_000),
                                       end: CMTime(value: endUs, timescale: 1_000_000))
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let output = AVAssetReaderAudioMixOutput(audioTracks: [first], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decoderInitFailed, "audio reader did not start")
        }
        self.reader = reader
        self.output = output
    }

    func nextAudio() throws -> CMSampleBuffer? {
        guard let output = output, let reader = reader else { return nil }
        if let sample = output.copyNextSampleBuffer() { return sample }
        if reader.status == .failed {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "audio reader failed")
        }
        return nil
    }

    func closeAudio() {
        if reader?.status == .reading { reader?.cancelReading() }
        reader = nil
        output = nil
    }
}

// MARK: - Passthrough remux

/// Copies every video and audio sample of a file into a new file unchanged, with
/// [transform] as the video track's preferred transform (the concat writer cannot set it).
enum PassthroughRemux {
    static func remux(from source: URL, to destination: URL, fileType: AVFileType, transform: CGAffineTransform) throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (videoTracks, audioTracks, duration) = try MediaBlocking.await {
            (try await asset.loadTracks(withMediaType: .video), try await asset.loadTracks(withMediaType: .audio),
             try await asset.load(.duration))
        }
        try? FileManager.default.removeItem(at: destination)
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        } catch {
            throw EngineError.from(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (track, isVideo) in videoTracks.prefix(1).map({ ($0, true) }) + audioTracks.prefix(1).map({ ($0, false) }) {
            let descriptions = try MediaBlocking.await { try await track.load(.formatDescriptions) }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: isVideo ? .video : .audio, outputSettings: nil,
                                           sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            if isVideo { input.transform = transform }
            guard writer.canAdd(input) else { throw EngineError(.encodingFailed, "remux input refused") }
            writer.add(input)
            pairs.append((output, input))
        }
        guard !pairs.isEmpty else { throw EngineError(.decodeFailed, "nothing to remux") }
        guard reader.startReading() else {
            throw reader.error.map(EngineError.from) ?? EngineError(.decodeFailed, "remux reader did not start")
        }
        guard writer.startWriting() else {
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "remux writer did not start")
        }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        var failed = false
        let failLock = NSLock()
        for (index, pair) in pairs.enumerated() {
            group.enter()
            var done = false
            let queue = DispatchQueue(label: "com.vecvel.danaview.editor.remux.\(index)")
            pair.1.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                while pair.1.isReadyForMoreMediaData {
                    guard let sample = pair.0.copyNextSampleBuffer() else {
                        done = true
                        pair.1.markAsFinished()
                        return group.leave()
                    }
                    if !pair.1.append(sample) {
                        failLock.lock()
                        failed = true
                        failLock.unlock()
                        done = true
                        pair.1.markAsFinished()
                        return group.leave()
                    }
                }
            }
        }
        group.wait()
        if failed || reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw (writer.error ?? reader.error).map(EngineError.from) ?? EngineError(.encodingFailed, "remux failed")
        }
        writer.endSession(atSourceTime: duration)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error.map(EngineError.from) ?? EngineError(.encodingFailed, "remux did not complete")
        }
    }
}
