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
// The class is package-private in Media3, so the barrier is DanaviewExtractorBarrier, a direct call
// from Media3's package: no reflection, so R8 sees the calls in a minified release build. If the
// call fails at runtime (a different Media3 that changed those members), this logs once and returns
// at once, which is the behaviour before this fix. On the main thread it never waits (the
// extractor's player runs there).

package com.vecvel.danaview.editor.engine.media

import android.os.Looper
import android.util.Log
import androidx.media3.inspector.frame.DanaviewExtractorBarrier
import com.vecvel.danaview.editor.engine.core.EngineContext
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

object FrameExtractorDrain {
    @Volatile
    private var warned = false

    /** The longest a job waits for the extractor's queued work (a decode in progress) to finish. */
    const val BOUND_MS = 5_000L

    /** True when the queued work finished (or nothing was queued); false on timeout or when it cannot tell. */
    fun awaitIdle(boundMs: Long = BOUND_MS): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return false
        val barrier = try {
            DanaviewExtractorBarrier.submit()
        } catch (e: LinkageError) {
            warnOnce(e)
            return false
        }
        return try {
            barrier.get(boundMs, TimeUnit.MILLISECONDS)
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

    private fun warnOnce(e: Throwable) {
        if (warned) return
        warned = true
        Log.w(EngineContext.TAG, "frame extractor drain unavailable (${e.javaClass.simpleName}); cancelled extractions end without waiting")
    }
}
