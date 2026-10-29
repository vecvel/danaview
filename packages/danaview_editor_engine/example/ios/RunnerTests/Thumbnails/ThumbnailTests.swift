// OWNER: IOS-03
//
// Thumbnails and disk cache (BUILD_PLAN IOS-03): tile shape and frame times on frame_counter
// (barcodes read from every strip cell), cache hit <= 20 ms, cancel stops work, priorities and the
// 8-tile concurrency cap, LRU cap and pinning, clear refused while active, and the work/ launch
// wipe with its exemptions.
//
// Deferred (no device available, D-43): miss <= 400 ms on the low-tier device (QA-04 records it);
// the simulator miss time is printed.

import Flutter
import ImageIO
import XCTest

@testable import danaview_editor_engine

enum ThumbTestSupport {
    static func request(
        fingerprint: String = "fc1080", uri: String, intervalMs: Int64, tileIndex: Int64, heightPx: Int64,
        framesPerTile: Int64 = 8
    ) -> ThumbnailRequestMsg {
        ThumbnailRequestMsg(
            media: ResolvedMediaMsg(uri: uri, fingerprint: fingerprint, isProxy: false), intervalMs: intervalMs,
            tileIndex: tileIndex, heightPx: heightPx, framesPerTile: framesPerTile, proxy: false)
    }

    static func decodeJPEG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// An engine context whose roots are [roots] (DiskCache initialised).
    static func context(_ roots: TempRoots) throws -> EngineContext {
        let context = EngineContext(messenger: FakeMessenger(), textures: nil)
        try context.configure(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        DiskCache(context: context).engineDidInitialize(paths: try context.requirePaths())
        return context
    }

    static func tile(
        _ service: ThumbnailService, id: String, _ request: ThumbnailRequestMsg, url: URL,
        priority: ThumbPriorityMsg = .visible, test: XCTestCase
    ) throws -> (ThumbnailTileMsg, TimeInterval) {
        let done = test.expectation(description: "tile \(id)")
        var result: Result<ThumbnailTileMsg, Error>?
        let started = Date()
        var elapsed: TimeInterval = 0
        service.tile(requestId: id, request: request, mediaURL: url, priority: priority) {
            elapsed = Date().timeIntervalSince(started)
            result = $0
            done.fulfill()
        }
        test.wait(for: [done], timeout: 30)
        return (try XCTUnwrap(result).get(), elapsed)
    }
}

final class ThumbnailTests: XCTestCase {
    func testTileShapeAndFrameTimesOnFrameCounter() throws {
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        let request = ThumbTestSupport.request(uri: url.path, intervalMs: 500, tileIndex: 1, heightPx: 270)
        let tile = try ThumbnailService.render(url: url, request: request, isCancelled: { false })
        XCTAssertEqual(tile.frames, 8)
        XCTAssertEqual(tile.frameWidthPx, 480)
        let image = try ThumbTestSupport.decodeJPEG(tile.encoded.data)
        XCTAssertEqual(image.width, 480 * 8)
        XCTAssertEqual(image.height, 270)
        for k in 0..<8 {
            let cell = try XCTUnwrap(image.cropping(to: CGRect(x: k * 480, y: 0, width: 480, height: 270)))
            let reading = FrameBarcode.read(cgImage: cell)
            XCTAssertEqual(reading.status, .ok, "frame \(k)")
            // Frame k of tile 1 is requested at (8 + k) · 500 ms = source frame (8 + k) · 15 at
            // 30 fps, within the ± interval / 2 tolerance (± 7.5 frames).
            let expected = (8 + k) * 15
            let index = try XCTUnwrap(reading.index, "frame \(k)")
            XCTAssertLessThanOrEqual(abs(index - expected), 8, "frame \(k): barcode \(index), expected ~\(expected)")
        }
    }

    func testLastTileIsShortAndRotationIsApplied() throws {
        let url = try ProbeFixtures.url("frame_counter_720p25.mp4")
        let short = try ThumbnailService.render(
            url: url, request: ThumbTestSupport.request(uri: url.path, intervalMs: 3000, tileIndex: 0, heightPx: 64),
            isCancelled: { false })
        XCTAssertEqual(short.frames, 3, "0, 3 and 6 s lie before the 8 s end")
        XCTAssertThrowsError(try ThumbnailService.render(
            url: url, request: ThumbTestSupport.request(uri: url.path, intervalMs: 1000, tileIndex: 1, heightPx: 64),
            isCancelled: { false }))

        let rotated = try ProbeFixtures.url("rotated_90.mov")
        let tile = try ThumbnailService.render(
            url: rotated, request: ThumbTestSupport.request(uri: rotated.path, intervalMs: 250, tileIndex: 0, heightPx: 128),
            isCancelled: { false })
        XCTAssertEqual(tile.frameWidthPx, 72, "720x1280 display at 128 px high")
        let image = try ThumbTestSupport.decodeJPEG(tile.encoded.data)
        XCTAssertEqual(image.width, 72 * Int(tile.frames))

        let still = try ProbeFixtures.url("still_4k.jpg")
        let stillTile = try ThumbnailService.render(
            url: still, request: ThumbTestSupport.request(uri: still.path, intervalMs: 1000, tileIndex: 0, heightPx: 90),
            isCancelled: { false })
        XCTAssertEqual(stillTile.frames, 1)
        XCTAssertEqual(stillTile.frameWidthPx, 160)
    }

