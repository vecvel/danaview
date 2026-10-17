// OWNER: AND-08
//
// Canonical JSON encoder of RenderPlan v1 values, byte-identical to core's `PlanJson.encode*`
// (CORE-29 canonical form): fixed key order per object, `assets` ids and `anim` channels sorted,
// default-valued optional keys omitted, integral reals written as integers, other reals in the
// shortest round-trip form formatted like Dart's `double.toString`, colours `"#RRGGBBAA"` (chroma
// key `"#RRGGBB"`). ARCH §11.9: the Android contract suite decodes, re-encodes and compares every
// fixture with this writer; the engine also uses it for diagnostics dumps (debug builds only).

package com.vecvel.danaview.editor.engine.plan

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode

/** Canonical encoder (see the file header). */
object PlanWriter {
    /** Canonical JSON text of [plan]. */
    fun planJson(plan: RenderPlan): String = Json().apply { plan(plan) }.toString()

    /** Canonical JSON text of [patch]. */
    fun patchJson(patch: RenderPlanPatch): String = Json().apply { patch(patch) }.toString()

    /** Canonical JSON text of [transient]. */
    fun transientJson(transient: PlanTransient): String = Json().apply { transient(transient) }.toString()

    /** UTF-8 bytes of [planJson]. */
    fun planBytes(plan: RenderPlan): ByteArray = planJson(plan).toByteArray(Charsets.UTF_8)

    /** `"#RRGGBBAA"` of an ARGB colour. */
    fun encodeColor(argb: Int): String {
        val a = (argb ushr 24) and 0xFF
        val rgb = argb and 0xFFFFFF
        return "#" + hex(rgb, 6) + hex(a, 2)
    }

    private fun hex(v: Int, digits: Int): String = Integer.toHexString(v).uppercase().padStart(digits, '0')

    /**
     * A JSON number the way core's canonical encoder writes [d]: integral finite values below 2^53
     * as integers, everything else like Dart's `double.toString` (shortest round-trip digits;
     * exponent form below 1e-6 and from 1e21 on, e.g. `1e-7`, `1.5e+21`).
     */
    fun formatNumber(d: Double): String {
        require(d.isFinite()) { "JSON numbers are finite" }
        if (d == Math.floor(d) && Math.abs(d) < 9007199254740992.0) return d.toLong().toString()
        return dartDoubleToString(d)
    }

    private fun dartDoubleToString(d: Double): String {
        if (d == 0.0) return if (1.0 / d < 0) "-0.0" else "0.0"
        val negative = d < 0
        val exact = BigDecimal(Math.abs(d))
        var digits = ""
        var exponent = 0 // value = 0.digits × 10^exponent
        for (p in 1..17) {
            val rounded = exact.round(MathContext(p, RoundingMode.HALF_EVEN))
            if (rounded.toDouble() == Math.abs(d)) {
                val unscaled = rounded.unscaledValue().toString().trimEnd('0')
                // rounded = unscaled' × 10^-scale; digits length k, decimal exponent n = k - scale (before trimming)
                val raw = rounded.unscaledValue().toString()
                exponent = raw.length - rounded.scale()
                digits = unscaled.ifEmpty { "0" }
                break
            }
        }
        val k = digits.length
        val n = exponent
        val body = when {
            n in k..21 -> digits + "0".repeat(n - k) + ".0"
            n in 1..21 -> digits.substring(0, n) + "." + digits.substring(n)
            n in -5..0 -> "0." + "0".repeat(-n) + digits
            else -> {
                val e = n - 1
                val mantissa = if (k == 1) digits else digits[0] + "." + digits.substring(1)
                mantissa + "e" + (if (e >= 0) "+" else "-") + Math.abs(e)
            }
        }
        return if (negative) "-$body" else body
    }

    /** Minimal JSON text builder (Dart `jsonEncode` escaping). */
    private class Json {
        private val sb = StringBuilder(1024)

        /** Per open container: whether the next member needs a comma. */
        private val needComma = ArrayList<Boolean>()
        private var afterKey = false

        override fun toString(): String = sb.toString()

        private fun beforeValue() {
            if (afterKey) {
                afterKey = false
                return
            }
            if (needComma.isEmpty()) return
            val i = needComma.size - 1
            if (needComma[i]) sb.append(',')
            needComma[i] = true
        }

        fun key(name: String) {
            val i = needComma.size - 1
            if (needComma[i]) sb.append(',')
            needComma[i] = true
            string(name)
            sb.append(':')
            afterKey = true
        }

        fun str(v: String) { beforeValue(); string(v) }
        fun num(v: Long) { beforeValue(); sb.append(v) }
        fun num(v: Int) { beforeValue(); sb.append(v) }
        fun num(v: Double) { beforeValue(); sb.append(formatNumber(v)) }
        fun bool(v: Boolean) { beforeValue(); sb.append(if (v) "true" else "false") }

        fun obj(block: Json.() -> Unit) {
            beforeValue()
            sb.append('{')
            needComma += false
            block()
            needComma.removeAt(needComma.size - 1)
            sb.append('}')
        }

