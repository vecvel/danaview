// OWNER: AND-08
//
// RenderPlan invariants (ARCH §11.3), mirroring core's `plan_validator.dart` (CORE-29) rule for
// rule and naming the same offending id (the contract corpus `invalid/` checks code and id). A
// violation natively is `planInvalid`, a bug: it is logged with the layer id only (never paths or
// content) and the preview keeps showing the last good frame.

package com.vecvel.danaview.editor.engine.plan

/** Kinds of plan invariant violations (names match core's `PlanViolationCode`). */
enum class PlanViolationCode {
    version, canvas, duration, duplicateId, asset, range, offGrid, map, seq, order, anim, value, zBand, gain,
}

/** One violation, naming the offending layer, segment or asset [id] when there is one. */
data class PlanViolation(val code: PlanViolationCode, val message: String, val id: String? = null) {
    override fun toString(): String = "PlanViolation(${code.name}${id?.let { " $it" } ?: ""}: $message)"
}

/** Validates plans against ARCH §11.3. */
object PlanValidator {
    private const val MIN_RATE = 0.1
    private const val MAX_RATE = 10.0
    private const val RATE_EPS = 1e-6

    /** First z of the text band (bands: video 0, overlay 1, text 2, subtitle 3; ARCH §11.4). */
    const val TEXT_BAND_Z = 20000

    /** One past the last z of the subtitle band. */
    const val BANDS_END_Z = 40000

