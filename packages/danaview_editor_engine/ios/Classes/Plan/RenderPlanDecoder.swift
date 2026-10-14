// OWNER: IOS-08
//
// Decoding of RenderPlan / Patch / Transient v1 (ARCH §11.1 rule 4, §11.2), mirroring
// packages/danaview_editor_core/lib/src/plan/plan_json.dart (CORE-29): the same defaults, the same
// accepted forms (integral doubles where ints are expected, `#RRGGBB` colours) and the same error
// paths. Unknown keys are ignored; JSON `null` counts as absent. Runs on `previewControlQueue` (or
// the export queue), never on the main thread.

import Foundation

/// Decodes the plan contract from UTF-8 JSON bytes (ARCH §4.4 name).
final class RenderPlanDecoder {
    // MARK: Entry points

    /// Decodes a full plan.
    static func decodePlan(_ data: Data) throws -> RenderPlan {
        try decodePlan(object(try PlanJSONReader.parse(data), ""))
    }

    /// Decodes a patch.
    static func decodePatch(_ data: Data) throws -> RenderPlanPatch {
        try decodePatch(object(try PlanJSONReader.parse(data), ""))
    }

    /// Decodes a transient (timing keys are ignored, ARCH §11.2).
    static func decodeTransient(_ data: Data) throws -> PlanTransient {
        try decodeTransient(object(try PlanJSONReader.parse(data), ""))
    }

    // MARK: Documents

    static func decodePlan(_ j: [String: JSONValue]) throws -> RenderPlan {
        let v = try int(j, "v", "")
        guard v == Int64(renderPlanVersion) else { throw PlanFormatError("unsupported plan version \(v)", "v") }
        // Same evaluation order as the Dart constructor call, so the first error reported matches.
        let rev = try int(j, "rev", "")
        let target = try enumValue(PlanTarget.self, try string(j, "target", ""), "target")
        let canvas = try decodeCanvas(object(j["canvas"], "canvas"))
        let durUs = try int(j, "durUs", "")
        let assets = try decodeAssets(object(j["assets"], "assets"), "assets")
        let layersRaw = try list(j["layers"], "layers")
        var layers: [PlanLayer] = []
        layers.reserveCapacity(layersRaw.count)
        for (i, e) in layersRaw.enumerated() {
            layers.append(try decodeLayer(object(e, "layers[\(i)]"), "layers[\(i)]"))
        }
        let audioRaw = try list(j["audio"], "audio")
        var audio: [AudioSeg] = []
        audio.reserveCapacity(audioRaw.count)
        for (i, e) in audioRaw.enumerated() {
            audio.append(try decodeAudio(object(e, "audio[\(i)]"), "audio[\(i)]"))
        }
        return RenderPlan(
            v: Int(v),
            rev: rev,
            target: target,
            canvas: canvas,
            durUs: durUs,
            assets: assets,
            layers: layers,
            audio: audio,
            req: isAbsent(j["req"]) ? nil : try decodeReq(object(j["req"], "req")))
    }

    static func decodePatch(_ j: [String: JSONValue]) throws -> RenderPlanPatch {
        let v = try int(j, "v", "")
        guard v == Int64(renderPlanVersion) else { throw PlanFormatError("unsupported patch version \(v)", "v") }
        let assets = isAbsent(j["assets"]) ? [:] : try object(j["assets"], "assets")
        let layers = isAbsent(j["layers"]) ? [:] : try object(j["layers"], "layers")
        let audio = isAbsent(j["audio"]) ? [:] : try object(j["audio"], "audio")
        var layerUpserts: [PlanLayer] = []
        for (i, e) in try list(isAbsent(layers["upsert"]) ? .array([]) : layers["upsert"], "layers.upsert").enumerated() {
            layerUpserts.append(try decodeLayer(object(e, "layers.upsert[\(i)]"), "layers.upsert[\(i)]"))
        }
        var audioUpserts: [AudioSeg] = []
        for (i, e) in try list(isAbsent(audio["upsert"]) ? .array([]) : audio["upsert"], "audio.upsert").enumerated() {
            audioUpserts.append(try decodeAudio(object(e, "audio.upsert[\(i)]"), "audio.upsert[\(i)]"))
        }
        return RenderPlanPatch(
            v: Int(v),
            from: try int(j, "from", ""),
            to: try int(j, "to", ""),
            canvas: isAbsent(j["canvas"]) ? nil : try decodeCanvas(object(j["canvas"], "canvas")),
            durUs: isAbsent(j["durUs"]) ? nil : try int(j, "durUs", ""),
            assetUpserts: isAbsent(assets["upsert"])
                ? [:] : try decodeAssets(object(assets["upsert"], "assets.upsert"), "assets.upsert"),
            assetRemovals: try strings(assets["remove"], "assets.remove"),
            layers: PatchSet(upsert: layerUpserts, remove: try strings(layers["remove"], "layers.remove")),
            audio: PatchSet(upsert: audioUpserts, remove: try strings(audio["remove"], "audio.remove")))
    }

