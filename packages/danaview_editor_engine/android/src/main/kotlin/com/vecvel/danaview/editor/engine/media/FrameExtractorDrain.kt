// OWNER: QA-05 D9
//
// Waits until Media3's FrameExtractor work queued before now has finished (media3-inspector-frame
// 1.11.1). Every FrameExtractor shares one process-wide FrameExtractorInternal: one ExoPlayer on the
// main looper, with tasks run in order by a Guava ExecutionSequencer. FrameExtractor.close() only
// queues the release of the caller's reference, and that release runs after the task in progress.
// A cancelled getFrame keeps decoding until its frame arrives. So when a freeze job was cancelled,
// its terminal event used to come while the extractor's decoder and playback thread were still
// alive, and they overlapped the next job's codecs (measured on emulator-5554 by
// CancelledJobCodecsTest: a c2 decoder and an ExoPlayer:Playback thread alive at the freeze job's
// `cancelled` event).
//
// [awaitIdle] queues a no-op behind everything in that sequencer and waits for it, with a bound.
// The class and its fields are package-private in Media3, so they are read by reflection. If the
// reflection fails (a different Media3, or a minified build that renamed them), this logs once and
// returns at once, which is the behaviour before this fix. On the main thread it never waits (the
// extractor's player runs there).

package com.vecvel.danaview.editor.engine.media

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.common.util.concurrent.ExecutionSequencer
import com.vecvel.danaview.editor.engine.core.EngineContext
import java.util.concurrent.Callable
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

object FrameExtractorDrain {
    private const val INTERNAL = "androidx.media3.inspector.frame.FrameExtractorInternal"

    @Volatile
    private var warned = false

    /** The longest a job waits for the extractor's queued work (a decode in progress) to finish. */
    const val BOUND_MS = 5_000L

    /** True when the queued work finished (or nothing was queued); false on timeout or when it cannot tell. */
    fun awaitIdle(boundMs: Long = BOUND_MS): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return false
        val (sequencer, handler) = internals() ?: return false
        return try {
            sequencer.submit(Callable<Unit?> { null }) { r -> handler.post(r) }.get(boundMs, TimeUnit.MILLISECONDS)
            true
        } catch (e: TimeoutException) {
            Log.w(EngineContext.TAG, "frame extractor still busy after $boundMs ms")
            false
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        } catch (e: Exception) {
            // The barrier itself never fails; a cancelled or failed predecessor still lets it run.
            false
        }
    }

    private fun internals(): Pair<ExecutionSequencer, Handler>? = try {
        val cls = Class.forName(INTERNAL)
        val instanceField = cls.getDeclaredField("instance").apply { isAccessible = true }
        val instance = synchronized(lockOf(cls)) { instanceField.get(null) }
        if (instance == null) {
            null
        } else {
            val sequencer = cls.getDeclaredField("executionSequencer").apply { isAccessible = true }.get(instance) as ExecutionSequencer
            val handler = cls.getDeclaredField("playerHandler").apply { isAccessible = true }.get(instance) as Handler
            sequencer to handler
        }
    } catch (e: ReflectiveOperationException) {
        warnOnce(e)
        null
    } catch (e: ClassCastException) {
        warnOnce(e)
        null
    } catch (e: LinkageError) {
        warnOnce(e)
        null
    }

    private fun lockOf(cls: Class<*>): Any = try {
        cls.getDeclaredField("LOCK").apply { isAccessible = true }.get(null) ?: cls
    } catch (e: ReflectiveOperationException) {
        cls
    }

    private fun warnOnce(e: Throwable) {
        if (warned) return
        warned = true
        Log.w(EngineContext.TAG, "frame extractor drain unavailable (${e.javaClass.simpleName}); cancelled extractions end without waiting")
    }
}
