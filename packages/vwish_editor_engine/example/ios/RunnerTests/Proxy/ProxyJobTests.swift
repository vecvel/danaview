// OWNER: IOS-05
//
// Proxy job and proxy registry (BUILD_PLAN IOS-05):
// - proxy PTS equal the source PTS on the VFR fixture, also across a resumed segment boundary;
// - size (540 short side), codec, GOP (<= 10 frames) and bit rate checked by AVAsset inspection;
// - an HDR (HLG 10-bit) source gives an 8-bit BT.709 SDR proxy with readable barcodes;
// - a rotated source keeps its preferred transform;
// - a simulated background interruption mid-proxy (JobRegistry + JobInterruption) resumes from
//   the last complete segment;
// - ProxyRegistry status by fingerprint and the LRU cap min(4 GB, 10 % free).

import AVFoundation
import XCTest

@testable import vwish_editor_engine

final class ProxyJobTests: XCTestCase {
    private var roots: TempRoots!
    private var paths: Paths!

    override func setUpWithError() throws {
        roots = try TempRoots()
        paths = try MediaJobTestSupport.paths(roots)
    }

    override func tearDown() {
        roots?.remove()
        super.tearDown()
    }

    private func job(_ fixture: String, fingerprint: String? = nil, segmentUs: Int64 = 2_000_000) throws -> ProxyJob {
        ProxyJob(mediaURL: try ProbeFixtures.url(fixture), fingerprint: fingerprint ?? "fp-\(fixture)", paths: paths,
                 segmentDurationUs: segmentUs)
    }

    func testProxySizeFromSource() {
        XCTAssertTrue(ProxyJob.proxySize(width: 1920, height: 1080) == (960, 540))
        XCTAssertTrue(ProxyJob.proxySize(width: 1080, height: 1920) == (540, 960))
        XCTAssertTrue(ProxyJob.proxySize(width: 640, height: 360) == (640, 360))   // never upscaled
        XCTAssertTrue(ProxyJob.proxySize(width: 3840, height: 2160) == (960, 540))
    }

    func testVfrProxyKeepsSourcePtsAcrossAResumedSegment() throws {
        let proxy = try job("vfr_720p.mp4")
        var fired = false
        var segmentsAfterResume: [Int] = []
        var resumed = false
        proxy.configureWriter = { writer in
            writer.faultInjector = { segment, frame in
                if resumed {
                    if !segmentsAfterResume.contains(segment) { segmentsAfterResume.append(segment) }
                    return nil
                }
                if !fired && segment == 1 && frame == 5 {
                    fired = true
                    return MediaJobTestSupport.interruptionError()
                }
                return nil
            }
        }
        XCTAssertThrowsError(try proxy.run(JobControl(jobId: "a"))) { error in
            XCTAssertEqual(EngineError.from(error).code, .interrupted)
        }
        XCTAssertTrue(fired)
        let checkpoint = try XCTUnwrap(SegmentCheckpoint.load(from: proxy.workDirectory))
        XCTAssertEqual(checkpoint.completed.map(\.index), [0], "segment 0 kept, segment 1 discarded")

        resumed = true
        let result = try proxy.run(JobControl(jobId: "b"))
        XCTAssertEqual(segmentsAfterResume.first, 1, "resumed at the interrupted segment")
        let asset = try XCTUnwrap(result.asset)
        XCTAssertEqual(asset.path, ProxyRegistry.proxyURL(fingerprint: "fp-vfr_720p.mp4", paths: paths).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.workDirectory.path))