    func testCacheHitWithin20msAndCachedBytesAreIdentical() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let context = try ThumbTestSupport.context(roots)
        let service = ThumbnailService(context: context)
        let url = try ProbeFixtures.url("frame_counter_720p25.mp4")
        let request = ThumbTestSupport.request(fingerprint: "fc25", uri: url.path, intervalMs: 1000, tileIndex: 0, heightPx: 90)
        let (miss, missTime) = try ThumbTestSupport.tile(service, id: "a", request, url: url, test: self)
        var best = TimeInterval.greatestFiniteMagnitude
        for i in 0..<5 {
            let (hit, hitTime) = try ThumbTestSupport.tile(service, id: "b\(i)", request, url: url, test: self)
            XCTAssertEqual(hit, miss)
            best = min(best, hitTime)
        }
        // DV_PERF_STRICT=1: 20 ms; loose: 4×, or half the miss measured above.
        PerfGate.assertAtMost(best, 0.02, baseline: missTime / 2, "cache hit took \(Int(best * 1000)) ms")
        let stores = DiskCache.stores(for: try context.requirePaths())
        XCTAssertNotNil(stores.thumbs.lookup(key: ThumbnailService.cacheKey(request), ext: "dvth"))
        print("IOS-03 simulator thumbnail miss \(Int(missTime * 1000)) ms, hit \(String(format: "%.2f", best * 1000)) ms")
    }

    func testCancelStopsWorkAndConcurrencyIsCapped() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let service = ThumbnailService(context: try ThumbTestSupport.context(roots))
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        var outcomes: [String: Result<ThumbnailTileMsg, Error>] = [:]
        let lock = NSLock()
        var peak = 0
        let all = expectation(description: "all replies")
        all.expectedFulfillmentCount = 24
        for i in 0..<24 {
            let request = ThumbTestSupport.request(
                fingerprint: "cancel-\(i)", uri: url.path, intervalMs: 40, tileIndex: Int64(i), heightPx: 360)
            service.tile(requestId: "r\(i)", request: request, mediaURL: url, priority: .background) { result in
                lock.lock()
                outcomes["r\(i)"] = result
                lock.unlock()
                all.fulfill()
            }
            peak = max(peak, service.runningCount)
        }
        peak = max(peak, service.runningCount)
        XCTAssertLessThanOrEqual(peak, ThumbnailService.maxConcurrent)
        for i in 0..<24 {
            service.cancel(requestId: "r\(i)")
        }
        wait(for: [all], timeout: 30)
        let cancelled = outcomes.values.filter {
            if case .failure(let error) = $0 { return EngineError.from(error).code == .cancelled }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(cancelled, 16, "pending and running tiles answer cancelled")
        // Running renders stop before their next frame and free their slots.
        let idle = expectation(description: "idle")
        DispatchQueue.global().async {
            for _ in 0..<200 where service.runningCount > 0 { usleep(10_000) }
            idle.fulfill()
        }
        wait(for: [idle], timeout: 5)
        XCTAssertEqual(service.runningCount, 0)
    }

    func testRenderStopsWhenCancelled() throws {
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        var calls = 0
        XCTAssertThrowsError(try ThumbnailService.render(
            url: url, request: ThumbTestSupport.request(uri: url.path, intervalMs: 500, tileIndex: 0, heightPx: 90),
            isCancelled: {
                calls += 1
                return calls > 2
            })) { error in
            XCTAssertEqual(EngineError.from(error).code, .cancelled)
        }
        XCTAssertEqual(calls, 3, "stopped before the third frame")
    }

    func testVisibleIsServedBeforePrefetch() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let service = ThumbnailService(context: try ThumbTestSupport.context(roots))
        let url = try ProbeFixtures.url("frame_counter_1080p30.mp4")
        let done = expectation(description: "done")
        done.expectedFulfillmentCount = 10
        var order: [String] = []
        let lock = NSLock()
        func submit(_ id: String, _ tile: Int64, _ priority: ThumbPriorityMsg) {
            let request = ThumbTestSupport.request(fingerprint: "prio", uri: url.path, intervalMs: 100, tileIndex: tile, heightPx: 270)
            service.tile(requestId: id, request: request, mediaURL: url, priority: priority) { _ in
                lock.lock()
                order.append(id)
                lock.unlock()
                done.fulfill()
            }
        }
        for i in 0..<8 { submit("busy\(i)", Int64(i), .background) }
        submit("prefetch", 20, .prefetch)
        submit("visible", 21, .visible)
        wait(for: [done], timeout: 60)
        let visible = try XCTUnwrap(order.firstIndex(of: "visible"))
        let prefetch = try XCTUnwrap(order.firstIndex(of: "prefetch"))
        XCTAssertLessThan(visible, prefetch, "order \(order)")
    }
}

