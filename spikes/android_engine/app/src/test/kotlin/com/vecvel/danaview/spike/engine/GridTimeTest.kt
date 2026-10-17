package com.vecvel.danaview.spike.engine

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** GridTime agrees with the shared vectors written by CORE-02 (frame_grid.json, ARCH §5). */
class GridTimeTest {
    private fun vectors(): JSONObject {
        // Unit tests run with the module directory as working directory.
        val candidates = listOf(
            "../../../packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json",
            "../../packages/danaview_editor_core/test/fixtures/vectors/frame_grid.json",
        )
        val file = candidates.map(::File).first { it.exists() }
        return JSONObject(file.readText())
    }

    @Test
    fun matchesSharedFrameGridVectors() {
        val rates = vectors().getJSONArray("rates")
        var checked = 0
        for (i in 0 until rates.length()) {
            val rate = rates.getJSONObject(i)
            val fps = rate.getInt("fps")
            val half = rate.getLong("halfFrameMinus1Us")
            val frames = rate.getJSONArray("frames")
            for (j in 0 until frames.length()) {
                val f = frames.getJSONObject(j)
                val k = f.getLong("k")
                val t = GridTime.timeOfFrame(k, fps)
                val p = GridTime.platformTimeOfFrame(k, fps)
                assertEquals("timeOfFrame fps=$fps k=$k", f.getLong("timeOfFrame"), t)
                assertEquals("floor fps=$fps k=$k", f.getLong("floorTime"), GridTime.floorTimeOfFrame(k, fps))
                assertEquals("P fps=$fps k=$k", f.getLong("platformTime"), p)
                val fi = f.getJSONObject("frameIndexOf")
                assertEquals(fi.getLong("tMinus1"), GridTime.frameIndexOf(t - 1, fps))
                assertEquals(fi.getLong("t"), GridTime.frameIndexOf(t, fps))
                assertEquals(fi.getLong("tPlus1"), GridTime.frameIndexOf(t + 1, fps))
                val n = f.getJSONObject("nearest")
                assertEquals(n.getLong("timeOfFrame"), GridTime.frameIndexNearest(t, fps))
                assertEquals(n.getLong("floorTime"), GridTime.frameIndexNearest(GridTime.floorTimeOfFrame(k, fps), fps))
                assertEquals(n.getLong("platformTime"), GridTime.frameIndexNearest(p, fps))
                assertEquals(f.getLong("nearestAtPlatformPlusHalf"), GridTime.frameIndexNearest(p + half, fps))
                assertEquals(f.getLong("nearestAtPlatformMinusHalf"), GridTime.frameIndexNearest(p - half, fps))
                checked++
            }
        }
        assert(checked > 60) { "too few vectors: $checked" }
    }

    @Test
    fun platformTimeIsAtMostOneMicrosecondBeforePlanEdge() {
        for (fps in intArrayOf(24, 25, 30, 48, 50, 60)) {
            for (k in 0L until 10_000L) {
                val d = GridTime.timeOfFrame(k, fps) - GridTime.platformTimeOfFrame(k, fps)
                assert(d in 0..1) { "fps=$fps k=$k d=$d" }
            }
        }
    }
}