    static func decodeTransient(_ j: [String: JSONValue]) throws -> PlanTransient {
        let v = try int(j, "v", "")
        guard v == Int64(renderPlanVersion) else { throw PlanFormatError("unsupported transient version \(v)", "v") }
        var layers: [TransientLayer] = []
        for (i, e) in try list(j["layers"], "layers").enumerated() {
            let p = "layers[\(i)]"
            let o = try object(e, p)
            layers.append(
                TransientLayer(
                    id: try string(o, "id", p),
                    xf: isAbsent(o["xf"]) ? nil : try decodeXf(object(o["xf"], "\(p).xf"), "\(p).xf"),
                    crop: isAbsent(o["crop"]) ? nil : try decodeCrop(o["crop"], "\(p).crop"),
                    base: isAbsent(o["base"]) ? nil : try decodeSize(o["base"], "\(p).base"),
                    fx: isAbsent(o["fx"]) ? nil : try decodeFx(object(o["fx"], "\(p).fx"), "\(p).fx"),
                    anim: isAbsent(o["anim"]) ? nil : try decodeAnim(object(o["anim"], "\(p).anim"), "\(p).anim"),
                    cmasks: isAbsent(o["cmasks"]) ? nil : try decodeCmasks(o["cmasks"], "\(p).cmasks")))
        }
        return PlanTransient(v: Int(v), item: try string(j, "item", ""), layers: layers)
    }

    // MARK: Pieces

    static func decodeCanvas(_ j: [String: JSONValue]) throws -> PlanCanvas {
        PlanCanvas(
            w: Int(try int(j, "w", "canvas")),
            h: Int(try int(j, "h", "canvas")),
            fps: Int(try int(j, "fps", "canvas")),
            gridFps: try optInt(j, "gridFps", "canvas").map { Int($0) },
            bg: isAbsent(j["bg"]) ? 0xFF00_0000 : try decodeColor(try string(j, "bg", "canvas"), "canvas.bg"))
    }

    static func decodeAssets(_ j: [String: JSONValue], _ path: String) throws -> [String: PlanAsset] {
        var out: [String: PlanAsset] = [:]
        out.reserveCapacity(j.count)
        for (id, value) in j {
            out[id] = try decodeAsset(object(value, "\(path).\(id)"), "\(path).\(id)")
        }
        return out
    }

    static func decodeAsset(_ j: [String: JSONValue], _ p: String) throws -> PlanAsset {
        PlanAsset(
            kind: try enumValue(PlanAssetKind.self, try string(j, "kind", p), "\(p).kind"),
            uri: try string(j, "uri", p),
            bookmark: try optString(j, "bookmark", p),
            fp: try optString(j, "fp", p) ?? "",
            proxyUri: try optString(j, "proxyUri", p),
            w: try optInt(j, "w", p).map { Int($0) },
            h: try optInt(j, "h", p).map { Int($0) },
            rot: try optInt(j, "rot", p).map { Int($0) },
            durUs: try optInt(j, "durUs", p),
            transfer: isAbsent(j["transfer"])
                ? .sdr : try enumValue(PlanTransfer.self, try string(j, "transfer", p), "\(p).transfer"),
            hasAudio: try optBool(j, "hasAudio", p),
            n: try optInt(j, "n", p).map { Int($0) },
            sw: try optInt(j, "sw", p).map { Int($0) },
            sh: try optInt(j, "sh", p).map { Int($0) },
            sscale: try optDouble(j, "sscale", p),
            reveal: try optBool(j, "reveal", p))
    }

