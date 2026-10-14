// OWNER: IOS-08
//
// CompositionBuilder (ARCH §13.2 'Composition' and 'Audio', §11.5, D-04, D-35, D-37): turns a
// RenderPlan into the AVMutableComposition, the AVMutableVideoComposition (custom compositor,
// per-boundary instructions) and the AVMutableAudioMix (one GainTap per audio track) that a preview
// item or an export reader plays.
//
// Video. One AVURLAsset per media asset (`AVURLAssetPreferPreciseDurationAndTimingKey`, tracks
// loaded with `loadTracks`), RETAINED for the composition's lifetime (holding only the AVAssetTrack
// makes every insertTimeRange fail with -11800 / Fig -12780, IOS-01). Media layers go to the
// composition video track named by their `seq` (CORE-36 packing). Per map segment:
// `insertTimeRange(source shifted by +500 µs (ε, D-04), at: CMTime(k0, gridFps))`, then
// `scaleTimeRange` of that range to `CMTime(k1 − k0, gridFps)`. Grid times are never converted to µs
// CMTimes (D-35); source ranges stay `CMTime(µs, 1_000_000)`. `hold` layers insert a 100 µs source
// range at `map[0].s0 + ε` scaled across the whole layer (the compositor sees that one frame).
// A runtime-generated 16×16 spacer (SpacerVideo) is scaled across `CMTime(0…K, gridFps)` so the
// compositor runs for every output frame, gaps included. Images, solids and sprites are compositor
// layers only.
//
// Audio. Segments are laid out by AudioMixLayout (interval colouring × pitch, ramp-seam pairs).
// Audio is sample-accurate (no ε): a unity-rate piece inserts its source start with the GRID
// duration (no time-pitch pass at a rate of 1 ± 10⁻⁶); other pieces insert the exact source µs and
// are scaled to the grid duration. Each track's AVMutableAudioMixInputParameters uses `.timeDomain`
// (pitch kept) or `.varispeed` and an IOS-18 GainTap carrying the plan envelope.
//
// Threading: `loadSources` is async (AVFoundation loading); `assemble` is synchronous and runs on
// the caller's queue (`previewControlQueue` for preview, the export queue for export).

import AVFoundation
import CoreGraphics
import Foundation

/// Options of one build.
struct CompositionBuildOptions {
    /// Directory of the spacer video (`Paths.engineAssets`).
    var spacerDirectory: URL
    /// Compositor render size (default: the canvas, i.e. full quality / export size).
    var renderSize: CGSize?
    /// Read `proxyUri` instead of the original when an asset has one (preview only).
    var useProxies = false
    /// The custom compositor (IOS-10's DVCompositor). Nil leaves AVFoundation's default.
    var compositorClass: AVVideoCompositing.Type?
    /// Makes the instruction objects (IOS-10 passes its DVInstruction); default `LayerInstruction`.
    var makeInstruction: (InstructionSpec) -> AVVideoCompositionInstructionProtocol = { LayerInstruction(spec: $0) }
    /// Resolves an asset to a URL (default `MediaURLResolver`; tests map fixtures to local media).
    var resolveURL: ((String, PlanAsset) throws -> URL)?
    /// Session-scoped access for bookmarked media (nil: no leases taken).
    var access: SessionMediaAccess?
    /// Lay speed-ramp audio out with IOS-18's ramp-seam crossfades.
    var rampSeamCrossfades = TapEnvelope.rampSeamCrossfadesEnabled
    /// Validate the video composition (`isValid`) after building; on by default in debug builds.
    var validate: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    init(spacerDirectory: URL) {
        self.spacerDirectory = spacerDirectory
    }
}

/// Loaded sources of a plan: assets (retained), their tracks and the spacer.
struct CompositionSources {
    struct Media {
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let videoRange: CMTimeRange?
        let audio: [AVAssetTrack]
        let audioRanges: [CMTimeRange]
    }

    let media: [String: Media]
    let spacer: AVURLAsset?
    let spacerTrack: AVAssetTrack?
    let spacerRange: CMTimeRange?
    let lease: MediaLease?
}