        fun arr(block: Json.() -> Unit) {
            beforeValue()
            sb.append('[')
            needComma += false
            block()
            needComma.removeAt(needComma.size - 1)
            sb.append(']')
        }

        private fun string(s: String) {
            sb.append('"')
            for (c in s) {
                when {
                    c == '"' -> sb.append("\\\"")
                    c == '\\' -> sb.append("\\\\")
                    c == '\b' -> sb.append("\\b")
                    c == '\t' -> sb.append("\\t")
                    c == '\n' -> sb.append("\\n")
                    c == '\u000C' -> sb.append("\\f")
                    c == '\r' -> sb.append("\\r")
                    c < ' ' -> sb.append("\\u00").append(Integer.toHexString(c.code).padStart(2, '0'))
                    else -> sb.append(c)
                }
            }
            sb.append('"')
        }

        // ------------------------------------------------------------ documents

        fun plan(p: RenderPlan) = obj {
            key("v"); num(p.v)
            key("rev"); num(p.rev)
            key("target"); str(p.target.wire)
            key("canvas"); canvas(p.canvas)
            key("durUs"); num(p.durUs)
            key("assets"); assets(p.assets)
            key("layers"); arr { p.layers.forEach { layer(it) } }
            key("audio"); arr { p.audio.forEach { audio(it) } }
            p.req?.let { r ->
                key("req")
                obj {
                    if (r.offline.isNotEmpty()) { key("offline"); strings(r.offline) }
                    if (r.pendingReverse.isNotEmpty()) { key("pendingReverse"); strings(r.pendingReverse) }
                    if (r.pendingStill.isNotEmpty()) { key("pendingStill"); strings(r.pendingStill) }
                }
            }
        }

        fun patch(p: RenderPlanPatch) = obj {
            key("v"); num(p.v)
            key("from"); num(p.from)
            key("to"); num(p.to)
            p.canvas?.let { key("canvas"); canvas(it) }
            p.durUs?.let { key("durUs"); num(it) }
            if (p.assetUpserts.isNotEmpty() || p.assetRemovals.isNotEmpty()) {
                key("assets")
                obj {
                    if (p.assetUpserts.isNotEmpty()) { key("upsert"); assets(p.assetUpserts) }
                    if (p.assetRemovals.isNotEmpty()) { key("remove"); strings(p.assetRemovals) }
                }
            }
            if (!p.layers.isEmpty) {
                key("layers")
                obj {
                    if (p.layers.upsert.isNotEmpty()) { key("upsert"); arr { p.layers.upsert.forEach { layer(it) } } }
                    if (p.layers.remove.isNotEmpty()) { key("remove"); strings(p.layers.remove) }
                }
            }
            if (!p.audio.isEmpty) {
                key("audio")
                obj {
                    if (p.audio.upsert.isNotEmpty()) { key("upsert"); arr { p.audio.upsert.forEach { audio(it) } } }
                    if (p.audio.remove.isNotEmpty()) { key("remove"); strings(p.audio.remove) }
                }
            }
        }

        fun transient(t: PlanTransient) = obj {
            key("v"); num(t.v)
            key("item"); str(t.item)
            key("layers")
            arr {
                for (l in t.layers) {
                    obj {
                        key("id"); str(l.id)
                        l.xf?.let { key("xf"); xf(it) }
                        l.crop?.let { key("crop"); crop(it) }
                        l.base?.let { key("base"); size(it) }
                        l.fx?.let { key("fx"); fx(it) }
                        l.anim?.let { key("anim"); anim(it) }
                        l.cmasks?.let { m -> key("cmasks"); arr { m.forEach { cmask(it) } } }
                    }
                }
            }
        }

        // ------------------------------------------------------------ pieces

        private fun strings(list: List<String>) = arr { list.forEach { str(it) } }

        private fun canvas(c: PlanCanvas) = obj {
            key("w"); num(c.w)
            key("h"); num(c.h)
            key("fps"); num(c.fps)
            if (c.gridFps != c.fps) { key("gridFps"); num(c.gridFps) }
            key("bg"); str(encodeColor(c.bg))
        }

        private fun assets(assets: Map<String, PlanAsset>) = obj {
            for (id in assets.keys.sorted()) {
                key(id)
                asset(assets.getValue(id))
            }
        }

        private fun asset(a: PlanAsset) = obj {
            key("kind"); str(a.kind.wire)
            key("uri"); str(a.uri)
            a.bookmark?.let { key("bookmark"); str(it) }
            if (a.fp.isNotEmpty()) { key("fp"); str(a.fp) }
            a.proxyUri?.let { key("proxyUri"); str(it) }
            a.w?.let { key("w"); num(it) }
            a.h?.let { key("h"); num(it) }
            a.rot?.let { key("rot"); num(it) }
            a.durUs?.let { key("durUs"); num(it) }
            if (a.transfer != PlanTransfer.SDR) { key("transfer"); str(a.transfer.wire) }
            a.hasAudio?.let { key("hasAudio"); bool(it) }
            a.n?.let { key("n"); num(it) }
            a.sw?.let { key("sw"); num(it) }
            a.sh?.let { key("sh"); num(it) }
            a.sscale?.let { key("sscale"); num(it) }
            a.reveal?.let { key("reveal"); bool(it) }
        }