    static func decodeLayer(_ j: [String: JSONValue], _ p: String) throws -> PlanLayer {
        let t = try list(j["t"], "\(p).t")
        guard t.count == 2 else { throw PlanFormatError("expected [t0, t1]", "\(p).t") }
        return PlanLayer(
            id: try string(j, "id", p),
            z: Int(try int(j, "z", p)),
            seq: try optInt(j, "seq", p).map { Int($0) },
            t0: try asInt(t[0], "\(p).t[0]"),
            t1: try asInt(t[1], "\(p).t[1]"),
            kind: try enumValue(PlanLayerKind.self, try string(j, "kind", p), "\(p).kind"),
            asset: try optString(j, "asset", p),
            map: isAbsent(j["map"]) ? [] : try decodeMap(j["map"], "\(p).map"),
            hold: try optBool(j, "hold", p) ?? false,
            color: isAbsent(j["color"]) ? nil : try decodeColor(try string(j, "color", p), "\(p).color"),
            base: isAbsent(j["base"]) ? nil : try decodeSize(j["base"], "\(p).base"),
            crop: isAbsent(j["crop"]) ? .full : try decodeCrop(j["crop"], "\(p).crop"),
            xf: isAbsent(j["xf"]) ? .identity : try decodeXf(object(j["xf"], "\(p).xf"), "\(p).xf"),
            fx: isAbsent(j["fx"]) ? .none : try decodeFx(object(j["fx"], "\(p).fx"), "\(p).fx"),
            anim: isAbsent(j["anim"]) ? [:] : try decodeAnim(object(j["anim"], "\(p).anim"), "\(p).anim"),
            cmasks: isAbsent(j["cmasks"]) ? [] : try decodeCmasks(j["cmasks"], "\(p).cmasks"))
    }

    static func decodeAudio(_ j: [String: JSONValue], _ p: String) throws -> AudioSeg {
        let t = try list(j["t"], "\(p).t")
        guard t.count == 2 else { throw PlanFormatError("expected [t0, t1]", "\(p).t") }
        return AudioSeg(
            id: try string(j, "id", p),
            asset: try string(j, "asset", p),
            stream: Int(try optInt(j, "stream", p) ?? 0),
            t0: try asInt(t[0], "\(p).t[0]"),
            t1: try asInt(t[1], "\(p).t[1]"),
            map: try decodeMap(j["map"], "\(p).map"),
            gain: try decodeKeys(j["gain"], "\(p).gain"),
            pitch: try optBool(j, "pitch", p) ?? true)
    }

    static func decodeReq(_ j: [String: JSONValue]) throws -> PlanRequirements {
        PlanRequirements(
            offline: try strings(j["offline"], "req.offline"),
            pendingReverse: try strings(j["pendingReverse"], "req.pendingReverse"),
            pendingStill: try strings(j["pendingStill"], "req.pendingStill"))
    }

    static func decodeMap(_ raw: JSONValue?, _ p: String) throws -> [MapSegment] {
        var out: [MapSegment] = []
        for (i, e) in try list(raw, p).enumerated() {
            let s = try list(e, "\(p)[\(i)]")
            guard s.count == 4 else { throw PlanFormatError("expected [t0, t1, s0, s1]", "\(p)[\(i)]") }
            let t0 = try asInt(s[0], "\(p)[\(i)][0]")
            let t1 = try asInt(s[1], "\(p)[\(i)][1]")
            let s0 = try asInt(s[2], "\(p)[\(i)][2]")
            let s1 = try asInt(s[3], "\(p)[\(i)][3]")
            guard t1 > t0, s1 >= s0 else { throw PlanFormatError("segment needs t1 > t0 and s1 ≥ s0", "\(p)[\(i)]") }
            out.append(MapSegment(t0, t1, s0, s1))
        }
        return out
    }

    static func decodeCrop(_ raw: JSONValue?, _ p: String) throws -> PlanCrop {
        let c = try list(raw, p)
        guard c.count == 4 else { throw PlanFormatError("expected [l, t, r, b]", p) }
        return PlanCrop(l: try asDouble(c[0], p), t: try asDouble(c[1], p), r: try asDouble(c[2], p), b: try asDouble(c[3], p))
    }

