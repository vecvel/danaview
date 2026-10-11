package com.vecvel.danaview.spike.engine

import org.json.JSONObject

/** Canonical spike compositions and their expected per-frame content. */
object Scenarios {
    const val W = 1280
    const val H = 720

    /** Region of each visual sequence slot (canvas px, y down); bottom-right shows only background. */
    val RECTS = mapOf(
        1 to floatArrayOf(0f, 0f, 640f, 360f),
        2 to floatArrayOf(640f, 0f, 640f, 360f),
        3 to floatArrayOf(0f, 360f, 640f, 360f),
    )
    val FULL = floatArrayOf(0f, 0f, W.toFloat(), H.toFloat())

    /** 3x2 grid of PiP rects (canvas px) for up to 6 sequences. */
    fun gridRect(i: Int): FloatArray {
        val w = W / 3f
        val h = H / 2f
        return floatArrayOf((i % 3) * w, (i / 3) * h, w, h)
    }

    /** Mapper options with the tiny H.264 clock band (see AND-01.md "Clock band"). */
    fun videoClock(fps: Int, base: MapperOptions = MapperOptions()) =
        base.copy(clockBandKind = ClockBandKind.VIDEO, clockBandVideoUri = TestMedia.uri("clock_$fps.mp4"))

    /**
     * The shape CompositionPlayer 1.11.1 can play (AND-01 finding): every visual sequence is ONE
     * item spanning the whole composition (no gaps, no item transitions). [n] sequences in a 3x2
     * grid, each from a different source offset.
     */
    fun fullLength(fps: Int, n: Int, seconds: Int = 4, rects: (Int) -> FloatArray = ::gridRect): SpikePlan {
        val d = (fps * seconds).toLong()
        val src = "barcode_$fps.mp4"
        val layers = (1..n).map { seq ->
            SpikeLayer("L$seq", seq, 0, d, TestMedia.uri(src), srcAt(src, 0.5 + seq * 1.1), rects(seq - 1))
        }
        return SpikePlan(W, H, fps, fps, d, layers)
    }

    fun gridRegions(n: Int) = (1..n).map { ProbeRegion("s$it", gridRect(it - 1)) }

    fun regions(vararg seqs: Int) = seqs.map { ProbeRegion("s$it", RECTS.getValue(it)) }

    /** Smallest k ≥ round(frac·d) with k ≡ residue (mod 3). */
    fun cutAt(d: Long, frac: Double, residue: Int): Long {
        var k = Math.round(frac * d)
        while (Math.floorMod(k, 3L) != residue.toLong()) k++
        return k
    }

    fun srcAt(name: String, seconds: Double): Long {
        val times = TestMedia.videoSampleTimesUs(name)
        val fps = name.substringAfter("barcode_").substringBefore(".").substringBefore("_").toInt()
        return times[(seconds * fps).toInt()]
    }

    /**
     * The AND-01 composition: transparent clock band (seq 0), 3 video sequences with gaps whose
     * edges sit at frames k ≡ 1 and 2 (mod 3), a background solid and 2 audio-only sequences.
     */
    fun gridCut(fps: Int, seconds: Int = 4): SpikePlan {
        val d = (fps * seconds).toLong()
        val src = "barcode_$fps.mp4"
        val uri = TestMedia.uri(src)
        val aEnd = cutAt(d, 0.26, 1)
        val bEnd = cutAt(d, 0.52, 2)
        val cStart = cutAt(d, 0.77, 2)
        val dStart = cutAt(d, 0.28, 1)
        val dEnd = cutAt(d, 0.54, 2)
        val eEnd = cutAt(d, 0.36, 1)
        val fStart = cutAt(d, 0.64, 2)
        val layers = listOf(
            SpikeLayer("A", 1, 0, aEnd, uri, srcAt(src, 0.8), RECTS.getValue(1)),
            SpikeLayer("B", 1, aEnd, bEnd, uri, srcAt(src, 6.5), RECTS.getValue(1)),
            SpikeLayer("C", 1, cStart, d, uri, srcAt(src, 2.0), RECTS.getValue(1)),
            SpikeLayer("D", 2, dStart, dEnd, uri, srcAt(src, 4.0), RECTS.getValue(2)),
            SpikeLayer("E", 3, 0, eEnd, uri, srcAt(src, 8.0), RECTS.getValue(3)),
            SpikeLayer("F", 3, fStart, d, uri, srcAt(src, 1.0), RECTS.getValue(3)),
        )
        val audio = listOf(
            SpikeAudio("a0", 0, 0, cutAt(d, 0.5, 1), TestMedia.uri("tone_440.m4a"), 0),
            SpikeAudio("a1", 1, aEnd, cutAt(d, 0.82, 2), TestMedia.uri("tone_880.m4a"), 500_000),
        )
        return SpikePlan(W, H, fps, fps, d, layers, audio)
    }

