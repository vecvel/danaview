// OWNER: QA-05 D9
//
// The internal thread of a Media3 Transformer ("Transformer:Internal"). Transformer.cancel() blocks
// until the internal thread has released the asset loader, the sample exporters and the muxer, but
// the thread itself quits lazily: TransformerInternal.endInternal posts `quitSafely` to its own
// handler and opens the condition cancel() waits on, so cancel() returns while the thread (the
// owner of the codecs it just released) is still alive. A job that reports its end right after
// cancel() therefore reports it with a Media3 codec owner still running (CI: CancelledJobCodecsTest,
// "transformer=1 at the terminal event" for EXPORT and PROXY). Jobs note the internal thread their
// Transformer.start() created ([startedBy]) and join it ([awaitEnd]) before they report their end.
// Media3 exposes no handle to the thread, so it is found by name: the threads alive after start()
// that were not alive before it (start() creates and starts the thread synchronously on the
// caller's looper).

package com.vecvel.danaview.editor.engine.media

import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineContext

/** Finds and joins the internal threads of Media3 Transformers (file header). */
object TransformerThreads {
    /** Media3's TransformerInternal thread name. */
    const val NAME = "Transformer:Internal"

    /** Live Transformer internal threads. */
    fun live(): Set<Thread> {
        var group = Thread.currentThread().threadGroup ?: return emptySet()
        while (true) group = group.parent ?: break
        var all = arrayOfNulls<Thread>(group.activeCount() + 32)
        var n = group.enumerate(all, true)
        while (n == all.size) {
            all = arrayOfNulls(all.size * 2)
            n = group.enumerate(all, true)
        }
        val out = HashSet<Thread>()
        for (i in 0 until n) {
            val t = all[i] ?: continue
            if (t.isAlive && t.name == NAME) out += t
        }
        return out
    }

    /** Runs [start] (a Transformer.start call) and returns the internal threads it created. */
    inline fun startedBy(start: () -> Unit): List<Thread> {
        val before = live()
        start()
        return live().filter { it !in before }
    }

    /** Waits (bounded in total by [boundMs]) for [threads] to end; keeps the interrupt flag. */
    fun awaitEnd(threads: Collection<Thread>, boundMs: Long = 2_000) {
        if (threads.isEmpty()) return
        val deadline = System.nanoTime() + boundMs * 1_000_000
        for (t in threads) {
            val left = (deadline - System.nanoTime()) / 1_000_000
            if (left <= 0) break
            try {
                t.join(left)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
        val alive = threads.count { it.isAlive }
        if (alive > 0) Log.w(EngineContext.TAG, "a Transformer internal thread did not end within $boundMs ms")
    }
}
