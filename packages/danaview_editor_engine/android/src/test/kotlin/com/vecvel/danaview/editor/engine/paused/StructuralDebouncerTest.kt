// OWNER: AND-17
//
// StructuralDebouncer on a virtual clock (D-36: 150 ms trailing, 600 ms max wait, one rebuild at a
// time): 10 structural patches in 1 s give at most 3 rebuilds; a lone patch rebuilds 150 ms later;
// a steady stream still rebuilds every 600 ms; patches during a running rebuild are merged and
// rebuilt after it; flush starts now; cancel drops the pending patch; the rebuilt value is the
// merge of everything submitted.

package com.vecvel.danaview.editor.engine.paused

import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.preview.DebounceScheduler
import com.vecvel.danaview.editor.engine.preview.StructuralDebouncer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.PriorityQueue

/** A single-threaded virtual-time scheduler. */
class VirtualScheduler : DebounceScheduler {
    private class Task(val at: Long, val seq: Long, val run: Runnable) {
        var cancelled = false
    }

    private val queue = PriorityQueue<Task>(compareBy<Task>({ it.at }, { it.seq }))
    private var seq = 0L
    var now = 0L
        private set

    override fun nowMs(): Long = now

    override fun schedule(delayMs: Long, task: Runnable): Cancellable {
        val t = Task(now + delayMs.coerceAtLeast(0), seq++, task)
        queue += t
        return Cancellable { t.cancelled = true }
    }

    override fun post(task: Runnable) {
        schedule(0, task)
    }

    /** Runs every task due up to [time] in order and moves the clock there. */
    fun advanceTo(time: Long) {
        while (true) {
            val next = queue.peek() ?: break
            if (next.at > time) break
            queue.poll()
            now = maxOf(now, next.at)
            if (!next.cancelled) next.run.run()
        }
        now = maxOf(now, time)
    }
}

class StructuralDebouncerTest {
    private val clock = VirtualScheduler()
    private val starts = ArrayList<Pair<Long, List<Int>>>()
    private var rebuildMs = 0L

    private fun debouncer() = StructuralDebouncer<List<Int>>(clock, merge = { a, b -> a + b }) { value, done ->
        starts += clock.now to value
        clock.schedule(rebuildMs) { done() }
    }

    @Test
    fun tenPatchesInOneSecondGiveAtMostThreeRebuilds() {
        for (rebuild in longArrayOf(0, 120, 400)) {
            starts.clear()
            rebuildMs = rebuild
            val d = debouncer()
            for (i in 0 until 10) {
                clock.advanceTo(clock.now + if (i == 0) 0 else 100)
                d.submit(listOf(i))
            }
            clock.advanceTo(clock.now + 5_000)
            assertTrue("rebuild ${rebuild} ms: ${starts.size} rebuilds", starts.size in 1..3)
            assertEquals("every patch is rebuilt exactly once", (0 until 10).toList(), starts.flatMap { it.second })
            assertEquals(10, d.submitted)
            assertFalse(d.isPending || d.isRebuilding)
        }
    }

    @Test
    fun lonePatchRebuildsAfterTheTrailingDelay() {
        val d = debouncer()
        clock.advanceTo(1_000)
        d.submit(listOf(1))
        clock.advanceTo(1_149)
        assertEquals(0, starts.size)
        clock.advanceTo(1_150)
        assertEquals(listOf(1_150L to listOf(1)), starts)
    }

    @Test
    fun steadyStreamRebuildsAtTheMaxWait() {
        val d = debouncer()
        // A patch every 50 ms for 3 s: the trailing timer never expires, the max wait does.
        var t = 0L
        while (t < 3_000) {
            clock.advanceTo(t)
            d.submit(listOf(t.toInt()))
            t += 50
        }
        clock.advanceTo(10_000)
        val times = starts.map { it.first }
        assertEquals(listOf(600L, 1_200L, 1_800L, 2_400L, 3_000L), times)
        assertEquals(60, starts.sumOf { it.second.size })
    }

    @Test
    fun patchesDuringARebuildRunAfterIt() {
        rebuildMs = 1_000
        val d = debouncer()
        d.submit(listOf(1))
        clock.advanceTo(150) // rebuild 1 starts, runs until 1150
        assertTrue(d.isRebuilding)
        clock.advanceTo(200)
        d.submit(listOf(2))
        clock.advanceTo(300)
        d.submit(listOf(3))
        clock.advanceTo(1_149)
        assertEquals("never two rebuilds at once", 1, starts.size)
        clock.advanceTo(1_150)
        // Max wait of patch 2 (200 + 600) has passed: the merged rebuild starts as soon as rebuild 1 ends.
        assertEquals(listOf(150L to listOf(1), 1_150L to listOf(2, 3)), starts)
        clock.advanceTo(5_000)
        assertEquals(2, d.rebuilds)
    }

    @Test
    fun flushStartsNowAndCancelDrops() {
        var idle = 0
        val d = debouncer()
        d.onIdle = { idle++ }
        clock.advanceTo(10)
        d.submit(listOf(1))
        d.flush()
        assertEquals(listOf(10L to listOf(1)), starts)
        clock.advanceTo(20)
        assertEquals(1, idle)
        d.submit(listOf(2))
        d.cancel()
        clock.advanceTo(2_000)
        assertEquals(1, starts.size)
        assertFalse(d.isPending)
    }

    @Test
    fun rebuildDoneCalledTwiceIsIgnored() {
        val calls = ArrayList<Int>()
        var doneRef: (() -> Unit)? = null
        val d = StructuralDebouncer<Int>(clock) { v, done ->
            calls += v
            doneRef = done
        }
        d.submit(1)
        clock.advanceTo(150)
        d.submit(2)
        doneRef!!()
        doneRef!!()
        clock.advanceTo(1_000)
        assertEquals(listOf(1, 2), calls)
        assertTrue(d.isRebuilding)
    }
}
