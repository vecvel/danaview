// OWNER: INT-07
//
// PickCopier (M-16, M-18) on the JVM: the copy lands in `<intoDir>/<uuid>/<name>`; it runs on its
// own thread (never the caller's); a source that stops sending (or never answers) fails with `io`
// after the stall / open timeout, with the partial directory deleted and one completion; a cancel
// fails with `cancelled`, deletes the partial copy and completes once; error codes: a known size
// that does not fit (with the margin) → diskFull before anything is written, ENOSPC on the output →
// diskFull, other output errors → io (never mediaOffline / permissionDenied), an unreadable source →
// permissionDenied, a missing source → mediaOffline, a failed read → io. And danaview-io stays
// responsive while a copy hangs: the glue's isRecording, freeBytes and probe answer during a copy,
// which is then cancelled when the engine detaches. An abort fires the source's hook (the provider
// call's CancellationSignal) so a hung query/open returns, and deletes the partial copy off the
// caller's thread even when the copy thread never wakes.

package com.vecvel.danaview.editor.engine.platform

import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.core.MainScheduler
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.glue.EngineHostApiImpl
import com.vecvel.danaview.editor.engine.glue.EngineRootPort
import com.vecvel.danaview.editor.engine.glue.PlatformHostApiImpl
import com.vecvel.danaview.editor.engine.glue.PlatformPort
import com.vecvel.danaview.editor.engine.glue.RecorderHostApiImpl
import com.vecvel.danaview.editor.engine.glue.RecorderPort
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.ProbeMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.EnginePigeonError
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** DV_PERF_STRICT=1 (environment or system property): absolute timing limits apply (a quiet machine). */
private val perfStrict = System.getenv("DV_PERF_STRICT") == "1" || System.getProperty("DV_PERF_STRICT") == "1"

class PickCopierTest {
    private val root: File = Files.createTempDirectory("pickcopier").toFile()
    private val intoDir = File(root, "work/picks")

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    /** Collects completions; [await] returns the first, [count] how many arrived. */
    private class Done<T> {
        val results = LinkedBlockingQueue<Result<T>>()
        val threads = LinkedBlockingQueue<String>()
        val count = AtomicInteger()
        val completion: Completion<T> = { r ->
            count.incrementAndGet()
            threads.add(Thread.currentThread().name)
            results.add(r)
        }

        fun await(timeoutMs: Long = 10_000): Result<T> =
            results.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: throw AssertionError("no completion within $timeoutMs ms")
    }

    /** A stream that sends [prefix] and then blocks until closed (a hung cloud provider). */
    private class HangingStream(private val prefix: ByteArray = ByteArray(0)) : InputStream() {
        private var pos = 0
        private val closed = CountDownLatch(1)
        val reading = CountDownLatch(1)

        override fun read(): Int = throw UnsupportedOperationException()

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (pos < prefix.size) {
                val n = minOf(len, prefix.size - pos)
                System.arraycopy(prefix, pos, b, off, n)
                pos += n
                return n
            }
            reading.countDown()
            closed.await()
            throw IOException("Stream closed")
        }

