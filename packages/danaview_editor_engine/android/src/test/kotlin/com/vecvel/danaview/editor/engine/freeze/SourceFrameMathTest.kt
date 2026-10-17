// OWNER: AND-06
//
// JVM tests of AND-06's pure parts: the byte-bounded LRU of the source-frame cache (memory bound,
// eviction order, oversize frames, trims), the 3x3 colour sample window and average, the long-side
// sizing, the tier budgets, and the exact-frame seek position rule (floor(pts / 1000) ms, ARCH §5).

package com.vecvel.danaview.editor.engine.freeze

import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.preview.ColorSampling
import com.vecvel.danaview.editor.engine.preview.FrameLru
import com.vecvel.danaview.editor.engine.preview.Sizing
import com.vecvel.danaview.editor.engine.preview.SourceFrameCache
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceFrameMathTest {
    private class Frame(val bytes: Long)

    @Test
    fun lruStaysWithinItsBudgetAndEvictsLeastRecentlyUsedFirst() {
        val lru = FrameLru<Int, Frame>(100) { it.bytes }
        assertTrue(lru.put(1, Frame(40)))
        assertTrue(lru.put(2, Frame(40)))
        assertEquals(80, lru.totalBytes)
        lru.get(1) // 1 is now the most recently used
        assertTrue(lru.put(3, Frame(40)))
        assertEquals("2 was the least recently used", listOf(1, 3), lru.keys())
        assertEquals(80, lru.totalBytes)
        assertNull(lru.get(2))
        for (k in 10 until 60) {
            lru.put(k, Frame(7 + (k % 5).toLong()))
            assertTrue("never over budget", lru.totalBytes <= 100)
        }
    }

    @Test
    fun aFrameLargerThanTheBudgetIsNotKept() {
        val lru = FrameLru<Int, Frame>(100) { it.bytes }
        lru.put(1, Frame(60))
        assertFalse(lru.put(2, Frame(101)))
        assertEquals(listOf(1), lru.keys())
        assertEquals(60, lru.totalBytes)
    }

    @Test
    fun replacingAKeyCountsItsBytesOnce() {
        val lru = FrameLru<Int, Frame>(100) { it.bytes }
        lru.put(1, Frame(30))
        lru.put(1, Frame(50))
        assertEquals(50, lru.totalBytes)
        assertEquals(1, lru.size)
    }

    @Test
    fun trimAndRemoveIf() {
        val lru = FrameLru<String, Frame>(100) { it.bytes }
        lru.put("a1", Frame(20))
        lru.put("b1", Frame(20))
        lru.put("a2", Frame(20))
        lru.put("b2", Frame(20))
        lru.trimTo(45)
        assertEquals("the two oldest go", listOf("a2", "b2"), lru.keys())
        lru.removeIf { it.startsWith("a") }
        assertEquals(listOf("b2"), lru.keys())
        assertEquals(20, lru.totalBytes)
        lru.trimTo(0)
        assertEquals(0, lru.size)
        assertEquals(0, lru.totalBytes)
    }

    @Test
    fun tierBudgetsMatchIosAndHoldTwo1080pFramesOnTheWeakestTier() {
        val mb = 1024L * 1024L
        assertEquals(16 * mb, SourceFrameCache.budgetFor(DeviceTierMsg.MINIMAL))
        assertEquals(24 * mb, SourceFrameCache.budgetFor(DeviceTierMsg.LOW))
        assertEquals(64 * mb, SourceFrameCache.budgetFor(DeviceTierMsg.MID))
        assertEquals(192 * mb, SourceFrameCache.budgetFor(DeviceTierMsg.HIGH))
        val frame1080 = 1920L * 1080 * 4
        assertEquals(2L, SourceFrameCache.budgetFor(DeviceTierMsg.MINIMAL) / frame1080)
        // A cache built with an explicit budget never reads the device tier.
        val lru = FrameLru<Int, Frame>(SourceFrameCache.budgetFor(DeviceTierMsg.MINIMAL)) { it.bytes }
        repeat(10) { lru.put(it, Frame(frame1080)) }
        assertEquals(2, lru.size)
    }

    @Test
    fun colourWindowIsThreeByThreeAroundThePointAndShiftedInsideAtEdges() {
        assertEquals(ColorSampling.Window(49, 29, 3, 3), ColorSampling.window(100, 60, 0.5, 0.5))
        assertEquals(ColorSampling.Window(0, 0, 3, 3), ColorSampling.window(100, 60, 0.0, 0.0))
        assertEquals(ColorSampling.Window(97, 57, 3, 3), ColorSampling.window(100, 60, 1.0, 1.0))
        assertEquals("out-of-range points are clamped", ColorSampling.Window(97, 0, 3, 3), ColorSampling.window(100, 60, 7.0, -3.0))
        assertEquals("tiny frames use what exists", ColorSampling.Window(0, 0, 2, 1), ColorSampling.window(2, 1, 0.9, 0.9))
    }

    @Test
    fun colourAverageIsPerComponentOverTheWindow() {
        val red = 0xFFFF0000.toInt()
        val blue = 0xFF0000FF.toInt()
        val c = ColorSampling.average(intArrayOf(red, red, red, blue, blue, blue, red, red, red))
        assertEquals(6.0 / 9, c.red, 1e-9)
        assertEquals(0.0, c.green, 1e-9)
        assertEquals(3.0 / 9, c.blue, 1e-9)
        assertEquals(1.0, c.alpha, 1e-9)
        val grey = ColorSampling.average(IntArray(9) { 0xFF808080.toInt() })
        assertEquals(128.0 / 255, grey.red, 1e-9)
    }

    @Test
    fun longSideBoundKeepsTheAspectAndNeverEnlarges() {
        assertEquals(270, Sizing.boundedHeight(1920, 1080, 480))
        assertEquals("portrait: the height is the long side", 480, Sizing.boundedHeight(720, 1280, 480))
        assertNull(Sizing.boundedHeight(640, 360, 1280))
        assertNull(Sizing.boundedHeight(1920, 1080, 1920))
        assertEquals(171, Sizing.widthForHeight(1280, 720, 96))
        assertEquals(96, Sizing.widthForHeight(0, 0, 96))
    }

    @Test
    fun exactSeekPositionIsTheFloorMillisecondOfTheFramePts() {
        assertEquals(0, ExactFrames.seekPositionMs(0))
        assertEquals(33, ExactFrames.seekPositionMs(33_333))
        assertEquals(33, ExactFrames.seekPositionMs(33_334))
        assertEquals(5_333, ExactFrames.seekPositionMs(5_333_333))
        assertEquals(1_000, ExactFrames.seekPositionMs(1_000_000))
        assertEquals("negative times clamp to zero", 0, ExactFrames.seekPositionMs(-5))
        // 30 fps frame k: floor(pts/1000) ms is above frame k-1's pts, so the first frame with
        // pts >= that position is frame k (Media3's EXACT rule, AND-01 V-N18).
        for (k in 1 until 2_000) {
            val pts = Math.floorDiv(2L * k * 1_000_000L + 30, 60L)
            val prev = Math.floorDiv(2L * (k - 1) * 1_000_000L + 30, 60L)
            assertTrue(ExactFrames.seekPositionMs(pts) * 1000 > prev)
            assertTrue(ExactFrames.seekPositionMs(pts) * 1000 <= pts)
        }
        assertTrue(ExactFrames.isFrame(33, 33_333))
        assertTrue("FrameExtractor rounding tolerance 1 ms", ExactFrames.isFrame(34, 33_333))
        assertFalse(ExactFrames.isFrame(66, 33_333))
        assertEquals(500L, ExactFrames.EPSILON_US)
    }
}
