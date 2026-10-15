// TEMPORARY diagnostic (FIX-IOS-DURATION); removed before the ticket ends.
import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class TmpDurationDiagTests: XCTestCase {
    func run(_ fps: Int, _ k: Int64, _ label: String, _ range: (CMTime) -> CMTimeRange) throws {
        let harness = try ExportHarness()
        defer { harness.remove() }
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
        let r = range(CMTime(value: k, timescale: CMTimeScale(fps)))
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = r
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: CompositionVideoSource.videoSettings)
        output.videoComposition = built.videoComposition
        reader.add(output)
        reader.startReading()
        var n = 0
        var first = CMTime.invalid
        var last = CMTime.invalid
        let done = DispatchSemaphore(value: 0)
        let box = UncheckedSendable(output)
        DispatchQueue.global().async {
            while let s = box.value.copyNextSampleBuffer() {
                n += 1
                if n == 1 { first = CMSampleBufferGetPresentationTimeStamp(s) }
                last = CMSampleBufferGetPresentationTimeStamp(s)
            }
            done.signal()
        }
        let timedOut = done.wait(timeout: .now() + 10) == .timedOut
        print("DIAG \(fps)x\(k) \(label) [\(r.start.seconds), \(r.end.seconds)] frames=\(n) first=\(first.value)/\(first.timescale) last=\(last.value)/\(last.timescale) timedOut=\(timedOut) status=\(reader.status.rawValue) err=\(String(describing: reader.error))")
        if timedOut { Thread.sleep(forTimeInterval: 1000) }
        built.releaseMedia()
    }
    func t(_ v: Int64, _ s: Int32) -> CMTime { CMTime(value: v, timescale: s) }
    func test01_60x179_1s() throws { try run(60, 179, "1s-end") { CMTimeRange(start: self.t(1, 1), end: $0) } }
    func test02_60x179_2s_178() throws { try run(60, 179, "2s-178") { _ in CMTimeRange(start: self.t(2, 1), end: self.t(178, 60)) } }
    func test03_60x179_2_5s() throws { try run(60, 179, "2.5s-end") { CMTimeRange(start: self.t(5, 2), end: $0) } }
    func test04_60x179_2s_inf() throws { try run(60, 179, "2s-inf") { _ in CMTimeRange(start: self.t(2, 1), duration: .positiveInfinity) } }
    func test05_30x91_2s() throws { try run(30, 91, "2s-end") { CMTimeRange(start: self.t(2, 1), end: $0) } }
    func test06_60x180_2s() throws { try run(60, 180, "2s-end") { CMTimeRange(start: self.t(2, 1), end: $0) } }
    func test07_60x179_119() throws { try run(60, 179, "119-end") { CMTimeRange(start: self.t(119, 60), end: $0) } }
    func test08_60x179_121() throws { try run(60, 179, "121-end") { CMTimeRange(start: self.t(121, 60), end: $0) } }
    func test09_48x49_half() throws { try run(48, 49, "0.5-end") { CMTimeRange(start: self.t(1, 2), end: $0) } }
    func test10_60x179_2s_dur() throws { try run(60, 179, "2s-dur59") { _ in CMTimeRange(start: self.t(2, 1), duration: self.t(59, 60)) } }
}
