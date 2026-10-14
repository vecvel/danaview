// OWNER: IOS-10
//
// Render parity (BUILD_PLAN IOS-10, ARCH §11.6): every frame of every API-03 reference golden
// (engine_api/images/goldens.json, ~30 plans incl. the 8× scale-keyframed text sprite and the
// typewriter reveal) rendered through DVRenderSession.render — the compositor's own render path,
// Metal CIContext, BGRA output buffer — with the golden's synthetic sources, compared with the Dart
// reference: mean |Δ| ≤ 1.5/255 per channel and p99 ≤ 6/255 with layer edges excluded, SSIM ≥ 0.98
// on the transform fixtures. Device runs are QA-03's.

import AVFoundation
import CoreImage
import XCTest

@testable import danaview_editor_engine

final class RenderParityTests: XCTestCase {
    private typealias Support = CompositorTestSupport

    /// Fixtures whose content is mostly placement (ARCH §11.6: SSIM is required on transform fixtures).
    private static let transformFixtures: Set<String> = [
        "api03_place", "api03_text_scale_8x", "transition_slide", "transition_zoom", "anim_every_channel",
    ]

    func testEveryGoldenFrameMatchesTheReference() throws {
        let root = try Support.imagesRoot()
        let goldens = try Support.goldens()
        XCTAssertGreaterThanOrEqual(goldens.count, 25)
        var failures: [String] = []
        var report: [String] = []
        var frames = 0
        for g in goldens {
            let assets = Support.GoldenAssets(root: root, sources: g.sources)
            let snapshot = ParamSnapshot(plan: g.plan)
            let session = try Support.session(snapshot: snapshot, assets: assets)
            for f in g.frames {
                let got = try render(session: session, snapshot: snapshot, k: f.k, assets: assets, size: g.size)
                frames += 1
                let want = try Support.pngRGBA(root.appendingPathComponent(f.png))
                XCTAssertEqual(want.w, g.size.w)
                XCTAssertEqual(want.h, g.size.h)
                if let dir = ProcessInfo.processInfo.environment["DANAVIEW_PARITY_DUMP"] {
                    Support.writePNG(got.px, w: g.size.w, h: g.size.h, to: URL(fileURLWithPath: dir).appendingPathComponent("\(g.name)_\(f.k)_got.png"))
                    Support.writePNG(want.px, w: g.size.w, h: g.size.h, to: URL(fileURLWithPath: dir).appendingPathComponent("\(g.name)_\(f.k)_want.png"))
                }
                let exclude = Support.edgeMask(snapshot: snapshot, k: f.k, w: g.size.w, h: g.size.h)
                let p = Support.parity(got.px, want.px, w: g.size.w, h: g.size.h, exclude: exclude)
                let line = String(
                    format: "%@ k=%lld mean=%.2f/255 p99=%.2f/255 ssim=%.4f excl=%d drawn=%@", g.name, f.k, p.mean * 255,
                    p.p99 * 255, p.ssim, p.excluded, got.drawn.joined(separator: ","))
                report.append(line)
                var bad: [String] = []
                if p.mean > 1.5 / 255 + 1e-9 { bad.append("mean") }
                if p.p99 > 6.0 / 255 + 1e-9 { bad.append("p99") }
                if Self.transformFixtures.contains(g.name) && p.ssim < 0.98 { bad.append("ssim") }
                if got.drawn != f.layers { bad.append("layers \(got.drawn) != \(f.layers)") }
                if !bad.isEmpty { failures.append("\(line) [\(bad.joined(separator: ", "))]") }
            }
        }
        print("IOS-10 parity (\(frames) frames):\n" + report.joined(separator: "\n"))
        XCTAssertGreaterThan(frames, 80)
        XCTAssertTrue(failures.isEmpty, "parity failures:\n" + failures.joined(separator: "\n"))
    }

    /// One golden frame through the compositor's render path: each media layer's synthetic frame is
    /// turned into a BGRA buffer in ENCODED orientation (the inverse of the asset's `rot`, as a decoder
    /// delivers it) on its own track, so the Metal source path and the display rotation are exercised.
    private func render(session: DVRenderSession, snapshot: ParamSnapshot, k: Int64, assets: Support.GoldenAssets,
                        size: (w: Int, h: Int)) throws -> (px: [UInt8], drawn: [String]) {
        var sources = DVRenderSession.Sources.none
        var track: CMPersistentTrackID = 1
        for layer in snapshot.evaluate(atFrame: k) where layer.kind == .media {
            guard let display = assets.media(layer) else { continue }
            let rot = layer.asset.flatMap { snapshot.plan.assets[$0]?.rot } ?? 0
            sources.buffers[track] = try Support.pixelBuffer(from: Support.encoded(display, rotation: rot), context: session.context)
            sources.trackIDByLayer[layer.id] = track
            track += 1
        }
        let pb = try Support.pixelBuffer(width: size.w, height: size.h)
        let output = try session.render(snapshot: snapshot, frame: k, sources: sources, mode: .normal, into: pb)
        XCTAssertEqual(DVRenderSession.frameIndex(of: pb), k)
        return (Support.rgba(pb).px, output.drawn)
    }
}
