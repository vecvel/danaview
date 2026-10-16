// OWNER: IOS-07 (temporary diagnostic, FIX-IOS-MEDIA)
import AVFoundation
import XCTest
@testable import danaview_editor_engine

final class ZZMemProbeTests: XCTestCase {
    func url() throws -> URL { try ProbeFixtures.url("frame_counter_1080p30.mp4") }

    func decodeAll(_ u: URL, seconds: Double) throws -> [CVPixelBuffer] {
        let info = try VideoTrackInfo.load(u)
        let reader = try AVAssetReader(asset: info.asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: info.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        out.alwaysCopiesSampleData = false
        reader.add(out); reader.startReading()
        var n = 0
        while let s = out.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(s) != nil { n += 1 } }
        print("MEMPROBE decoded \(n)")
        return []
    }

    func testA_decodeOnly() throws {
        let u = try url()
        _ = try decodeAll(u, seconds: 1)
        let d = try MediaJobTestSupport.peakFootprintDelta { _ = try decodeAll(u, seconds: 8) }
        print("MEMPROBE A decode-only \(d / 1_048_576) MB")
    }

    func encode(_ u: URL, to out: URL, intra: Bool, seconds: Double) throws {
        let info = try VideoTrackInfo.load(u)
        let reader = try AVAssetReader(asset: info.asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let src = AVAssetReaderTrackOutput(track: info.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        src.alwaysCopiesSampleData = false
        reader.add(src)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let settings = SegmentEncodeSettings(codec: .h264, width: 1920, height: 1080, fps: 30, averageBitRate: intra ? 18_000_000 : 6_000_000,
            maxKeyFrameIntervalFrames: intra ? 1 : nil, maxKeyFrameIntervalSeconds: intra ? nil : 1, allowFrameReordering: false, container: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var maxWait = 0
        while let s = src.copyNextSampleBuffer() {
            guard let img = CMSampleBufferGetImageBuffer(s) else { continue }
            var w = 0
            while !input.isReadyForMoreMediaData { usleep(1000); w += 1 }
            maxWait = max(maxWait, w)
            ad.append(img, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(s))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        print("MEMPROBE encode intra=\(intra) status=\(writer.status.rawValue) maxWait=\(maxWait)")
    }

    func testB_encodeIntra() throws {
        let u = try url()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe_b.mov")
        try encode(u, to: out, intra: true, seconds: 0.5)
        let d = try MediaJobTestSupport.peakFootprintDelta { try encode(u, to: out, intra: true, seconds: 2) }
        print("MEMPROBE B encode intra 2s \(d / 1_048_576) MB")
    }

    func testC_encodeLongGop() throws {
        let u = try url()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe_c.mov")
        try encode(u, to: out, intra: false, seconds: 0.5)
        let d = try MediaJobTestSupport.peakFootprintDelta { try encode(u, to: out, intra: false, seconds: 2) }
        print("MEMPROBE C encode gop 2s \(d / 1_048_576) MB")
    }

    func testE_lengths() throws {
        let u = try url()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe_e.mov")
        try encode(u, to: out, intra: false, seconds: 0.5)
        for sec in [0.2, 1.0, 4.0, 8.0] {
            let d = try MediaJobTestSupport.peakFootprintDelta { try encode(u, to: out, intra: false, seconds: sec) }
            print("MEMPROBE E gop \(sec)s \(d / 1_048_576) MB")
        }
    }

    func testD_randomAccess() throws {
        let u = try url()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("probe_d.mov")
        try encode(u, to: out, intra: true, seconds: 2)
        func run() throws {
            let asset = AVURLAsset(url: out)
            let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
            let pts = try ReverseFrameSource.samplePts(asset: asset, track: track)
            let reader = try AVAssetReader(asset: asset)
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            o.supportsRandomAccess = true
            o.alwaysCopiesSampleData = false
            reader.add(o)
            func r(_ i: Int) -> CMTimeRange { CMTimeRange(start: pts[i], end: i + 1 < pts.count ? pts[i + 1] : CMTimeAdd(pts[i], CMTime(value: 1, timescale: 1000))) }
            reader.timeRange = r(pts.count - 1)
            reader.startReading()
            for k in 0..<pts.count {
                let i = pts.count - 1 - k
                if k > 0 { while o.copyNextSampleBuffer() != nil {}; o.reset(forReadingTimeRanges: [NSValue(timeRange: r(i))]) }
                _ = o.copyNextSampleBuffer()
            }
            print("MEMPROBE D read \(pts.count)")
        }
        try run()
        let d = try MediaJobTestSupport.peakFootprintDelta { try run() }
        print("MEMPROBE D random access \(d / 1_048_576) MB")
    }
}
