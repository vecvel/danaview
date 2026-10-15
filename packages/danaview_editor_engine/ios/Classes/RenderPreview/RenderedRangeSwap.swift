// OWNER: IOS-19
//
// RenderedRangeSwap (ARCH D-45(A), §12.2 'Rendered ranges', §13.2): IOS-11's rendered-range hook
// (`RenderedRangeHook`) for one preview session, plus the playback plan that swaps the cached
// render-preview files in.
//
// Ranges. `setRenderedRanges` (RenderedRangeHandler) replaces the session's whole set and binds it
// to the session's current plan (the Dart session sends it on its plan queue, after every plan or
// patch sent before it). The engine drops every range an applied patch touches until the next
// call, so a stale render never plays: `planDidChange(from:to:patch:)` applies the reference rule
// `patchTouchesRange` (API-01 fake, `testing.dart`) natively; a `setPlan` (patch nil) drops every
// range. When the session did not report a change, any plan whose revision differs from the bound
// one is reconciled by comparing the two plans (a layer, the canvas, the duration or an asset that
// changed touches the range the same way) before a range is used, and a revision the swap has no
// plan for serves no range at all.
//
// Playback plan (`playbackPlan(for:)`). During playback only, every playable range plays from its
// file: the plan is rewritten so that inside each range the media layers have no source (their
// map is cut out of the range; a layer that lies wholly inside is removed; layers keep their ids,
// so transients and keyframes still apply outside the range), non-media layers lying wholly inside
// the range are removed, and one opaque full-canvas media layer `!render-<n>` on a fresh composition
// track above every other layer plays the file as one segment, `[start, end) → [0, end − start)`
// (CompositionBuilder adds its ε, D-04, so output frame k0 + i shows file frame i). The switch
// happens at the range's exact frame boundaries because the cut and the new layer share the same
// grid edges. Audio is untouched (it stays live). Paused, scrub and exact seeks keep the full
// composition (the session uses the playback plan only while playing). A range is playable when
// both edges lie on the output grid (the file's frames) and on the edit grid (instruction edges),
// inside the plan's duration, and the plan is a preview plan; export plans are never rewritten,
// so render files are never referenced by an export.
//
// Session lookup. The glue hands `setRenderedRanges` to RenderedRangeHandler with a session id;
// RenderedRangeRegistry keeps one swap per (engine context, session id). The preview session
// manager (IOS-11) installs the same swap as the session's `Dependencies.renderedRanges`, sets its
// `planProvider` and removes it on dispose.

import Foundation

/// One rendered range of a session (µs of the session's plan; [fileURL] in the renders directory).
struct RenderedRange: Equatable {
    var startUs: Int64
    var endUs: Int64
    var fileURL: URL
    var hash: String

    /// Whether `[t0, t1)` overlaps the range.
    func overlaps(_ t0: Int64, _ t1: Int64) -> Bool { t0 < endUs && startUs < t1 }
}

// MARK: - Rules

enum RenderedRangeRules {
    /// Layer id prefix of the swapped-in render layers.
    static let layerPrefix = "!render-"
    /// Asset id prefix of the render files.
    static let assetPrefix = "__render"
    /// Fingerprint prefix of the render files' assets.
    static let fingerprintPrefix = "render:"

    static func layerId(_ i: Int) -> String { "\(layerPrefix)\(i)" }
    static func assetId(_ i: Int) -> String { "\(assetPrefix)\(i)" }

    /// Whether an asset of a plan is a render-preview file.
    static func isRenderAsset(id: String, _ asset: PlanAsset) -> Bool {
        id.hasPrefix(assetPrefix) || asset.fp.hasPrefix(fingerprintPrefix)
    }

