// OWNER: IOS-08
//
// RenderPlan contract v1 value types (ARCH §11.2), mirroring
// packages/danaview_editor_core/lib/src/plan/render_plan.dart (CORE-29). Immutable values with
// value equality; decoded by `RenderPlanDecoder`, re-encoded canonically by `PlanEncoder`.
// Times are integer µs; colours are ARGB UInt32 (`"#RRGGBBAA"` on the wire).

import Foundation

/// The decoded schema version.
let renderPlanVersion = 1

/// `target` of a plan.
enum PlanTarget: String, Equatable {
    case preview, export
}

/// `canvas` (ARCH §11.2). `gridFps` defaults to `fps`.
struct PlanCanvas: Equatable {
    var w: Int
    var h: Int
    var fps: Int
    var gridFps: Int
    /// ARGB.
    var bg: UInt32

    init(w: Int, h: Int, fps: Int, gridFps: Int? = nil, bg: UInt32 = 0xFF00_0000) {
        self.w = w
        self.h = h
        self.fps = fps
        self.gridFps = gridFps ?? fps
        self.bg = bg
    }

    /// The output grid (frames rendered).
    var outputGrid: FrameGrid { FrameGrid(fps) }
    /// The edit grid (layer edges, map breakpoints).
    var editGrid: FrameGrid { FrameGrid(gridFps) }
}

/// Asset kinds.
enum PlanAssetKind: String, Equatable {
    case video, audio, image, lut, sprite
}

/// Transfer functions (HDR sources are tone-mapped to SDR before effects).
enum PlanTransfer: String, Equatable {
    case sdr, hlg, pq
}

/// One `assets` entry.
struct PlanAsset: Equatable {
    var kind: PlanAssetKind
    var uri: String
    var bookmark: String?
    var fp: String = ""
    var proxyUri: String?
    var w: Int?
    var h: Int?
    var rot: Int?
    var durUs: Int64?
    var transfer: PlanTransfer = .sdr
    var hasAudio: Bool?
    var n: Int?
    var sw: Int?
    var sh: Int?
    var sscale: Double?
    var reveal: Bool?
}

/// Layer kinds.
enum PlanLayerKind: String, Equatable {
    case media, image, solid, sprite
}

/// One time-map segment `[t0, t1, s0, s1]` (timeline → source µs).
struct MapSegment: Equatable {
    var t0: Int64
    var t1: Int64
    var s0: Int64
    var s1: Int64

    init(_ t0: Int64, _ t1: Int64, _ s0: Int64, _ s1: Int64) {
        self.t0 = t0
        self.t1 = t1
        self.s0 = s0
        self.s1 = s1
    }

    /// Source µs per timeline µs.
    var rate: Double { Double(s1 - s0) / Double(t1 - t0) }

    /// Source time at timeline time t (ARCH §11.5, unbiased; ε is the builder's business).
    func source(at t: Int64) -> Double {
        Double(s0) + Double(t - t0) * Double(s1 - s0) / Double(t1 - t0)
    }
}

/// A size `[w, h]` in canvas px.
struct PlanSize: Equatable {
    var w: Double
    var h: Double
}

/// Normalized display-oriented crop `[l, t, r, b]`.
struct PlanCrop: Equatable {
    var l: Double
    var t: Double
    var r: Double
    var b: Double

    static let full = PlanCrop(l: 0, t: 0, r: 1, b: 1)
    var isFull: Bool { l == 0 && t == 0 && r == 1 && b == 1 }
}

/// `xf` (centre nil = canvas centre).
struct PlanTransform: Equatable {
    var cx: Double?
    var cy: Double?
    var s: Double = 1
    var r: Double = 0
    var fx = false
    var fy = false
    var op: Double = 1

    static let identity = PlanTransform()
    var isIdentity: Bool { cx == nil && cy == nil && s == 1 && r == 0 && !fx && !fy && op == 1 }
}

/// `fx.adj`: the eight colour adjustments in [-1, 1].
struct PlanAdjust: Equatable {
    /// Order of the wire keys and of `values`.
    static let names = ["exposure", "brightness", "contrast", "highlights", "shadows", "saturation", "temperature", "tint"]

    var values: [Double]

    init(values: [Double] = Array(repeating: 0, count: 8)) {
        precondition(values.count == 8)
        self.values = values
    }

    func value(_ name: String) -> Double {
        guard let i = Self.names.firstIndex(of: name) else { return 0 }
        return values[i]
    }
}

/// `fx.detail`.
struct PlanDetail: Equatable {
    var sharpen: Double = 0
    var blur: Double = 0
    var vignette: Double = 0
}

/// `fx.lut`.
struct PlanLut: Equatable {
    var asset: String
    var i: Double = 1
}

/// `fx.chroma` (key is RGB without alpha).
struct PlanChroma: Equatable {
    var key: UInt32
    var sim: Double = 0.4
    var smooth: Double = 0.1
    var spill: Double = 0.3
}

/// Mask shapes.
enum PlanMaskShape: String, Equatable {
    case rect, ellipse
}

/// `fx.mask` (layer-normalized).
struct PlanMask: Equatable {
    var shape: PlanMaskShape
    var cx: Double = 0.5
    var cy: Double = 0.5
    var w: Double = 1
    var h: Double = 1
    var r: Double = 0
    var corner: Double = 0
    var feather: Double = 0
    var op: Double = 1
    var inv = false
}

