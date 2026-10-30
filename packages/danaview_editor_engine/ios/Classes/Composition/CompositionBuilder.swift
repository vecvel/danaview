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
// CMTimes (D-35); source ranges stay `CMTime(µs, 1_000_000)`. `hold` (freeze-frame) layers show the
// rule frame at `map[0].s0` (greatest PTS ≤ s0 + ε) for the whole layer: that whole sample
// [PTS, next PTS) (read once per hold time without decoding, `sampleRange`) is frozen across
// [k0, k1) like the spacer (one edit at an integral scale plus an unscaled remainder; the same
// `layFrozen` as the past-source-end hold below, and `ExportSpacer` splits both at a reader's
// start). Never a 100 µs range inside the sample scaled across the layer: a reader opening inside
// that edit stalled (a 10 s freeze, segmented export). Only when the sample cannot be read is
// that 100 µs range used.
// Past the source end (ARCH §11.5: the rule frame there is the LAST source frame): the segment
// that runs past the video track's end plays at its own rate up to the last sample's PTS (read
// once per such asset, `lastSampleRange`), and that whole sample, frozen like the spacer (one edit
// at an integral scale plus an unscaled remainder), holds the last frame from there to the layer end; a segment starting past it is all hold. Never
// a clamped range stretched over the segment (that slowed the remaining source down and dropped
// later segments). The hold's source starts at the sample's PTS: an edit whose source starts
// inside a sample stalls an AVAssetReader that opens inside it (segmented export). A part that
// holds no output frame time is left out (no extra edit at a clip that ends exactly at its
// source end), so the only edit points off the grid are such play → hold seams.
// A runtime-generated 16×16 spacer (SpacerVideo) covers `CMTime(0…K, gridFps)` so the compositor
// runs for every output frame, gaps included. It is laid as n whole spacer durations (one edit at an
// integral scale) plus an unscaled remainder edit shorter than one spacer duration, never as one
// edit at a fractional scale: a reader or player item starting inside a fractionally scaled spacer
// edit never gets a sample (`copyNextSampleBuffer` blocks; 60 fps × 179, 48 fps × 49 frames;
// FIX-IOS-SPACER). Images, solids and sprites are compositor layers only.
//
// Audio. Segments are laid out by AudioMixLayout (interval colouring × pitch, ramp-seam pairs).
// Audio is sample-accurate (no ε): a unity-rate piece inserts its source start with the GRID
// duration (no time-pitch pass at a rate of 1 ± 10⁻⁶); other pieces insert the exact source µs and
// are scaled to the grid duration. A piece running past its source end plays at its own rate up
// to the end and the track is empty (silent) after it (ARCH §11.5), never stretched; a piece
// starting past the end is left out. Each track's AVMutableAudioMixInputParameters uses `.timeDomain`
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
        /// The last video sample [PTS, track end) in track time, read only for assets a layer plays
        /// past the end of (ARCH §11.5 hold); nil otherwise or when it could not be read.
        var lastVideoSample: CMTimeRange? = nil
        /// The sample [PTS, next PTS) a `hold` layer freezes, in track time, by the layer's
        /// `map[0].s0` (µs); a hold time whose sample could not be read is missing.
        var heldSamples: [Int64: CMTimeRange] = [:]
        let audio: [AVAssetTrack]
        let audioRanges: [CMTimeRange]

        /// Every sample frozen across a range of the composition (holds and the last-frame hold).
        var frozenSamples: [CMTimeRange] {
            var units = lastVideoSample.map { [$0] } ?? []
            for unit in heldSamples.values.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 }) where !units.contains(unit) {
                units.append(unit)
            }
            return units
        }
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

    /// Where the last audio media of the composition ends (zero without audio). A mix reader ends
    /// there even when the timeline goes on (audio past its source end, ARCH §11.5, or audio
    /// segments ending before the timeline end); the export fills the rest with silence.
    var audioMediaEnd: CMTime {
        composition.tracks(withMediaType: .audio)
            .compactMap { $0.segments.last(where: { !$0.isEmpty })?.timeMapping.target.end }
            .max { CMTimeCompare($0, $1) < 0 } ?? .zero
    }

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
    /// Source length of the fallback hold range (scaled across the layer) when a sample is unread.
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
            var last: CMTimeRange?
            var held: [Int64: CMTimeRange] = [:]
            if let v = video, let range = videoRange {
                if layersRunPastTheEnd(plan, asset: id, videoEnd: range.end) {
                    last = lastSampleRange(asset: asset, track: v, trackRange: range)
                }
                for s0 in holdTimes(plan, asset: id) {
                    held[s0] = sampleRange(asset: asset, track: v, trackRange: range, at: FrameGrid.cmTime(us: s0 + epsilonUs))
                }
            }
            media[id] = CompositionSources.Media(
                asset: asset, video: video, videoRange: videoRange, lastVideoSample: last, heldSamples: held, audio: audio,
                audioRanges: audioRanges)
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

    /// Whether a (non-`hold`) media layer of [plan] on [asset] shows an output frame past the video
    /// track's end [videoEnd] (it then holds the last sample, whose range `lastSampleRange` reads).
    static func layersRunPastTheEnd(_ plan: RenderPlan, asset: String, videoEnd: CMTime) -> Bool {
        let grid = plan.canvas.editGrid
        return plan.layers.contains { l in
            guard l.kind == .media, !l.hold, l.asset == asset else { return false }
            let layerEnd = grid.cmTime(frame: grid.frameIndexOf(l.t1))
            for seg in l.map {
                let k0 = grid.frameIndexOf(seg.t0)
                let k1 = grid.frameIndexOf(seg.t1)
                guard k1 > k0 else { continue }
                let start = FrameGrid.cmTime(us: seg.s0 + epsilonUs)
                let whole = FrameGrid.cmTime(us: seg.s1 - seg.s0)
                guard CMTimeCompare(CMTimeAdd(start, whole), videoEnd) > 0 else { continue }
                let at = grid.cmTime(frame: k0)
                let through = CMTimeCompare(start, videoEnd) < 0
                    ? scaled(grid.cmTime(frame: k1 - k0), part: CMTimeSubtract(videoEnd, start), whole: whole) : .zero
                return hasOutputFrame(in: CMTimeAdd(at, through), layerEnd, grid: plan.canvas.outputGrid)
            }
            return false
        }
    }

    /// The distinct `map[0].s0` (µs) of the `hold` layers of [plan] on [asset] that show a frame.
    static func holdTimes(_ plan: RenderPlan, asset: String) -> [Int64] {
        let grid = plan.canvas.editGrid
        let times = plan.layers.compactMap { l -> Int64? in
            guard l.kind == .media, l.hold, l.asset == asset, grid.frameIndexOf(l.t1) > grid.frameIndexOf(l.t0) else { return nil }
            return l.map.first?.s0
        }
        return Set(times).sorted()
    }

    /// The presentation range [PTS, track end) of [track]'s last sample in track time (edit lists
    /// applied); nil when unreadable (see `sampleRange`).
    static func lastSampleRange(asset: AVAsset, track: AVAssetTrack, trackRange: CMTimeRange) -> CMTimeRange? {
        sampleRange(asset: asset, track: track, trackRange: trackRange, at: trackRange.end)
    }

    /// The presentation range [PTS, next PTS) in track time (edit lists applied) of the sample of
    /// [track] shown at track time [time]: the greatest PTS ≤ [time] before the track end (so the
    /// last sample at or past the end), up to the next sample's PTS (the track end for the last
    /// sample). Read without decoding (compressed samples of [time − 2 s, time + 1 s]); nil when
    /// unreadable or when no sample starts at or before [time]. A frozen-frame edit inserts exactly
    /// this range: an edit whose source starts inside a sample (the old 100 µs range) stalls an
    /// AVAssetReader that starts inside it (segmented export).
    static func sampleRange(asset: AVAsset, track: AVAssetTrack, trackRange: CMTimeRange, at time: CMTime) -> CMTimeRange? {
        guard trackRange.end.isNumeric, time.isNumeric, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let t = CMTimeMinimum(time, trackRange.end)
        let start = CMTimeMaximum(trackRange.start, CMTimeSubtract(t, CMTime(value: 2, timescale: 1)))
        let end = CMTimeMinimum(trackRange.end, CMTimeAdd(t, CMTime(value: 1, timescale: 1)))
        guard CMTimeCompare(start, end) < 0 else { return nil }
        reader.timeRange = CMTimeRange(start: start, end: end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var stamps: [CMTime] = []
        // Bounded: 3 s of compressed samples (the cap only guards against a runaway source).
        while stamps.count < 10_000, let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isNumeric, CMTimeCompare(pts, trackRange.end) < 0 { stamps.append(pts) }
        }
        guard let pts = stamps.filter({ CMTimeCompare($0, t) <= 0 }).max(by: { CMTimeCompare($0, $1) < 0 }),
              CMTimeCompare(pts, trackRange.start) >= 0 else { return nil }
        // Every sample with a PTS inside the window was delivered (decode order does not matter).
        let next = stamps.filter { CMTimeCompare($0, pts) > 0 && CMTimeCompare($0, end) <= 0 }.min { CMTimeCompare($0, $1) < 0 }
        if let next { return CMTimeRange(start: pts, end: next) }
        // No later sample in the window: the last sample (ends at the track end), else unknown.
        return CMTimeCompare(end, trackRange.end) == 0 ? CMTimeRange(start: pts, end: trackRange.end) : nil
    }

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
                    guard k1 > k0 else { continue }
                    if let unit = src.heldSamples[m0.s0] {
                        // The rule sample at s0, frozen across the layer (see the file header).
                        try insertFrozen(
                            track: track, unit: unit, of: video, at: grid.cmTime(frame: k0), duration: grid.cmTime(frame: k1 - k0),
                            ends: &ends)
                        continue
                    }
                    warnings.append("hold sample unread on \(layer.id): sub-sample hold")
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
                let layerEnd = grid.cmTime(frame: grid.frameIndexOf(layer.t1))
                for seg in layer.map {
                    let k0 = grid.frameIndexOf(seg.t0)
                    let k1 = grid.frameIndexOf(seg.t1)
                    guard k1 > k0 else { continue }
                    let at = grid.cmTime(frame: k0)
                    let target = grid.cmTime(frame: k1 - k0)
                    let source = CMTimeRange(
                        start: FrameGrid.cmTime(us: seg.s0 + epsilonUs), duration: FrameGrid.cmTime(us: seg.s1 - seg.s0))
                    if CMTimeCompare(source.end, range.end) <= 0 {
                        try insertVideo(track: track, source: source, of: video, at: at, target: target, ends: &ends)
                        continue
                    }
                    // The map runs past the source end (ARCH §11.5): this segment plays at its rate
                    // up to the last sample, then the layer holds the last frame to its end (rates
                    // are positive, so every later segment is past the end too). Never stretched.
                    if src.lastVideoSample == nil, layersRunPastTheEnd(plan, asset: id, videoEnd: range.end) {
                        warnings.append("last sample unread on \(layer.id): sub-sample hold")
                    }
                    try insertPastSourceEnd(
                        track: track, source: source, of: video, lastSample: src.lastVideoSample ?? lastFrameRange(sourceEnd: range.end),
                        at: at, target: target, layerEnd: layerEnd, outputGrid: plan.canvas.outputGrid, ends: &ends)
                    break
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
            try layoutSpacer(t, source: spacerTrack, range: spacerRange, end: grid.cmTime(frame: total))
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

    /// The spacer edits covering [0, end) for a spacer source of duration `unit`
    /// (FIX-IOS-SPACER): `whole` = n·unit with n = floor(end / unit) on exact integers (one edit
    /// scaled by the integral ratio n; zero when end < unit), then the remainder end − whole
    /// (< unit) as an unscaled insert of the spacer's first `remainder` (zero when end is a whole
    /// multiple of unit).
    static func spacerLayout(end: CMTime, unit: CMTime) -> (n: Int64, whole: CMTime, remainder: CMTime)? {
        guard end.isNumeric, unit.isNumeric, end.value > 0, unit.value > 0, end.timescale > 0, unit.timescale > 0 else {
            return nil
        }
        // end = a/b, unit = c/d: n = floor(a·d / (b·c)).
        let (num, o1) = Int64(end.value).multipliedReportingOverflow(by: Int64(unit.timescale))
        let (den, o2) = Int64(end.timescale).multipliedReportingOverflow(by: unit.value)
        guard !o1, !o2, den > 0 else { return nil }
        let n = num / den
        guard n <= Int64(Int32.max) else { return nil }
        let whole = n == 0 ? CMTime.zero : CMTimeMultiply(unit, multiplier: Int32(n))
        return (n, whole, CMTimeSubtract(end, whole))
    }

    /// Lays the spacer across [0, end) on [track] (see `spacerLayout`). Every edit either has an
    /// integral scale or none, so a reader or player starting anywhere gets samples.
    static func layoutSpacer(_ track: AVMutableCompositionTrack, source: AVAssetTrack, range: CMTimeRange, end: CMTime) throws {
        guard let layout = spacerLayout(end: end, unit: range.duration) else {
            // Unrepresentable ratio (not expected): the single scaled edit.
            try track.insertTimeRange(range, of: source, at: .zero)
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: end)
            return
        }
        if layout.n > 0 {
            try track.insertTimeRange(range, of: source, at: .zero)
            if layout.n > 1 {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: layout.whole)
            }
        }
        if layout.remainder > .zero {
            try track.insertTimeRange(
                CMTimeRange(start: range.start, duration: layout.remainder), of: source, at: layout.whole)
        }
    }

    /// [target] × [part] / [whole] (composition timescale): the composition length of [part] of a
    /// source range of length [whole] laid over [target].
    static func scaled(_ target: CMTime, part: CMTime, whole: CMTime) -> CMTime {
        guard CMTimeCompare(whole, .zero) > 0 else { return .zero }
        let seconds = CMTimeGetSeconds(target) * CMTimeGetSeconds(part) / CMTimeGetSeconds(whole)
        return CMTime(value: CMTimeValue((seconds * Double(compositionTimeScale)).rounded()), timescale: compositionTimeScale)
    }

    /// Whether an output frame time `CMTime(m, fps)` lies in [from, to): the only composition times
    /// the compositor is asked for (a range without one never shows).
    static func hasOutputFrame(in from: CMTime, _ to: CMTime, grid: FrameGrid) -> Bool {
        guard from.isNumeric, to.isNumeric, CMTimeCompare(from, to) < 0 else { return false }
        // m = ceil(from × fps), exact on the rational.
        let ts = Int64(from.timescale)
        let (product, overflow) = from.value.multipliedReportingOverflow(by: grid.fps)
        let m = overflow
            ? Int64((Double(from.value) * Double(grid.fps) / Double(ts)).rounded(.up))
            : FrameGrid.ceilDiv(product, ts)
        return CMTimeCompare(grid.cmTime(frame: m), to) < 0
    }

    /// Fallback hold range when the last sample could not be read: [end − holdSourceUs, end), inside
    /// the last sample (shows the right frame; a reader starting inside it may stall).
    static func lastFrameRange(sourceEnd end: CMTime) -> CMTimeRange {
        let d = FrameGrid.cmTime(us: holdSourceUs)
        return CMTimeRange(start: CMTimeSubtract(end, d), duration: d)
    }

    /// Lays the map segment at [at] (grid length [target], [source] ending past the video track's
    /// end) and the rest of the layer up to [layerEnd] (ARCH §11.5, rule frame = greatest PTS ≤
    /// s + ε): the segment's source at its own rate up to the PTS of the last sample, then a
    /// frozen-frame edit of [lastSample] (that whole sample, scaled) from there to the layer end:
    /// from that point the rule frame is the last one. A part that holds no output frame of
    /// [outputGrid] is left out (it would never be shown, and an extra edit makes the decoder re-read
    /// the last GOP); a segment starting at or past the last sample is all hold.
    private static func insertPastSourceEnd(
        track: AVMutableCompositionTrack, source: CMTimeRange, of sourceTrack: AVAssetTrack, lastSample: CMTimeRange,
        at: CMTime, target: CMTime, layerEnd: CMTime, outputGrid: FrameGrid, ends: inout [CMPersistentTrackID: CMTime]
    ) throws {
        // Nothing shown past the track end (a clip ending at its source end, ε past it): one edit
        // to the track end, no hold.
        if CMTimeCompare(source.start, lastSample.end) < 0 {
            let throughEnd = scaled(target, part: CMTimeSubtract(lastSample.end, source.start), whole: source.duration)
            if !hasOutputFrame(in: CMTimeAdd(at, throughEnd), layerEnd, grid: outputGrid) {
                guard CMTimeCompare(throughEnd, .zero) > 0 else { return }
                try insertVideo(
                    track: track, source: CMTimeRange(start: source.start, end: lastSample.end), of: sourceTrack, at: at,
                    target: throughEnd, ends: &ends)
                return
            }
        }
        var heldFrom = at
        let sourceEnd = lastSample.start
        if CMTimeCompare(source.start, sourceEnd) < 0 {
            let played = CMTimeRange(start: source.start, end: sourceEnd)
            let playedTarget = scaled(target, part: played.duration, whole: source.duration)
            let playedEnd = CMTimeAdd(at, playedTarget)
            if CMTimeCompare(playedTarget, .zero) > 0,
               hasOutputFrame(in: at, playedEnd, grid: outputGrid) || !hasOutputFrame(in: playedEnd, layerEnd, grid: outputGrid) {
                try insertVideo(track: track, source: played, of: sourceTrack, at: at, target: playedTarget, ends: &ends)
                heldFrom = playedEnd
            }
        }
        guard hasOutputFrame(in: heldFrom, layerEnd, grid: outputGrid) else { return }
        try insertFrozen(track: track, unit: lastSample, of: sourceTrack, at: heldFrom, duration: CMTimeSubtract(layerEnd, heldFrom), ends: &ends)
    }

    /// One source sample [unit] frozen across [at, at + duration) the way the spacer is laid
    /// (`spacerLayout`, FIX-IOS-SPACER): n whole unit durations as one edit at the integral scale n,
    /// then an unscaled remainder shorter than one unit. An AVAssetReader opening inside a
    /// fractionally scaled one-sample edit may never get a sample (a reader from 3.33 s inside a
    /// 33 ms sample scaled to 1.034 s stalled).
    private static func insertFrozen(
        track: AVMutableCompositionTrack, unit: CMTimeRange, of sourceTrack: AVAssetTrack, at: CMTime, duration: CMTime,
        ends: inout [CMPersistentTrackID: CMTime]
    ) throws {
        padTrack(track, to: at, ends: &ends)
        try layFrozen(track, unit: unit, of: sourceTrack, at: at, duration: duration)
        ends[track.trackID] = CMTimeAdd(at, duration)
    }

    /// Inserts [unit] frozen across [at, at + duration) (see `insertFrozen`; later edits move by
    /// [duration]). Also used by `ExportSpacer` to re-lay a hold so a sample starts at a reader's start.
    static func layFrozen(_ track: AVMutableCompositionTrack, unit: CMTimeRange, of sourceTrack: AVAssetTrack, at: CMTime, duration: CMTime) throws {
        guard CMTimeCompare(duration, .zero) > 0 else { return }
        do {
            guard let layout = spacerLayout(end: duration, unit: unit.duration) else {
                try track.insertTimeRange(unit, of: sourceTrack, at: at)
                track.scaleTimeRange(CMTimeRange(start: at, duration: unit.duration), toDuration: duration)
                return
            }
            if layout.n > 0 {
                try track.insertTimeRange(unit, of: sourceTrack, at: at)
                if layout.n > 1 { track.scaleTimeRange(CMTimeRange(start: at, duration: unit.duration), toDuration: layout.whole) }
            }
            if layout.remainder > .zero {
                try track.insertTimeRange(CMTimeRange(start: unit.start, duration: layout.remainder), of: sourceTrack, at: CMTimeAdd(at, layout.whole))
            }
        } catch {
            throw EngineError(.decodeFailed, "insertTimeRange failed (\((error as NSError).code))")
        }
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
        var target = CMTimeAdd(grid.cmTime(frame: k1 - k0), extra)
        guard CMTimeCompare(target, .zero) > 0 else { return true }
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
            // Past its source end audio is silent (ARCH §11.5): the piece plays at its own rate up to
            // the source end and the track stays empty after it. Never stretched over the piece.
            guard CMTimeCompare(source.start, sourceRange.end) < 0 else { return false }
            let whole = source.duration
            source = CMTimeRange(start: source.start, end: sourceRange.end)
            target = unity ? source.duration : scaled(target, part: source.duration, whole: whole)
            exact = false
        }
        padTrack(track, to: at, ends: &ends)
        do {
            try track.insertTimeRange(source, of: sourceTrack, at: at)
        } catch {
            throw EngineError(.decodeFailed, "audio insertTimeRange failed (\((error as NSError).code))")
        }
        if !unity {
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