    /// The reference rule (`patchTouchesRange`, ARCH §12.2): applying [patch] to [before] touches
    /// [range] when it removes or upserts a layer whose old or new span overlaps it, changes the
    /// canvas, changes the duration and the range ends after the shorter one, or changes or removes
    /// an asset [before] had. Audio changes never touch a range.
    static func patchTouches(before: RenderPlan, patch: RenderPlanPatch, range: RenderedRange) -> Bool {
        if patch.canvas != nil { return true }
        if let dur = patch.durUs, dur != before.durUs, range.endUs > min(dur, before.durUs) { return true }
        if patch.assetRemovals.contains(where: { before.assets[$0] != nil }) { return true }
        for (id, asset) in patch.assetUpserts {
            if let old = before.assets[id], old != asset { return true }
        }
        var old: [String: PlanLayer] = [:]
        for l in before.layers { old[l.id] = l }
        for id in patch.layers.remove {
            if let l = old[id], range.overlaps(l.t0, l.t1) { return true }
        }
        for l in patch.layers.upsert {
            if range.overlaps(l.t0, l.t1) { return true }
            if let o = old[l.id], range.overlaps(o.t0, o.t1) { return true }
        }
        return false
    }

    /// The same rule for two plans without the patch between them: a layer that was added, removed
    /// or changed, the canvas, the duration or an asset of [before] that changed or went away.
    static func changeTouches(before: RenderPlan, after: RenderPlan, range: RenderedRange) -> Bool {
        if before.canvas != after.canvas { return true }
        if before.durUs != after.durUs, range.endUs > min(before.durUs, after.durUs) { return true }
        for (id, asset) in before.assets where after.assets[id] != asset { return true }
        var old: [String: PlanLayer] = [:]
        for l in before.layers { old[l.id] = l }
        var seen = Set<String>()
        for l in after.layers {
            seen.insert(l.id)
            guard let o = old[l.id] else {
                if range.overlaps(l.t0, l.t1) { return true }
                continue
            }
            if o != l, range.overlaps(o.t0, o.t1) || range.overlaps(l.t0, l.t1) { return true }
        }
        for l in before.layers where !seen.contains(l.id) && range.overlaps(l.t0, l.t1) { return true }
        return false
    }

    /// Whether [range] can play from its file in [plan] (see the header).
    static func playable(_ range: RenderedRange, in plan: RenderPlan) -> Bool {
        guard plan.target == .preview, range.startUs >= 0, range.startUs < range.endUs, range.endUs <= plan.durUs else {
            return false
        }
        let out = plan.canvas.outputGrid
        let edit = plan.canvas.editGrid
        return out.isOnGrid(range.startUs) && out.isOnGrid(range.endUs) && edit.isOnGrid(range.startUs)
            && edit.isOnGrid(range.endUs)
    }

    /// Output frames `[k0, k1)` of [range] in [plan].
    static func frames(_ range: RenderedRange, in plan: RenderPlan) -> Range<Int64> {
        let grid = plan.canvas.outputGrid
        return grid.frameIndexOf(range.startUs)..<grid.frameIndexOf(range.endUs)
    }

    /// [map] without `[a, b)` (segments split at the edges; source times interpolated).
    static func cut(_ map: [MapSegment], _ a: Int64, _ b: Int64) -> [MapSegment] {
        var out: [MapSegment] = []
        for seg in map {
            if seg.t1 <= a || seg.t0 >= b {
                out.append(seg)
                continue
            }
            if seg.t0 < a {
                out.append(MapSegment(seg.t0, a, seg.s0, Int64(seg.source(at: a).rounded())))
            }
            if seg.t1 > b {
                out.append(MapSegment(b, seg.t1, Int64(seg.source(at: b).rounded()), seg.s1))
            }
        }
        return out
    }

