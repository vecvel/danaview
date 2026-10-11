// OWNER: ENG-08
//
// Fakes for the glue JVM tests: a manual main thread with fake time, recording lanes, and helpers to
// capture Pigeon replies. Lanes and main only run tasks when the test drains them, so a test can
// prove which thread ran what and in which order.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.Cancellable
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.Lane
import com.vecvel.vwish.editor.engine.core.LaneSpec
import com.vecvel.vwish.editor.engine.core.MainScheduler
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.EnginePigeonError
import android.os.Handler
import android.os.Looper
import java.util.concurrent.RejectedExecutionException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail

/** Where a task ran. */
enum class Where { MAIN, PREVIEW, GL, EXPORT, JOBS, IO }

/** A trace of which thread ran tasks, shared by the fake main thread and lanes. */
class Trace {
    val ran = mutableListOf<Where>()
    var current: Where? = null
}

/** A manual main thread with fake time; [drain] runs queued and due delayed tasks. */
class FakeMain(private val trace: Trace = Trace()) : MainScheduler {
    var now = 0L
    private val queue = ArrayDeque<Runnable>()
    private val delayed = mutableListOf<Triple<Long, Long, Runnable>>()
    private var seq = 0L

    override fun execute(command: Runnable) {
        queue.addLast(command)
    }

    override fun postDelayed(task: Runnable, delayMs: Long): Cancellable {
        val entry = Triple(now + delayMs, seq++, task)
        delayed.add(entry)
        return Cancellable { delayed.remove(entry) }
    }

    override fun nowMs(): Long = now

    override fun isCurrentThread(): Boolean = trace.current == Where.MAIN

    /** Runs [block] as if on main. */
    fun <T> onMain(block: () -> T): T {
        val previous = trace.current
        trace.current = Where.MAIN
        try {
            return block()
        } finally {
            trace.current = previous
        }
    }

    /** Runs queued tasks (and those they queue). Returns how many ran. */
    fun drain(): Int {
        var n = 0
        while (queue.isNotEmpty()) {
            val task = queue.removeFirst()
            onMain { trace.ran.add(Where.MAIN); task.run() }
            n++
        }
        return n
    }

    /** Advances fake time by [ms], running delayed tasks that become due in order. */
    fun advance(ms: Long) {
        val target = now + ms
        while (true) {
            val next = delayed.filter { it.first <= target }.minWithOrNull(compareBy({ it.first }, { it.second })) ?: break
            delayed.remove(next)
            now = next.first
            onMain { next.third.run() }
            drain()
        }
        now = target
        drain()
    }

    val pending: Int get() = queue.size
}

/** A lane that queues tasks until [drain]; can be made to reject. */
class FakeLane(override val spec: LaneSpec, private val trace: Trace) : Lane {
    private val queue = ArrayDeque<Runnable>()
    var rejecting = false
    var executed = 0

    private val where = Where.valueOf(spec.name)

    override val looper: Looper? = null
    override val handler: Handler? = null

    override fun execute(command: Runnable) {
        if (rejecting) throw RejectedExecutionException("lane quit")
        queue.addLast(command)
    }

    override fun isCurrentThread(): Boolean = trace.current == where

    override fun quit() {
        rejecting = true
    }

    /** Runs queued tasks. Returns how many ran. */
    fun drain(): Int {
        var n = 0
        while (queue.isNotEmpty()) {
            val task = queue.removeFirst()
            val previous = trace.current
            trace.current = where
            trace.ran.add(where)
            try {
                task.run()
            } finally {
                trace.current = previous
            }
            executed++
            n++
        }
        return n
    }

    val pending: Int get() = queue.size
}

/** Fake EngineThreads: a [FakeMain] plus [FakeLane]s, all recording into one [Trace]. */
class FakeThreads {
    val trace = Trace()
    val main = FakeMain(trace)
    private val lanes = LaneSpec.entries.associateWith { FakeLane(it, trace) }
    val threads = EngineThreads(main) { spec -> lanes.getValue(spec) }

    fun lane(spec: LaneSpec): FakeLane = lanes.getValue(spec)

    /** Drains every lane and main until nothing is left. */
    fun settle() {
        var progress = true
        while (progress) {
            progress = false
            for (lane in lanes.values) if (lane.drain() > 0) progress = true
            if (main.drain() > 0) progress = true
        }
    }
}

/** Captures one Pigeon reply and where it was delivered. */
class Reply<T>(private val trace: Trace) {
    val results = mutableListOf<Result<T>>()
    val deliveredOn = mutableListOf<Where?>()

    val callback: (Result<T>) -> Unit = { result ->
        results.add(result)
        deliveredOn.add(trace.current)
    }

    /** The single reply's value; fails if absent, repeated or an error. */
    fun value(): T {
        assertEquals("exactly one reply", 1, results.size)
        assertEquals("reply on main", Where.MAIN, deliveredOn.single())
        return results.single().getOrElse { fail("expected success, got $it"); throw it }
    }

    /** The single reply's Pigeon error; fails if absent, repeated or a success. */
    fun error(): EnginePigeonError {
        assertEquals("exactly one reply", 1, results.size)
        assertEquals("reply on main", Where.MAIN, deliveredOn.single())
        val error = results.single().exceptionOrNull()
        assertNotNull("expected a failure", error)
        assertTrue("expected EnginePigeonError, got $error", error is EnginePigeonError)
        return error as EnginePigeonError
    }

    /** Asserts the reply is an error with [code]. */
    fun assertError(code: String): EnginePigeonError = error().also { assertEquals(code, it.code) }
}

/** Test roots in POSIX form (the engine only runs on Android). */
object TestRoots {
    const val CACHE = "/data/user/0/app/cache/vwish/editor"
    const val SUPPORT = "/data/user/0/app/files/vwish/editor"
    const val SPEECH = "/data/user/0/app/files/vwish/speech"
    val paths: Paths = Paths.fromDart(CACHE, SUPPORT)
}
