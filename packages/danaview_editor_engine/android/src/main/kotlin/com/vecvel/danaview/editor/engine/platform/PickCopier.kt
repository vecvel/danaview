// OWNER: INT-07 (M-16, M-18)
//
// The copy behind `PlatformHostApi.materializePick` (PickMaterializer), off danaview-io. A pick from
// a cloud DocumentsProvider (Drive, offline) can stream for minutes or hang, and danaview-io also
// carries recorder control, probe, freeBytes and stat, so the copy must never run there (M-16):
// - Every copy runs on its own daemon thread from a process-wide cached pool (`danaview-copy-N`,
//   background priority); danaview-io only validates and hands off. A copy whose source never
//   unblocks keeps its thread, but never a lane; [start]'s `onAbort` hook (a CancellationSignal in
//   PickMaterializer) lets a stall or cancel unblock a provider query or open that is still running.
// - A watchdog (`danaview-copy-watch`) fails a copy that makes no progress: [openTimeoutMs] until
//   the first byte arrives (provider query + open + first read; cloud providers may download before
//   they answer) and [stallTimeoutMs] between later reads. A stalled copy fails with `io`
//   (retryable), closes the source to unblock the read, and deletes its directory.
// - [start] returns a [Cancellable]: cancelled copies fail with `cancelled` and delete their
//   directory. Completion happens exactly once, whichever of success, failure, stall or cancel
//   comes first. An abort deletes the partial directory on the watchdog thread (never the caller's,
//   which may be main), and the copy thread deletes it again when it wakes up after a stall or
//   cancel (an open file cannot be deleted on every platform).
// Error codes (M-18, Pigeon `materializePick` doc): the source side maps a SecurityException or an
// EACCES/EPERM open to `permissionDenied`, a missing item to `mediaOffline`, a failed read to `io`;
// the output side (the engine's own work directory) maps ENOSPC to `diskFull` and anything else to
// `io` (never `mediaOffline`/`permissionDenied`, which would blame the source); a known source size
// that does not fit with [marginBytes] to spare (Dart's ImportPolicy.freeSpaceMarginBytes) fails
// with `diskFull` before anything is written. Pure JVM (testable without a device).

package com.vecvel.danaview.editor.engine.platform

import android.os.Process
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import java.io.Closeable
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** What a pick copy reads: the copy's file name, the source size when known, and how to open it. */
class PickSource(val fileName: String, val sizeBytes: Long?, val open: () -> InputStream)