/// A composition built from a plan, with everything that must stay alive while it plays.
final class BuiltComposition {
    let plan: RenderPlan
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    /// Nil for a plan without audio (no audio tracks at all).
    let audioMix: AVMutableAudioMix?
    /// Composition video track per CORE-36 slot.
    let trackIDBySeq: [Int: CMPersistentTrackID]
    let spacerTrackID: CMPersistentTrackID?
    let instructions: [InstructionSpec]
    let audioLayout: AudioMixLayout
    /// Composition audio track id and gain tap per `audioLayout.tracks` entry.
    let audioTrackIDs: [CMPersistentTrackID]
    let gainTaps: [GainTap]
    /// Non-fatal issues (clamped source ranges, missing audio streams), without paths.
    let warnings: [String]
    let buildMs: Double
    /// Retains the assets (IOS-01: they must outlive the composition) and the media leases.
    let sources: CompositionSources

    fileprivate init(
        plan: RenderPlan, composition: AVMutableComposition, videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix?, trackIDBySeq: [Int: CMPersistentTrackID], spacerTrackID: CMPersistentTrackID?,
        instructions: [InstructionSpec], audioLayout: AudioMixLayout, audioTrackIDs: [CMPersistentTrackID],
        gainTaps: [GainTap], warnings: [String], buildMs: Double, sources: CompositionSources
    ) {
        self.plan = plan
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.trackIDBySeq = trackIDBySeq
        self.spacerTrackID = spacerTrackID
        self.instructions = instructions
        self.audioLayout = audioLayout
        self.audioTrackIDs = audioTrackIDs
        self.gainTaps = gainTaps
        self.warnings = warnings
        self.buildMs = buildMs
        self.sources = sources
    }

    /// The instruction covering [time].
    func instruction(at time: CMTime) -> InstructionSpec? { InstructionBuilder.lookup(instructions, at: time) }

    /// Gain-only patch (ARCH §11.2): swaps every tap's envelope for [plan]'s gains. Returns false
    /// (nothing swapped) when [plan]'s audio no longer matches the layout (rebuild instead).
    @discardableResult
    func updateGains(_ plan: RenderPlan) -> Bool {
        var next: [TapEnvelope] = []
        for i in audioLayout.tracks.indices {
            guard let e = audioLayout.envelope(track: i, plan: plan) else { return false }
            next.append(e)
        }
        for (tap, envelope) in zip(gainTaps, next) { tap.swapEnvelope(envelope) }
        return true
    }

    /// Releases the media leases now (they are also released when this object goes away).
    func releaseMedia() { sources.lease?.release() }

    /// AVFoundation's validation of the video composition against the composition (ARCH §13.2:
    /// `isValid` in debug). Returns the problems found (empty = valid).
    func validate() async -> [String] {
        let collector = CompositionValidationCollector()
        let range = CMTimeRange(start: .zero, duration: composition.duration)
        let ok: Bool
        if #available(iOS 18.0, *) {
            ok = videoComposition.isValid(
                for: composition.tracks, assetDuration: composition.duration, timeRange: range,
                validationDelegate: collector)
        } else if #available(iOS 16.0, *) {
            ok = (try? await videoComposition.isValid(for: composition, timeRange: range, validationDelegate: collector)) ?? false
        } else {
            ok = videoComposition.isValid(for: composition, timeRange: range, validationDelegate: collector)
        }
        var problems = collector.problems
        if !ok && problems.isEmpty { problems.append("isValid returned false") }
        return problems
    }
}

/// Collects `AVVideoCompositionValidationHandling` reports.
final class CompositionValidationCollector: NSObject, AVVideoCompositionValidationHandling {
    private let lock = NSLock()
    private var _problems: [String] = []

