// OWNER: ENG-08
//
// Memory pressure → engine signals and cache trims (ARCH §12.1, §18.3).

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineEventSink
import com.vecvel.vwish.editor.engine.core.EventHub
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalKindMsg
import org.junit.Assert.assertEquals
import org.junit.Test

class MemorySignalsTest {
    @Test
    fun trimLevelsMapToReactions() {
        // ComponentCallbacks2: RUNNING_MODERATE 5, RUNNING_LOW 10, RUNNING_CRITICAL 15, UI_HIDDEN 20,
        // BACKGROUND 40, MODERATE 60, COMPLETE 80.
        assertEquals(MemoryReaction(false, null), MemorySignals.reactionFor(5))
        assertEquals(MemoryReaction(true, CacheTrimLevelMsg.MEMORY_PRESSURE), MemorySignals.reactionFor(10))
        assertEquals(MemoryReaction(true, CacheTrimLevelMsg.MEMORY_PRESSURE), MemorySignals.reactionFor(15))
        assertEquals(MemoryReaction(false, null), MemorySignals.reactionFor(20))
        assertEquals(MemoryReaction(false, CacheTrimLevelMsg.BACKGROUND), MemorySignals.reactionFor(40))
        assertEquals(MemoryReaction(false, CacheTrimLevelMsg.BACKGROUND), MemorySignals.reactionFor(80))
    }

    @Test
    fun memoryWarningEmitsASignalAndTrims() {
        val trace = Trace()
        val main = FakeMain(trace)
        val hub = EventHub(main)
        val events = mutableListOf<EngineEventMsg>()
        main.onMain { hub.attach(EngineEventSink { events.add(it) }) }
        val trims = mutableListOf<CacheTrimLevelMsg>()
        val signals = MemorySignals(hub) { trims.add(it) }

        signals.onTrimMemory(15)
        @Suppress("DEPRECATION")
        signals.onLowMemory()
        signals.onTrimMemory(40)
        main.drain()

        assertEquals(listOf(CacheTrimLevelMsg.MEMORY_PRESSURE, CacheTrimLevelMsg.MEMORY_PRESSURE, CacheTrimLevelMsg.BACKGROUND), trims)
        assertEquals(2, events.size)
        events.forEach {
            assertEquals(EngineEventKindMsg.SIGNAL, it.kind)
            assertEquals(SignalKindMsg.MEMORY_WARNING, it.signal!!.kind)
        }
    }

    @Test
    fun nothingHappensBeforeTheEngineIsInitialized() {
        val trace = Trace()
        val main = FakeMain(trace)
        val hub = EventHub(main)
        val trims = mutableListOf<CacheTrimLevelMsg>()
        var initialized = false
        val signals = MemorySignals(hub, { initialized }) { trims.add(it) }

        signals.onTrimMemory(15)
        signals.onTrimMemory(80)
        main.drain()
        val events = mutableListOf<EngineEventMsg>()
        main.onMain { hub.attach(EngineEventSink { events.add(it) }) }
        assertEquals("no trims before initialize", emptyList<CacheTrimLevelMsg>(), trims)
        assertEquals("no memory warning buffered for the first listener", emptyList<EngineEventMsg>(), events)

        initialized = true
        signals.onTrimMemory(15)
        main.drain()
        assertEquals(listOf(CacheTrimLevelMsg.MEMORY_PRESSURE), trims)
        assertEquals(1, events.size)
    }
}
