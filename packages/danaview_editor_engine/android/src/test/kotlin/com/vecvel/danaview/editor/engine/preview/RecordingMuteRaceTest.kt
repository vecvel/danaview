// OWNER: AND-10
//
// INT-07 review D1: a voice recording that starts while a preview session is still opening mutes a
// session whose backend has not been opened yet. The contingency backend must store the flag (its
// open applies it) instead of reaching for its host, and the manager's mute fan-out must survive a
// failing session: before the fix the throw landed on danaview-preview's looper and killed the app.

package com.vecvel.danaview.editor.engine.preview

import android.content.ContextWrapper
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.core.MainScheduler
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingMuteRaceTest {
    // ---- the contingency backend before open ----

    @Test
    fun contingencyMuteBeforeOpenIsStoredAndAppliedByOpen() = withSdkInt(29) {
        val backend = ContingencyPreviewBackend()
        // Before the fix each of these read the unset `host` (UninitializedPropertyAccessException).
        backend.setMuted(true)
        backend.setRenderSize(640, 360)
        backend.setUseProxies(true)
        backend.trim(CacheTrimLevelMsg.MEMORY_PRESSURE)
        assertTrue(backend.mutedForNewEngine)

        var opened: Result<Unit>? = null
        backend.open(UnusedHost) { opened = it }
        assertTrue("open completes", opened?.isSuccess == true)
        // No native shim on the JVM: open plays through the stills delegate; the stored flag is
        // what open applies to a new engine (and to the delegate) and stays set.
        assertTrue(backend.usesStillsFallback)
        assertTrue(backend.mutedForNewEngine)

        // Unmute after open restores the gain path.
        backend.setMuted(false)
        assertFalse(backend.mutedForNewEngine)
    }

    // ---- the manager's fan-out ----

    // A real PreviewSession needs EGL and a ContentResolver (not on the JVM), so the fan-out the
    // manager runs on danaview-preview (`PreviewSessionManager.eachGuarded`, used by
    // `setRecordingMuted` and by the re-mute after an open) is driven over the sessions' backends.

    @Test
    fun aFailingSessionDoesNotStopTheMuteFanOutOrReachTheLane() {
        val failing = MuteBackend(throwOnMute = true)
        val healthy = MuteBackend(throwOnMute = false)
        val preview = QueueLane(LaneSpec.PREVIEW)
        fun fanOut(muted: Boolean) = preview.execute {
            PreviewSessionManager.eachGuarded(listOf<PreviewBackend>(failing, healthy), "recording mute") { it.setMuted(muted) }
        }

        fanOut(true)
        preview.drain() // before the fix the throw escaped onto the lane's looper
        assertEquals(listOf(true), failing.mutes)
        assertEquals("the session after the failing one is still muted", listOf(true), healthy.mutes)

        fanOut(false)
        preview.drain()
        assertEquals(listOf(true, false), failing.mutes)
        assertEquals(listOf(true, false), healthy.mutes)
    }

    @Test
    fun theManagerRecordsTheMuteForSessionsOpenedLater() {
        val lanes = LaneSpec.entries.associateWith { QueueLane(it) }
        val ctx = EngineContext(ContextWrapper(null), EngineThreads(QueueMain()) { lanes.getValue(it) })
        val manager = PreviewSessionManager(ctx)
        manager.setRecordingMuted(true)
        lanes.getValue(LaneSpec.PREVIEW).drain()
        assertTrue(manager.recordingMuted)
        manager.setRecordingMuted(false)
        lanes.getValue(LaneSpec.PREVIEW).drain()
        assertFalse(manager.recordingMuted)
    }

    // ---- fakes ----

    /** A backend whose mute fails (as the contingency backend did before open) or records. */
    private class MuteBackend(private val throwOnMute: Boolean) : PreviewBackend {
        val mutes = mutableListOf<Boolean>()
        override val name = "mute-fake"
        override val drawsOnSurface = false
        override val exactSeekTimeoutMs = 1_000L
        override fun open(host: PreviewBackendHost, done: Completion<Unit>) = done.succeed(Unit)
        override fun rebuild(plan: RenderPlan, done: Completion<Unit>) = done.succeed(Unit)
        override fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>) = done.succeed(Unit)
        override fun detachSurface(done: Completion<Unit>) = done.succeed(Unit)
        override fun play(fromFrame: Long, loop: FrameRange?, done: Completion<Unit>) = done.succeed(Unit)
        override fun pause(done: Completion<Long>) = done.succeed(0L)
        override fun seek(k: Long, exact: Boolean, done: Completion<Unit>) = done.succeed(Unit)
        override fun setRenderSize(width: Int, height: Int) = Unit
        override fun setUseProxies(on: Boolean) = Unit
        override fun capture(done: Completion<PausedFrameRenderer.Captured>) = Unit
        override fun trim(level: CacheTrimLevelMsg) = Unit
        override fun suspendForExport(done: Completion<Unit>) = done.succeed(Unit)
        override fun resumeAfterExport(done: Completion<Unit>) = done.succeed(Unit)
        override fun release(done: Completion<Unit>) = done.succeed(Unit)
        override fun setMuted(muted: Boolean) {
            mutes.add(muted)
            if (throwOnMute) throw UninitializedPropertyAccessException("lateinit property host has not been initialized")
        }
    }

    /** A queue-backed lane. */
    private class QueueLane(override val spec: LaneSpec) : Lane {
        private val queue = ArrayDeque<Runnable>()
        override val looper: Looper? = null
        override val handler: Handler? = null
        override fun execute(command: Runnable) {
            queue.addLast(command)
        }
        override fun isCurrentThread(): Boolean = false
        override fun quit() = Unit
        fun drain() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }

    /** A main scheduler that never runs its tasks. */
    private class QueueMain : MainScheduler {
        override fun execute(command: Runnable) = Unit
        override fun postDelayed(task: Runnable, delayMs: Long): Cancellable = Cancellable { }
        override fun nowMs(): Long = 0L
        override fun isCurrentThread(): Boolean = false
    }

    /** A host the fallback path only stores (the contingency backend's open below the shim). */
    private object UnusedHost : PreviewBackendHost {
        override val sessionId: String = "pv_test"
        override val ctx: EngineContext get() = error("unused")
        override val snapshot: AtomicReference<ParamSnapshot> get() = error("unused")
        override val renderer: PausedFrameRenderer get() = error("unused")
        override val scheduler: DebounceScheduler get() = error("unused")
        override val previewLane: Lane get() = error("unused")
        override val frameCount: Long = 0
        override val useProxies: Boolean = false
        override fun frameDisplayed(k: Long) = Unit
        override fun frameDropped(k: Long) = Unit
        override fun stalled() = Unit
        override fun recovered() = Unit
        override fun ended(k: Long) = Unit
        override fun failed(error: Throwable) = Unit
    }

    private companion object {
        /**
         * Runs [block] with `Build.VERSION.SDK_INT` = [sdk]. The JVM stubs report 0, which would skip
         * the API 29 engine path the race happens on. Restored afterwards.
         */
        fun withSdkInt(sdk: Int, block: () -> Unit) {
            // sun.misc.Unsafe through reflection: the unit-test compile classpath is android.jar.
            val field = Build.VERSION::class.java.getField("SDK_INT")
            val unsafeClass = Class.forName("sun.misc.Unsafe")
            val unsafe = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
            val base = unsafeClass.getMethod("staticFieldBase", java.lang.reflect.Field::class.java).invoke(unsafe, field)
            val offset = unsafeClass.getMethod("staticFieldOffset", java.lang.reflect.Field::class.java).invoke(unsafe, field) as Long
            val getInt = unsafeClass.getMethod("getInt", Any::class.java, Long::class.javaPrimitiveType)
            val putInt = unsafeClass.getMethod("putInt", Any::class.java, Long::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            val old = getInt.invoke(unsafe, base, offset) as Int
            putInt.invoke(unsafe, base, offset, sdk)
            try {
                assertEquals(sdk, Build.VERSION.SDK_INT)
                block()
            } finally {
                putInt.invoke(unsafe, base, offset, old)
            }
        }
    }
}