    var problems: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _problems
    }

    private func add(_ p: String) {
        lock.lock()
        _problems.append(p)
        lock.unlock()
    }

    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        add("invalid value for \(key)")
        return true
    }

    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        add("empty time range at \(timeRange.start.seconds)")
        return true
    }

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoCompositionInstruction: AVVideoCompositionInstructionProtocol
    ) -> Bool {
        add("invalid instruction time range at \(videoCompositionInstruction.timeRange.start.seconds)")
        return true
    }

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingInvalidTrackIDIn videoCompositionInstruction: AVVideoCompositionInstructionProtocol,
        layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset
    ) -> Bool {
        add("invalid track id in an instruction")
        return true
    }
}

enum CompositionBuilder {
    /// ε of D-04: displayed frame = greatest PTS ≤ s + 500 µs.
    static let epsilonUs: Int64 = 500
    /// Source length inserted for a `hold` layer (scaled across the layer).
    static let holdSourceUs: Int64 = 100
    /// Timescale of the composition: exact for every v1 grid (lcm 1200) and for µs.
    static let compositionTimeScale: CMTimeScale = 3_000_000

    // MARK: Entry points

    /// Loads the sources and assembles the composition (async; tests and export).
    static func build(plan: RenderPlan, options: CompositionBuildOptions) async throws -> BuiltComposition {
        let start = CFAbsoluteTimeGetCurrent()
        let sources = try await loadSources(plan: plan, options: options)
        let built = try assemble(plan: plan, sources: sources, options: options, startedAt: start)
        if options.validate {
            let problems = await built.validate()
            if !problems.isEmpty {
                Log.error(.preview, "composition rev \(plan.rev) failed validation: \(problems.prefix(3).joined(separator: "; "))")
            }
        }
        return built
    }

