// TEMPORARY diagnostic (FIX-IOS-DURATION); removed before the ticket ends.
import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class TmpDurationDiagTests: XCTestCase {
    func testDiag() throws {
        let harness = try ExportHarness()
        defer { harness.remove() }
        for (fps, k) in [(60, 179 as Int64), (30, 91)] {
            let durUs = FrameGrid(fps).timeOfFrame(k)
            let data = ExportPlans.plan(
                w: 320, h: 180, fps: fps, durUs: durUs, assets: [],
                layers: [ExportPlans.solid("it_s0000000001#v", t0: 0, t1: durUs, color: "#FF0000FF", w: 100, h: 100, cx: 160, cy: 90)])
            let plan = try RenderPlanDecoder.decodePlan(data)
            let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
            var options = CompositionBuildOptions(spacerDirectory: harness.paths.engineAssets)
            options.renderSize = CGSize(width: 320, height: 180)
            options.useProxies = false
            options.validate = false
            session.configure(&options)
            let input = UncheckedSendable((plan, options))
            let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
            print("DIAG \(fps)x\(k) compDur=\(built.composition.duration.seconds) instr=\(built.videoComposition.instructions.map { "\($0.timeRange.start.value)/\($0.timeRange.start.timescale)-\($0.timeRange.end.value)/\($0.timeRange.end.timescale)" })")
            let gEnd = CMTime(value: k, timescale: CMTimeScale(fps))
            let s2 = CMTime(value: 2_000_000, timescale: 1_000_000)
            let r1 = CMTimeRange(start: s2, end: gEnd)
            print("DIAG range start=\(r1.start.value)/\(r1.start.timescale) dur=\(r1.duration.value)/\(r1.duration.timescale) end=\(r1.end.value)/\(r1.end.timescale) cmp=\(CMTimeCompare(r1.end, gEnd))")
            for (label, range) in [
                ("seg3-mixed", r1),
                ("seg3-grid", CMTimeRange(start: CMTime(value: Int64(2 * fps), timescale: CMTimeScale(fps)), end: gEnd)),
                ("seg3-3e6", CMTimeRange(start: CMTimeConvertScale(s2, timescale: 3_000_000, method: .roundHalfAwayFromZero), end: CMTimeConvertScale(gEnd, timescale: 3_000_000, method: .roundHalfAwayFromZero))),
                ("clamped", ExportTime.readerRange(startUs: 0, endUs: durUs, plan: plan)),
                ("us", CMTimeRange(start: .zero, end: FrameGrid.cmTime(us: durUs))),
                ("grid-1", CMTimeRange(start: .zero, end: CMTime(value: k - 1, timescale: CMTimeScale(fps)))),
            ] {
                let reader = try AVAssetReader(asset: built.composition)
                reader.timeRange = range
                let output = AVAssetReaderVideoCompositionOutput(
                    videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
                output.videoComposition = built.videoComposition
                reader.add(output)
                reader.startReading()
                var n = 0
                var last = CMTime.invalid
                let done = DispatchSemaphore(value: 0)
                let box = UncheckedSendable((reader, output))
                DispatchQueue.global().async {
                    while let s = box.value.1.copyNextSampleBuffer() {
                        n += 1
                        last = CMSampleBufferGetPresentationTimeStamp(s)
                    }
                    done.signal()
                }
                let timedOut = done.wait(timeout: .now() + 15) == .timedOut
                print("DIAG \(fps)x\(k) \(label) frames=\(n) last=\(last.value)/\(last.timescale) timedOut=\(timedOut) status=\(reader.status.rawValue) err=\(String(describing: reader.error))")
                if timedOut { reader.cancelReading() }
            }
            built.releaseMedia()
        }
    }
}
