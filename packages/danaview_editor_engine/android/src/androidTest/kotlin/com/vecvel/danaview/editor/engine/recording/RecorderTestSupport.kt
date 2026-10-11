// OWNER: AND-13
//
// Test support of the voice recorder tests: an engine context with roots in the test app's dirs, an
// event collector, a blocking call helper, a WAV header reader, and a permission relay that lets the
// real system permission dialog answer (the library's test APK has no activity of its own, so the
// relay hosts an android.app.Fragment in androidx.test's EmptyActivity and receives
// onRequestPermissionsResult there).

package com.vecvel.danaview.editor.engine.recording

import android.app.Activity
import android.app.Fragment
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object RecorderTestEngine {
    fun create(name: String): EngineContext {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val ctx = EngineContext(app, EngineThreads.android())
        val cache = File(app.cacheDir, "$name/danaview/editor")
        val support = File(app.filesDir, "$name/danaview/editor")
        cache.parentFile?.deleteRecursively()
        support.parentFile?.deleteRecursively()
        ctx.installRoots(Paths.fromDart(cache.absolutePath, support.absolutePath))
        return ctx
    }
}

/** Collects the events the hub delivers (on main). */
class EventCollector {
    private val events = ArrayList<EngineEventMsg>()

    fun attach(ctx: EngineContext) = ctx.events.attach { e -> synchronized(events) { events.add(e) } }

    fun snapshot(): List<EngineEventMsg> = synchronized(events) { events.toList() }

    fun clear() = synchronized(events) { events.clear() }

    /** Waits until [predicate] holds for some event; returns it or null after [timeoutMs]. */
    fun await(timeoutMs: Long, predicate: (EngineEventMsg) -> Boolean): EngineEventMsg? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            snapshot().firstOrNull(predicate)?.let { return it }
            Thread.sleep(20)
        }
        return snapshot().firstOrNull(predicate)
    }
}

/** Runs [block] and waits for its completion. */
fun <T> awaitResult(timeoutMs: Long = 20_000, block: (Completion<T>) -> Unit): Result<T> {
    val latch = CountDownLatch(1)
    var result: Result<T>? = null
    block { r ->
        result = r
        latch.countDown()
    }
    check(latch.await(timeoutMs, TimeUnit.MILLISECONDS)) { "no completion within $timeoutMs ms" }
    return result!!
}

/** Runs [block] on the main thread and waits for its completion. */
fun <T> awaitOnMain(timeoutMs: Long = 60_000, block: (Completion<T>) -> Unit): Result<T> {
    val latch = CountDownLatch(1)
    var result: Result<T>? = null
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        block { r ->
            result = r
            latch.countDown()
        }
    }
    check(latch.await(timeoutMs, TimeUnit.MILLISECONDS)) { "no completion within $timeoutMs ms" }
    return result!!
}

/** A parsed canonical 44-byte WAV header. */
data class WavHeader(
    val riff: String,
    val riffSize: Long,
    val wave: String,
    val fmt: String,
    val fmtSize: Int,
    val format: Int,
    val channels: Int,
    val sampleRate: Int,
    val byteRate: Int,
    val blockAlign: Int,
    val bits: Int,
    val data: String,
    val dataSize: Long,
) {
    companion object {
        fun read(file: File): WavHeader {
            val bytes = ByteArray(44)
            RandomAccessFile(file, "r").use { it.readFully(bytes) }
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun tag(at: Int) = String(bytes, at, 4, Charsets.US_ASCII)
            return WavHeader(
                riff = tag(0),
                riffSize = b.getInt(4).toLong() and 0xffffffffL,
                wave = tag(8),
                fmt = tag(12),
                fmtSize = b.getInt(16),
                format = b.getShort(20).toInt(),
                channels = b.getShort(22).toInt(),
                sampleRate = b.getInt(24),
                byteRate = b.getInt(28),
                blockAlign = b.getShort(32).toInt(),
                bits = b.getShort(34).toInt(),
                data = tag(36),
                dataSize = b.getInt(40).toLong() and 0xffffffffL,
            )
        }
    }
}

/**
 * Hosts a headless fragment in androidx.test's EmptyActivity so that runtime permission requests
 * show the real system dialog and their results come back to the test.
 */
class PermissionRelay private constructor(val activity: Activity, private val fragment: RelayFragment) {
    fun request(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean {
        fragment.pending = onResult
        @Suppress("DEPRECATION")
        fragment.requestPermissions(permissions, REQUEST_CODE)
        return true
    }

    fun finish() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { activity.finish() }
    }

    @Suppress("DEPRECATION")
    class RelayFragment : Fragment() {
        var pending: ((Array<out String>, IntArray) -> Unit)? = null

        @Deprecated("android.app.Fragment API")
        override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
            val cb = pending ?: return
            pending = null
            cb(permissions, grantResults)
        }
    }

    companion object {
        private const val REQUEST_CODE = 0x5a5a
        const val EMPTY_ACTIVITY = "androidx.test.core.app.InstrumentationActivityInvoker\$EmptyActivity"

        /** Launches EmptyActivity and adds the relay fragment. */
        @Suppress("DEPRECATION")
        fun launch(): PermissionRelay {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val intent = Intent(Intent.ACTION_MAIN)
                .setClassName(instrumentation.targetContext.packageName, EMPTY_ACTIVITY)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity = instrumentation.startActivitySync(intent)
            val fragment = RelayFragment()
            instrumentation.runOnMainSync {
                activity.fragmentManager.beginTransaction().add(fragment, "danaview-relay").commitNow()
            }
            return PermissionRelay(activity, fragment)
        }
    }
}