    static func decodeSize(_ raw: JSONValue?, _ p: String) throws -> PlanSize {
        let c = try list(raw, p)
        guard c.count == 2 else { throw PlanFormatError("expected [w, h]", p) }
        return PlanSize(w: try asDouble(c[0], p), h: try asDouble(c[1], p))
    }

    static func decodeXf(_ j: [String: JSONValue], _ p: String) throws -> PlanTransform {
        PlanTransform(
            cx: try optDouble(j, "cx", p),
            cy: try optDouble(j, "cy", p),
            s: try optDouble(j, "s", p) ?? 1,
            r: try optDouble(j, "r", p) ?? 0,
            fx: try optBool(j, "fx", p) ?? false,
            fy: try optBool(j, "fy", p) ?? false,
            op: try optDouble(j, "op", p) ?? 1)
    }

    static func decodeFx(_ j: [String: JSONValue], _ p: String) throws -> PlanEffects {
        var fx = PlanEffects()
        if !isAbsent(j["adj"]) {
            let a = try object(j["adj"], "\(p).adj")
            fx.adj = PlanAdjust(values: try PlanAdjust.names.map { try optDouble(a, $0, "\(p).adj") ?? 0 })
        }
        if !isAbsent(j["detail"]) {
            let d = try object(j["detail"], "\(p).detail")
            fx.detail = PlanDetail(
                sharpen: try optDouble(d, "sharpen", "\(p).detail") ?? 0,
                blur: try optDouble(d, "blur", "\(p).detail") ?? 0,
                vignette: try optDouble(d, "vignette", "\(p).detail") ?? 0)
        }
        if !isAbsent(j["lut"]) {
            let l = try object(j["lut"], "\(p).lut")
            fx.lut = PlanLut(asset: try string(l, "asset", "\(p).lut"), i: try optDouble(l, "i", "\(p).lut") ?? 1)
        }
        if !isAbsent(j["chroma"]) {
            let c = try object(j["chroma"], "\(p).chroma")
            fx.chroma = PlanChroma(
                key: try decodeColor(try string(c, "key", "\(p).chroma"), "\(p).chroma.key") & 0xFF_FFFF,
                sim: try optDouble(c, "sim", "\(p).chroma") ?? 0.4,
                smooth: try optDouble(c, "smooth", "\(p).chroma") ?? 0.1,
                spill: try optDouble(c, "spill", "\(p).chroma") ?? 0.3)
        }
        if !isAbsent(j["mask"]) {
            let mp = "\(p).mask"
            let m = try object(j["mask"], mp)
            fx.mask = PlanMask(
                shape: try enumValue(PlanMaskShape.self, try string(m, "shape", mp), "\(mp).shape"),
                cx: try optDouble(m, "cx", mp) ?? 0.5,
                cy: try optDouble(m, "cy", mp) ?? 0.5,
                w: try optDouble(m, "w", mp) ?? 1,
                h: try optDouble(m, "h", mp) ?? 1,
                r: try optDouble(m, "r", mp) ?? 0,
                corner: try optDouble(m, "corner", mp) ?? 0,
                feather: try optDouble(m, "feather", mp) ?? 0,
                op: try optDouble(m, "op", mp) ?? 1,
                inv: try optBool(m, "inv", mp) ?? false)
        }
        return fx
    }

    static func decodeAnim(_ j: [String: JSONValue], _ p: String) throws -> [String: [AnimKey]] {
        var out: [String: [AnimKey]] = [:]
        for (name, value) in j {
            out[name] = try decodeKeys(value, "\(p).\(name)")
        }
        return out
    }

    static func decodeKeys(_ raw: JSONValue?, _ p: String) throws -> [AnimKey] {
        var out: [AnimKey] = []
        for (i, e) in try list(raw, p).enumerated() {
            let k = try list(e, "\(p)[\(i)]")
            guard k.count == 2 else { throw PlanFormatError("expected [tUs, v]", "\(p)[\(i)]") }
            out.append(AnimKey(try asInt(k[0], "\(p)[\(i)][0]"), try asDouble(k[1], "\(p)[\(i)][1]")))
        }
        return out
    }