        let source = try MediaJobTestSupport.videoFacts(try ProbeFixtures.url("vfr_720p.mp4"))
        let output = try MediaJobTestSupport.videoFacts(URL(fileURLWithPath: asset.path))
        XCTAssertEqual(output.ptsUs.count, source.ptsUs.count)
        for (a, b) in zip(output.ptsUs, source.ptsUs) {
            XCTAssertLessThanOrEqual(abs(a - b), 2, "proxy pts \(a) vs source \(b)")
        }
        let frames = try SegmentTestSupport.readBack(URL(fileURLWithPath: asset.path))
        let sourceFrames = try SegmentTestSupport.readBack(try ProbeFixtures.url("vfr_720p.mp4"))
        XCTAssertEqual(frames.map(\.index), sourceFrames.map(\.index))
    }

    func testProxySizeCodecGopAndBitRate() throws {
        let result = try job("frame_counter_1080p30.mp4", segmentUs: 10_000_000).run(JobControl(jobId: "p"))
        let url = URL(fileURLWithPath: try XCTUnwrap(result.asset).path)
        let facts = try MediaJobTestSupport.videoFacts(url)
        XCTAssertEqual(facts.width, 960)
        XCTAssertEqual(facts.height, 540)
        XCTAssertEqual(facts.codec, kCMVideoCodecType_H264)
        XCTAssertLessThanOrEqual(MediaJobTestSupport.maxGop(facts.sync), ProxyJob.gopFrames)
        XCTAssertEqual(facts.ptsUs.count, 240)
        // Average rate capped at 3 Mbit/s (synthetic content may need less); 25 % rate-control slack.
        let bitRate = Double(SegmentedWriter.fileSize(url)) * 8 / 8.0
        XCTAssertLessThanOrEqual(bitRate, 3_000_000 * 1.25)
        XCTAssertGreaterThan(bitRate, 100_000)
        let sourceFrames = try SegmentTestSupport.readBack(try ProbeFixtures.url("frame_counter_1080p30.mp4"))
        XCTAssertEqual(try SegmentTestSupport.readBack(url).map(\.index), sourceFrames.map(\.index))
    }

    func testHdrSourceGivesSdrProxy() throws {
        let result = try job("hlg_10bit_720p.mov").run(JobControl(jobId: "h"))
        let url = URL(fileURLWithPath: try XCTUnwrap(result.asset).path)
        let facts = try MediaJobTestSupport.videoFacts(url)
        XCTAssertEqual(facts.codec, kCMVideoCodecType_H264)
        XCTAssertEqual(facts.width, 960)
        XCTAssertEqual(facts.height, 540)
        XCTAssertEqual(facts.transfer, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        XCTAssertTrue(facts.bitsPerComponent == nil || facts.bitsPerComponent == 8)
        let info = try VideoTrackInfo.load(url)
        XCTAssertFalse(info.isHDR)
        let frames = try SegmentTestSupport.readBack(url)
        XCTAssertEqual(frames.count, 90)
        XCTAssertEqual(frames.compactMap(\.index), Array(0..<90))
    }

    func testRotatedSourceKeepsItsTransform() throws {
        let result = try job("rotated_90.mov").run(JobControl(jobId: "r"))
        let url = URL(fileURLWithPath: try XCTUnwrap(result.asset).path)
        let source = try MediaJobTestSupport.videoFacts(try ProbeFixtures.url("rotated_90.mov"))
        let facts = try MediaJobTestSupport.videoFacts(url)
        XCTAssertEqual(facts.width, 960)
        XCTAssertEqual(facts.height, 540)
        XCTAssertEqual(facts.transform.a, source.transform.a, accuracy: 1e-6)
        XCTAssertEqual(facts.transform.b, source.transform.b, accuracy: 1e-6)
        XCTAssertEqual(facts.transform.c, source.transform.c, accuracy: 1e-6)
        XCTAssertEqual(facts.transform.d, source.transform.d, accuracy: 1e-6)
    }

    func testCancelDeletesPartialOutputs() throws {
        let proxy = try job("frame_counter_720p25.mp4")
        let control = JobControl(jobId: "c")
        proxy.configureWriter = { writer in
            writer.faultInjector = { segment, frame in
                if segment == 1 && frame == 3 { control.stop(.cancel) }
                return nil
            }
        }
        XCTAssertThrowsError(try proxy.run(control)) { error in
            XCTAssertEqual(EngineError.from(error).code, .cancelled)
        }
        proxy.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.workDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.outputURL.path))
    }

    // MARK: Registry

    func testProxyRegistryStatusAndReuse() throws {
        let fingerprint = "fp-status"
        XCTAssertEqual(ProxyRegistry.status(fingerprint: fingerprint, paths: paths), .noProxy)
        ProxyRegistry.mark(fingerprint: fingerprint, .running)
        XCTAssertEqual(ProxyRegistry.status(fingerprint: fingerprint, paths: paths), .running)
        ProxyRegistry.mark(fingerprint: fingerprint, nil)
        let proxy = try job("frame_counter_720p25.mp4", fingerprint: fingerprint, segmentUs: 10_000_000)
        _ = try proxy.run(JobControl(jobId: "s"))
        XCTAssertEqual(ProxyRegistry.status(fingerprint: fingerprint, paths: paths), .ready)
        // A second job reuses the ready proxy without encoding.
        var encoded = false
        let again = try job("frame_counter_720p25.mp4", fingerprint: fingerprint)
        again.configureWriter = { _ in encoded = true }
        let result = try again.run(JobControl(jobId: "s2"))
        XCTAssertFalse(encoded)
        XCTAssertEqual(result.asset?.path, proxy.outputURL.path)
    }

    func testProxyCapIsMinOf4GBAnd10PercentFreeAndEvictsLeastRecentlyUsed() throws {
        XCTAssertEqual(ProxyRegistry.capBytes(paths: paths, freeBytes: 100 * 1_073_741_824), ProxyRegistry.absoluteCapBytes)
        XCTAssertEqual(ProxyRegistry.capBytes(paths: paths, freeBytes: 10_000_000), 1_000_000)

        try paths.ensureDirectory(paths.proxies)
        var urls: [URL] = []
        for i in 0..<4 {
            let url = ProxyRegistry.proxyURL(fingerprint: "lru-\(i)", paths: paths)
            try Data(count: 400_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10) * 60)], ofItemAtPath: url.path)
            urls.append(url)
        }
        // Touch lru-0 so it is the most recently used.
        XCTAssertNotNil(ProxyRegistry.readyProxy(fingerprint: "lru-0", paths: paths))
        ProxyRegistry.pin(urls[1], paths: paths)
        defer { ProxyRegistry.unpin(urls[1], paths: paths) }
        // 10 % of 10 MB free = 1 MB cap: two 400 kB files fit.
        ProxyRegistry.enforceCap(paths: paths, freeBytes: 10_000_000)
        let exists = urls.map { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertTrue(exists[0], "recently used kept")
        XCTAssertTrue(exists[1], "pinned kept")
        XCTAssertFalse(exists[2] && exists[3], "least recently used evicted")
        let total = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count * 400_000
        XCTAssertLessThanOrEqual(total, 1_000_000)
    }

    func testStaleProxyWorkIsPruned() throws {
        let stale = paths.work.appendingPathComponent("proxy-old", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let checkpoint = SegmentCheckpoint(
            jobKind: "proxy", inputHash: "x", settings: SegmentTestSupport.settings(), startUs: 0, endUs: 1_000_000,
            segmentDurationUs: 1_000_000)
        try checkpoint.save(to: stale)
        ProxyRegistry.pruneStaleWork(paths: paths, now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "fresh checkpoint kept")
        ProxyRegistry.pruneStaleWork(paths: paths, now: Date(timeIntervalSinceNow: 8 * 24 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
