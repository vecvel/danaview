// OWNER: IOS-19
//
// Simulator numbers of a 4-layer chroma-key range (BUILD_PLAN IOS-19: recorded in the PR): the
// render time of a 3 s range (base + 3 chroma-keyed PiPs, 640×360 at 25 fps) and the frames an
// AVPlayer drops while playing it through an AVPlayerItemVideoOutput polled at 120 Hz, with the
// live composition and with the rendered range swapped in. Printed as `IOS-19 numbers …`; the
// only assertions are that both play and that the swapped playback drops no more than the live
// one plus a small allowance (simulator timing is noisy).

import AVFoundation
import QuartzCore
import XCTest

@testable import danaview_editor_engine

final class RenderPreviewNumbersTests: XCTestCase {
    private var harness: RenderPreviewHarness!

    override func setUpWithError() throws {
        harness = try RenderPreviewHarness()
    }

    override func tearDown() {
        harness?.remove()
        harness = nil
    }

    /// Plays [plan] once through an AVPlayer and returns the distinct output frames shown.
    private func play(_ plan: RenderPlan, size: CGSize) throws -> (shown: Int, expected: Int, wallMs: Double) {
        let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)))
        var options = CompositionBuildOptions(spacerDirectory: harness.paths.engineAssets)
        options.renderSize = size
        options.validate = false
        options.resolveURL = RenderPreviewFixtures.resolve
        session.configure(&options)
        let input = UncheckedSendable((plan, options))
        let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
        defer { built.releaseMedia() }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        XCTAssertTrue(JobEventRecorder.spin(timeout: 30) { item.status == .readyToPlay }, "item ready")
        // Warm up: the first composed frame pays decoder and kernel start-up.
        let warm = expectation(description: "seek")
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in warm.fulfill() }
        wait(for: [warm], timeout: 30)
        let expected = Int(plan.canvas.outputGrid.frameIndexOf(plan.durUs))
        var shown = Set<Int64>()
        let start = CACurrentMediaTime()
        player.playImmediately(atRate: 1)
        let deadline = start + Double(plan.durUs) / 1_000_000 + 1.0
        while CACurrentMediaTime() < deadline {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
               let k = DVRenderSession.frameIndex(of: pb) {
                shown.insert(k)
            }
            if item.currentTime().seconds * 1_000_000 >= Double(plan.durUs) - 1 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }
        player.pause()
        return (shown.count, expected, (CACurrentMediaTime() - start) * 1000)
    }

    func testFourLayerChromaKeyRangeNumbers() throws {
        let durUs: Int64 = 3_000_000
        let plan = RenderPreviewFixtures.chromaKeyed(try RenderPreviewFixtures.plan(durUs: durUs, pips: 3))
        XCTAssertEqual(plan.layers.count, 4)
        let url = RenderPreviewFixtures.renderURL(harness.paths, "chroma")
        let job = RenderPreviewJob(plan: RenderPreviewFixtures.cut(plan, 0, durUs), outputURL: url,
                                   options: RenderPreviewFixtures.options(harness.paths))
        _ = try harness.run(job)
        let size = job.renderSize
        let swap = RenderedRangeSwap()
        swap.setRanges([RenderedRange(startUs: 0, endUs: durUs, fileURL: url, hash: "chroma")], plan: plan)
        let swapped = try XCTUnwrap(swap.playbackPlan(for: plan))

        let live = try play(plan, size: size)
        let cached = try play(swapped, size: size)
        let liveDropped = live.expected - live.shown
        let cachedDropped = cached.expected - cached.shown
        let line = String(
            format: "IOS-19 numbers (simulator, %dx%d, 25 fps, %d frames, base + 3 chroma PiPs): render %.0f ms (%.2fx real time); "
                + "live playback dropped %d, rendered-range playback dropped %d",
            Int(size.width), Int(size.height), live.expected, job.renderMs, Double(durUs) / 1000 / job.renderMs, liveDropped,
            cachedDropped)
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(live.shown, 0)
        XCTAssertGreaterThan(cached.shown, 0)
        XCTAssertLessThanOrEqual(cachedDropped, liveDropped + 5, "the rendered range plays at least as smoothly")
    }
}