final class DiskCacheTests: XCTestCase {
    func testLruCapAndPinning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("danaview-lru-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CacheStore(directory: dir, capBytes: 1000)
        let now = Date()
        for i in 0..<3 {
            let url = try store.write(Data(repeating: UInt8(i), count: 300), key: "k\(i)", ext: "bin")
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i - 10))], ofItemAtPath: url.path)
        }
        // k0 is the oldest; a hit makes it the newest.
        XCTAssertNotNil(store.lookup(key: "k0", ext: "bin"))
        let pinned = store.url(forKey: "k1", ext: "bin")
        store.pin(pinned)
        try store.write(Data(repeating: 9, count: 300), key: "k3", ext: "bin")  // 1200 > 1000
        XCTAssertLessThanOrEqual(store.totalBytes, 1000)
        XCTAssertNotNil(store.lookup(key: "k0", ext: "bin"), "recently used survives")
        XCTAssertNotNil(store.lookup(key: "k1", ext: "bin"), "pinned survives")
        XCTAssertNil(store.lookup(key: "k2", ext: "bin"), "least recently used is evicted")
        store.unpin(pinned)
        XCTAssertFalse(store.isPinned(pinned))
        store.clear()
        XCTAssertEqual(store.totalBytes, 0)
        XCTAssertEqual(CacheStore.fileName("abc-1.x"), "abc-1.x")
        XCTAssertEqual(CacheStore.fileName("a/b").count, 32)
        XCTAssertEqual(ThumbnailService.decodeCached(ThumbnailService.encodeCached(
            ThumbnailTileMsg(encoded: FlutterStandardTypedData(bytes: Data([1, 2, 3])), frames: 8, frameWidthPx: 160))),
            ThumbnailTileMsg(encoded: FlutterStandardTypedData(bytes: Data([1, 2, 3])), frames: 8, frameWidthPx: 160))
    }

    func testClearIsRefusedWhileActive() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let paths = try Paths(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        let thumbs = DiskCache.stores(for: paths).thumbs
        try thumbs.write(Data(repeating: 1, count: 10), key: "t", ext: "dvth")
        DiskCache.beginActivity()
        XCTAssertFalse(DiskCache.trim(.clearAll, paths: paths))
        XCTAssertNotNil(thumbs.lookup(key: "t", ext: "dvth"))
        DiskCache.endActivity()
        XCTAssertTrue(DiskCache.trim(.clearAll, paths: paths))
        XCTAssertNil(thumbs.lookup(key: "t", ext: "dvth"))
    }

    func testLaunchWipeOfWork() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let paths = try Paths(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        let fm = FileManager.default
        func make(_ relative: String, age: TimeInterval = 0) throws -> URL {
            let url = paths.work.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            if age > 0 {
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            return url
        }
        let stale = try make("reverse-old/chunk.mp4")
        _ = try make("export-resumable/v-0.mp4")
        let checkpoint = SegmentCheckpoint(
            jobKind: "export", inputHash: "h", settings: SegmentTestSupport.settings(), startUs: 0, endUs: 1_000_000,
            segmentDurationUs: 1_000_000)
        try checkpoint.save(to: paths.work.appendingPathComponent("export-resumable"))
        let oldPick = try make("picks/a/old.mov", age: 25 * 3600)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                             ofItemAtPath: oldPick.deletingLastPathComponent().path)
        let newPick = try make("picks/b/new.mov")
        let oldDrop = try make("drops/old.png", age: 30 * 3600)
        let detached = try make("export-done/out.mp4")
        WorkExemptions.add(detached, paths: paths)
        let expired = try make("export-expired/out.mp4")
        WorkExemptions.add(expired, expires: Date().addingTimeInterval(-60), paths: paths)
        let active = try make("proxy-running/v-0.mp4")
        DiskCache.markActive(active.deletingLastPathComponent())
        defer { DiskCache.unmarkActive(active.deletingLastPathComponent()) }

        DiskCache.wipeWork(paths: paths)

        XCTAssertFalse(fm.fileExists(atPath: stale.path), "stale job files are wiped")
        XCTAssertTrue(fm.fileExists(atPath: paths.work.appendingPathComponent("export-resumable/v-0.mp4").path),
                      "resumable checkpoints survive")
        XCTAssertFalse(fm.fileExists(atPath: oldPick.deletingLastPathComponent().path), "picks older than 24 h are wiped")
        XCTAssertTrue(fm.fileExists(atPath: newPick.path))
        XCTAssertFalse(fm.fileExists(atPath: oldDrop.path))
        XCTAssertTrue(fm.fileExists(atPath: detached.path), "completedWhileDetached outputs survive 7 days")
        XCTAssertFalse(fm.fileExists(atPath: expired.path), "expired exemptions are wiped")
        XCTAssertTrue(fm.fileExists(atPath: active.path), "active job files survive")
        XCTAssertEqual(WorkExemptions.live(paths), ["export-done/out.mp4"])
        WorkExemptions.remove(detached, paths: paths)
        XCTAssertTrue(WorkExemptions.live(paths).isEmpty)
    }
}
