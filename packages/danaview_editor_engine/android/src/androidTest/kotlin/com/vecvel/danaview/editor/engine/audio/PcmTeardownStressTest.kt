// OWNER: AND-04
//
// QA-05 native crash regression (soak run b on d2600495): closing a PcmStream while its decoder's
// input callback was copying a sample into a codec input buffer crashed the process (SIGSEGV in
// memcpy <- GetByteArrayRegion on "danaview-pcm"): stop()/release() ran on the reading thread and
// unmapped the buffer mid-copy. The decoder now tears down on the callback thread. These tests
// close and cancel the AAC decoder at random points while its input is being fed, many times; the
// old code crashed the instrumentation process here, the fix must survive every round, leave no
// "danaview-pcm" thread behind and still decode a full range afterwards.

package com.vecvel.danaview.editor.engine.audio

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.PcmDecoder
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random

@RunWith(AndroidJUnit4::class)
class PcmTeardownStressTest {
    companion object {
        private const val TAG = "DanaviewAudioTest"
        private const val ROUNDS = 150
        private lateinit var ctx: EngineContext
        private lateinit var clip: File

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = AudioTestEngine.create("pcm-teardown-test")
            // AAC 48 kHz mono, 6 s (the decoder path, not the raw-PCM one).
            clip = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/clap_flash_av.mp4")
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }

        private fun pcmThreads(): Int = Thread.getAllStackTraces().keys.count { it.name == "danaview-pcm" && it.isAlive }

        /** Waits for the decoder threads of closed streams to end (their teardown quits them). */
        private fun awaitPcmThreads(atMost: Int) {
            val deadline = System.nanoTime() + 5_000_000_000L
            while (pcmThreads() > atMost && System.nanoTime() < deadline) Thread.sleep(20)
            assertTrue("danaview-pcm threads left: ${pcmThreads()} (at most $atMost)", pcmThreads() <= atMost)
        }
    }

    @Test
    fun closeAtRandomPointsWhileInputIsFed() {
        val before = pcmThreads()
        val random = Random(5150)
        var chunks = 0L
        repeat(ROUNDS) {
            val reads = random.nextInt(0, 6)
            PcmDecoder(ctx).open(clip.absolutePath).use { pcm ->
                for (i in 0 until reads) {
                    val chunk = pcm.read() ?: break
                    chunks += 1
                    assertTrue(chunk.isNotEmpty())
                }
                // Close with input callbacks still arriving (the codec feeds ahead of the reader).
                if (random.nextBoolean()) Thread.sleep(random.nextLong(0, 4))
            }
        }
        Log.i(TAG, "PCM close stress: $ROUNDS rounds, $chunks chunks read")
        awaitPcmThreads(before)
    }

    @Test
    fun cancelFromAnotherThreadWhileDecoding() {
        val before = pcmThreads()
        val random = Random(505)
        var cancelled = 0
        repeat(ROUNDS) {
            val cancel = AtomicBoolean(false)
            val delayMs = random.nextLong(0, 40)
            val canceller = Thread {
                try {
                    Thread.sleep(delayMs)
                } catch (e: InterruptedException) {
                    return@Thread
                }
                cancel.set(true)
            }.apply { start() }
            try {
                PcmDecoder(ctx).open(clip.absolutePath, startUs = random.nextLong(0, 3_000_000)) { cancel.get() }.use { pcm ->
                    while (pcm.read() != null) Unit
                }
            } catch (e: EngineException) {
                assertEquals(EngineErrorCode.cancelled, e.code)
                cancelled += 1
            } finally {
                canceller.interrupt()
                canceller.join()
            }
        }
        Log.i(TAG, "PCM cancel stress: $ROUNDS rounds, $cancelled cancelled")
        assertTrue("some rounds must be cancelled mid-decode ($cancelled)", cancelled > 0)
        awaitPcmThreads(before)
    }

    @Test
    fun closeTwiceIsHarmlessAndAFullDecodeStillWorks() {
        val stream = PcmDecoder(ctx).open(clip.absolutePath, startUs = 1_000_000, endUs = 2_000_000)
        stream.read()
        stream.close()
        stream.close()
        PcmDecoder(ctx).open(clip.absolutePath, startUs = 1_000_000, endUs = 2_000_000).use { pcm ->
            var frames = 0L
            while (true) frames += (pcm.read() ?: break).size / pcm.channels
            // 1 s at 48 kHz, sample-accurate (± 1 ms like the speech tests).
            assertTrue("frames $frames", kotlin.math.abs(frames - 48_000L) <= 48)
        }
    }
}
