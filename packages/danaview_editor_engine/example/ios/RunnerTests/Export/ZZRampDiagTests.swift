// OWNER: IOS-12 (temporary diagnostic, FIX-IOS-MEDIA)
import AVFoundation
import XCTest
@testable import danaview_editor_engine

final class ZZRampDiagTests: XCTestCase {
    static let speeds: [Double] = [1, 1.25, 1.6, 2, 1.6, 1.25, 1]
    static let segUs: Int64 = 300_000

    func rampPlan() throws -> RenderPlan {
        var s0: Int64 = 500_000
        var map: [String] = []
        for (k, r) in Self.speeds.enumerated() {
            let s1 = s0 + Int64((r * Double(Self.segUs)).rounded())
            map.append("[\(Int64(k) * Self.segUs),\(Int64(k + 1) * Self.segUs),\(s0),\(s1)]")
            s0 = s1
        }
        let dur = Int64(Self.speeds.count) * Self.segUs
        let seg = "{\"id\":\"it_ramp0000001#a\",\"asset\":\"md_tone01000\",\"t\":[0,\(dur)],\"map\":[\(map.joined(separator: ","))],\"gain\":[[0,1]]}"
        let data = ExportPlans.plan(w: 320, h: 180, fps: 30, durUs: dur,
            assets: [ExportPlans.audio("md_tone01000", file: "tone_1khz.wav", durUs: 10_000_000)],
            layers: [ExportPlans.solid("it_bg000000001", t0: 0, t1: dur, color: "#202020FF", w: 320, h: 180, cx: 160, cy: 90)],
            audio: [seg])
        return try RenderPlanDecoder.decodePlan(data)
    }

    func factory(_ roots: TempRoots) throws -> ExportCompositionFactory {
        let paths = try MediaJobTestSupport.paths(roots)
        return { plan in
            let session = try DVRenderSession(snapshots: ParamSnapshotStore(ParamSnapshot(plan: plan)), qos: .userInitiated)
            var options = CompositionBuildOptions(spacerDirectory: paths.engineAssets)
            options.renderSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
            options.useProxies = false
            options.access = SessionMediaAccess()
            options.validate = false
            options.resolveURL = { _, asset in
                let name = URL(string: asset.uri)?.lastPathComponent ?? ""
                return TestFixtures.url(.engine, "media/\(name)")!
            }
            session.configure(&options)
            let input = UncheckedSendable((plan, options))
            let built = try MediaBlocking.await { try await CompositionBuilder.build(plan: input.value.0, options: input.value.1) }
            return ExportComposition(built: built, session: session)
        }
    }

    func testRampReads() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let plan = try rampPlan()
        let make = try factory(roots)
        let dur = plan.durUs
        let n = Int(ProcessInfo.processInfo.environment["RAMP_N"] ?? "") ?? 80
        var bad = 0
        var missed = 0
        var falsePos = 0
        for it in 0..<n {
            let comp = try make(plan)
            defer { comp.release() }
            let src = MixAudioSource(composition: comp, expectAudible: true, control: nil)
            src.validates = false
            src.timePitchWatch = TimePitchWatch.of(plan)
            try src.openAudio(startUs: 0, endUs: dur)
            var pcm: [Float] = []
            var bufInfo: [String] = []
            while let s = try src.nextAudio() {
                let block = CMSampleBufferGetDataBuffer(s)!
                let len = CMBlockBufferGetDataLength(block) / 4
                var f = [Float](repeating: 0, count: len)
                f.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len * 4, destination: $0.baseAddress!) }
                bufInfo.append(String(format: "%.4f+%d", CMSampleBufferGetPresentationTimeStamp(s).seconds, len / 2))
                pcm.append(contentsOf: f)
            }
            src.closeAudio()
            let dumpDir = URL(fileURLWithPath: "/private/tmp/claude-502/-Users-besaoct-Desktop-danaview/6a71d6af-2203-4cdc-90d6-87e7399c6be4/scratchpad/ramp_dump")
            try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            pcm.withUnsafeBytes { try? Data($0).write(to: dumpDir.appendingPathComponent("read_\(it).f32")) }
            let x = stride(from: 0, to: pcm.count, by: 2).map { pcm[$0] }
            let c = Float(2 * cos(2 * Double.pi * 1000 / 48_000))
            var e = [Float](repeating: 0, count: x.count)
            for i in 2..<x.count { e[i] = x[i] - c * x[i - 1] + x[i - 2] }
            func at(_ us: Int64) -> Int { Int(us * 48_000 / 1_000_000) }
            func maxAbs(_ a: Int, _ b: Int) -> (Float, Int) { var m: Float = 0; var w = a; for i in max(2, a)..<min(b, e.count) where abs(e[i]) > m { m = abs(e[i]); w = i }; return (m, w) }
            var floor: Float = 0
            for k in 0..<Self.speeds.count { floor = max(floor, maxAbs(at(Int64(k) * Self.segUs + 50_000), at(Int64(k + 1) * Self.segUs - 50_000)).0) }
            var worst: (Float, Int) = (0, 0)
            for k in 1..<Self.speeds.count { let m = maxAbs(at(Int64(k) * Self.segUs - 40_000), at(Int64(k) * Self.segUs + 40_000)); if m.0 > worst.0 { worst = m } }
            let jumps = comp.built.gainTaps.map(\.rangeDiscontinuities)
            // zero runs
            var runs: [String] = []
            var z = 0
            for i in 0..<x.count { if x[i] == 0 { z += 1 } else { if z >= 8 && i - z > 100 { runs.append("\(i - z)+\(z)") }; z = 0 } }
            let excess = worst.0 - floor
            let isBad = excess > 0.01
            if isBad { bad += 1 }
            if isBad && src.dropouts + src.seamSteps == 0 { missed += 1 }
            if !isBad && src.dropouts + src.seamSteps > 0 { falsePos += 1 }
            print("RAMPDIAG it=\(it) drop=\(src.dropouts)/\(src.seamSteps) \(src.firstTimePitchFault ?? "-") frames=\(x.count) floor=\(floor) worst=\(worst.0)@\(worst.1) excess=\(excess) bad=\(isBad) jumps=\(jumps) zeroRuns=\(runs.prefix(8)) peak=\(src.peak)")
            if isBad {
                let w = worst.1
                var prof: [String] = []
                for blk in stride(from: max(0, w - 480), to: min(w + 480, x.count), by: 24) {
                    var m: Float = 0; var em: Float = 0
                    for i in blk..<min(blk + 24, x.count) { m = max(m, abs(x[i])); em = max(em, abs(e[i])) }
                    prof.append(String(format: "%.3f/%.3f", m, em))
                }
                print("RAMPDIAG profile it=\(it): \(prof.joined(separator: " "))")
                print("RAMPDIAG buffers it=\(it): \(bufInfo.joined(separator: " "))")
            }
        }
        print("RAMPDIAG bad \(bad)/\(n) missed=\(missed) falsePositives=\(falsePos)")
    }
}