    /// [plan] with every playable range of [ranges] playing from its file; nil when none applies.
    static func playbackPlan(_ plan: RenderPlan, ranges: [RenderedRange]) -> RenderPlan? {
        let playing = ranges.filter { playable($0, in: plan) }.sorted { $0.startUs < $1.startUs }
        guard !playing.isEmpty else { return nil }
        var layers = plan.layers
        for r in playing {
            var next: [PlanLayer] = []
            next.reserveCapacity(layers.count)
            for var l in layers {
                guard r.overlaps(l.t0, l.t1) else {
                    next.append(l)
                    continue
                }
                let inside = l.t0 >= r.startUs && l.t1 <= r.endUs
                if l.kind != .media {
                    if !inside { next.append(l) }
                    continue
                }
                if inside { continue }
                if l.hold {
                    // A still (playback stills) decodes one frame; it stays under the render.
                    next.append(l)
                    continue
                }
                let map = cut(l.map, r.startUs, r.endUs)
                guard let first = map.first, let last = map.last else { continue }
                l.map = map
                // A layer that only starts or ends inside the range is shortened (keyframe times
                // are absolute, so nothing moves); one that spans it keeps a gap.
                if first.t0 >= r.endUs { l.t0 = first.t0 }
                if last.t1 <= r.startUs { l.t1 = last.t1 }
                next.append(l)
            }
            layers = next
        }
        let topZ = (plan.layers.map(\.z).max() ?? 0) + 1
        let seq = (plan.layers.compactMap(\.seq).max() ?? -1) + 1
        var assets = plan.assets
        for (i, r) in playing.enumerated() {
            let id = assetId(i)
            assets[id] = PlanAsset(
                kind: .video, uri: r.fileURL.absoluteString, bookmark: nil, fp: fingerprintPrefix + r.hash, proxyUri: nil,
                w: nil, h: nil, rot: 0, durUs: r.endUs - r.startUs, transfer: .sdr, hasAudio: false)
            var layer = PlanLayer(id: layerId(i), z: topZ, seq: seq, t0: r.startUs, t1: r.endUs, kind: .media, asset: id)
            layer.map = [MapSegment(r.startUs, r.endUs, 0, r.endUs - r.startUs)]
            layer.base = PlanSize(w: Double(plan.canvas.w), h: Double(plan.canvas.h))
            layers.append(layer)
        }
        var out = plan
        out.assets = assets
        out.layers = layers.sorted(by: PlanLayer.drawOrder)
        return out
    }
}

// MARK: - Swap

final class RenderedRangeSwap: RenderedRangeHook {
    /// One playback boundary crossing (tests and diagnostics).
    struct Crossing: Equatable {
        let range: Range<Int64>
        let entered: Bool
        let frame: Int64
    }

    private let lock = NSLock()
    private var ranges: [RenderedRange] = []
    /// The plan [ranges] are valid for (nil: unbound, nothing plays).
    private var boundPlan: RenderPlan?
    private var inside: Set<Range<Int64>> = []
    private var _crossings: [Crossing] = []

    /// The session's current plan (installed by the session manager; nil until then).
    var planProvider: (() -> RenderPlan?)?

    init() {}

    // MARK: Ranges

    /// Replaces the whole set and binds it to [plan] (default: the session's current plan).
    func setRanges(_ next: [RenderedRange], plan: RenderPlan? = nil) {
        let current = plan ?? planProvider?()
        lock.lock()
        ranges = next.sorted { $0.startUs < $1.startUs }
        boundPlan = current
        inside.removeAll()
        lock.unlock()
    }

    /// The session applied a patch (or, with [patch] nil, replaced the plan): drops every range the
    /// change touches (every range for a new plan) and re-binds the rest to [new].
    func planDidChange(from old: RenderPlan?, to new: RenderPlan, patch: RenderPlanPatch?) {
        lock.lock()
        defer { lock.unlock() }
        guard let bound = boundPlan else { return }
        guard let patch, let old else {
            ranges.removeAll()
            boundPlan = new
            return
        }
        // Changes the swap missed in between are reconciled first.
        if old.rev != bound.rev {
            ranges.removeAll { RenderedRangeRules.changeTouches(before: bound, after: old, range: $0) }
        }
        ranges.removeAll { RenderedRangeRules.patchTouches(before: old, patch: patch, range: $0) }
        boundPlan = new
    }

