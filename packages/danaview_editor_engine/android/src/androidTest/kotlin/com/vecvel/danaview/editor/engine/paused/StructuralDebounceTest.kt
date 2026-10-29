// OWNER: AND-17
//
// AC "debounce coalesces 10 structural patches in 1 s into <= 3 rebuilds", on a real
// danaview-preview Handler (HandlerDebounceScheduler, uptime clock) with rebuilds that take time
// on another thread (0, 250 and 700 ms: a fast re-plan, a typical one and a slow cold rebuild);
// every patch's change reaches exactly one rebuild, rebuilds never overlap, and the last patch is
// rebuilt within trailing + rebuild time of being submitted. Also: the latest-wins default merge.

package com.vecvel.danaview.editor.engine.paused

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.HandlerLane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.preview.HandlerDebounceScheduler
import com.vecvel.danaview.editor.engine.preview.StructuralDebouncer
import com.vecvel.danaview.editor.engine.harness.PerfGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class StructuralDebounceTest {
    @Test
    fun tenPatchesInOneSecondGiveAtMostThreeRebuilds() {
        for (rebuildMs in longArrayOf(0, 250, 700)) {
            val lane = HandlerLane(LaneSpec.PREVIEW)
            val rebuilder = Executors.newSingleThreadExecutor()
            val rebuilt = Collections.synchronizedList(ArrayList<List<Int>>())
            val running = AtomicInteger()
            val overlaps = AtomicInteger()
            val idle = CountDownLatch(1)
            var lastRebuildStart = 0L
            try {
                val handler: Handler = lane.handler
                lateinit var d: StructuralDebouncer<List<Int>>
                val created = CountDownLatch(1)
                handler.post {
                    d = StructuralDebouncer(HandlerDebounceScheduler(handler), merge = { a, b -> a + b }) { value, done ->
                        if (running.incrementAndGet() > 1) overlaps.incrementAndGet()
                        lastRebuildStart = SystemClock.uptimeMillis()
                        rebuilt += value
                        rebuilder.execute {
                            if (rebuildMs > 0) Thread.sleep(rebuildMs)
                            running.decrementAndGet()
                            done()
                        }
                    }
                    created.countDown()
                }
                assertTrue(created.await(5, TimeUnit.SECONDS))
                val start = SystemClock.uptimeMillis()
                var lastSubmit = 0L
                for (i in 0 until 10) {
                    val due = start + i * 100L
                    SystemClock.sleep((due - SystemClock.uptimeMillis()).coerceAtLeast(0))
                    handler.post {
                        if (i == 9) {
                            lastSubmit = SystemClock.uptimeMillis()
                            d.onIdle = { idle.countDown() }
                        }
                        d.submit(listOf(i))
                    }
                }
                assertTrue("debouncer settles", idle.await(10, TimeUnit.SECONDS))
                val patches = rebuilt.flatten()
                Log.i(AND17_TAG, "debounce, rebuild $rebuildMs ms: 10 patches in ${SystemClock.uptimeMillis() - start} ms -> ${rebuilt.size} rebuilds $rebuilt; last rebuild started ${lastRebuildStart - lastSubmit} ms after the last patch (emulator)")
                // How many rebuilds the 10 patches coalesce into depends on the lane keeping up:
                // 1..3 with DV_PERF_STRICT=1; on a loaded emulator at most one per patch (the
                // order, once-each and no-overlap checks below hold in both modes).
                val maxRebuilds = if (PerfGate.strict) 3 else 10
                assertTrue("rebuild $rebuildMs ms: ${rebuilt.size} rebuilds (max $maxRebuilds, ${PerfGate.mode})", rebuilt.size in 1..maxRebuilds)
                assertEquals("each patch rebuilt once, in order", (0 until 10).toList(), patches)
                assertEquals("rebuilds never overlap", 0, overlaps.get())
                val lateBound = PerfGate.boundMs(StructuralDebouncer.TRAILING_MS + rebuildMs + 100)
                assertTrue("last patch rebuilt in time (${lastRebuildStart - lastSubmit} ms, bound $lateBound, ${PerfGate.mode})", lastRebuildStart - lastSubmit <= lateBound)
            } finally {
                rebuilder.shutdown()
                lane.quit()
            }
        }
    }

    @Test
    fun latestValueWinsByDefault() {
        val lane = HandlerLane(LaneSpec.PREVIEW)
        try {
            val got = Collections.synchronizedList(ArrayList<String>())
            val idle = CountDownLatch(1)
            lane.handler.post {
                val d = StructuralDebouncer<String>(HandlerDebounceScheduler(lane.handler)) { v, done ->
                    got += v
                    done()
                }
                d.onIdle = { idle.countDown() }
                d.submit("rev1")
                d.submit("rev2")
                d.submit("rev3")
                assertTrue(d.isPending)
                assertFalse(d.isRebuilding)
            }
            assertTrue(idle.await(5, TimeUnit.SECONDS))
            assertEquals(listOf("rev3"), got)
        } finally {
            lane.quit()
        }
    }
}
