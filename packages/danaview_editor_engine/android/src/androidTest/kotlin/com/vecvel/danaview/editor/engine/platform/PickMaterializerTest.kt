// OWNER: INT-07
//
// PickMaterializer on the device (INT-07 materializePick; M-16, M-18, M-20): a `content://` pick
// (the engine FileProvider as the test provider) is copied with its display name into
// `<work>/picks/<uuid>/`; a `file://` pick with `%20` in its name is decoded like Dart and copied; an
// app-owned copy under work/ is returned as is; a missing file or a deleted content item is
// `mediaOffline`, an unreadable file `permissionDenied`; and while a copy hangs on its source the
// real danaview-io HandlerThread keeps answering, until cancelAll (the engine detach) fails the copy
// with `cancelled` and deletes the partial directory.

package com.vecvel.danaview.editor.engine.platform

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.AfterClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PickMaterializerTest {
    companion object {
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = PlatformTestEngine.create()
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    private val picks get() = ctx.requirePaths().workPicks

    private fun outsideDir(name: String) = File(PlatformTestEngine.app.filesDir, "pick-src/$name").also {
        it.deleteRecursively()
        it.mkdirs()
    }

    private fun materialize(m: PickMaterializer, uri: String): Result<String> = awaitResult { done -> m.materialize(uri, picks, done) }

    private fun codeOf(r: Result<*>) = EngineErrors.from(r.exceptionOrNull() ?: throw AssertionError("expected a failure")).code

    @Test
    fun contentPicksAreCopiedWithTheirDisplayName() {
        val src = File(PlatformTestEngine.providerDir(ctx, "pick-content"), "holiday clip.mp4")
        val data = quickHashPattern(3 * 1024 * 1024 + 17)
        src.writeBytes(data)
        val path = materialize(PickMaterializer(ctx), PlatformTestEngine.contentUri(ctx, src).toString()).getOrThrow()
        val out = File(path)
        assertEquals("holiday clip.mp4", out.name)
        assertEquals(picks.canonicalFile, out.parentFile!!.parentFile!!.canonicalFile)
        assertArrayEquals(data, out.readBytes())
        out.parentFile!!.deleteRecursively()
    }

    @Test
    fun percentEncodedFileUrisAreDecodedLikeDart() {
        val src = File(outsideDir("pick-file"), "My Clip.bin")
        val data = quickHashPattern(100_000)
        src.writeBytes(data)
        val uri = "file://" + src.absolutePath.replace(" ", "%20")
        val path = materialize(PickMaterializer(ctx), uri).getOrThrow()
        assertEquals("My Clip.bin", File(path).name)
        assertArrayEquals(data, File(path).readBytes())
        File(path).parentFile!!.deleteRecursively()
    }

    @Test
    fun appOwnedCopiesUnderWorkAreReturnedAsIs() {
        val src = File(PlatformTestEngine.providerDir(ctx, "pick-asis"), "copy.mp4").apply { writeBytes(ByteArray(10)) }
        assertEquals(src.absolutePath, materialize(PickMaterializer(ctx), "file://" + src.absolutePath).getOrThrow())
        assertEquals(src.absolutePath, materialize(PickMaterializer(ctx), src.absolutePath).getOrThrow())
    }

    @Test
    fun missingAndUnreadableSourcesGetTheirOwnCodes() {
        val m = PickMaterializer(ctx)
        val dir = outsideDir("pick-codes")
        val before = picks.listFiles().orEmpty().toSet()
        assertEquals(EngineErrorCode.mediaOffline, codeOf(materialize(m, File(dir, "gone.mp4").absolutePath)))

        val served = File(PlatformTestEngine.providerDir(ctx, "pick-gone"), "gone.mp4").apply { writeBytes(ByteArray(10)) }
        val uri = PlatformTestEngine.contentUri(ctx, served).toString()
        served.delete()
        assertEquals(EngineErrorCode.mediaOffline, codeOf(materialize(m, uri)))

        val locked = File(dir, "locked.mp4").apply { writeBytes(ByteArray(10)) }
        locked.setReadable(false, false)
        try {
            assumeFalse("the test process can read a mode-000 file (root?)", locked.canRead())
            assertEquals(EngineErrorCode.permissionDenied, codeOf(materialize(m, locked.absolutePath)))
        } finally {
            locked.setReadable(true, true)
        }
        assertEquals("no partial copies", before, picks.listFiles().orEmpty().toSet())
    }

    @Test
    fun danaviewIoKeepsAnsweringWhileACopyHangsUntilCancelAll() {
        val reading = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val hanging = object : InputStream() {
            private var sent = false
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (!sent) {
                    sent = true
                    return minOf(len, 4096)
                }
                reading.countDown()
                closed.await()
                throw IOException("closed")
            }
            override fun close() = closed.countDown()
        }
        val src = File(outsideDir("pick-hang"), "slow.mp4").apply { writeBytes(ByteArray(10)) }
        val m = PickMaterializer({ ctx.pathsOrNull }, { ctx.appContext.contentResolver }, PickCopier(), openFile = { hanging })
        val pending = Pending<String>()
        val before = picks.listFiles().orEmpty().toSet()
        ctx.threads.io.execute { m.materialize(src.absolutePath, picks, pending.completion) }
        assertTrue("copy started", reading.await(10, TimeUnit.SECONDS))
        assertEquals(1, m.running)

        val ioAnswered = CountDownLatch(1)
        ctx.threads.io.execute { ioAnswered.countDown() }
        assertTrue("danaview-io answered during the copy", ioAnswered.await(2, TimeUnit.SECONDS))
        val free = awaitResult<Long>(5_000) { done -> ctx.threads.io.execute { done(Result.success(picks.parentFile!!.usableSpace)) } }
        assertTrue(free.getOrThrow() > 0)

        m.cancelAll()
        assertEquals(EngineErrorCode.cancelled, codeOf(pending.await(5_000)))
        assertEquals(0, m.running)
        val deadline = System.currentTimeMillis() + 5_000
        while (picks.listFiles().orEmpty().toSet() != before && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals("the partial copy is deleted", before, picks.listFiles().orEmpty().toSet())
    }
}