        override fun close() = closed.countDown()
    }

    private fun codeOf(r: Result<*>): EngineErrorCode {
        val e = r.exceptionOrNull() ?: throw AssertionError("expected a failure, got ${r.getOrNull()}")
        return EngineErrors.from(e).code
    }

    private fun awaitGone(dirs: () -> List<File>, timeoutMs: Long = 5_000) {
        val end = System.nanoTime() + timeoutMs * 1_000_000
        while (dirs().isNotEmpty() && System.nanoTime() < end) Thread.sleep(20)
        assertEquals("partial copies left behind", emptyList<File>(), dirs())
    }

    private fun leftovers(): List<File> = intoDir.listFiles()?.toList() ?: emptyList()

    private fun bytes(n: Int) = ByteArray(n) { (it * 31 + 7).toByte() }

    // ---- the copy ----

    @Test
    fun copiesIntoAUniqueDirectoryOnItsOwnThread() {
        val data = bytes(700_000)
        val done = Done<String>()
        PickCopier().start(intoDir, { PickSource("clip.mp4", data.size.toLong()) { ByteArrayInputStream(data) } }, done.completion)
        val path = done.await().getOrThrow()
        val out = File(path)
        assertEquals("clip.mp4", out.name)
        assertEquals(intoDir.canonicalFile, out.parentFile!!.parentFile!!.canonicalFile)
        assertArrayEquals(data, out.readBytes())
        assertTrue(done.threads.single().startsWith("danaview-copy-"))
        val second = Done<String>()
        PickCopier().start(intoDir, { PickSource("clip.mp4", null) { ByteArrayInputStream(data) } }, second.completion)
        assertNotEquals(path, second.await().getOrThrow())
        Thread.sleep(50)
        assertEquals(1, done.count.get())
    }

    // ---- stall timeout ----

    @Test
    fun aSourceThatStopsSendingFailsWithIoAndLeavesNothing() {
        val stream = HangingStream(bytes(300_000))
        val done = Done<String>()
        val copier = PickCopier(openTimeoutMs = 10_000, stallTimeoutMs = 300)
        val started = System.nanoTime()
        copier.start(intoDir, { PickSource("clip.mp4", null) { stream } }, done.completion)
        val r = done.await()
        val tookMs = (System.nanoTime() - started) / 1_000_000
        assertEquals(EngineErrorCode.io, codeOf(r))
        assertTrue("retryable", EngineErrors.from(r.exceptionOrNull()!!).retryable)
        // Never before the 300 ms stall timeout (both modes); how soon after is timing: 5 s with
        // DV_PERF_STRICT=1, 30 s on a loaded CI host.
        val lateMs = if (perfStrict) 5_000L else 30_000L
        assertTrue("stalled after $tookMs ms (bound 250..$lateMs)", tookMs in 250..lateMs)
        awaitGone(::leftovers)
        Thread.sleep(400)
        assertEquals(1, done.count.get())
    }

    @Test
    fun aSourceThatNeverAnswersFailsAfterTheOpenTimeout() {
        val never = CountDownLatch(1)
        val done = Done<String>()
        PickCopier(openTimeoutMs = 300, stallTimeoutMs = 60_000).start(intoDir, {
            never.await(30, TimeUnit.SECONDS) // a provider query that hangs
            PickSource("clip.mp4", null) { ByteArrayInputStream(ByteArray(1)) }
        }, done.completion)
        assertEquals(EngineErrorCode.io, codeOf(done.await()))
        never.countDown()
        Thread.sleep(200)
        assertEquals(1, done.count.get())
        assertEquals(emptyList<File>(), leftovers())
    }

    // ---- cancel ----

    @Test
    fun cancelFailsWithCancelledDeletesThePartialCopyAndCompletesOnce() {
        val stream = HangingStream(bytes(512 * 1024))
        val done = Done<String>()
        val handle = PickCopier(stallTimeoutMs = 60_000).start(intoDir, { PickSource("clip.mp4", null) { stream } }, done.completion)
        assertTrue(stream.reading.await(10, TimeUnit.SECONDS))
        assertEquals(1, leftovers().size) // the partial copy exists while it runs
        handle.cancel()
        handle.cancel()
        assertEquals(EngineErrorCode.cancelled, codeOf(done.await()))
        awaitGone(::leftovers)
        Thread.sleep(200)
        assertEquals(1, done.count.get())
    }

    @Test
    fun cancelBeforeTheCopyThreadRunsCopiesNothing() {
        val gate = CountDownLatch(1)
        val pool: ExecutorService = Executors.newSingleThreadExecutor()
        try {
            pool.execute { gate.await() }
            val done = Done<String>()
            val opened = AtomicInteger()
            val handle = PickCopier(executor = pool).start(intoDir, {
                opened.incrementAndGet()
                PickSource("clip.mp4", null) { ByteArrayInputStream(ByteArray(10)) }
            }, done.completion)
            handle.cancel()
            gate.countDown()
            assertEquals(EngineErrorCode.cancelled, codeOf(done.await()))
            pool.submit {}.get(5, TimeUnit.SECONDS)
            assertEquals(0, opened.get())
            assertEquals(emptyList<File>(), leftovers())
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun anAbortFiresTheHookSoAHungProviderCallReturnsAndFreesItsThread() {
        // A provider query that ignores interrupts and returns only when its CancellationSignal fires.
        for (stall in listOf(false, true)) {
            val signal = CountDownLatch(1)
            val returned = CountDownLatch(1)
            val hooks = AtomicInteger()
            val done = Done<String>()
            val copier = if (stall) PickCopier(openTimeoutMs = 300, stallTimeoutMs = 60_000) else PickCopier(stallTimeoutMs = 60_000)
            val handle = copier.start(intoDir, {
                try {
                    while (!signal.await(10, TimeUnit.SECONDS)) Unit
                    throw IllegalStateException("OperationCanceledException") // what ContentResolver.query throws
                } finally {
                    returned.countDown()
                }
            }, { hooks.incrementAndGet(); signal.countDown() }, done.completion)
            if (!stall) {
                Thread.sleep(100)
                handle.cancel()
                handle.cancel()
            }
            val code = codeOf(done.await())
            assertEquals(if (stall) EngineErrorCode.io else EngineErrorCode.cancelled, code)
            assertTrue("the provider call returned (stall=$stall)", returned.await(5, TimeUnit.SECONDS))
            Thread.sleep(200)
            assertEquals(1, hooks.get())
            assertEquals(1, done.count.get())
            assertEquals(emptyList<File>(), leftovers())
        }
    }

    @Test
    fun cancelDeletesThePartialCopyOffTheCallersThreadEvenIfTheCopyThreadNeverWakes() {
        val release = CountDownLatch(1)
        val reading = CountDownLatch(1)
        val stuck = object : InputStream() { // ignores close and interrupts (a hung provider pipe)
            var sent = false
            @Volatile var woke = false
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (!sent) {
                    sent = true
                    return len.coerceAtMost(4096)
                }
                reading.countDown()
                while (true) {
                    try {
                        release.await()
                        woke = true
                        return -1
                    } catch (e: InterruptedException) {
                        // ignored, like a binder read
                    }
                }
            }
        }
        val watchdog = ScheduledThreadPoolExecutor(1)
        val watchdogBusy = CountDownLatch(1)
        try {
            val done = Done<String>()
            val handle = PickCopier(watchdog = watchdog, stallTimeoutMs = 60_000).start(intoDir, { PickSource("clip.mp4", null) { stuck } }, done.completion)
            assertTrue(reading.await(10, TimeUnit.SECONDS))
            assertEquals(1, leftovers().size)
            watchdog.execute { watchdogBusy.await() } // hold the watchdog so the delete waits there
            handle.cancel()
            assertEquals(EngineErrorCode.cancelled, codeOf(done.await()))
            assertEquals("the caller's thread deleted nothing", 1, leftovers().size)
            watchdogBusy.countDown()
            awaitGone(::leftovers) // deleted by the watchdog while the copy thread is still stuck
            assertTrue("the copy thread is still stuck", !stuck.woke)
        } finally {
            watchdogBusy.countDown()
            release.countDown()
            watchdog.shutdownNow()
        }
    }

    // ---- error codes (M-18) ----

    @Test
    fun aKnownSizeThatDoesNotFitIsDiskFullBeforeAnythingIsWritten() {
        val opened = AtomicInteger()
        val copier = PickCopier(freeBytes = { 100L * 1024 * 1024 }, marginBytes = 64L * 1024 * 1024)
        val done = Done<String>()
        copier.start(intoDir, {
            PickSource("big.mp4", 40L * 1024 * 1024) { opened.incrementAndGet(); ByteArrayInputStream(ByteArray(1)) }
        }, done.completion)
        assertEquals(EngineErrorCode.diskFull, codeOf(done.await()))
        assertEquals(0, opened.get())
        assertEquals(emptyList<File>(), leftovers())
        // The same size fits with the margin to spare on a bigger volume.
        val fits = Done<String>()
        PickCopier(freeBytes = { 200L * 1024 * 1024 }).start(intoDir, {
            PickSource("big.mp4", 40L * 1024 * 1024) { ByteArrayInputStream(ByteArray(3)) }
        }, fits.completion)
        assertTrue(fits.await().isSuccess)
    }

    @Test
    fun outputFailuresAreDiskFullOrIoNeverBlamingTheSource() {
        fun outputCode(error: IOException, free: Long = Long.MAX_VALUE / 2): EngineErrorCode {
            val done = Done<String>()
            PickCopier(freeBytes = { free }, openOutput = { throw error }).start(intoDir, {
                PickSource("clip.mp4", null) { ByteArrayInputStream(ByteArray(10)) }
            }, done.completion)
            return codeOf(done.await())
        }
        assertEquals(EngineErrorCode.diskFull, outputCode(FileNotFoundException("/x: open failed: ENOSPC (No space left on device)")))
        assertEquals(EngineErrorCode.io, outputCode(FileNotFoundException("/x: open failed: EACCES (Permission denied)")))
        assertEquals(EngineErrorCode.io, outputCode(FileNotFoundException("/x: open failed: ENAMETOOLONG (File name too long)")))
        assertEquals(EngineErrorCode.diskFull, outputCode(IOException("write failed"), free = 0))
        assertEquals(emptyList<File>(), leftovers())
    }

    @Test
    fun aFullDiskMidCopyIsDiskFullAndThePartialCopyIsDeleted() {
        val done = Done<String>()
        val copier = PickCopier(openOutput = { f ->
            object : OutputStream() {
                private val real = FileOutputStream(f)
                private var written = 0
                override fun write(b: Int) = throw UnsupportedOperationException()
                override fun write(b: ByteArray, off: Int, len: Int) {
                    if (written > 0) throw IOException("write failed: ENOSPC (No space left on device)")
                    real.write(b, off, len)
                    written += len
                }
                override fun close() = real.close()
            }
        })
        copier.start(intoDir, { PickSource("clip.mp4", null) { ByteArrayInputStream(bytes(1_000_000)) } }, done.completion)
        assertEquals(EngineErrorCode.diskFull, codeOf(done.await()))
        awaitGone(::leftovers)
    }

    @Test
    fun sourceFailuresArePermissionDeniedMediaOfflineOrIo() {
        fun sourceCode(open: () -> InputStream): EngineErrorCode {
            val done = Done<String>()
            PickCopier().start(intoDir, { PickSource("clip.mp4", null, open) }, done.completion)
            return codeOf(done.await())
        }
        assertEquals(EngineErrorCode.permissionDenied, sourceCode { throw SecurityException("Permission Denial: reading provider") })
        assertEquals(EngineErrorCode.permissionDenied, sourceCode { throw FileNotFoundException("/s/a.mp4: open failed: EACCES (Permission denied)") })
        assertEquals(EngineErrorCode.permissionDenied, sourceCode { throw FileNotFoundException("/s/a.mp4 (Permission denied)") })
        assertEquals(EngineErrorCode.mediaOffline, sourceCode { throw FileNotFoundException("/s/a.mp4: open failed: ENOENT (No such file or directory)") })
        assertEquals(EngineErrorCode.mediaOffline, sourceCode { throw FileNotFoundException("No item at content://x/1") })
        assertEquals(EngineErrorCode.io, sourceCode { throw IOException("provider crashed") })
        val failingRead = object : InputStream() {
            override fun read(): Int = throw IOException("EIO")
            override fun read(b: ByteArray, off: Int, len: Int): Int = throw IOException("EIO")
        }
        assertEquals(EngineErrorCode.io, sourceCode { failingRead })
        // A query that throws SecurityException (revoked grant) before the open.
        val done = Done<String>()
        PickCopier().start(intoDir, { throw SecurityException("revoked") }, done.completion)
        assertEquals(EngineErrorCode.permissionDenied, codeOf(done.await()))
        awaitGone(::leftovers)
    }

    // ---- danaview-io stays responsive (M-16) ----

    /** A real thread per lane and for main (the glue's threading, without a Looper). */
    private class ThreadLane(override val spec: LaneSpec) : Lane {
        private val pool = Executors.newSingleThreadExecutor { r -> Thread(r, spec.threadName).apply { isDaemon = true } }
        override val looper = null
        override val handler = null
        override fun execute(command: Runnable) = pool.execute(command)
        override fun isCurrentThread() = Thread.currentThread().name == spec.threadName
        override fun quit() {
            pool.shutdownNow()
        }
    }

    private class ThreadMain : MainScheduler {
        private val pool = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "test-main").apply { isDaemon = true } }
        override fun execute(command: Runnable) = pool.execute(command)
        override fun postDelayed(task: Runnable, delayMs: Long): Cancellable {
            val f = pool.schedule(task, delayMs, TimeUnit.MILLISECONDS)
            return Cancellable { f.cancel(false) }
        }
        override fun nowMs() = System.nanoTime() / 1_000_000
        override fun isCurrentThread() = Thread.currentThread().name == "test-main"
    }

    private inline fun <reified T> unused(): T =
        Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, m, _ -> throw AssertionError("unexpected ${m.name}") } as T

    private fun <T> callAndWait(block: (callback: (Result<T>) -> Unit) -> Unit, main: MainScheduler, timeoutMs: Long = 3_000): Result<T> {
        val q = LinkedBlockingQueue<Result<T>>()
        main.execute { block { q.add(it) } }
        return q.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: throw AssertionError("no reply within $timeoutMs ms")
    }

    @Test
    fun danaviewIoAnswersRecorderProbeAndFreeBytesWhileACopyHangs() {
        val main = ThreadMain()
        val threads = EngineThreads(main, ::ThreadLane)
        val cache = File(root, "cache/danaview/editor")
        val roots = Paths.fromDart(cache.absolutePath, File(root, "support/danaview/editor").absolutePath)
        val stream = HangingStream(bytes(64 * 1024))
        val copier = PickCopier(stallTimeoutMs = 60_000)
        val handles = mutableListOf<Cancellable>()
        val ioThreadsSeen = LinkedBlockingQueue<String>()
        val platformPort = object : PlatformPort by unused<PlatformPort>() {
            override fun materializePick(uri: String, intoDir: File, done: Completion<String>) {
                ioThreadsSeen.add(Thread.currentThread().name)
                handles += copier.start(intoDir, { PickSource("clip.mp4", null) { stream } }, done)
            }
        }
        val recorderPort = object : RecorderPort by unused<RecorderPort>() {
            override fun isRecording(done: Completion<Boolean>) = done.succeed(true)
        }
        val rootPort = object : EngineRootPort by unused<EngineRootPort>() {
            override val paths: Paths? get() = roots
            override fun freeBytes(path: String, done: Completion<Long>) = done.succeed(42L)
            override fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>) = done(Result.failure(IllegalStateException("probed")))
        }
        val platform = PlatformHostApiImpl(threads, platformPort, { roots })
        val recorder = RecorderHostApiImpl(threads, recorderPort, { roots })
        val engine = EngineHostApiImpl(threads, rootPort)
        try {
            val pick = LinkedBlockingQueue<Result<String>>()
            main.execute { platform.materializePick("content://media/external/video/1", File(roots.work, "picks").absolutePath) { pick.add(it) } }
            assertTrue("copy started", stream.reading.await(10, TimeUnit.SECONDS))
            assertEquals(LaneSpec.IO.threadName, ioThreadsSeen.poll(1, TimeUnit.SECONDS))

            assertEquals(true, callAndWait<Boolean>({ recorder.isRecording(it) }, main).getOrThrow())
            assertEquals(42L, callAndWait<Long>({ engine.freeBytes(cache.absolutePath, it) }, main).getOrThrow())
            val media = ResolvedMediaMsg(uri = "content://media/external/video/2", fingerprint = "fp1", isProxy = false)
            val probed = callAndWait<ProbeMsg>({ engine.probe(media, it) }, main)
            assertTrue(probed.isFailure) // answered (by the fake), not stuck behind the copy
            assertNotNull(probed.exceptionOrNull() as? EnginePigeonError)

            assertTrue("the copy is still running", pick.isEmpty())
            handles.forEach { it.cancel() } // what GlueRegistrar.detach does through PickMaterializer.cancelAll
            val r = pick.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("no materializePick reply")
            assertEquals("cancelled", (r.exceptionOrNull() as EnginePigeonError).code)
            awaitGone({ File(roots.work, "picks").listFiles()?.toList() ?: emptyList() })
        } finally {
            threads.shutdown()
        }
    }
}