    /** All violations of [plan] (empty when valid). */
    fun validate(plan: RenderPlan): List<PlanViolation> {
        val out = ArrayList<PlanViolation>()
        fun add(c: PlanViolationCode, m: String, id: String? = null) {
            out += PlanViolation(c, m, id)
        }

        if (plan.v != RENDER_PLAN_VERSION) add(PlanViolationCode.version, "v must be $RENDER_PLAN_VERSION")
        val c = plan.canvas
        if (c.w < 16 || c.h < 16 || c.w % 2 != 0 || c.h % 2 != 0) add(PlanViolationCode.canvas, "w/h must be even and >= 16")
        if (c.fps !in FrameGrid.RATES || c.gridFps !in FrameGrid.RATES) add(PlanViolationCode.canvas, "fps and gridFps must be integer v1 rates")
        // An invalid gridFps is reported once above; grid checks are skipped instead of cascading.
        val gridValid = c.gridFps in FrameGrid.RATES
        val grid = FrameGrid.of(if (gridValid) c.gridFps else 30)
        fun onGrid(t: Long) = !gridValid || grid.isOnGrid(t)
        if (plan.durUs < 0 || !onGrid(plan.durUs)) add(PlanViolationCode.duration, "durUs must be >= 0 and on the gridFps grid")

        for ((id, a) in plan.assets) checkAsset(a) { add(PlanViolationCode.asset, it, id) }

        val ids = HashSet<String>()
        val bySeq = LinkedHashMap<Int, MutableList<PlanLayer>>()
        val byZ = LinkedHashMap<Int, MutableList<PlanLayer>>()
        var prev: PlanLayer? = null
        for (l in plan.layers) {
            if (!ids.add(l.id)) add(PlanViolationCode.duplicateId, "duplicate layer id", l.id)
            prev?.let { if (compareLayers(it, l) > 0) add(PlanViolationCode.order, "layers must be sorted by (z, t0, id)", l.id) }
            prev = l
            if (!(l.t0 < l.t1) || l.t0 < 0 || l.t1 > plan.durUs) add(PlanViolationCode.range, "needs 0 <= t0 < t1 <= durUs", l.id)
            if (!onGrid(l.t0) || !onGrid(l.t1)) add(PlanViolationCode.offGrid, "layer edges must lie on the gridFps grid", l.id)
            if (l.z < 0 || l.z >= BANDS_END_Z) add(PlanViolationCode.zBand, "z outside the four bands", l.id)
            if (l.kind == PlanLayerKind.SPRITE && l.z >= 0 && l.z < TEXT_BAND_Z) {
                add(PlanViolationCode.zBand, "sprite layers belong to the text or subtitle bands", l.id)
            }
            if ((l.kind == PlanLayerKind.MEDIA || l.kind == PlanLayerKind.IMAGE) && l.z >= TEXT_BAND_Z && l.z < BANDS_END_Z) {
                add(PlanViolationCode.zBand, "media and image layers belong to the video or overlay bands", l.id)
            }
            byZ.getOrPut(l.z) { ArrayList() } += l

            val assetKind = l.asset?.let { plan.assets[it]?.kind }
            when (l.kind) {
                PlanLayerKind.MEDIA -> {
                    if (assetKind != PlanAssetKind.VIDEO) add(PlanViolationCode.asset, "media layers need a video asset", l.id)
                    val seq = l.seq
                    if (seq == null || seq < 0) add(PlanViolationCode.seq, "media layers need seq >= 0", l.id)
                    else bySeq.getOrPut(seq) { ArrayList() } += l
                    checkMap(l.map, l.t0, l.t1, ::onGrid, { add(PlanViolationCode.map, it, l.id) }, { add(PlanViolationCode.offGrid, it, l.id) })
                }
                PlanLayerKind.IMAGE -> {
                    if (assetKind != PlanAssetKind.IMAGE) add(PlanViolationCode.asset, "image layers need an image asset", l.id)
                    if (l.seq != null) add(PlanViolationCode.seq, "only media layers carry seq", l.id)
                }
                PlanLayerKind.SPRITE -> {
                    if (assetKind != PlanAssetKind.SPRITE) add(PlanViolationCode.asset, "sprite layers need a sprite asset", l.id)
                    if (l.seq != null) add(PlanViolationCode.seq, "only media layers carry seq", l.id)
                }
                PlanLayerKind.SOLID -> {
                    if (l.color == null) add(PlanViolationCode.value, "solid layers need a color", l.id)
                    if (l.seq != null) add(PlanViolationCode.seq, "only media layers carry seq", l.id)
                }
            }
            if (l.kind != PlanLayerKind.MEDIA && (l.map.isNotEmpty() || l.hold)) add(PlanViolationCode.map, "map/hold only on media layers", l.id)
            val lut = l.fx.lut
            if (lut != null && plan.assets[lut.asset]?.kind != PlanAssetKind.LUT) add(PlanViolationCode.asset, "lut asset missing", l.id)
            checkValues(l) { add(PlanViolationCode.value, it, l.id) }
            for ((channel, keys) in l.anim) {
                if (channel !in PlanChannels.ALL) add(PlanViolationCode.anim, "unknown channel", l.id)
                if (!keys.isSortedUnique()) add(PlanViolationCode.anim, "keys must be sorted and unique", l.id)
                if (keys.isEmpty()) add(PlanViolationCode.anim, "channel has no keys", l.id)
                val range = channelRange(channel)
                if (range != null && keys.anyOutside(range.first, range.second)) {
                    add(PlanViolationCode.value, "channel values outside their range", l.id)
                }
            }
            if (l.anim.containsKey(PlanChannels.REVEAL)) {
                val ok = l.kind == PlanLayerKind.SPRITE && l.asset?.let { plan.assets[it]?.reveal } == true
                if (!ok) add(PlanViolationCode.anim, "reveal only on sprites whose asset has reveal: true", l.id)
            }
            for (m in l.cmasks) {
                if (!(m.w >= 0 && m.h >= 0 && m.feather >= 0)) add(PlanViolationCode.value, "canvas mask w, h and feather must be >= 0", l.id)
                for ((channel, keys) in m.anim) {
                    if (channel !in PlanChannels.CANVAS_MASK || !keys.isSortedUnique()) {
                        add(PlanViolationCode.anim, "invalid canvas-mask channel", l.id)
                    }
                }
            }
        }

        // Packing slots never overlap (CORE-36).
        for (slot in bySeq.values) {
            val sorted = slot.sortedBy { it.t0 }
            for (i in 1 until sorted.size) {
                if (sorted[i].t0 < sorted[i - 1].t1) add(PlanViolationCode.seq, "overlaps another layer of its seq", sorted[i].id)
            }
        }
        // Within one z, at most two layers at once (lowered transition windows).
        for (group in byZ.values) {
            val events = ArrayList<Triple<Long, Int, String>>()
            for (l in group) {
                events += Triple(l.t0, 1, l.id)
                events += Triple(l.t1, -1, l.id)
            }
            events.sortWith(compareBy<Triple<Long, Int, String>> { it.first }.thenBy { it.second })
            var active = 0
            for (e in events) {
                active += e.second
                if (active > 2) {
                    add(PlanViolationCode.zBand, "more than two layers overlap within one z", e.third)
                    break
                }
            }
        }

        val audioIds = HashSet<String>()
        var prevA: AudioSeg? = null
        for (a in plan.audio) {
            if (!audioIds.add(a.id)) add(PlanViolationCode.duplicateId, "duplicate audio id", a.id)
            prevA?.let { p -> if (p.t0 > a.t0 || (p.t0 == a.t0 && p.id > a.id)) add(PlanViolationCode.order, "audio must be sorted by (t0, id)", a.id) }
            prevA = a
            val kind = plan.assets[a.asset]?.kind
            if (kind != PlanAssetKind.AUDIO && kind != PlanAssetKind.VIDEO) add(PlanViolationCode.asset, "audio needs an audio or video asset", a.id)
            if (!(a.t0 < a.t1) || a.t0 < 0 || a.t1 > plan.durUs) add(PlanViolationCode.range, "needs 0 <= t0 < t1 <= durUs", a.id)
            if (!onGrid(a.t0) || !onGrid(a.t1)) add(PlanViolationCode.offGrid, "audio edges must lie on the gridFps grid", a.id)
            checkMap(a.map, a.t0, a.t1, ::onGrid, { add(PlanViolationCode.map, it, a.id) }, { add(PlanViolationCode.offGrid, it, a.id) })
            if (a.stream < 0) add(PlanViolationCode.value, "stream must be >= 0", a.id)
            if (a.gain.isEmpty()) add(PlanViolationCode.gain, "gain needs at least one key", a.id)
            if (a.gain.anyOutside(0.0, 2.0)) add(PlanViolationCode.gain, "gain values must be in [0, 2]", a.id)
            if (!a.gain.isSortedUnique()) add(PlanViolationCode.gain, "gain keys must be sorted and unique", a.id)
        }
        return out
    }