    /// The ranges still valid for [plan] (reconciles a plan the swap was not told about).
    func validRanges(for plan: RenderPlan) -> [RenderedRange] {
        lock.lock()
        defer { lock.unlock() }
        return reconcile(plan)
    }

    private func reconcile(_ plan: RenderPlan) -> [RenderedRange] {
        guard let bound = boundPlan else { return [] }
        if bound.rev != plan.rev || bound.canvas != plan.canvas || bound.durUs != plan.durUs {
            ranges.removeAll { RenderedRangeRules.changeTouches(before: bound, after: plan, range: $0) }
            boundPlan = plan
        }
        return ranges
    }

    /// Every range currently held (tests).
    var allRanges: [RenderedRange] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    /// The crossings reported by the session (tests and diagnostics).
    var crossings: [Crossing] {
        lock.lock()
        defer { lock.unlock() }
        return _crossings
    }

    /// The range frames playback is inside.
    var activeRanges: Set<Range<Int64>> {
        lock.lock()
        defer { lock.unlock() }
        return inside
    }

    // MARK: Playback

    /// [plan] for playback with every valid, playable range playing from its file; nil when the
    /// live composition plays (no range, a paused or export plan).
    func playbackPlan(for plan: RenderPlan) -> RenderPlan? {
        guard plan.target == .preview else { return nil }
        return RenderedRangeRules.playbackPlan(plan, ranges: validRanges(for: plan))
    }

    // MARK: RenderedRangeHook

    func renderedRanges(planRev: Int64) -> [Range<Int64>] {
        let plan = planProvider?()
        lock.lock()
        defer { lock.unlock() }
        let target: RenderPlan
        if let plan, plan.rev == planRev {
            target = plan
        } else if let bound = boundPlan, bound.rev == planRev {
            target = bound
        } else {
            return []
        }
        return reconcile(target)
            .filter { RenderedRangeRules.playable($0, in: target) }
            .map { RenderedRangeRules.frames($0, in: target) }
    }

    func playbackCrossed(range: Range<Int64>, entered: Bool, atFrame k: Int64) {
        lock.lock()
        if entered { inside.insert(range) } else { inside.remove(range) }
        _crossings.append(Crossing(range: range, entered: entered, frame: k))
        if _crossings.count > 512 { _crossings.removeFirst(_crossings.count - 512) }
        lock.unlock()
    }
}

// MARK: - Registry

/// One RenderedRangeSwap per preview session of an engine context.
final class RenderedRangeRegistry {
    private static let lock = NSLock()
    private static var byContext: [ObjectIdentifier: Entry] = [:]

    private final class Entry {
        weak var context: EngineContext?
        let registry: RenderedRangeRegistry
        init(context: EngineContext, registry: RenderedRangeRegistry) {
            self.context = context
            self.registry = registry
        }
    }

    private let lock = NSLock()
    private var swaps: [String: RenderedRangeSwap] = [:]

    /// The registry of [context].
    static func of(_ context: EngineContext) -> RenderedRangeRegistry {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(context)
        if let e = byContext[key], e.context === context { return e.registry }
        byContext = byContext.filter { $0.value.context != nil }
        let r = RenderedRangeRegistry()
        byContext[key] = Entry(context: context, registry: r)
        return r
    }

    /// The swap of [sessionId] (created on first use).
    func swap(for sessionId: String) -> RenderedRangeSwap {
        lock.lock()
        defer { lock.unlock() }
        if let s = swaps[sessionId] { return s }
        let s = RenderedRangeSwap()
        swaps[sessionId] = s
        return s
    }

    /// The swap of [sessionId] if one exists.
    func existingSwap(for sessionId: String) -> RenderedRangeSwap? {
        lock.lock()
        defer { lock.unlock() }
        return swaps[sessionId]
    }

    /// Forgets [sessionId] (session disposed).
    func remove(sessionId: String) {
        lock.lock()
        swaps[sessionId] = nil
        lock.unlock()
    }

    var sessionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(swaps.keys)
    }
}