/// `fx`.
struct PlanEffects: Equatable {
    var adj: PlanAdjust?
    var detail: PlanDetail?
    var lut: PlanLut?
    var chroma: PlanChroma?
    var mask: PlanMask?

    static let none = PlanEffects()
    var isEmpty: Bool { adj == nil && detail == nil && lut == nil && chroma == nil && mask == nil }
}

/// One animation key `[tUs, v]`.
struct AnimKey: Equatable {
    var tUs: Int64
    var v: Double

    init(_ tUs: Int64, _ v: Double) {
        self.tUs = tUs
        self.v = v
    }
}

/// Animatable channel names (ARCH §11.2).
enum PlanChannels {
    static let xfCx = "xf.cx"
    static let xfCy = "xf.cy"
    static let xfS = "xf.s"
    static let xfR = "xf.r"
    static let xfOp = "xf.op"
    static let reveal = "reveal"
    static let adjust = PlanAdjust.names.map { "adj.\($0)" }
    static let detail = ["detail.sharpen", "detail.blur", "detail.vignette"]
    static let mask = ["mask.cx", "mask.cy", "mask.w", "mask.h", "mask.r", "mask.feather", "mask.op"]
    /// Every channel a layer `anim` may contain.
    static let all: Set<String> = Set([xfCx, xfCy, xfS, xfR, xfOp, reveal] + adjust + detail + mask)
    /// Channels a canvas mask `anim` may contain.
    static let canvasMask: Set<String> = ["cx", "cy", "w", "h"]
}

/// `cmasks[]` entry (canvas px).
struct CanvasMask: Equatable {
    var cx: Double
    var cy: Double
    var w: Double
    var h: Double
    var r: Double = 0
    var feather: Double = 0
    var inv = false
    var anim: [String: [AnimKey]] = [:]
}

/// One layer (ARCH §11.2).
struct PlanLayer: Equatable {
    var id: String
    var z: Int
    var seq: Int?
    var t0: Int64
    var t1: Int64
    var kind: PlanLayerKind
    var asset: String?
    var map: [MapSegment] = []
    var hold = false
    /// ARGB.
    var color: UInt32?
    var base: PlanSize?
    var crop: PlanCrop = .full
    var xf: PlanTransform = .identity
    var fx: PlanEffects = .none
    var anim: [String: [AnimKey]] = [:]
    var cmasks: [CanvasMask] = []

    /// Draw order (z, t0, id); ids compare by UTF-16 code units like Dart.
    static func drawOrder(_ a: PlanLayer, _ b: PlanLayer) -> Bool {
        if a.z != b.z { return a.z < b.z }
        if a.t0 != b.t0 { return a.t0 < b.t0 }
        return PlanIds.less(a.id, b.id)
    }

    /// Whether the layer covers plan time t (half-open).
    func covers(_ t: Int64) -> Bool { t0 <= t && t < t1 }
}

/// One audio segment (ARCH §11.2).
struct AudioSeg: Equatable {
    var id: String
    var asset: String
    var stream: Int = 0
    var t0: Int64
    var t1: Int64
    var map: [MapSegment]
    var gain: [AnimKey]
    /// true = keep pitch (time-stretch), false = varispeed.
    var pitch = true

    /// Order (t0, id).
    static func order(_ a: AudioSeg, _ b: AudioSeg) -> Bool {
        if a.t0 != b.t0 { return a.t0 < b.t0 }
        return PlanIds.less(a.id, b.id)
    }
}

/// `req` (preview only, informational).
struct PlanRequirements: Equatable {
    var offline: [String] = []
    var pendingReverse: [String] = []
    var pendingStill: [String] = []
}

/// A full plan.
struct RenderPlan: Equatable {
    var v: Int = renderPlanVersion
    var rev: Int64
    var target: PlanTarget
    var canvas: PlanCanvas
    var durUs: Int64
    var assets: [String: PlanAsset]
    /// Bottom → top (sorted by z, t0, id).
    var layers: [PlanLayer]
    /// Sorted by t0, id.
    var audio: [AudioSeg]
    var req: PlanRequirements?
}

/// Upserts and removals of one kind.
struct PatchSet<T: Equatable>: Equatable {
    var upsert: [T] = []
    var remove: [String] = []
    var isEmpty: Bool { upsert.isEmpty && remove.isEmpty }
}

/// A plan patch (ARCH §11.2).
struct RenderPlanPatch: Equatable {
    var v: Int = renderPlanVersion
    var from: Int64
    var to: Int64
    var canvas: PlanCanvas?
    var durUs: Int64?
    var assetUpserts: [String: PlanAsset] = [:]
    var assetRemovals: [String] = []
    var layers = PatchSet<PlanLayer>()
    var audio = PatchSet<AudioSeg>()
}

/// One layer of a transient: param fields only (nil = unchanged).
struct TransientLayer: Equatable {
    var id: String
    var xf: PlanTransform?
    var crop: PlanCrop?
    var base: PlanSize?
    var fx: PlanEffects?
    var anim: [String: [AnimKey]]?
    var cmasks: [CanvasMask]?
}

/// A transient (ARCH §11.2): merged over the current layers, never assigned a revision.
struct PlanTransient: Equatable {
    var v: Int = renderPlanVersion
    var item: String
    var layers: [TransientLayer]
}

/// Id ordering shared with Dart (`String.compareTo` compares UTF-16 code units).
enum PlanIds {
    static func less(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}
