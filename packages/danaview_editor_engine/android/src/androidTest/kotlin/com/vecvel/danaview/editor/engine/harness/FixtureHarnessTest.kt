// OWNER: ENG-09
//
// Proves the example host packs the shared fixtures into the plugin's test APK and that ENG-05's
// media decodes on the device with a readable frame barcode.
//
// Frame-exact timing is NOT asserted here; that belongs to the Android engine (AND-xx) and QA-02.
// Finding (2026-10-10, API 35 arm64 emulator): frame_counter_1080p30.mp4 is standard AVFoundation
// output (ctts v0 offsets + elst media_time 40/600 = a 2-frame B-frame delay), yet
// MediaMetadataRetriever.getFrameAtTime(160.5/30 s, OPTION_CLOSEST) and getFrameAtIndex(160) both
// return barcode 162, i.e. the platform retriever's timeline runs 2 frames ahead of the edit list
// (ffmpeg, AVFoundation and the JVM test agree on index == frame number). The test logs the
// measured offset under the tag DanaviewFixtureHarness.

package com.vecvel.danaview.editor.engine.harness

import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeStatus
import com.vecvel.danaview.editor.engine.support.read
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FixtureHarnessTest {
    @Test
    fun everyFixtureTreeIsPacked() {
        assertTrue(TestFixtures.list(FixtureTree.ENGINE, "media").contains("frame_counter_1080p30.mp4"))
        assertTrue(TestFixtures.list(FixtureTree.CORE).contains("vectors"))
        assertTrue(TestFixtures.list(FixtureTree.ENGINE_API).isNotEmpty())
    }

    @Test
    fun manifestParses() {
        val manifest = JSONObject(TestFixtures.readText(FixtureTree.ENGINE, "media/manifest.json"))
        assertTrue(manifest.has("files"))
    }

    @Test
    fun frameCounterDecodesWithAReadableBarcode() {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/frame_counter_1080p30.mp4")
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            // The middle of frame 160 (160.5 / 30 s).
            val bitmap = retriever.getFrameAtTime(5_350_000L, MediaMetadataRetriever.OPTION_CLOSEST)
            assertNotNull("decoded frame", bitmap)
            val reading = FrameBarcode.read(bitmap!!)
            assertEquals(FrameBarcodeStatus.OK, reading.status)
            val index = reading.index!!
            Log.i("DanaviewFixtureHarness", "frame_counter_1080p30 @160.5/30 s -> barcode $index (offset ${index - 160})")
            // Readable and within the B-frame reorder window (see the finding above).
            assertTrue("barcode $index too far from 160", index in 158..162)
        } finally {
            retriever.release()
        }
    }
}