    static func decodeCmasks(_ raw: JSONValue?, _ p: String) throws -> [CanvasMask] {
        var out: [CanvasMask] = []
        for (i, e) in try list(raw, p).enumerated() {
            let mp = "\(p)[\(i)]"
            let j = try object(e, mp)
            out.append(
                CanvasMask(
                    cx: try asDouble(j["cx"], "\(mp).cx"),
                    cy: try asDouble(j["cy"], "\(mp).cy"),
                    w: try asDouble(j["w"], "\(mp).w"),
                    h: try asDouble(j["h"], "\(mp).h"),
                    r: try optDouble(j, "r", mp) ?? 0,
                    feather: try optDouble(j, "feather", mp) ?? 0,
                    inv: try optBool(j, "inv", mp) ?? false,
                    anim: isAbsent(j["anim"]) ? [:] : try decodeAnim(object(j["anim"], "\(mp).anim"), "\(mp).anim")))
        }
        return out
    }

    /// ARGB for `"#RRGGBBAA"` (or `"#RRGGBB"`, alpha FF).
    static func decodeColor(_ s: String, _ path: String) throws -> UInt32 {
        let chars = Array(s.utf8)
        guard chars.first == UInt8(ascii: "#"), chars.count == 7 || chars.count == 9,
              chars.dropFirst().allSatisfy({ isHex($0) }),
              let value = UInt32(String(decoding: chars.dropFirst(), as: UTF8.self), radix: 16)
        else { throw PlanFormatError("expected \"#RRGGBBAA\"", path) }
        if chars.count == 7 { return 0xFF00_0000 | value }
        return (value & 0xFF) << 24 | (value >> 8)
    }

    private static func isHex(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c)
    }

    // MARK: Primitives (Dart `_obj`, `_list`, `_asInt`, …)

    static func isAbsent(_ v: JSONValue?) -> Bool {
        if case .some(let value) = v, value != .null { return false }
        return true
    }

    static func object(_ raw: JSONValue?, _ p: String) throws -> [String: JSONValue] {
        if case .object(let o)? = raw { return o }
        throw PlanFormatError("expected an object", p)
    }

    static func list(_ raw: JSONValue?, _ p: String) throws -> [JSONValue] {
        if case .array(let a)? = raw { return a }
        throw PlanFormatError("expected an array", p)
    }

    static func strings(_ raw: JSONValue?, _ p: String) throws -> [String] {
        if isAbsent(raw) { return [] }
        return try list(raw, p).enumerated().map { i, e in
            guard case .string(let s) = e else { throw PlanFormatError("expected a string", "\(p)[\(i)]") }
            return s
        }
    }

    static func asInt(_ v: JSONValue?, _ p: String) throws -> Int64 {
        switch v {
        case .int(let i)?: return i
        case .double(let d)? where d.isFinite && d == d.rounded(.towardZero) && abs(d) < 9.2e18: return Int64(d)
        default: throw PlanFormatError("expected an integer", p)
        }
    }

    static func asDouble(_ v: JSONValue?, _ p: String) throws -> Double {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: throw PlanFormatError("expected a number", p)
        }
    }

    private static func join(_ p: String, _ k: String) -> String { p.isEmpty ? k : "\(p).\(k)" }

    static func int(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> Int64 {
        try asInt(j[k], join(p, k))
    }

    static func optInt(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> Int64? {
        isAbsent(j[k]) ? nil : try asInt(j[k], "\(p).\(k)")
    }

    static func optDouble(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> Double? {
        isAbsent(j[k]) ? nil : try asDouble(j[k], "\(p).\(k)")
    }

    static func optBool(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> Bool? {
        guard let v = j[k], v != .null else { return nil }
        guard case .bool(let b) = v else { throw PlanFormatError("expected a boolean", "\(p).\(k)") }
        return b
    }

    static func string(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> String {
        guard case .string(let s)? = j[k] else { throw PlanFormatError("expected a string", join(p, k)) }
        return s
    }

    static func optString(_ j: [String: JSONValue], _ k: String, _ p: String) throws -> String? {
        isAbsent(j[k]) ? nil : try string(j, k, p)
    }

    static func enumValue<T: RawRepresentable>(_ type: T.Type, _ name: String, _ p: String) throws -> T
    where T.RawValue == String {
        guard let v = T(rawValue: name) else { throw PlanFormatError("unknown value \"\(name)\"", p) }
        return v
    }
}
