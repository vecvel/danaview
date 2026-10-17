// OWNER: IOS-05
//
// Helpers of the media job tests (IOS-05 proxies and registry, IOS-06 freeze, IOS-07 reverse):
// temporary engine roots with Paths, an event recorder on the EventHub, track inspection
// (sample PTS, sync samples, format facts) and the process memory footprint.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

enum MediaJobTestSupport {
    /// Temporary roots and their Paths.
    static func paths(_ roots: TempRoots) throws -> Paths {
        try Paths(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
    }

    /// An engine context on [roots] with DiskCache initialised.
    static func context(_ roots: TempRoots, events: EventHub = EventHub()) throws -> EngineContext {
        let context = EngineContext(messenger: FakeMessenger(), textures: nil, events: events, presentingViewController: { nil })
        try context.configure(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        DiskCache(context: context).engineDidInitialize(paths: try context.requirePaths())
        return context
    }

    /// The error AVFoundation reports when the encoder is taken away in the background.
    static func interruptionError() -> NSError {
        NSError(domain: AVFoundationErrorDomain, code: -11847)
    }

    struct TrackFacts {
        var width: Int
        var height: Int
        var codec: FourCharCode
        var transfer: String?
        var bitsPerComponent: Int?
        var transform: CGAffineTransform
        var estimatedDataRate: Float
        var durationUs: Int64
        /// Presentation order sample PTS (µs).
        var ptsUs: [Int64]
        /// Sync flag of each sample, in decode order.
        var sync: [Bool]
    }

    /// Facts of the first video track of [url] (compressed passthrough read).
    static func videoFacts(_ url: URL) throws -> TrackFacts {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try XCTUnwrap(try MediaBlocking.await { try await asset.loadTracks(withMediaType: .video).first })
        let (size, transform, rate, descriptions, range) = try MediaBlocking.await {
            (try await track.load(.naturalSize), try await track.load(.preferredTransform),
             try await track.load(.estimatedDataRate), try await track.load(.formatDescriptions),
             try await track.load(.timeRange))
        }
        let description = try XCTUnwrap(descriptions.first)
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let bits = (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var mediaPts: [CMTime] = []
        var sync: [Bool] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            mediaPts.append(CMSampleBufferGetPresentationTimeStamp(sample))
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            sync.append(!(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false))
        }
        // Passthrough samples carry media times: presentation (track) times through the edit list.
        let edits = try TrackEdits.load(track)
        let pts = edits.trackTimes(ofMediaPts: mediaPts, mediaEnd: edits.mediaEnd ?? range.end)
            .map { Int64(($0.seconds * 1_000_000).rounded()) }
        return TrackFacts(
            width: Int(size.width), height: Int(size.height), codec: CMFormatDescriptionGetMediaSubType(description),
            transfer: transfer, bitsPerComponent: bits, transform: transform, estimatedDataRate: rate,
            durationUs: Int64((range.duration.seconds * 1_000_000).rounded()), ptsUs: pts.sorted(), sync: sync)
    }

    /// Largest distance in samples between two sync samples (decode order).
    static func maxGop(_ sync: [Bool]) -> Int {
        var longest = 0, run = 0
        for (i, isSync) in sync.enumerated() {
            if isSync && i > 0 { longest = max(longest, run); run = 0 }
            run += 1
        }
        return max(longest, run)
    }

    /// Physical footprint of the process in bytes.
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Samples the footprint every 20 ms while [work] runs; returns the peak delta in bytes.
    static func peakFootprintDelta(during work: () throws -> Void) rethrows -> Int64 {
        let base = footprint()
        var peak = base
        let lock = NSLock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "danaview.test.footprint"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler {
            let now = footprint()
            lock.lock()
            peak = max(peak, now)
            lock.unlock()
        }
        timer.resume()
        defer { timer.cancel() }
        try work()
        lock.lock()
        defer { lock.unlock() }
        return max(0, max(peak, footprint()) - base)
    }

    /// Writes a synthetic H.264 clip of [frames] frames at [fps] whose frames carry the barcode
    /// of their index (tests that need sizes the committed fixtures do not have, e.g. 4K).
    static func makeBarcodeClip(_ url: URL, width: Int, height: Int, fps: Int, frames: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000, AVVideoMaxKeyFrameIntervalKey: fps],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // Only the band rows of the canvas are painted and copied.
        var canvas = [UInt8](repeating: 0, count: width * 4 * height)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
            // Grey background varying with the index, barcode band on top.
            memset(base, Int32(40 + (index * 7) % 160), bpr * height)
            let bandRows = FrameBarcode.bandHeight(frameHeight: height)
            FrameBarcode.paint(into: &canvas, width: width, height: height, index: index)
            for row in 0..<bandRows {
                canvas.withUnsafeBytes { raw in
                    memcpy(base.advanced(by: row * bpr), raw.baseAddress!.advanced(by: row * width * 4), width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}

/// Records job events delivered by an EventHub (main thread).
final class JobEventRecorder {
    let hub: EventHub
    private(set) var events: [EngineEventMsg] = []
    private(set) var progressTimes: [String: [TimeInterval]] = [:]
    private var waiters: [(String, XCTestExpectation)] = []

    init() {
        hub = EventHub()
        hub.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { [weak self] value in
            guard let self = self, let event = value as? EngineEventMsg else { return }
            self.events.append(event)
            if let id = event.jobId {
                if event.progress != nil { self.progressTimes[id, default: []].append(ProcessInfo.processInfo.systemUptime) }
                if event.jobDone != nil || event.failure != nil {
                    for (jobId, expectation) in self.waiters where jobId == id { expectation.fulfill() }
                    self.waiters.removeAll { $0.0 == id }
                }
            }
        })
    }

    func done(_ jobId: String) -> JobResultMsg? { events.first { $0.jobId == jobId && $0.jobDone != nil }?.jobDone }
    func failure(_ jobId: String) -> FailureMsg? { events.first { $0.jobId == jobId && $0.failure != nil }?.failure }
    func ended(_ jobId: String) -> Bool { done(jobId) != nil || failure(jobId) != nil }

    /// Waits on the main run loop until [jobId] ends.
    func waitForEnd(_ jobId: String, test: XCTestCase, timeout: TimeInterval = 120) {
        if ended(jobId) { return }
        let expectation = test.expectation(description: "job \(jobId) ends")
        waiters.append((jobId, expectation))
        test.wait(for: [expectation], timeout: timeout)
    }

    /// Spins the main run loop until [condition] holds or [timeout] passes.
    @discardableResult
    static func spin(timeout: TimeInterval = 30, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
