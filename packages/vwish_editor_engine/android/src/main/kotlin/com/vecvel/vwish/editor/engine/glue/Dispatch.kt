// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// How every host handler runs (ARCH §12.6): on the platform main thread it validates the arguments,
// then posts the work to an engine lane and returns at once; the work completes a Completion from
// any thread, and the reply goes back to Dart on the main thread, exactly once, with errors mapped
// to `FlutterError(code = EngineErrorCode.name, scrubbed message, details)`. Nothing blocks main.

package com.vecvel.vwish.editor.engine.glue

import android.util.Log
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.MainScheduler
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Glue logging: codes and class names only, never paths, URIs or user content. */
object GlueLog {
    /** Logs a swallowed failure of [what]. */
    fun warn(what: String, error: Throwable) {
        val e = EngineErrors.from(error)
        Log.w(EngineContext.TAG, "$what failed: ${e.code.name}")
    }

    /** Logs an informational line (no user content). */
    fun info(text: String) {
        Log.i(EngineContext.TAG, text)
    }
}

/** Runs host handlers: validate on main, work on a lane, reply on main (ARCH §12.6). */
class GlueDispatcher(private val main: MainScheduler) {
    /**
     * Asynchronous handler: runs [check] now (on main; an exception replies the error without
     * hopping), then [work] on [lane]. [work] completes its Completion once; a throw from [work]
     * counts as a failure. The Pigeon [reply] is invoked on main exactly once.
     */
    fun <T> async(lane: Executor, reply: (Result<T>) -> Unit, check: () -> Unit = {}, work: (Completion<T>) -> Unit) {
        val once = OnceReply(main, reply)
        try {
            check()
        } catch (t: Throwable) {
            once.complete(Result.failure(t))
            return
        }
        try {
            lane.execute {
                try {
                    work { result -> once.complete(result) }
                } catch (t: Throwable) {
                    once.complete(Result.failure(t))
                }
            }
        } catch (e: RejectedExecutionException) {
            once.complete(Result.failure(EngineException(EngineErrorCode.busy, "engine lane unavailable", retryable = true)))
        }
    }

    /** An immediate reply on main, e.g. `notSupportedOnDevice` for an API Android does not have. */
    fun <T> reply(reply: (Result<T>) -> Unit, result: Result<T>) {
        OnceReply(main, reply).complete(result)
    }

    /**
     * Synchronous (fire-and-forget) handler: [check] runs now and its failure is thrown to Pigeon as
     * an `EnginePigeonError`; [work] runs on [lane], and its failures are only logged ([what]).
     */
    fun fireAndForget(lane: Executor, what: String, check: () -> Unit = {}, work: () -> Unit) {
        try {
            check()
        } catch (t: Throwable) {
            throw EngineErrors.toPigeon(t)
        }
        try {
            lane.execute {
                try {
                    work()
                } catch (t: Throwable) {
                    GlueLog.warn(what, t)
                }
            }
        } catch (e: RejectedExecutionException) {
            GlueLog.warn(what, e)
        }
    }
}

/** Delivers one Pigeon reply on main; later completions are ignored (and logged). */
private class OnceReply<T>(private val main: MainScheduler, private val reply: (Result<T>) -> Unit) {
    private val done = AtomicBoolean(false)

    fun complete(result: Result<T>) {
        if (!done.compareAndSet(false, true)) {
            Log.w(EngineContext.TAG, "a host call completed twice; the second completion was ignored")
            return
        }
        val mapped: Result<T> = result.exceptionOrNull()?.let { Result.failure(EngineErrors.toPigeon(it)) } ?: result
        main.execute { reply(mapped) }
    }
}