    /// Loads in a task, then assembles on [queue] (`previewControlQueue`) and completes there.
    static func build(
        plan: RenderPlan, options: CompositionBuildOptions, queue: DispatchQueue,
        completion: @escaping (Result<BuiltComposition, Error>) -> Void
    ) {
        let input = UncheckedSendable((plan, options, completion))
        Task {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let sources = UncheckedSendable(try await loadSources(plan: input.value.0, options: input.value.1))
                queue.async {
                    let (plan, options, completion) = input.value
                    let result = Result { try assemble(plan: plan, sources: sources.value, options: options, startedAt: start) }
                    if options.validate, case .success(let built) = result {
                        let box = UncheckedSendable(built)
                        Task {
                            let problems = await box.value.validate()
                            if !problems.isEmpty {
                                Log.error(.preview, "composition failed validation: \(problems.prefix(3).joined(separator: "; "))")
                            }
                        }
                    }
                    completion(result)
                }
            } catch {
                let failure = UncheckedSendable(error)
                queue.async { input.value.2(.failure(failure.value)) }
            }
        }
    }

    // MARK: Loading

    /// Opens one AVURLAsset per referenced media asset and loads its tracks; ensures the spacer.
    static func loadSources(plan: RenderPlan, options: CompositionBuildOptions) async throws -> CompositionSources {
        var needVideo = Set<String>()
        var needAudio = Set<String>()
        for l in plan.layers where l.kind == .media {
            if let a = l.asset { needVideo.insert(a) }
        }
        for s in plan.audio { needAudio.insert(s.asset) }
        var media: [String: CompositionSources.Media] = [:]
        var scopedURLs: [URL] = []
        // Provisional session references: scoped access must be held while AVFoundation opens the
        // files; they are exchanged for the composition's lease below (or dropped on failure).
        defer { if let access = options.access { scopedURLs.forEach(access.release) } }
        for id in needVideo.union(needAudio).sorted() {
            guard let planAsset = plan.assets[id] else {
                throw EngineError(.planInvalid, "asset \(id) missing from the plan")
            }
            let url: URL
            if let resolve = options.resolveURL {
                url = try resolve(id, planAsset)
            } else {
                let resolved = try MediaURLResolver.resolve(planAsset, useProxies: options.useProxies)
                url = resolved.url
                if resolved.scoped, let access = options.access {
                    access.acquire(url)
                    scopedURLs.append(url)
                }
            }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var video: AVAssetTrack?
            var videoRange: CMTimeRange?
            var audio: [AVAssetTrack] = []
            var audioRanges: [CMTimeRange] = []
            do {
                if needVideo.contains(id) {
                    video = try await asset.loadTracks(withMediaType: .video).first
                    guard let v = video else {
                        throw EngineError(.unsupportedMedia, "asset \(id) has no video track", mediaFingerprint: fpOf(planAsset))
                    }
                    videoRange = try await v.load(.timeRange)
                }
                if needAudio.contains(id) {
                    audio = try await asset.loadTracks(withMediaType: .audio)
                    for t in audio { audioRanges.append(try await t.load(.timeRange)) }
                }
            } catch let e as EngineError {
                throw e
            } catch {
                throw EngineError(.mediaOffline, "asset \(id) could not be opened", mediaFingerprint: fpOf(planAsset), retryable: true)
            }
            media[id] = CompositionSources.Media(asset: asset, video: video, videoRange: videoRange, audio: audio, audioRanges: audioRanges)
        }
        let lease = options.access.flatMap { scopedURLs.isEmpty ? nil : $0.lease(scopedURLs) }

        var spacer: AVURLAsset?
        var spacerTrack: AVAssetTrack?
        var spacerRange: CMTimeRange?
        if plan.canvas.editGrid.frameIndexOf(plan.durUs) > 0 {
            let url = try await SpacerVideo.ensure(in: options.spacerDirectory)
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw EngineError(.internal, "spacer has no video track")
            }
            spacer = asset
            spacerTrack = track
            spacerRange = try await track.load(.timeRange)
        }
        return CompositionSources(media: media, spacer: spacer, spacerTrack: spacerTrack, spacerRange: spacerRange, lease: lease)
    }

    private static func fpOf(_ a: PlanAsset) -> String? { a.fp.isEmpty ? nil : a.fp }

    // MARK: Assembly

    /// Builds the composition from loaded [sources] synchronously on the caller's queue.
    static func assemble(
        plan: RenderPlan, sources: CompositionSources, options: CompositionBuildOptions,
        startedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) throws -> BuiltComposition {
        let grid = plan.canvas.editGrid
        let composition = AVMutableComposition()
        composition.naturalSize = CGSize(width: plan.canvas.w, height: plan.canvas.h)
        var warnings: [String] = []
        // End of each track's content (avoids re-reading `segments` on every insertion).
        var ends: [CMPersistentTrackID: CMTime] = [:]

        // Video tracks, one per seq slot in ascending order.
        let mediaLayers = plan.layers.filter { $0.kind == .media }
        let seqs = Set(mediaLayers.compactMap(\.seq)).sorted()
        var tracks: [Int: AVMutableCompositionTrack] = [:]
        for seq in seqs {
            guard let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EngineError(.internal, "cannot add a video track")
            }
            t.naturalTimeScale = compositionTimeScale
            tracks[seq] = t
        }
        let bySeq = Dictionary(grouping: mediaLayers.filter { $0.seq != nil }, by: { $0.seq! })
        for seq in seqs {
            let track = tracks[seq]!
            let layers = bySeq[seq]!.sorted { $0.t0 < $1.t0 }
            for layer in layers {
                guard let id = layer.asset, let src = sources.media[id], let video = src.video, let range = src.videoRange else {
                    throw EngineError(.planInvalid, "media layer \(layer.id) has no loaded video")
                }
                if layer.hold {
                    guard let m0 = layer.map.first else { continue }
                    let k0 = grid.frameIndexOf(layer.t0)
                    let k1 = grid.frameIndexOf(layer.t1)
                    var start = FrameGrid.cmTime(us: m0.s0 + epsilonUs)
                    let maxStart = CMTimeSubtract(range.end, FrameGrid.cmTime(us: holdSourceUs))
                    if CMTimeCompare(start, maxStart) > 0 {
                        start = maxStart
                        warnings.append("hold source clamped on \(layer.id)")
                    }
                    try insertVideo(
                        track: track, source: CMTimeRange(start: start, duration: FrameGrid.cmTime(us: holdSourceUs)),
                        of: video, at: grid.cmTime(frame: k0), target: grid.cmTime(frame: k1 - k0), ends: &ends)
                    continue
                }
                for seg in layer.map {
                    let k0 = grid.frameIndexOf(seg.t0)
                    let k1 = grid.frameIndexOf(seg.t1)
                    guard k1 > k0 else { continue }
                    var source = CMTimeRange(
                        start: FrameGrid.cmTime(us: seg.s0 + epsilonUs), duration: FrameGrid.cmTime(us: seg.s1 - seg.s0))
                    if CMTimeCompare(source.end, range.end) > 0 {
                        // Asset slightly shorter than the plan says: read to its end and scale that.
                        let end = range.end
                        guard CMTimeCompare(source.start, end) < 0 else {
                            warnings.append("source range beyond the asset on \(layer.id)")
                            continue
                        }
                        source = CMTimeRange(start: source.start, end: end)
                        warnings.append("source range clamped on \(layer.id)")
                    }
                    try insertVideo(
                        track: track, source: source, of: video, at: grid.cmTime(frame: k0), target: grid.cmTime(frame: k1 - k0),
                        ends: &ends)
                }
            }
        }

        // Spacer across [0, K).
        var spacerTrackID: CMPersistentTrackID?
        let total = grid.frameIndexOf(plan.durUs)
        if total > 0, let spacerTrack = sources.spacerTrack, let spacerRange = sources.spacerRange {
            guard let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EngineError(.internal, "cannot add the spacer track")
            }
            t.naturalTimeScale = compositionTimeScale
            try t.insertTimeRange(spacerRange, of: spacerTrack, at: .zero)
            t.scaleTimeRange(CMTimeRange(start: .zero, duration: spacerRange.duration), toDuration: grid.cmTime(frame: total))
            spacerTrackID = t.trackID
        }

        // Audio.
        var skip = Set<String>()
        for seg in plan.audio {
            let streams = sources.media[seg.asset]?.audio.count ?? 0
            if seg.stream >= streams {
                skip.insert(seg.id)
                warnings.append("audio stream \(seg.stream) missing for \(seg.id)")
            }
        }
        let layout = AudioMixLayout.make(plan, rampSeams: options.rampSeamCrossfades, skip: skip)
        var audioTracks: [AVMutableCompositionTrack] = []
        for _ in layout.tracks {
            guard let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EngineError(.internal, "cannot add an audio track")
            }
            t.naturalTimeScale = compositionTimeScale
            audioTracks.append(t)
        }
        let segById = Dictionary(plan.audio.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for piece in layout.pieces {
            guard let seg = segById[piece.segmentId], let src = sources.media[seg.asset] else { continue }
            let sourceTrack = src.audio[seg.stream]
            let sourceRange = src.audioRanges[seg.stream]
            if !(try insertAudio(
                piece: piece, track: audioTracks[piece.track], of: sourceTrack, sourceRange: sourceRange, grid: grid,
                ends: &ends)) {
                warnings.append("audio source range clamped on \(seg.id)")
            }
        }
        var gainTaps: [GainTap] = []
        var audioMix: AVMutableAudioMix?
        if !layout.tracks.isEmpty {
            var parameters: [AVMutableAudioMixInputParameters] = []
            for (i, spec) in layout.tracks.enumerated() {
                let tap = GainTap(envelope: layout.envelope(track: i, plan: plan) ?? .unity)
                let p = AVMutableAudioMixInputParameters(track: audioTracks[i])
                p.audioTimePitchAlgorithm = spec.pitch ? .timeDomain : .varispeed
                try tap.attach(to: p)
                parameters.append(p)
                gainTaps.append(tap)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }

        // Instructions and the video composition.
        let trackIDBySeq = tracks.mapValues(\.trackID)
        let specs = InstructionBuilder.build(plan: plan, trackIDBySeq: trackIDBySeq)
        let vc = AVMutableVideoComposition()
        if let compositor = options.compositorClass { vc.customVideoCompositorClass = compositor }
        vc.frameDuration = plan.canvas.outputGrid.frameDuration
        vc.renderSize = options.renderSize ?? CGSize(width: plan.canvas.w, height: plan.canvas.h)
        vc.instructions = specs.map(options.makeInstruction)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

        let built = BuiltComposition(
            plan: plan, composition: composition, videoComposition: vc, audioMix: audioMix, trackIDBySeq: trackIDBySeq,
            spacerTrackID: spacerTrackID, instructions: specs, audioLayout: layout, audioTrackIDs: audioTracks.map(\.trackID),
            gainTaps: gainTaps, warnings: warnings, buildMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000, sources: sources)
        if !warnings.isEmpty { Log.info(.preview, "composition rev \(plan.rev): \(warnings.count) warning(s)") }
        return built
    }

    private static func insertVideo(
        track: AVMutableCompositionTrack, source: CMTimeRange, of sourceTrack: AVAssetTrack, at: CMTime, target: CMTime,
        ends: inout [CMPersistentTrackID: CMTime]
    ) throws {
        padTrack(track, to: at, ends: &ends)
        do {
            try track.insertTimeRange(source, of: sourceTrack, at: at)
        } catch {
            throw EngineError(.decodeFailed, "insertTimeRange failed (\((error as NSError).code))")
        }
        track.scaleTimeRange(CMTimeRange(start: at, duration: source.duration), toDuration: target)
        ends[track.trackID] = CMTimeAdd(at, target)
    }

    /// Inserts one audio piece; false when its source had to be clamped to the asset.
    private static func insertAudio(
        piece: AudioMixLayout.Piece, track: AVMutableCompositionTrack, of sourceTrack: AVAssetTrack,
        sourceRange: CMTimeRange, grid: FrameGrid, ends: inout [CMPersistentTrackID: CMTime]
    ) throws -> Bool {
        let m = piece.segment
        let k0 = grid.frameIndexOf(m.t0)
        let k1 = grid.frameIndexOf(m.t1)
        guard k1 > k0 else { return true }
        let pre = FrameGrid.cmTime(us: piece.preUs)
        let extra = FrameGrid.cmTime(us: piece.preUs + piece.postUs)
        let at = CMTimeSubtract(grid.cmTime(frame: k0), pre)
        let target = CMTimeAdd(grid.cmTime(frame: k1 - k0), extra)
        let unity = m.s1 - m.s0 == m.t1 - m.t0
        let rate = m.rate
        let s0 = max(0, m.s0 - Int64((Double(piece.preUs) * rate).rounded()))
        var source: CMTimeRange
        if unity {
            source = CMTimeRange(start: FrameGrid.cmTime(us: s0), duration: target)
        } else {
            let s1 = m.s1 + Int64((Double(piece.postUs) * rate).rounded())
            source = CMTimeRange(start: FrameGrid.cmTime(us: s0), end: FrameGrid.cmTime(us: s1))
        }
        var exact = true
        if CMTimeCompare(source.end, sourceRange.end) > 0 {
            guard CMTimeCompare(source.start, sourceRange.end) < 0 else { return false }
            source = CMTimeRange(start: source.start, end: sourceRange.end)
            exact = false
        }
        padTrack(track, to: at, ends: &ends)
        do {
            try track.insertTimeRange(source, of: sourceTrack, at: at)
        } catch {
            throw EngineError(.decodeFailed, "audio insertTimeRange failed (\((error as NSError).code))")
        }
        if !unity || !exact {
            track.scaleTimeRange(CMTimeRange(start: at, duration: source.duration), toDuration: target)
        }
        ends[track.trackID] = CMTimeAdd(at, target)
        return exact
    }

    /// Inserts an empty range so the next insertion lands at [time] (tracks are filled in order).
    private static func padTrack(_ track: AVMutableCompositionTrack, to time: CMTime, ends: inout [CMPersistentTrackID: CMTime]) {
        let end = ends[track.trackID] ?? .zero
        if CMTimeCompare(time, end) > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: time))
            ends[track.trackID] = time
        }
    }
}

/// Carries a non-Sendable value across a queue hop whose ordering the caller guarantees.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
