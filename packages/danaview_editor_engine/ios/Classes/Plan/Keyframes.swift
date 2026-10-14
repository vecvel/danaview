// OWNER: IOS-08
//
// The plan's one animation primitive (ARCH §11.1 rule 2): `[[tUs, v], …]` in absolute timeline µs,
// linear between keys, held outside them; no keys = the static value. Evaluated at
// `timeOfFrame(k)` of the output rate, never at a raw platform time (D-35). Vectors:
// packages/danaview_editor_engine_api/test_fixtures/vectors/keyframes.json (API-03).

import Foundation

enum Keyframes {
    /// Value of [keys] at plan time [tUs]; [fallback] when there are no keys.
    static func evaluate(_ keys: [AnimKey], at tUs: Int64, fallback: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return fallback }
        if tUs <= first.tUs { return first.v }
        if tUs >= last.tUs { return last.v }
        var lo = 0
        var hi = keys.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if keys[mid].tUs <= tUs { lo = mid } else { hi = mid }
        }
        let a = keys[lo]
        let b = keys[hi]
        let f = Double(tUs - a.tUs) / Double(b.tUs - a.tUs)
        return a.v + (b.v - a.v) * f
    }

    /// Value of channel [name] of [anim] at [tUs], or [fallback] when the channel is absent.
    static func channel(_ anim: [String: [AnimKey]], _ name: String, at tUs: Int64, fallback: Double) -> Double {
        guard let keys = anim[name] else { return fallback }
        return evaluate(keys, at: tUs, fallback: fallback)
    }
}
