// OWNER: IOS-08
//
// CompositionBuilder acceptance tests (BUILD_PLAN IOS-08): every contract plan builds a valid
// composition; every grid-aligned edit point, scaled duration and instruction range is an exact
// CMTime(k, gridFps) and video source ranges equal the plan's µs (+ ε); the instruction at
// CMTime(k, 30) matches grid_cuts_30fps.expected_active.json for every frame; packing vectors map
// to composition video tracks; tap envelopes equal the plan gain envelopes and gain-only patches
// swap them; ramp audio alternates over two tracks; a no-audio plan has no audio tracks; the
// spacer is generated at runtime; bookmark access is refcounted per session; a 2,000-item plan
// builds within budget.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

final class CompositionBuilderTests: XCTestCase {
    private typealias Support = CompositionTestSupport

    private func videoTracks(_ b: BuiltComposition) -> [AVMutableCompositionTrack] {
        b.composition.tracks(withMediaType: .video)
    }

    /// Non-empty segments of [track].
    private func segments(_ track: AVCompositionTrack) -> [AVCompositionTrackSegment] {
        track.segments.filter { !$0.isEmpty }
    }

    // MARK: Every fixture

    func testEveryContractPlanBuildsAValidExactComposition() async throws {
        let plans = try Support.contractPlans()
        XCTAssertGreaterThanOrEqual(plans.count, 20)
        let options = try await Support.options()
        for (name, plan) in plans {
            let built = try await CompositionBuilder.build(plan: plan, options: options)
            let problems = await built.validate()
            let total = plan.canvas.editGrid.frameIndexOf(plan.durUs)
            if total > 0 { XCTAssertEqual(problems, [], name) }
            try checkExactness(built, name: name)
            try checkInstructions(built, name: name)
            XCTAssertEqual(built.composition.tracks(withMediaType: .audio).count, built.audioLayout.tracks.count, name)
            XCTAssertEqual(built.audioMix == nil, plan.audio.isEmpty, name)
            XCTAssertEqual(
                CMTimeCompare(built.videoComposition.frameDuration, CMTime(value: 1, timescale: CMTimeScale(plan.canvas.fps))), 0, name)
            XCTAssertEqual(built.videoComposition.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
            XCTAssertEqual(built.videoComposition.renderSize, CGSize(width: plan.canvas.w, height: plan.canvas.h))
            print("IOS-08 build \(name): \(String(format: "%.1f", built.buildMs)) ms, warnings \(built.warnings)")
        }
    }

    /// Edit points, scaled durations and source ranges are exact.
    private func checkExactness(_ built: BuiltComposition, name: String) throws {
        let plan = built.plan
        let grid = plan.canvas.editGrid
        let total = grid.frameIndexOf(plan.durUs)
        // Spacer across exactly [0, K).
        if total > 0 {
            let spacer = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.spacerTrackID)), name)
            XCTAssertEqual(CMTimeCompare(spacer.timeRange.start, .zero), 0, name)
            XCTAssertEqual(CMTimeCompare(spacer.timeRange.end, grid.cmTime(frame: total)), 0, "\(name): spacer end")
            XCTAssertEqual(videoTracks(built).count, Set(plan.layers.compactMap(\.seq)).count + 1, name)
        } else {
            XCTAssertNil(built.spacerTrackID)
        }
        // Every media layer map segment: target at CMTime(k0, grid) for CMTime(k1 − k0, grid); source = µs + ε.
        for layer in plan.layers where layer.kind == .media {
            let track = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.trackIDBySeq[layer.seq!])), name)
            let segs = segments(track)
            let pieces = layer.hold ? [layer.map[0]] : layer.map
            for (i, m) in pieces.enumerated() {
                let k0 = grid.frameIndexOf(layer.hold ? layer.t0 : m.t0)
                let k1 = grid.frameIndexOf(layer.hold ? layer.t1 : m.t1)
                guard let seg = segs.first(where: { CMTimeCompare($0.timeMapping.target.start, grid.cmTime(frame: k0)) == 0 }) else {
                    XCTFail("\(name): \(layer.id) piece \(i) not found at frame \(k0)")
                    continue
                }
                let target = seg.timeMapping.target
                XCTAssertEqual(Support.gridFrame(target.start, fps: grid.fps), k0, "\(name) \(layer.id)")
                XCTAssertEqual(CMTimeCompare(target.duration, grid.cmTime(frame: k1 - k0)), 0, "\(name) \(layer.id): scaled duration")
                let source = seg.timeMapping.source
                XCTAssertEqual(CMTimeCompare(source.start, FrameGrid.cmTime(us: m.s0 + CompositionBuilder.epsilonUs)), 0, "\(name) \(layer.id): source start")
                let expectedDuration = layer.hold ? CompositionBuilder.holdSourceUs : m.s1 - m.s0
                if !built.warnings.contains(where: { $0.contains(layer.id) }) {
                    XCTAssertEqual(CMTimeCompare(source.duration, FrameGrid.cmTime(us: expectedDuration)), 0, "\(name) \(layer.id): source duration")
                }
            }
        }
        // Every video edit point on every track is a grid frame.
        for track in videoTracks(built) {
            for seg in track.segments {
                XCTAssertNotNil(Support.gridFrame(seg.timeMapping.target.start, fps: grid.fps), "\(name): video edit point off grid")
                XCTAssertNotNil(Support.gridFrame(seg.timeMapping.target.end, fps: grid.fps), "\(name): video edit end off grid")
            }
        }
        // Plain (non-ramp) audio pieces start and end on the grid; their sources start at the plan µs.
        for track in built.composition.tracks(withMediaType: .audio) {
            let index = try XCTUnwrap(built.audioTrackIDs.firstIndex(of: track.trackID))
            guard !built.audioLayout.tracks[index].isRampPair else { continue }
            for seg in segments(track) {
                XCTAssertNotNil(Support.gridFrame(seg.timeMapping.target.start, fps: grid.fps), "\(name): audio edit point off grid")
                XCTAssertNotNil(Support.gridFrame(seg.timeMapping.target.end, fps: grid.fps), "\(name): audio edit end off grid")
                let us = seg.timeMapping.source.start
                XCTAssertEqual(CMTimeCompare(us, FrameGrid.cmTime(us: FrameGrid.us(us))), 0, "\(name): audio source is plan µs")
            }
        }
    }

    /// Instructions are contiguous grid ranges over [0, K), bottom → top with the right tracks.
    private func checkInstructions(_ built: BuiltComposition, name: String) throws {
        let plan = built.plan
        let grid = plan.canvas.editGrid
        let total = grid.frameIndexOf(plan.durUs)
        let specs = built.instructions
        XCTAssertEqual(built.videoComposition.instructions.count, specs.count)
        guard total > 0 else { return XCTAssertTrue(specs.isEmpty, name) }
        XCTAssertEqual(specs.first?.startFrame, 0, name)
        XCTAssertEqual(specs.last?.endFrame, total, name)
        let order = Dictionary(uniqueKeysWithValues: plan.layers.enumerated().map { ($1.id, $0) })
        for (i, s) in specs.enumerated() {
            if i > 0 { XCTAssertEqual(s.startFrame, specs[i - 1].endFrame, name) }
            XCTAssertLessThan(s.startFrame, s.endFrame)
            let range = built.videoComposition.instructions[i].timeRange
            XCTAssertEqual(Support.gridFrame(range.start, fps: grid.fps), s.startFrame, name)
            XCTAssertEqual(Support.gridFrame(range.end, fps: grid.fps), s.endFrame, name)
            XCTAssertEqual(range.start.timescale, CMTimeScale(grid.fps), "\(name): instruction timescale is gridFps")
            let idx = s.layerIds.map { order[$0]! }
            XCTAssertEqual(idx, idx.sorted(), "\(name): bottom → top")
            let t = grid.timeOfFrame(s.startFrame)
            XCTAssertEqual(Set(s.layerIds), Set(plan.layers.filter { $0.covers(t) }.map(\.id)), "\(name) frame \(s.startFrame)")
            for id in s.layerIds {
                let l = plan.layers[order[id]!]
                if l.kind == .media {
                    XCTAssertEqual(s.trackIDByLayer[id], built.trackIDBySeq[l.seq!])
                    XCTAssertTrue(s.requiredTrackIDs.contains(built.trackIDBySeq[l.seq!]!))
                }
            }
            let instruction = try XCTUnwrap(built.videoComposition.instructions[i] as? LayerInstruction)
            XCTAssertEqual(instruction.requiredSourceTrackIDs?.count ?? 0, s.requiredTrackIDs.count)
        }
    }

    // MARK: D-35 grid cuts

    func testInstructionAtEveryFrameOfGridCutsMatchesExpectedActive() async throws {
        let plan = try Support.plan("grid_cuts_30fps.json")
        let built = try await CompositionBuilder.build(plan: plan, options: try await Support.options())
        let expected = try Support.json(.core, "render_plans/contract/grid_cuts_30fps.expected_active.json")
        let frames = try XCTUnwrap(expected["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 90)
        for f in frames {
            let k = (f["k"] as! NSNumber).int64Value
            let want = Set(f["active"] as! [String])
            let spec = try XCTUnwrap(built.instruction(at: CMTime(value: k, timescale: 30)), "frame \(k)")
            XCTAssertEqual(Set(spec.layerIds), want, "frame \(k)")
            // The AVFoundation instruction objects agree (what the compositor will be handed).
            let objects = built.videoComposition.instructions.compactMap { $0 as? LayerInstruction }
            let hit = objects.filter { CMTimeRangeContainsTime($0.timeRange, time: CMTime(value: k, timescale: 30)) }
            XCTAssertEqual(hit.count, 1, "frame \(k)")
            XCTAssertEqual(Set(hit.first?.layerIds ?? []), want, "frame \(k)")
        }
        // Boundaries at frames ≡ 1 and 2 (mod 3).
        XCTAssertEqual(built.instructions.map(\.startFrame), [0, 31, 32, 61, 62])
    }

    // MARK: Packing

    func testPackingVectorsMapToCompositionTracks() async throws {
        let doc = try Support.json(.core, "vectors/packing.json")
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        var options = try await Support.options()
        options.validate = false
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let inputs = try XCTUnwrap(c["inputs"] as? [[String: Any]])
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let seqs = try XCTUnwrap(expected["seq"] as? [String: NSNumber])
            let slotCount = (expected["slotCount"] as! NSNumber).intValue
            guard !inputs.isEmpty else { continue }
            var layers: [PlanLayer] = []
            for i in inputs {
                let id = i["id"] as! String
                let t0 = (i["t0"] as! NSNumber).int64Value
                let t1 = (i["t1"] as! NSNumber).int64Value
                layers.append(
                    PlanLayer(
                        id: id, z: (i["z"] as! NSNumber).intValue, seq: seqs[id]!.intValue, t0: t0, t1: t1, kind: .media,
                        asset: "md_v", map: [MapSegment(t0, t1, 0, min(t1 - t0, 60_000_000))]))
            }
            layers.sort(by: PlanLayer.drawOrder)
            let plan = RenderPlan(
                rev: 1, target: .preview, canvas: PlanCanvas(w: 640, h: 360, fps: 30), durUs: layers.map(\.t1).max()!,
                assets: ["md_v": PlanAsset(kind: .video, uri: "file:///v.mp4")], layers: layers, audio: [])
            let built = try await CompositionBuilder.build(plan: plan, options: options)
            XCTAssertEqual(built.trackIDBySeq.count, slotCount, name)
            XCTAssertEqual(videoTracks(built).count, slotCount + 1, "\(name): one track per slot plus the spacer")
            for l in layers {
                let track = try XCTUnwrap(built.composition.track(withTrackID: built.trackIDBySeq[l.seq!]!))
                let k0 = plan.canvas.editGrid.frameIndexOf(l.t0)
                XCTAssertTrue(
                    segments(track).contains { CMTimeCompare($0.timeMapping.target.start, CMTime(value: k0, timescale: 30)) == 0 },
                    "\(name): \(l.id) on the track of seq \(l.seq!)")
            }
        }
    }

    // MARK: Audio

    func testTapEnvelopesEqualThePlanGainEnvelopes() async throws {
        let options = try await Support.options()
        for name in ["audio_gain_envelopes.json", "overlay_pip_chroma_mask.json", "speed_ramp_multi_segment.json", "transition_cross_dissolve.json"] {
            let plan = try Support.plan(name)
            let built = try await CompositionBuilder.build(plan: plan, options: options)
            XCTAssertEqual(built.gainTaps.count, built.audioLayout.tracks.count)
            for (i, track) in built.audioLayout.tracks.enumerated() {
                let envelope = built.gainTaps[i].envelope
                for id in track.segmentIds {
                    let seg = plan.audio.first { $0.id == id }!
                    var t = seg.t0
                    while t < seg.t1 {
                        let want = Keyframes.evaluate(seg.gain, at: t, fallback: 1)
                        XCTAssertEqual(envelope.envelopeGain(atUs: Double(t)), want, accuracy: 1e-9, "\(name) \(id) at \(t)")
                        t += 997
                    }
                    for k in seg.gain where k.tUs >= seg.t0 && k.tUs < seg.t1 {
                        XCTAssertEqual(envelope.envelopeGain(atUs: Double(k.tUs)), k.v, accuracy: 1e-12, "\(name) key at \(k.tUs)")
                    }
                }
            }
            // Every input parameter has a tap and the right time-pitch algorithm.
            let params = try XCTUnwrap(built.audioMix?.inputParameters)
            XCTAssertEqual(params.count, built.audioLayout.tracks.count)
            for (i, p) in params.enumerated() {
                XCTAssertNotNil(p.audioTapProcessor, name)
                XCTAssertEqual(p.audioTimePitchAlgorithm, built.audioLayout.tracks[i].pitch ? .timeDomain : .varispeed, name)
                XCTAssertEqual(p.trackID, built.audioTrackIDs[i])
            }
        }
    }

    func testGainOnlyPatchSwapsTheTapEnvelope() async throws {
        let plan = try Support.plan("audio_gain_envelopes.json")
        let built = try await CompositionBuilder.build(plan: plan, options: try await Support.options())
        var upsert = plan.audio[0]
        upsert.gain = [AnimKey(upsert.t0, 0.25), AnimKey(upsert.t1, 2)]
        let patch = RenderPlanPatch(from: plan.rev, to: plan.rev + 1, audio: PatchSet(upsert: [upsert]))
        XCTAssertEqual(PlanPatching.classify(patch, from: plan), .paramOnly)
        let next = try PlanPatching.apply(patch, to: plan)
        let track = try XCTUnwrap(built.audioLayout.tracks.firstIndex { $0.segmentIds.contains(upsert.id) })
        let before = built.gainTaps[track].envelope
        XCTAssertTrue(built.updateGains(next))
        let after = built.gainTaps[track].envelope
        XCTAssertFalse(before === after)
        let mid = (upsert.t0 + upsert.t1) / 2
        XCTAssertEqual(after.envelopeGain(atUs: Double(mid)), Keyframes.evaluate(upsert.gain, at: mid, fallback: 1), accuracy: 1e-9)
        // A structural change cannot be applied as a gain swap.
        var removed = next
        removed.audio.removeFirst()
        XCTAssertFalse(built.updateGains(removed))
    }

    func testRampAudioAlternatesAcrossTwoTracksWithSeamCrossfades() async throws {
        let plan = try Support.plan("speed_ramp_multi_segment.json")
        var options = try await Support.options()
        options.rampSeamCrossfades = true
        let built = try await CompositionBuilder.build(plan: plan, options: options)
        let seg = plan.audio[0]
        XCTAssertEqual(built.audioLayout.tracks.count, 2)
        XCTAssertTrue(built.audioLayout.tracks.allSatisfy { $0.isRampPair && !$0.pitch })
        let half = TapEnvelope.seamCrossfadeUs / 2
        for (k, piece) in built.audioLayout.pieces.enumerated() {
            XCTAssertEqual(piece.track, k % 2)
            XCTAssertEqual(piece.preUs, k > 0 ? half : 0)
            XCTAssertEqual(piece.postUs, k < seg.map.count - 1 ? half : 0)
        }
        let boundaries = seg.map.dropFirst().map(\.t0)
        for (i, tap) in built.gainTaps.enumerated() {
            XCTAssertEqual(tap.envelope.seams, TapEnvelope.alternatingSeams(boundariesUs: Array(boundaries), track: i))
        }
        // Track 0's first piece ends 2.5 ms after the first seam (the grid frame plus the extension).
        let track0 = try XCTUnwrap(built.composition.track(withTrackID: built.audioTrackIDs[0]))
        let first = try XCTUnwrap(segments(track0).first)
        let expectedEnd = CMTimeAdd(plan.canvas.editGrid.cmTime(gridUs: seg.map[0].t1), FrameGrid.cmTime(us: half))
        XCTAssertEqual(CMTimeCompare(first.timeMapping.target.end, expectedEnd), 0)
        XCTAssertEqual(segments(track0).count, (seg.map.count + 1) / 2)

        // Without the option the ramp stays on one track, per-segment scaled.
        options.rampSeamCrossfades = false
        let single = try await CompositionBuilder.build(plan: plan, options: options)
        XCTAssertEqual(single.audioLayout.tracks.count, 1)
        XCTAssertEqual(segments(try XCTUnwrap(single.composition.track(withTrackID: single.audioTrackIDs[0]))).count, seg.map.count)
    }

    func testIntervalColouringByPitch() {
        func seg(_ id: String, _ t0: Int64, _ t1: Int64, pitch: Bool = true) -> AudioSeg {
            AudioSeg(id: id, asset: "a", t0: t0, t1: t1, map: [MapSegment(t0, t1, 0, t1 - t0)], gain: [AnimKey(0, 1)], pitch: pitch)
        }
        let plan = RenderPlan(
            rev: 1, target: .preview, canvas: PlanCanvas(w: 64, h: 64, fps: 30), durUs: 3_000_000,
            assets: ["a": PlanAsset(kind: .audio, uri: "file:///a.wav")],
            layers: [],
            audio: [seg("a1", 0, 1_000_000), seg("a2", 0, 2_000_000), seg("v1", 0, 1_000_000, pitch: false), seg("a3", 1_000_000, 3_000_000)])
        let layout = AudioMixLayout.make(plan, rampSeams: true)
        XCTAssertEqual(layout.tracks.count, 3)
        XCTAssertEqual(layout.tracks[0].segmentIds, ["a1", "a3"])
        XCTAssertEqual(layout.tracks[1].segmentIds, ["a2"])
        XCTAssertEqual(layout.tracks[2].segmentIds, ["v1"])
        XCTAssertFalse(layout.tracks[2].pitch)
    }

    func testNoAudioPlanBuildsWithoutAudioTracks() async throws {
        for name in ["no_audio_export.json", "grid_cuts_30fps.json", "image_solid_layers.json"] {
            let plan = try Support.plan(name)
            XCTAssertTrue(plan.audio.isEmpty)
            let built = try await CompositionBuilder.build(plan: plan, options: try await Support.options())
            XCTAssertTrue(built.composition.tracks(withMediaType: .audio).isEmpty, name)
            XCTAssertNil(built.audioMix, name)
            XCTAssertTrue(built.gainTaps.isEmpty, name)
            XCTAssertTrue(built.updateGains(plan), name)
        }
        let empty = try Support.plan("empty_plan.json")
        let built = try await CompositionBuilder.build(plan: empty, options: try await Support.options())
        XCTAssertTrue(built.composition.tracks.isEmpty)
        XCTAssertTrue(built.instructions.isEmpty)
    }

    // MARK: Spacer, hold

    func testSpacerIsGeneratedAtRuntime() async throws {
        let dir = try Support.spacerDirectory(fresh: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = try await Support.options()
        options.spacerDirectory = dir
        let plan = try Support.plan("image_solid_layers.json")
        let built = try await CompositionBuilder.build(plan: plan, options: options)
        let url = dir.appendingPathComponent(SpacerVideo.fileName)
        XCTAssertEqual(SpacerVideo.fileName, "spacer_16x16_v1.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 16, height: 16))
        let total = plan.canvas.editGrid.frameIndexOf(plan.durUs)
        let spacer = try XCTUnwrap(built.composition.track(withTrackID: try XCTUnwrap(built.spacerTrackID)))
        XCTAssertEqual(CMTimeCompare(spacer.timeRange.duration, CMTime(value: total, timescale: CMTimeScale(plan.canvas.gridFps))), 0)
        // A second build reuses the file.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        _ = try await CompositionBuilder.build(plan: plan, options: options)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

    // MARK: Security-scoped access

    func testBookmarkAccessIsRefcountedPerSession() async throws {
        var begins: [URL] = []
        var ends: [URL] = []
        let lock = NSLock()
        let access = SessionMediaAccess(
            begin: { url in lock.lock(); begins.append(url); lock.unlock() },
            end: { url in lock.lock(); ends.append(url); lock.unlock() })
        let media = try await Support.syntheticMedia()
        let bookmark = try media.bookmarkData().base64EncodedString()
        var plan = try Support.plan("minimal_preview.json")
        plan.assets["md_clipA00000001"]?.uri = media.absoluteString
        plan.assets["md_clipA00000001"]?.bookmark = bookmark
        let resolved = try MediaURLResolver.resolve(plan.assets["md_clipA00000001"]!, useProxies: false)
        XCTAssertTrue(resolved.scoped)

        var options = CompositionBuildOptions(spacerDirectory: try Support.spacerDirectory())
        options.access = access
        options.validate = false
        let first = try await CompositionBuilder.build(plan: plan, options: options)
        XCTAssertEqual(access.count(resolved.url), 1)
        // A structural rebuild takes its lease before the old composition releases its own.
        let second = try await CompositionBuilder.build(plan: plan, options: options)
        XCTAssertEqual(access.count(resolved.url), 2)
        first.releaseMedia()
        first.releaseMedia()
        XCTAssertEqual(access.count(resolved.url), 1)
        XCTAssertEqual(begins.count, 1, "process-wide access starts once per session")
        XCTAssertTrue(ends.isEmpty)
        second.releaseMedia()
        XCTAssertEqual(access.count(resolved.url), 0)
        XCTAssertEqual(ends.count, 1)

        // Proxies win when requested; plain file URIs need no scope.
        var proxied = plan.assets["md_clipA00000001"]!
        proxied.proxyUri = "file:///proxy.mp4"
        XCTAssertEqual(try MediaURLResolver.resolve(proxied, useProxies: true).url.path, "/proxy.mp4")
        proxied.bookmark = nil
        XCTAssertFalse(try MediaURLResolver.resolve(proxied, useProxies: false).scoped)
        proxied.uri = "content://media/1"
        XCTAssertThrowsError(try MediaURLResolver.resolve(proxied, useProxies: false))
    }

    // MARK: Queue entry point

    func testBuildCompletesOnTheGivenQueue() async throws {
        let queue = DispatchQueue(label: "ios08.previewControl")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let plan = try Support.plan("minimal_preview.json")
        let options = try await Support.options()
        let onQueue: Bool = try await withCheckedThrowingContinuation { cont in
            CompositionBuilder.build(plan: plan, options: options, queue: queue) { result in
                switch result {
                case .success: cont.resume(returning: DispatchQueue.getSpecific(key: key) == true)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        XCTAssertTrue(onQueue)
    }

    // MARK: Budget

    func testTwoThousandItemPlanBuildsWithinBudget() async throws {
        // 2,000 clips of 15 frames (video layer + audio segment each) over two packing slots.
        var layers: [PlanLayer] = []
        var audio: [AudioSeg] = []
        let frameUs = 1_000_000.0 / 30
        func t(_ k: Int64) -> Int64 { FrameGrid(30).timeOfFrame(k) }
        for i in 0..<2_000 {
            let k0 = Int64(i * 15)
            let k1 = k0 + 15
            let s0 = Int64(i % 100) * 500_000
            let len = t(k1) - t(k0)
            layers.append(
                PlanLayer(
                    id: String(format: "it_%06d#v", i), z: 10, seq: i % 2, t0: t(k0), t1: t(k1), kind: .media, asset: "md_v",
                    map: [MapSegment(t(k0), t(k1), s0, s0 + len)], base: PlanSize(w: 1920, h: 1080)))
            audio.append(
                AudioSeg(
                    id: String(format: "it_%06d#a", i), asset: "md_v", t0: t(k0), t1: t(k1), map: [MapSegment(t(k0), t(k1), s0, s0 + len)],
                    gain: [AnimKey(t(k0), 1)]))
        }
        _ = frameUs
        layers.sort(by: PlanLayer.drawOrder)
        audio.sort(by: AudioSeg.order)
        let plan = RenderPlan(
            rev: 1, target: .preview, canvas: PlanCanvas(w: 1920, h: 1080, fps: 30), durUs: t(30_000),
            assets: ["md_v": PlanAsset(kind: .video, uri: "file:///v.mp4", hasAudio: true)], layers: layers, audio: audio)
        XCTAssertEqual(PlanValidator.validate(plan), [])
        var options = try await Support.options()
        options.validate = false
        // Warm-up (asset open, spacer), then measure.
        _ = try await CompositionBuilder.build(plan: plan, options: options)
        var full: [Double] = []
        var assemble: [Double] = []
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            let sources = try await CompositionBuilder.loadSources(plan: plan, options: options)
            let mid = CFAbsoluteTimeGetCurrent()
            let built = try CompositionBuilder.assemble(plan: plan, sources: sources, options: options, startedAt: mid)
            let end = CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(built.instructions.count, 2_000)
            full.append((end - start) * 1000)
            assemble.append((end - mid) * 1000)
        }
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let decoded = try RenderPlanDecoder.decodePlan(PlanEncoder.encode(plan))
        let decodeMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
        XCTAssertEqual(decoded.layers.count, 2_000)
        let medianFull = full.sorted()[1]
        let medianAssemble = assemble.sorted()[1]
        print("IOS-08 2000-item build (simulator): full p50 \(String(format: "%.1f", medianFull)) ms, assemble p50 \(String(format: "%.1f", medianAssemble)) ms, encode+decode \(String(format: "%.1f", decodeMs)) ms")
        PerfGate.assertAtMost(medianFull, 150, "2,000-item build budget (ARCH §18.2, mid tier)")
    }
}