    /** Draw order of layers: (z, t0, id) (ARCH §11.4). */
    fun compareLayers(a: PlanLayer, b: PlanLayer): Int = when {
        a.z != b.z -> a.z.compareTo(b.z)
        a.t0 != b.t0 -> a.t0.compareTo(b.t0)
        else -> a.id.compareTo(b.id)
    }

    /** Order of audio segments: (t0, id). */
    fun compareAudio(a: AudioSeg, b: AudioSeg): Int = if (a.t0 != b.t0) a.t0.compareTo(b.t0) else a.id.compareTo(b.id)

    private fun channelRange(channel: String): Pair<Double, Double>? = when {
        channel == PlanChannels.XF_OP || channel == "mask.op" || channel == "mask.feather" || channel.startsWith("detail.") -> 0.0 to 1.0
        channel.startsWith("adj.") -> -1.0 to 1.0
        channel == PlanChannels.XF_S || channel == "mask.w" || channel == "mask.h" || channel == PlanChannels.REVEAL -> 0.0 to Double.MAX_VALUE
        else -> null
    }

    private fun checkAsset(a: PlanAsset, bad: (String) -> Unit) {
        fun uriOk(u: String) = u.startsWith("file://") || u.startsWith("content://")
        if (!uriOk(a.uri)) bad("uri must be file:// or content:// (never http)")
        val proxy = a.proxyUri
        if (proxy != null && !uriOk(proxy)) bad("proxyUri must be file:// or content://")
        if (a.rot != null && a.rot !in setOf(0, 90, 180, 270)) bad("rot must be 0, 90, 180 or 270")
        if ((a.w != null && a.w < 1) || (a.h != null && a.h < 1)) bad("w and h must be >= 1")
        if (a.durUs != null && a.durUs < 0) bad("durUs must be >= 0")
        when (a.kind) {
            PlanAssetKind.LUT -> {
                val n = a.n
                if (n == null || n < 2 || n > 65) bad("lut assets need n in 2..65")
            }
            PlanAssetKind.SPRITE -> {
                if (a.sw == null || a.sh == null || a.sw < 1 || a.sh < 1) bad("sprite assets need sw and sh >= 1")
                val sscale = a.sscale
                if (sscale == null || !(sscale > 0)) bad("sprite assets need sscale > 0")
            }
            PlanAssetKind.VIDEO, PlanAssetKind.AUDIO, PlanAssetKind.IMAGE -> Unit
        }
    }

