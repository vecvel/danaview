// OWNER: AND-03
//
// The pure parts of ThumbnailService: frame times per tile, the cache key and `.dvth` format
// (shared with iOS), cell widths, and the priority queue (visible > prefetch > background, FIFO).

package com.vecvel.danaview.editor.engine.thumbs

import com.vecvel.danaview.editor.engine.media.CacheStore
import com.vecvel.danaview.editor.engine.media.ThumbnailQueue
import com.vecvel.danaview.editor.engine.media.ThumbnailService
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailTileMsg
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThumbnailContractTest {
    private fun request(tile: Long, interval: Long = 1000, height: Long = 180, frames: Long = 8, proxy: Boolean = false) =
        ThumbnailRequestMsg(
            media = ResolvedMediaMsg(uri = "/data/x.mp4", fingerprint = "fp-1", isProxy = proxy),
            intervalMs = interval, tileIndex = tile, heightPx = height, framesPerTile = frames, proxy = proxy,
        )

    @Test
    fun frameTimesOfATile() {
        assertEquals(listOf(0L, 1000, 2000, 3000, 4000, 5000, 6000, 7000), ThumbnailService.frameTimesMs(request(0), 8000.0))
        assertEquals(listOf(8000L, 9000, 10000, 11000, 12000, 13000, 14000, 15000), ThumbnailService.frameTimesMs(request(1), 60_000.0))
        assertEquals(listOf(2000L, 2250, 2500, 2750, 3000, 3250, 3500, 3750), ThumbnailService.frameTimesMs(request(1, interval = 250), 8000.0))
    }

    @Test
    fun framesAtOrPastTheEndAreLeftOut() {
        // frame_counter_1080p30 is 8 s: tile 0 at 1.5 s intervals keeps 0..7.5 s minus 9 s and 10.5 s.
        assertEquals(listOf(0L, 1500, 3000, 4500, 6000, 7500), ThumbnailService.frameTimesMs(request(0, interval = 1500), 8000.0))
        assertEquals(emptyList<Long>(), ThumbnailService.frameTimesMs(request(2), 8000.0))
        assertEquals(listOf(0L), ThumbnailService.frameTimesMs(request(0), 1000.0))
    }

    @Test
    fun cacheKeyMatchesIos() {
        assertEquals(CacheStore.stableHash("fp-1|1000|180|0|8|0"), ThumbnailService.cacheKey(request(0)))
        assertEquals("57f7fa2ac1029b392e7486222edc807f", ThumbnailService.cacheKey(request(0)))
        assertEquals(CacheStore.stableHash("fp-1|1000|180|3|8|1"), ThumbnailService.cacheKey(request(3, proxy = true)))
    }

    @Test
    fun cachedTileRoundTrips() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 0xFF.toByte(), 0xD9.toByte())
        val tile = ThumbnailTileMsg(encoded = jpeg, frames = 8, frameWidthPx = 320)
        val bytes = ThumbnailService.encodeCached(tile)
        assertEquals("DVTH", String(bytes, 0, 4, Charsets.US_ASCII))
        assertArrayEquals(byteArrayOf(8, 0, 0, 0, 64, 1, 0, 0), bytes.copyOfRange(4, 12))
        val back = ThumbnailService.decodeCached(bytes)!!
        assertEquals(8L, back.frames)
        assertEquals(320L, back.frameWidthPx)
        assertArrayEquals(jpeg, back.encoded)
        assertNull(ThumbnailService.decodeCached("DVTX".toByteArray() + ByteArray(12)))
        assertNull(ThumbnailService.decodeCached(ByteArray(12)))
    }

    @Test
    fun cellWidthKeepsTheDisplayAspect() {
        assertEquals(320, ThumbnailService.frameWidth(1920, 1080, 180))
        assertEquals(101, ThumbnailService.frameWidth(720, 1280, 180))
        assertEquals(180, ThumbnailService.frameWidth(512, 512, 180))
        assertEquals(1, ThumbnailService.frameWidth(1, 4000, 180))
        assertEquals(180, ThumbnailService.frameWidth(0, 0, 180))
    }

    private data class Item(val id: String, val priority: ThumbPriorityMsg, val seq: Long)

    @Test
    fun queueServesVisibleThenPrefetchThenBackgroundFifo() {
        val queue = ThumbnailQueue<Item>({ it.priority }, { it.seq })
        queue.add(Item("bg1", ThumbPriorityMsg.BACKGROUND, 1))
        queue.add(Item("pre1", ThumbPriorityMsg.PREFETCH, 2))
        queue.add(Item("vis1", ThumbPriorityMsg.VISIBLE, 3))
        queue.add(Item("pre2", ThumbPriorityMsg.PREFETCH, 4))
        queue.add(Item("vis2", ThumbPriorityMsg.VISIBLE, 5))
        queue.add(Item("bg2", ThumbPriorityMsg.BACKGROUND, 6))
        assertEquals("pre2", queue.removeIf { it.id == "pre2" }?.id)
        assertNull(queue.removeIf { it.id == "missing" })
        val order = generateSequence { queue.poll() }.map { it.id }.toList()
        assertEquals(listOf("vis1", "vis2", "pre1", "bg1", "bg2"), order)
        assertEquals(0, queue.size)
    }

    @Test
    fun concurrencyLimits() {
        assertEquals(2, ThumbnailService.MAX_RENDERS)
        assertEquals(8, ThumbnailService.MAX_IN_FLIGHT)
        assertEquals(70, ThumbnailService.JPEG_QUALITY)
    }
}
