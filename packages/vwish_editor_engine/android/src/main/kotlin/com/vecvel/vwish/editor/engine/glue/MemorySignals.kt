// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// Engine-wide memory signals (ARCH §12.1, §18.3). Android reports memory pressure through
// ComponentCallbacks2: RUNNING_LOW / RUNNING_CRITICAL and onLowMemory become a `memoryWarning`
// signal plus `trimCaches(memoryPressure)`; BACKGROUND and above trim with `background` (no signal).
// The callbacks are registered when the plugin attaches, but they do nothing until Dart has called
// `initialize`: a player-only session never starts engine lanes or services, and emits no signals.
// Thermal signals belong to AND-02 (DeviceProfile's OnThermalStatusChangedListener).

package com.vecvel.vwish.editor.engine.glue

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import com.vecvel.vwish.editor.engine.core.EventHub
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalKindMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalMsg
import java.util.concurrent.atomic.AtomicBoolean

/** What the engine does for one `onTrimMemory` level. */
data class MemoryReaction(val signal: Boolean, val trim: CacheTrimLevelMsg?)

/**
 * Memory pressure → signals and cache trims (installed once per process). [active] gates every
 * reaction (true once the engine is initialized).
 */
class MemorySignals(
    private val hub: EventHub,
    private val active: () -> Boolean = { true },
    private val trim: (CacheTrimLevelMsg) -> Unit,
) : ComponentCallbacks2 {
    override fun onTrimMemory(level: Int) = react(reactionFor(level))

    @Deprecated("Deprecated in Java")
    override fun onLowMemory() = react(MemoryReaction(signal = true, trim = CacheTrimLevelMsg.MEMORY_PRESSURE))

    override fun onConfigurationChanged(newConfig: Configuration) = Unit

    private fun react(reaction: MemoryReaction) {
        if (!active()) return
        if (reaction.signal) hub.signal(SignalMsg(kind = SignalKindMsg.MEMORY_WARNING))
        reaction.trim?.let { level ->
            try {
                trim(level)
            } catch (t: Throwable) {
                GlueLog.warn("memory trim", t)
            }
        }
    }

    companion object {
        // ComponentCallbacks2 levels (constants, so JVM tests can use them).
        private const val RUNNING_LOW = 10
        private const val UI_HIDDEN = 20
        private const val BACKGROUND = 40

        private val installed = AtomicBoolean(false)

        /** The reaction to `onTrimMemory(level)`. */
        fun reactionFor(level: Int): MemoryReaction = when {
            level >= BACKGROUND -> MemoryReaction(signal = false, trim = CacheTrimLevelMsg.BACKGROUND)
            level >= UI_HIDDEN -> MemoryReaction(signal = false, trim = null)
            level >= RUNNING_LOW -> MemoryReaction(signal = true, trim = CacheTrimLevelMsg.MEMORY_PRESSURE)
            else -> MemoryReaction(signal = false, trim = null)
        }

        /** Registers the callbacks on the application context once per process. */
        fun installOnce(appContext: Context, hub: EventHub, active: () -> Boolean, trim: (CacheTrimLevelMsg) -> Unit) {
            if (installed.compareAndSet(false, true)) appContext.registerComponentCallbacks(MemorySignals(hub, active, trim))
        }
    }
}
