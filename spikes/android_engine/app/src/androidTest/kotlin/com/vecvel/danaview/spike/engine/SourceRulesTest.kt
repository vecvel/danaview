@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.spike.engine.Scenarios.json
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Source-side claims: V-N5 (hdrMode tone-maps HLG), V-N6 (upright frames for rotated sources),
 * V-N15 (clock band yields export fps above the source rate), V-N16 (ε source-frame rule at clip
 * starts, ARCH §11.5) and V-N17 (fast items capped at the project fps).
 */
@RunWith(AndroidJUnit4::class)
class SourceRulesTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)

    // ---------------------------------------------------------------- V-N16

    /** Offsets of a clip start relative to a sample PTS (µs); the rule frame is that sample for all. */
    private val offsets = longArrayOf(-400, 0, 300, 600, 16_000, 17_500, 32_000)

    private fun epsilonPlan(src: String): SpikePlan {
        val times = TestMedia.videoSampleTimesUs(src)
        val clipLen = 6L
        val layers = offsets.mapIndexed { j, off ->
            val i = 20 + j * 37 // distinct source frames per clip
            SpikeLayer("c$j", 1, j * clipLen, (j + 1) * clipLen, TestMedia.uri(src), times[i] + off, Scenarios.RECTS.getValue(1))
        }
        return SpikePlan(Scenarios.W, Scenarios.H, 30, 30, offsets.size * clipLen, layers)
    }

    private fun epsilonExport(src: String, mode: EpsilonMode): JSONObject {
        val plan = epsilonPlan(src)
        val times = TestMedia.videoSampleTimesUs(src)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
        val c = mapper.build(plan, store, MapperOptions(epsilon = mode, probe = probe, includeAudio = false))
        ExportHarness(ctx).export(c, File(TestMedia.outDir, "eps_${mode}_$src"))
        val starts = JSONArray()
        var startMismatches = 0
        var midMismatches = 0
        for (f in probe.frames.sortedBy { it.ptsUs }) {
            val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
            val mm = Scenarios.checkFrame(plan, k, f.regions, times, listOf(1))
            val isStart = k % 6 == 0L
            if (isStart) {
                val j = (k / 6).toInt()
                starts.put(JSONObject().put("offsetUs", offsets[j]).put("ok", mm.isEmpty()).put("detail", mm.firstOrNull() ?: ""))
            }
            if (mm.isNotEmpty()) if (isStart) startMismatches++ else midMismatches++
        }
        return JSONObject().put("mode", mode.name).put("source", src).put("frames", probe.frames.size)
            .put("clipStartMismatches", startMismatches).put("midClipMismatches", midMismatches).put("starts", starts)
    }

    @Test
    fun epsilonRule_export_vn16() {
        val runs = JSONArray()
        val byMode = HashMap<String, Int>()
        for (src in listOf("barcode_30.mp4", "barcode_30_bf.mp4")) {
            for (mode in EpsilonMode.entries) {
                val r = epsilonExport(src, mode)
                runs.put(r)
                byMode.merge(mode.name, r.getInt("clipStartMismatches") + r.getInt("midClipMismatches"), Int::plus)
            }
        }
        Results.write("VN16_epsilon_export", JSONObject().put("runs", runs).put("totalMismatchesByMode", JSONObject(byMode as Map<*, *>)))
        assertEquals("SNAP_TO_RULE_FRAME must meet the rule at every frame: $runs", 0, byMode.getValue(EpsilonMode.SNAP_TO_RULE_FRAME.name))
    }

    /**
     * Same rule in CompositionPlayer. Each offset is a full-length single-item sequence (the only
     * secondary shape the player plays, see PlayerTopologyTest). Multi-sequence seeks fail in
     * Media3 1.11.1 (R1), so the composition plays from 0 and a composition-level probe checks
     * every composited frame (frames 0..2 carry the clip-start case).
     */
    @Test
    fun epsilonRule_player_vn16() {
        val src = "barcode_30_bf.mp4"
        val times = TestMedia.videoSampleTimesUs(src)
        val results = JSONArray()
        var mismatches = 0
        var startFramesChecked = 0
        for (group in offsets.toList().chunked(3)) {
            val layers = group.mapIndexed { idx, off ->
                val i = 30 + idx * 41
                SpikeLayer("o$off", idx + 1, 0, 60, TestMedia.uri(src), times[i] + off, Scenarios.RECTS.getValue(idx + 1))
            }
            val plan = SpikePlan(Scenarios.W, Scenarios.H, 30, 30, 60, layers)
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val regions = Scenarios.regions(*(1..layers.size).toList().toIntArray())
            val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), regions)
            val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(epsilon = EpsilonMode.SNAP_TO_RULE_FRAME, includeAudio = false, probe = probe)))
            PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
                h.load(c)
                h.awaitReady()
                // The probe is not cleared: frame 0 is composited while preparing.
                h.playToEnd(plan.durUs / 1000 + 20_000)
            }
            val check = Scenarios.check(plan, probe.frames.toList(), times, (1..layers.size).toList())
            val startKs = probe.frames.map { GridTime.frameIndexNearest(it.ptsUs, plan.fps) }.filter { it in 0L..2L }.toSet()
            startFramesChecked += startKs.size
            mismatches += check.mismatches.size
            results.put(JSONObject().put("offsets", JSONArray(group)).put("startFramesComposited", JSONArray(startKs.sorted())).put("barcode", check.json()))
        }
        Results.write(
            "VN16_epsilon_player",
            JSONObject().put("mode", "SNAP_TO_RULE_FRAME").put("source", src).put("checks", results)
                .put("startFramesChecked", startFramesChecked).put("mismatches", mismatches),
        )
        assertEquals(results.toString(), 0, mismatches)
        assertTrue("clip-start frames 0..2 composited in every group: $results", startFramesChecked == 3 * results.length())
    }

    // ---------------------------------------------------------------- V-N5, V-N6

    private fun hevcMain10Decoder(): String? = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
        !info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, true) } &&
            info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC).profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 }
    }?.name

    private fun singleSourcePlan(src: String, seconds: Int = 2): SpikePlan {
        val d = 30L * seconds
        return SpikePlan(Scenarios.W, Scenarios.H, 30, 30, d, listOf(SpikeLayer("S", 1, 0, d, TestMedia.uri(src), TestMedia.videoSampleTimesUs(src)[3], Scenarios.RECTS.getValue(1))))
    }

    /** Checks barcode, grey level and orientation markers of region s1 on every frame. */
    private fun sourceChecks(plan: SpikePlan, frames: List<ProbeFrame>, src: String): JSONObject {
        val times = TestMedia.videoSampleTimesUs(src)
        var barcodeOk = 0
        var orientationOk = 0
        val greys = ArrayList<Double>()
        val bad = ArrayList<String>()
        for (f in frames) {
            val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
            val r = f.regions.getValue("s1")
            val mm = Scenarios.checkFrame(plan, k, f.regions, times, listOf(1))
            if (mm.isEmpty()) barcodeOk++ else if (bad.size < 8) bad += mm
            val green = Barcode.g(r.markerLeft) > 0.6f && Barcode.b(r.markerLeft) < 0.4f
            val blue = Barcode.b(r.markerRight) > 0.6f && Barcode.g(r.markerRight) < 0.4f
            if (green && blue) orientationOk++
            greys += Barcode.r(r.grey).toDouble()
        }
        return JSONObject().put("frames", frames.size).put("barcodeOk", barcodeOk).put("orientationOk", orientationOk)
            .put("greyLevel", Results.stats(greys)).put("firstBad", Results.arr(bad))
    }

    private fun causes(t: Throwable): JSONArray {
        val out = JSONArray()
        var c: Throwable? = t
        while (c != null && out.length() < 6) {
            out.put("${c.javaClass.simpleName}: ${c.message}")
            c = c.cause
        }
        return out
    }

    /** One HLG export; returns the record and whether it exported. */
    private fun hlgExport(src: String): JSONObject {
        val plan = singleSourcePlan(src)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
        val c = mapper.build(plan, store, MapperOptions(probe = probe, includeAudio = false))
        val json = JSONObject().put("source", src)
        try {
            val out = ExportHarness(ctx).export(c, File(TestMedia.outDir, "hlg_export_$src"))
            val video = OutputInspector.tracks(out.file).first { it.mime.startsWith("video/") }.format
            val transfer = if (video.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) video.getInteger(MediaFormat.KEY_COLOR_TRANSFER) else -1
            json.put("exported", true).put("outputMime", video.getString(MediaFormat.KEY_MIME)).put("outputColorTransfer", transfer)
                .put("checks", sourceChecks(plan, probe.frames.toList(), src))
        } catch (e: ExportHarness.ExportFailed) {
            json.put("exported", false).put("error", e.exception.errorCodeName).put("causes", causes(e.exception))
        }
        return json
    }

    /**
     * V-N5. hlg_30.mp4 is HEVC Main10 HLG (needs a Main10 decoder); hlg8_30.mp4 is 8-bit H.264
     * tagged BT.2020/HLG, which every device decodes, so it shows whether Media3's OpenGL
     * tone-mapping path itself runs on this GPU.
     */
    @Test
    fun hlgToneMapped_export_vn5() {
        val decoder = hevcMain10Decoder()
        val main10 = hlgExport("hlg_30.mp4")
        val eightBit = hlgExport("hlg8_30.mp4")
        Results.write(
            "VN05_hlg_export",
            JSONObject().put("hevcMain10Decoder", decoder ?: JSONObject.NULL).put("glVersion", glVersion())
                .put("runs", JSONArray().put(main10).put(eightBit)),
        )
        for (r in listOf(main10, eightBit)) {
            if (!r.getBoolean("exported")) continue
            // SDR output: transfer is SDR video (3) or unset, never HLG (7) / ST2084 (6).
            val transfer = r.getInt("outputColorTransfer")
            assertTrue("output transfer $transfer", transfer != MediaFormat.COLOR_TRANSFER_HLG && transfer != MediaFormat.COLOR_TRANSFER_ST2084)
            val checks = r.getJSONObject("checks")
            assertEquals(checks.toString(), checks.getInt("frames"), checks.getInt("barcodeOk"))
            val grey = checks.getJSONObject("greyLevel").getDouble("p50")
            assertTrue("tone-mapped mid grey $grey", grey in 0.2..0.8)
        }
        // A Main10 HLG source must export wherever a Main10 decoder exists.
        assertTrue("export failed although $decoder exists: $main10", decoder == null || main10.getBoolean("exported"))
    }

    private fun glVersion(): String {
        val display = android.opengl.EGL14.eglGetDisplay(android.opengl.EGL14.EGL_DEFAULT_DISPLAY)
        val v = IntArray(2)
        android.opengl.EGL14.eglInitialize(display, v, 0, v, 1)
        val cfg = arrayOfNulls<android.opengl.EGLConfig>(1)
        val n = IntArray(1)
        android.opengl.EGL14.eglChooseConfig(display, intArrayOf(android.opengl.EGL14.EGL_RENDERABLE_TYPE, android.opengl.EGLExt.EGL_OPENGL_ES3_BIT_KHR, android.opengl.EGL14.EGL_SURFACE_TYPE, android.opengl.EGL14.EGL_PBUFFER_BIT, android.opengl.EGL14.EGL_NONE), 0, cfg, 0, 1, n, 0)
        val ctx = android.opengl.EGL14.eglCreateContext(display, cfg[0], android.opengl.EGL14.EGL_NO_CONTEXT, intArrayOf(android.opengl.EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, android.opengl.EGL14.EGL_NONE), 0)
        val surf = android.opengl.EGL14.eglCreatePbufferSurface(display, cfg[0], intArrayOf(android.opengl.EGL14.EGL_WIDTH, 1, android.opengl.EGL14.EGL_HEIGHT, 1, android.opengl.EGL14.EGL_NONE), 0)
        android.opengl.EGL14.eglMakeCurrent(display, surf, surf, ctx)
        val s = "${android.opengl.GLES20.glGetString(android.opengl.GLES20.GL_VERSION)}; EXT_YUV_target=${android.opengl.GLES20.glGetString(android.opengl.GLES20.GL_EXTENSIONS)?.contains("GL_EXT_YUV_target")}"
        android.opengl.EGL14.eglMakeCurrent(display, android.opengl.EGL14.EGL_NO_SURFACE, android.opengl.EGL14.EGL_NO_SURFACE, android.opengl.EGL14.EGL_NO_CONTEXT)
        android.opengl.EGL14.eglDestroySurface(display, surf)
        android.opengl.EGL14.eglDestroyContext(display, ctx)
        return s
    }

    @Test
    fun rotatedSourceUpright_export_vn6() {
        val plan = singleSourcePlan("rotated_30.mp4")
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
        val c = mapper.build(plan, store, MapperOptions(probe = probe, includeAudio = false))
        ExportHarness(ctx).export(c, File(TestMedia.outDir, "rotated_export.mp4"))
        val checks = sourceChecks(plan, probe.frames.toList(), "rotated_30.mp4")
        Results.write("VN06_rotation_export", checks)
        assertEquals(checks.toString(), checks.getInt("frames"), checks.getInt("orientationOk"))
        assertEquals(checks.toString(), checks.getInt("frames"), checks.getInt("barcodeOk"))
    }

    @Test
    fun rotatedSourceUpright_player_vn6() {
        val plan = singleSourcePlan("rotated_30.mp4")
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
        val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(probe = probe, includeAudio = false)))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.load(c)
            h.awaitReady()
            probe.clear()
            h.playToEnd(plan.durUs / 1000 + 60_000)
        }
        val checks = sourceChecks(plan, probe.frames.toList(), "rotated_30.mp4")
        Results.write("VN06_rotation_player", checks)
        assertTrue(checks.getInt("frames") > 0)
        assertEquals(checks.toString(), checks.getInt("frames"), checks.getInt("orientationOk"))
        assertEquals(checks.toString(), checks.getInt("frames"), checks.getInt("barcodeOk"))
    }

    // ---------------------------------------------------------------- V-N15

    @Test
    fun exportFpsAboveSourceRate_vn15() {
        val runs = JSONArray()
        for ((grid, out) in listOf(30 to 60, 24 to 48, 30 to 50)) {
            val src = "barcode_$grid.mp4"
            val d = grid * 2L
            val layer = SpikeLayer("S", 1, 0, d, TestMedia.uri(src), Scenarios.srcAt(src, 1.0), Scenarios.RECTS.getValue(1))
            val plan = SpikePlan(Scenarios.W, Scenarios.H, out, grid, d, listOf(layer))
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
            val c = mapper.build(plan, store, MapperOptions(probe = probe, includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME))
            val o = ExportHarness(ctx).export(c, File(TestMedia.outDir, "fps_${grid}_$out.mp4"))
            val pts = TestMedia.sampleTimes(o.file, "video/")
            val steps = pts.toList().zipWithNext { a, b -> (b - a).toDouble() }
            val outFrames = (plan.durUs * out + 999_999) / 1_000_000
            // Which source frame each output frame showed (floor rule vs Media3's nearest selection).
            val times = TestMedia.videoSampleTimesUs(src)
            val ruleMismatches = Scenarios.check(plan, probe.frames.toList(), times, listOf(1)).mismatches.size
            runs.put(
                JSONObject().put("gridFps", grid).put("exportFps", out).put("expectedFrames", outFrames)
                    .put("exportedFrames", pts.size).put("frameStepUs", Results.stats(steps))
                    .put("floorRuleMismatches", ruleMismatches),
            )
            assertEquals("frames at $out fps from a $grid fps source", outFrames.toInt(), pts.size)
            assertTrue("constant step", steps.all { Math.abs(it - 1e6 / out) <= 1000 })
        }
        Results.write("VN15_export_fps", JSONObject().put("runs", runs))
    }

    // ---------------------------------------------------------------- V-N17

    private fun fastPlan(): SpikePlan {
        val d = 60L // 2 s at 30 fps; at 4x the item consumes 8 s of source
        val src = "barcode_30.mp4"
        return SpikePlan(Scenarios.W, Scenarios.H, 30, 30, d, listOf(SpikeLayer("F", 1, 0, d, TestMedia.uri(src), Scenarios.srcAt(src, 0.5), Scenarios.RECTS.getValue(1), speed = 4f)))
    }

    @Test
    fun fastItemFrameRateCap_export_vn17() {
        val runs = JSONArray()
        val calls = HashMap<FastItemCap, Int>()
        for (cap in FastItemCap.entries) {
            val plan = fastPlan()
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val rec = EffectRecorder()
            val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
            val c = mapper.build(plan, store, MapperOptions(fastCap = cap, recorder = rec, probe = probe, includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME))
            val json = JSONObject().put("cap", cap.name)
            try {
                val o = ExportHarness(ctx).export(c, File(TestMedia.outDir, "fast_$cap.mp4"))
                val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
                val check = Scenarios.check(plan, probe.frames.toList(), times, listOf(1))
                calls[cap] = rec.of(1).size
                json.put("placeEffectCalls", rec.of(1).size).put("outputFrames", o.result.videoFrameCount)
                    .put("wallMs", o.wallMs).put("barcode", check.json())
            } catch (e: ExportHarness.ExportFailed) {
                json.put("error", e.exception.errorCodeName).put("message", e.exception.message)
            }
            runs.put(json)
        }
        Results.write("VN17_fast_items_export", JSONObject().put("speed", 4).put("compositionFrames", 60).put("runs", runs))
        val uncapped = calls[FastItemCap.NONE] ?: error("uncapped export failed: $runs")
        assertTrue("uncapped item should process ~4x frames: $runs", uncapped >= 200)
        // At least one Media3 mechanism caps the decoded frames at ~project fps (60 + slack).
        assertTrue("no cap mechanism worked: $runs", calls.filterKeys { it != FastItemCap.NONE }.values.any { it <= 75 })
    }

    @Test
    fun fastItemFrameRateCap_player_vn17() {
        val runs = JSONArray()
        for (cap in FastItemCap.entries) {
            val plan = fastPlan()
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val rec = EffectRecorder()
            val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(fastCap = cap, recorder = rec, includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME)))
            val json = JSONObject().put("cap", cap.name)
            try {
                PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
                    h.load(c)
                    h.awaitReady()
                    rec.clear()
                    val ended = h.playToEnd(plan.durUs / 1000 + 60_000)
                    json.put("ended", ended).put("placeEffectCalls", rec.of(1).size).put("rendered", h.rendered.size)
                }
            } catch (t: Throwable) {
                json.put("error", t.toString()).put("cause", t.cause?.toString() ?: "")
            }
            runs.put(json)
        }
        Results.write("VN17_fast_items_player", JSONObject().put("speed", 4).put("compositionFrames", 60).put("runs", runs))
    }
}