/** Runs pick copies off the engine lanes, with a stall watchdog and cancellation (file header). */
class PickCopier(
    private val executor: Executor = copyPool,
    private val watchdog: ScheduledExecutorService = watchdogPool,
    private val openTimeoutMs: Long = OPEN_TIMEOUT_MS,
    private val stallTimeoutMs: Long = STALL_TIMEOUT_MS,
    private val freeBytes: (File) -> Long = { it.usableSpace },
    private val marginBytes: Long = FREE_SPACE_MARGIN_BYTES,
    private val openOutput: (File) -> OutputStream = { FileOutputStream(it) },
) {
    /**
     * Copies the source [prepare] describes (run on the copy thread: it may block on a provider)
     * into `<intoDir>/<uuid>/<fileName>` and completes [done] once with the copy's absolute path.
     */
    fun start(intoDir: File, prepare: () -> PickSource, done: Completion<String>): Cancellable =
        start(intoDir, prepare, {}, done)

    /**
     * As [start], and [onAbort] runs once when the copy is stalled or cancelled, so that [prepare] or
     * [PickSource.open] blocked in a provider call (which ignores interrupts) can be unblocked.
     */
    fun start(intoDir: File, prepare: () -> PickSource, onAbort: () -> Unit, done: Completion<String>): Cancellable {
        val task = Task(intoDir, prepare, onAbort, done)
        task.arm()
        try {
            executor.execute(task)
        } catch (e: RejectedExecutionException) {
            task.abort(EngineException(EngineErrorCode.busy, "no copy thread available", retryable = true, cause = e))
        }
        return Cancellable { task.abort(EngineException(EngineErrorCode.cancelled, "the copy was cancelled")) }
    }

    private inner class Task(
        private val intoDir: File,
        private val prepare: () -> PickSource,
        private val onAbort: () -> Unit,
        private val done: Completion<String>,
    ) : Runnable {
        private val finished = AtomicBoolean(false)
        private val input = AtomicReference<Closeable?>(null)
        private val lock = Any()
        @Volatile private var lastProgressNs = System.nanoTime()
        @Volatile private var streaming = false
        @Volatile private var dir: File? = null
        private var thread: Thread? = null // guarded by lock
        private var watch: ScheduledFuture<*>? = null

        fun arm() {
            val period = maxOf(10L, minOf(openTimeoutMs, stallTimeoutMs) / 4)
            watch = try {
                watchdog.scheduleWithFixedDelay({ checkStall() }, period, period, TimeUnit.MILLISECONDS)
            } catch (e: RejectedExecutionException) {
                null
            }
        }

        private fun checkStall() {
            if (finished.get()) return
            val idleMs = (System.nanoTime() - lastProgressNs) / 1_000_000
            if (streaming && idleMs >= stallTimeoutMs) {
                abort(EngineException(EngineErrorCode.io, "the source stopped sending data", retryable = true))
            } else if (!streaming && idleMs >= openTimeoutMs) {
                abort(EngineException(EngineErrorCode.io, "the source did not answer in time", retryable = true))
            }
        }

        /**
         * Fails the copy now (stall, cancel, no thread): completion once, source closed and its
         * provider call cancelled, files deleted off the caller's thread (a cancel may come from main).
         */
        fun abort(error: EngineException) {
            if (!finished.compareAndSet(false, true)) return
            watch?.cancel(false)
            try {
                onAbort()
            } catch (t: Throwable) {
                // best effort: it only unblocks a provider call
            }
            closeQuietly(input.getAndSet(null))
            synchronized(lock) { thread?.interrupt() }
            try {
                watchdog.execute { deleteDir() }
            } catch (e: RejectedExecutionException) {
                deleteDir()
            }
            done.fail(error)
        }

        override fun run() {
            if (finished.get()) return
            synchronized(lock) { thread = Thread.currentThread() }
            try {
                val path = copy()
                if (finished.compareAndSet(false, true)) {
                    watch?.cancel(false)
                    done.succeed(path)
                } else {
                    deleteDir()
                }
            } catch (t: Throwable) {
                deleteDir()
                if (finished.compareAndSet(false, true)) {
                    watch?.cancel(false)
                    done.fail(EngineErrors.from(t))
                }
            } finally {
                synchronized(lock) {
                    thread = null
                    Thread.interrupted() // a pooled thread must not keep an abort's interrupt
                }
            }
        }

        private fun progress() {
            lastProgressNs = System.nanoTime()
        }

        private fun ensureLive() {
            if (finished.get()) throw EngineException(EngineErrorCode.cancelled, "the copy was stopped")
        }

        private fun copy(): String {
            val source = sourceSide { prepare() }
            ensureLive()
            val size = source.sizeBytes
            if (size != null && size >= 0 && freeAt(intoDir) < size + marginBytes) {
                throw EngineException(EngineErrorCode.diskFull, "not enough free space for the copy")
            }
            val target = File(intoDir, UUID.randomUUID().toString())
            dir = target
            if (!target.mkdirs() && !target.isDirectory) {
                if (freeAt(intoDir) < marginBytes) throw EngineException(EngineErrorCode.diskFull, "no space left for the pick directory")
                throw EngineException(EngineErrorCode.io, "cannot create the pick directory")
            }
            ensureLive()
            val out = File(target, source.fileName)
            val stream = sourceSide { source.open() }
            input.set(stream)
            if (finished.get()) {
                closeQuietly(input.getAndSet(null))
                ensureLive()
            }
            try {
                outputSide { openOutput(out) }.use { o ->
                    val buffer = ByteArray(BUFFER)
                    while (true) {
                        val n = try {
                            stream.read(buffer)
                        } catch (e: IOException) {
                            ensureLive() // a stall or cancel closed the stream: report that instead
                            throw EngineException(EngineErrorCode.io, "reading the picked item failed", retryable = true, cause = e)
                        }
                        ensureLive()
                        if (n < 0) break
                        streaming = true
                        progress()
                        if (n > 0) outputSide { o.write(buffer, 0, n) }
                        progress()
                    }
                    outputSide { o.flush() }
                }
            } finally {
                closeQuietly(input.getAndSet(null))
                closeQuietly(stream)
            }
            ensureLive()
            return out.absolutePath
        }

        /** Source-side failures: unreadable → permissionDenied, gone → mediaOffline, other → io. */
        private inline fun <T> sourceSide(block: () -> T): T = try {
            block()
        } catch (e: EngineException) {
            throw e
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "the picked item cannot be read", cause = e)
        } catch (e: FileNotFoundException) {
            ensureLive()
            if (EngineErrors.isPermissionDenied(e)) throw EngineException(EngineErrorCode.permissionDenied, "the picked item cannot be read", cause = e)
            throw EngineException(EngineErrorCode.mediaOffline, "the picked item is gone", cause = e)
        } catch (e: IOException) {
            ensureLive()
            throw EngineException(EngineErrorCode.io, "opening the picked item failed", retryable = true, cause = e)
        }

        /** Output-side failures (the engine's work directory): ENOSPC or no room → diskFull, other → io. */
        private inline fun <T> outputSide(block: () -> T): T = try {
            block()
        } catch (e: IOException) {
            ensureLive()
            if (EngineErrors.isNoSpace(e) || freeAt(intoDir) < MIN_FREE_BYTES) {
                throw EngineException(EngineErrorCode.diskFull, "no space left for the copy", cause = e)
            }
            throw EngineException(EngineErrorCode.io, "writing the copy failed", cause = e)
        }

        private fun deleteDir() {
            dir?.let { d -> if (d.exists()) d.deleteRecursively() }
        }
    }

    /** Free bytes on the volume holding [dir] (its nearest existing ancestor); MAX_VALUE when unknown. */
    private fun freeAt(dir: File): Long {
        var d: File? = dir
        while (d != null && !d.exists()) d = d.parentFile
        if (d == null) return Long.MAX_VALUE
        return try {
            freeBytes(d)
        } catch (e: RuntimeException) {
            Long.MAX_VALUE
        }
    }

    companion object {
        /** Read/write buffer. */
        private const val BUFFER = 256 * 1024

        /** No first byte for this long (query, open, first read) fails the copy with `io`. */
        const val OPEN_TIMEOUT_MS = 5 * 60_000L

        /** No further byte for this long fails the copy with `io`. */
        const val STALL_TIMEOUT_MS = 60_000L

        /** Kept free besides the copy (Dart ImportPolicy.freeSpaceMarginBytes, 64 MiB). */
        const val FREE_SPACE_MARGIN_BYTES = 64L * 1024 * 1024

        /** Below this, a failed write is reported as a full disk even without ENOSPC in the message. */
        private const val MIN_FREE_BYTES = 1024L * 1024

        private fun daemon(prefix: String, background: Boolean): ThreadFactory {
            val n = AtomicInteger()
            return ThreadFactory { r ->
                Thread({
                    if (background) {
                        try {
                            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                        } catch (t: Throwable) {
                            // JVM tests (android.jar stubs): keep the default priority.
                        }
                    }
                    r.run()
                }, "$prefix-${n.incrementAndGet()}").apply { isDaemon = true }
            }
        }

        /** One thread per running copy (threads idle out after 60 s). */
        private val copyPool: Executor by lazy { Executors.newCachedThreadPool(daemon("danaview-copy", true)) }

        private val watchdogPool: ScheduledExecutorService by lazy {
            ScheduledThreadPoolExecutor(1, daemon("danaview-copy-watch", false)).apply { removeOnCancelPolicy = true }
        }

        private fun closeQuietly(c: Closeable?) {
            try {
                c?.close()
            } catch (t: Throwable) {
                // closing is best effort (it only unblocks a read)
            }
        }
    }
}