    private fun checkMap(
        map: List<MapSegment>,
        t0: Long,
        t1: Long,
        onGrid: (Long) -> Boolean,
        bad: (String) -> Unit,
        offGrid: (String) -> Unit,
    ) {
        if (map.isEmpty()) {
            bad("map must cover [t0, t1)")
            return
        }
        if (map.first().t0 != t0 || map.last().t1 != t1) bad("map must start at t0 and end at t1")
        for (i in map.indices) {
            val s = map[i]
            if (i > 0 && s.t0 != map[i - 1].t1) bad("map segments must be contiguous")
            if (!onGrid(s.t0) || !onGrid(s.t1)) offGrid("map breakpoints must lie on the gridFps grid")
            val r = s.rate
            if (r < MIN_RATE - RATE_EPS || r > MAX_RATE + RATE_EPS) bad("segment rate outside [0.1, 10]")
        }
    }

    private fun checkValues(l: PlanLayer, bad: (String) -> Unit) {
        fun unit(v: Double) = v >= 0 && v <= 1
        if (!unit(l.xf.op)) bad("xf.op outside [0, 1]")
        val adj = l.fx.adj
        if (adj != null && adj.values.any { it < -1 || it > 1 }) bad("adj values outside [-1, 1]")
        val d = l.fx.detail
        if (d != null && !(unit(d.sharpen) && unit(d.blur) && unit(d.vignette))) bad("detail values outside [0, 1]")
        val lut = l.fx.lut
        if (lut != null && !unit(lut.i)) bad("lut.i outside [0, 1]")
        val ch = l.fx.chroma
        if (ch != null && !(unit(ch.sim) && unit(ch.smooth) && unit(ch.spill))) bad("chroma values outside [0, 1]")
        val m = l.fx.mask
        if (m != null && !(unit(m.feather) && unit(m.op) && m.corner >= 0 && m.corner <= 0.5)) bad("mask values out of range")
        val base = l.base
        if (base != null && !(base.w.isFinite() && base.h.isFinite() && base.w > 0 && base.h > 0)) bad("base must be positive")
        if (!(l.xf.s.isFinite() && l.xf.r.isFinite() && (l.xf.cx ?: 0.0).isFinite() && (l.xf.cy ?: 0.0).isFinite())) bad("xf values must be finite")
        val c = l.crop
        if (!(unit(c.l) && unit(c.t) && unit(c.r) && unit(c.b) && c.l < c.r && c.t < c.b)) bad("crop must satisfy 0 <= l < r <= 1, 0 <= t < b <= 1")
    }
}
