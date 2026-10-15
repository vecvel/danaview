package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.preview.fallback.VideoDeck
import org.junit.Test

class DiagTmpTest {
    @Test
    fun rangePlayback() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        val q3 = FallbackPlans.QUADRANTS.take(3)
        RangeHarness("and18_diag", plan, q3).use { h ->
            val file = h.rig.render(RangeCut.cut(plan, 31, 92), "diag").first
            h.bind(listOf(h.rig.msg(31, 92, h.grid, file)))
            h.seekExact(0, 30_000)
            h.sink.awaitK(0)
            Thread.sleep(300)
            h.sink.clear()
            h.host.dropped.clear()
            VideoDeck.DEBUG = true
            try {
                h.playToEnd(0, 60_000)
            } finally {
                VideoDeck.DEBUG = false
            }
            Thread.sleep(200)
            val s = h.stats()
            log18("diag shown=${h.sink.frames.map { it.k }} dropped=${h.host.dropped.toList()} held=${s.held} missed=${s.missed} rebuffers=${s.rebuffers} range=${s.rangeFrames} decks=${s.deckCount}")
        }
    }
}