    /** Expected barcode of [seq] at output frame [k] (null = background), per ARCH §11.5. */
    fun expected(plan: SpikePlan, seq: Int, k: Long, times: LongArray): Int? {
        val t = GridTime.timeOfFrame(k, plan.fps)
        val l = plan.layersOf(seq).firstOrNull {
            t >= GridTime.timeOfFrame(it.k0, plan.gridFps) && t < GridTime.timeOfFrame(it.k1, plan.gridFps)
        } ?: return null
        val s = l.srcStartUs + ((t - GridTime.timeOfFrame(l.k0, plan.gridFps)) * l.speed.toDouble()).toLong()
        return TestMedia.ruleFrame(times, s)
    }

    data class Check(val frames: Int, val mismatches: List<String>, val offGrid: Int, val distinctK: Int)

    /** Compares probe frames with [expected] for every region; also checks pts stay on P(k). */
    fun check(plan: SpikePlan, frames: List<ProbeFrame>, times: LongArray, seqs: List<Int>): Check {
        val mismatches = ArrayList<String>()
        var offGrid = 0
        val ks = HashSet<Long>()
        for (f in frames) {
            val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
            if (k < 0 || k >= plan.durFrames) continue
            ks += k
            if (Math.abs(f.ptsUs - GridTime.platformTimeOfFrame(k, plan.fps)) > 1000) offGrid++
            for (seq in seqs) {
                val want = expected(plan, seq, k, times)
                val got = f.regions["s$seq"]?.reading
                val ok = when (want) {
                    null -> got == Barcode.Background
                    else -> got == Barcode.Value(want)
                }
                if (!ok) mismatches += "k=$k pts=${f.ptsUs} s$seq want=${want ?: "bg"} got=$got"
            }
        }
        return Check(frames.size, mismatches, offGrid, ks.size)
    }

    /** Canvas rows a [ReaderImage] needs so [readImage] can decode [regions]. */
    fun rowsFor(regions: List<ProbeRegion>): List<Int> =
        regions.flatMap { listOf(Barcode.barcodeY(it.rect), Barcode.greyY(it.rect), Barcode.markerY(it.rect)) }.distinct()

    /** Decodes the regions of an ImageReader image (rows from [rowsFor]), like [ProbeEffect] does. */
    fun readImage(img: ReaderImage, regions: List<ProbeRegion>, bg: FloatArray): Map<String, RegionReading> {
        val rows = img.rows ?: error("image has no rows")
        return regions.associate { r ->
            val bar = rows.getValue(Barcode.barcodeY(r.rect))
            val grey = rows.getValue(Barcode.greyY(r.rect))
            val marker = rows.getValue(Barcode.markerY(r.rect))
            fun at(row: IntArray, x: Float) = row[x.toInt().coerceIn(0, row.size - 1)]
            r.name to RegionReading(
                Barcode.decode((0 until 16).map { at(bar, Barcode.columnX(r.rect, it).toFloat()) }, bg),
                at(grey, r.rect[0] + r.rect[2] / 2),
                at(marker, r.rect[0] + r.rect[2] * 0.25f),
                at(marker, r.rect[0] + r.rect[2] * 0.75f),
            )
        }
    }

    /** Mismatches of one decoded frame [k] against [expected]. */
    fun checkFrame(plan: SpikePlan, k: Long, readings: Map<String, RegionReading>, times: LongArray, seqs: List<Int>): List<String> =
        seqs.mapNotNull { seq ->
            val want = expected(plan, seq, k, times)
            val got = readings["s$seq"]?.reading
            val ok = if (want == null) got == Barcode.Background else got == Barcode.Value(want)
            if (ok) null else "k=$k s$seq want=${want ?: "bg"} got=$got"
        }

    fun Check.json(): JSONObject = JSONObject()
        .put("frames", frames)
        .put("distinctFrames", distinctK)
        .put("mismatches", mismatches.size)
        .put("firstMismatches", Results.arr(mismatches.take(12)))
        .put("ptsOffGridOver1ms", offGrid)
}