        private fun layer(l: PlanLayer) = obj {
            key("id"); str(l.id)
            key("z"); num(l.z)
            l.seq?.let { key("seq"); num(it) }
            key("t"); arr { num(l.t0); num(l.t1) }
            key("kind"); str(l.kind.wire)
            l.asset?.let { key("asset"); str(it) }
            if (l.map.isNotEmpty()) { key("map"); map(l.map) }
            if (l.hold) { key("hold"); bool(true) }
            l.color?.let { key("color"); str(encodeColor(it)) }
            l.base?.let { key("base"); size(it) }
            if (!l.crop.isFull) { key("crop"); crop(l.crop) }
            if (!l.xf.isIdentity) { key("xf"); xf(l.xf) }
            if (!l.fx.isEmpty) { key("fx"); fx(l.fx) }
            if (l.anim.isNotEmpty()) { key("anim"); anim(l.anim) }
            if (l.cmasks.isNotEmpty()) { key("cmasks"); arr { l.cmasks.forEach { cmask(it) } } }
        }

        private fun audio(a: AudioSeg) = obj {
            key("id"); str(a.id)
            key("asset"); str(a.asset)
            if (a.stream != 0) { key("stream"); num(a.stream) }
            key("t"); arr { num(a.t0); num(a.t1) }
            key("map"); map(a.map)
            key("gain"); keys(a.gain)
            if (!a.pitch) { key("pitch"); bool(false) }
        }

        private fun map(map: List<MapSegment>) = arr {
            for (s in map) arr { num(s.t0); num(s.t1); num(s.s0); num(s.s1) }
        }

        private fun keys(k: Keyframes) = arr {
            for (i in 0 until k.size) arr { num(k.timeAt(i)); num(k.valueOf(i)) }
        }

        private fun size(s: PlanSize) = arr { num(s.w); num(s.h) }

        private fun crop(c: PlanCrop) = arr { num(c.l); num(c.t); num(c.r); num(c.b) }

        private fun xf(x: PlanTransform) = obj {
            x.cx?.let { key("cx"); num(it) }
            x.cy?.let { key("cy"); num(it) }
            if (x.s != 1.0) { key("s"); num(x.s) }
            if (x.r != 0.0) { key("r"); num(x.r) }
            if (x.fx) { key("fx"); bool(true) }
            if (x.fy) { key("fy"); bool(true) }
            if (x.op != 1.0) { key("op"); num(x.op) }
        }

        private fun fx(f: PlanEffects) = obj {
            f.adj?.let { adj ->
                key("adj")
                obj {
                    val values = adj.values
                    for (i in PlanAdjust.NAMES.indices) {
                        if (values[i] != 0.0) { key(PlanAdjust.NAMES[i]); num(values[i]) }
                    }
                }
            }
            f.detail?.let { d ->
                key("detail")
                obj {
                    if (d.sharpen != 0.0) { key("sharpen"); num(d.sharpen) }
                    if (d.blur != 0.0) { key("blur"); num(d.blur) }
                    if (d.vignette != 0.0) { key("vignette"); num(d.vignette) }
                }
            }
            f.lut?.let { l ->
                key("lut")
                obj { key("asset"); str(l.asset); key("i"); num(l.i) }
            }
            f.chroma?.let { c ->
                key("chroma")
                obj {
                    key("key"); str("#" + hex(c.key and 0xFFFFFF, 6))
                    key("sim"); num(c.sim)
                    key("smooth"); num(c.smooth)
                    key("spill"); num(c.spill)
                }
            }
            f.mask?.let { m ->
                key("mask")
                obj {
                    key("shape"); str(m.shape.wire)
                    key("cx"); num(m.cx)
                    key("cy"); num(m.cy)
                    key("w"); num(m.w)
                    key("h"); num(m.h)
                    if (m.r != 0.0) { key("r"); num(m.r) }
                    if (m.corner != 0.0) { key("corner"); num(m.corner) }
                    if (m.feather != 0.0) { key("feather"); num(m.feather) }
                    if (m.op != 1.0) { key("op"); num(m.op) }
                    if (m.inv) { key("inv"); bool(true) }
                }
            }
        }

        private fun anim(anim: Map<String, Keyframes>) = obj {
            for (name in anim.keys.sorted()) {
                key(name)
                keys(anim.getValue(name))
            }
        }

        private fun cmask(m: CanvasMask) = obj {
            key("cx"); num(m.cx)
            key("cy"); num(m.cy)
            key("w"); num(m.w)
            key("h"); num(m.h)
            if (m.r != 0.0) { key("r"); num(m.r) }
            if (m.feather != 0.0) { key("feather"); num(m.feather) }
            if (m.inv) { key("inv"); bool(true) }
            if (m.anim.isNotEmpty()) { key("anim"); anim(m.anim) }
        }
    }
}
